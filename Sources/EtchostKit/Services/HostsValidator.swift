import Foundation

/// 합성 전 검증 이슈. 저장을 막지 않고 경고 목록으로 노출한다.
/// 형식 오류(invalidIP/invalidDomain)는 에디터가 이미 저장을 막으므로,
/// 여기서의 핵심은 중복·충돌·하이잭 의심 탐지다.
public struct ValidationIssue: Equatable, Sendable, Identifiable {
    public enum Severity: String, Equatable, Sendable {
        case error
        case warning
    }

    public enum Kind: String, Equatable, Sendable {
        case invalidIP
        case invalidDomain
        case duplicateDomain
        case conflictingIP
        case suspiciousRedirect
    }

    public let id: UUID
    public let severity: Severity
    public let kind: Kind
    public let domain: String?
    public let message: String

    public init(severity: Severity, kind: Kind, domain: String?, message: String) {
        self.id = UUID()
        self.severity = severity
        self.kind = kind
        self.domain = domain
        self.message = message
    }

    public static func == (lhs: ValidationIssue, rhs: ValidationIssue) -> Bool {
        lhs.severity == rhs.severity && lhs.kind == rhs.kind && lhs.domain == rhs.domain
            && lhs.message == rhs.message
    }
}

public struct HostsValidator: Sendable {
    /// 비활성(`# disabled:`) 항목은 중복·충돌·의심 검사에서 제외한다.
    /// 하이잭 의심 판정용 유명 도메인. 서브도메인 포함 매칭한다.
    public static let wellKnownDomains: Set<String> = [
        "google.com", "youtube.com", "facebook.com", "instagram.com",
        "apple.com", "icloud.com", "github.com", "microsoft.com",
        "naver.com", "daum.net", "kakao.com", "coupang.com",
        "amazon.com", "cloudflare.com", "openai.com"
    ]

    public init() {}

    /// 구조화 항목 목록 검증. 도메인 비교는 소문자 정규화.
    public func validate(entries: [HostEntry]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var seenEnabled: [String: [String]] = [:]

        for entry in entries {
            if !HostEntry.isValidIP(entry.ip) {
                issues.append(ValidationIssue(
                    severity: .error,
                    kind: .invalidIP,
                    domain: entry.domain,
                    message: Loc.str("validator.invalidIP", entry.ip)))
            }
            if !HostEntry.isWellFormedDomain(entry.domain) {
                issues.append(ValidationIssue(
                    severity: .error,
                    kind: .invalidDomain,
                    domain: entry.domain,
                    message: Loc.str("validator.invalidDomain", entry.domain)))
            }
            guard entry.isEnabled else { continue }
            let key = entry.domain.lowercased()
            seenEnabled[key, default: []].append(entry.ip)
        }

        for (domain, ips) in seenEnabled {
            let unique = Set(ips)
            if unique.count > 1 {
                issues.append(ValidationIssue(
                    severity: .warning,
                    kind: .conflictingIP,
                    domain: domain,
                    message: Loc.str("validator.conflictingIP", domain, unique.sorted().joined(separator: ", "))))
            } else if ips.count > 1 {
                issues.append(ValidationIssue(
                    severity: .warning,
                    kind: .duplicateDomain,
                    domain: domain,
                    message: Loc.str("validator.duplicateDomain", domain, ips.count)))
            }
            if isSuspicious(domain: domain, ips: unique) {
                issues.append(ValidationIssue(
                    severity: .warning,
                    kind: .suspiciousRedirect,
                    domain: domain,
                    message: Loc.str("validator.suspiciousRedirect", domain)))
            }
        }
        return issues.sorted {
            if $0.severity != $1.severity { return $0.severity == .error }
            return ($0.domain ?? "") < ($1.domain ?? "")
        }
    }

    /// 합성 텍스트 검증. 파싱 불가 줄도 error 이슈로 포함한다.
    public func validate(text: String) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let (entries, invalid) = HostEntry.parseAll(text)
        for line in invalid {
            issues.append(ValidationIssue(
                severity: .error,
                kind: .invalidDomain,
                domain: nil,
                message: Loc.str("validator.invalidLine", line)))
        }
        return issues + validate(entries: entries)
    }

    private func isSuspicious(domain: String, ips: Set<String>) -> Bool {
        let lowered = domain.lowercased()
        let known = Self.wellKnownDomains.contains { lowered == $0 || lowered.hasSuffix("." + $0) }
        guard known else { return false }
        // 0.0.0.0 단일 매핑은 차단리스트 표준 관례(의도적 차단)이므로 제외.
        if ips == ["0.0.0.0"] { return false }
        return ips.contains { isNonRoutable($0) }
    }

    /// 루프백·사설·0.0.0.0이면 true. 유명 도메인이 여기로 향하면 차단이든 하이잭이든 확인이 필요하다.
    private func isNonRoutable(_ ip: String) -> Bool {
        let t = ip.trimmingCharacters(in: .whitespaces)
        if t == "0.0.0.0" || t == "::" { return true }
        if t.hasPrefix("127.") || t == "::1" { return true }
        if t.hasPrefix("10.") || t.hasPrefix("192.168.") { return true }
        if t.hasPrefix("172.") {
            let parts = t.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        if t.lowercased().hasPrefix("fc") || t.lowercased().hasPrefix("fd") { return true }
        if t.lowercased().hasPrefix("fe80:") { return true }
        return false
    }
}
