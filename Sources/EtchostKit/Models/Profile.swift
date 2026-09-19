import Darwin
import Foundation

/// 구조화 hosts 항목. Phase1 MVP: ip/domain/comment/isEnabled만 지원.
/// 여러 도메인(한 줄 다중 호스트)은 Phase2에서 `[String]` 확장 예정 — 지금은 두 번째 토큰 이후를 단일 domain으로 취급하지 않고 거부하지 않음(첫 공백 분리 후 나머지를 domain+comment 파싱).
public struct HostEntry: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var ip: String
    public var domain: String
    public var comment: String?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        ip: String,
        domain: String,
        comment: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.ip = ip
        self.domain = domain
        self.comment = comment
        self.isEnabled = isEnabled
    }

    public var line: String {
        var parts = [ip, domain]
        if let comment, !comment.isEmpty {
            parts.append("# \(comment)")
        }
        let text = parts.joined(separator: "\t")
        return isEnabled ? text : "# disabled: \(text)"
    }

    // MARK: - 구조화 편집 검증/유틸

    /// IP 검증: IPv4(옥텟 0–255) 또는 IPv6(inet_pton 표준 검사)면 true.
    public static func isValidIP(_ ip: String) -> Bool {
        let t = ip.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.contains(":") {
            return t.withCString { cstr in
                var addr = in6_addr()
                return inet_pton(AF_INET6, cstr, &addr) == 1
            }
        }
        let octets = t.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { part in
            guard let v = UInt8(String(part)), String(v) == part else { return false }
            return true
        }
    }

    /// 도메인(호스트) 형식 검증: ASCII만, 공백 없음, 영문/숫자/하이픈/언더스코어/점/별표만 허용.
    public static func isWellFormedDomain(_ domain: String) -> Bool {
        let t = domain.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return t.allSatisfy { ch in ch.isASCII && (ch.isLetter || ch.isNumber || "-_.*".contains(ch)) }
    }

    /// 도메인 입력 정제: 한글 등 비-ASCII 문자를 즉시 제거해 입력 자체를 차단.
    public static func sanitizedDomain(_ raw: String) -> String {
        raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.*".contains($0)) }
    }

    /// IP 입력 정제: 숫자/점/콜론/16진(IPv6)만 남김.
    public static func sanitizedIP(_ raw: String) -> String {
        raw.filter { $0.isASCII && ($0.isNumber || ".:abcdefABCDEF".contains($0)) }
    }

    /// 붙여넣기 "ip host #comment" (탭/공백 혼용) → 세 필드로 분할. 파싱 불가면 nil.
    public struct PastedEntry: Equatable, Sendable {
        public var ip: String
        public var domain: String
        public var comment: String?
    }

    public static func parsePasted(_ text: String) -> PastedEntry? {
        var working = text.trimmingCharacters(in: .whitespaces)
        if working.hasPrefix("# disabled:") {
            working = String(working.dropFirst("# disabled:".count))
        }
        var comment: String?
        if let hashIdx = working.firstIndex(of: "#") {
            comment = String(working[working.index(after: hashIdx)...]).trimmingCharacters(in: .whitespaces)
            working = String(working[..<hashIdx]).trimmingCharacters(in: .whitespaces)
        }
        let tokens = working.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 2 else { return nil }
        let ip = String(tokens[0])
        let domain = tokens[1...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty, !domain.isEmpty else { return nil }
        return PastedEntry(
            ip: ip,
            domain: domain,
            comment: comment?.isEmpty == true ? nil : comment
        )
    }

    /// 한 줄 파싱. 빈 줄·순수 주석(#)은 nil. `# disabled:` 접두는 isEnabled=false로 복원.
    public static func parse(_ line: String) -> HostEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var working = trimmed
        var isEnabled = true
        if working.hasPrefix("# disabled:") {
            isEnabled = false
            working = String(working.dropFirst("# disabled:".count)).trimmingCharacters(in: .whitespaces)
        } else if working.hasPrefix("#") {
            return nil
        }
        guard !working.isEmpty else { return nil }

        var comment: String?
        var content = working
        if let hashIdx = working.firstIndex(of: "#") {
            comment = String(working[working.index(after: hashIdx)...]).trimmingCharacters(in: .whitespaces)
            content = String(working[..<hashIdx]).trimmingCharacters(in: .whitespaces)
        }

        let components = content.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .flatMap { $0.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true) }
        guard components.count >= 2 else { return nil }
        let ip = String(components[0]).trimmingCharacters(in: .whitespaces)
        let domain = String(components[1...].joined(separator: " ")).trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty, !domain.isEmpty else { return nil }

        return HostEntry(
            ip: ip,
            domain: domain,
            comment: comment?.isEmpty == true ? nil : comment,
            isEnabled: isEnabled
        )
    }

    /// 여러 줄 텍스트 → entries. 무효 줄 번호 반환(에디터 하이라이트용).
    public static func parseAll(_ text: String) -> (entries: [HostEntry], invalidLines: [Int]) {
        var entries: [HostEntry] = []
        var invalid: [Int] = []
        for (idx, raw) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || (trimmed.hasPrefix("#") && !trimmed.hasPrefix("# disabled:")) { continue }
            if let entry = HostEntry.parse(raw) {
                entries.append(entry)
            } else {
                invalid.append(idx + 1)
            }
        }
        return (entries, invalid)
    }

    public static func text(from entries: [HostEntry]) -> String {
        entries.map(\.line).joined(separator: "\n")
    }

    /// 반영된 hosts 텍스트를 표(팝오버)용 행으로 파싱. 그룹(# Profile / # Fragment / 기본 loopback) 추적.
    public static func tableRows(from text: String) -> [HostsTableRow] {
        var rows: [HostsTableRow] = []
        var group = Loc.str("hosts.group.baseline")
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("# Profile:") || trimmed.hasPrefix("# Fragment:") {
                group = trimmed
                continue
            }
            if trimmed.hasPrefix("#") && !trimmed.hasPrefix("# disabled:") { continue }
            guard let entry = HostEntry.parse(raw) else { continue }
            rows.append(HostsTableRow(
                ip: entry.ip,
                host: entry.domain,
                comment: entry.comment ?? "",
                isEnabled: entry.isEnabled,
                group: group
            ))
        }
        return rows
    }
}

/// 메뉴바 팝오버 표에 표시할 hosts 행.
public struct HostsTableRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ip: String
    public let host: String
    public let comment: String
    public let isEnabled: Bool
    public let group: String

    public init(
        id: UUID = UUID(),
        ip: String,
        host: String,
        comment: String = "",
        isEnabled: Bool = true,
        group: String
    ) {
        self.id = id
        self.ip = ip
        self.host = host
        self.comment = comment
        self.isEnabled = isEnabled
        self.group = group
    }
}

/// 명명된 /etc/hosts 설정. 본문 entries + 토글된 프래그먼트를 합성.
/// 적용 필요 여부는 `Composer.fingerprint` 대 `appliedHash` 비교로 판정 (AppModel 경유).
public struct Profile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var entries: [HostEntry]
    public var fragmentIDs: [UUID]
    public var order: Int
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var appliedAt: Date?
    public var appliedHash: String?

    public init(
        id: UUID = UUID(),
        name: String,
        entries: [HostEntry] = [],
        fragmentIDs: [UUID] = [],
        order: Int = 0,
        isActive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        appliedAt: Date? = nil,
        appliedHash: String? = nil
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.fragmentIDs = fragmentIDs
        self.order = order
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.appliedAt = appliedAt
        self.appliedHash = appliedHash
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, entries, fragmentIDs, order, isActive, createdAt, updatedAt, appliedAt, appliedHash
    }

    /// 구버전 profiles.json(fragmentIDs 없음) 마이그레이션: 키가 없으면 빈 배열.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        entries = try container.decode([HostEntry].self, forKey: .entries)
        fragmentIDs = try container.decodeIfPresent([UUID].self, forKey: .fragmentIDs) ?? []
        order = try container.decode(Int.self, forKey: .order)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        appliedAt = try container.decodeIfPresent(Date.self, forKey: .appliedAt)
        appliedHash = try container.decodeIfPresent(String.self, forKey: .appliedHash)
    }

    public var enabledCount: Int { entries.filter(\.isEnabled).count }

    /// 본문 entries만의 해시 (참조 무결성용; stale 판정은 fingerprint 사용).
    public var currentHash: String {
        var hasher = Hasher()
        hasher.combine(entries.map { "\($0.ip) \($0.domain) \($0.comment ?? "") \($0.isEnabled)" }.joined(separator: "\n"))
        return String(hasher.finalize(), radix: 16)
    }

    public mutating func markApplied(fingerprint: String) {
        appliedAt = Date()
        appliedHash = fingerprint
        updatedAt = Date()
    }

    public mutating func updateName(_ newName: String) {
        name = newName
        updatedAt = Date()
    }

    public mutating func updateEntries(_ newEntries: [HostEntry]) {
        entries = newEntries
        updatedAt = Date()
    }

    public mutating func toggleFragment(_ fragmentID: UUID) {
        if fragmentIDs.contains(fragmentID) {
            fragmentIDs.removeAll { $0 == fragmentID }
        } else {
            fragmentIDs.append(fragmentID)
        }
        updatedAt = Date()
    }
}
