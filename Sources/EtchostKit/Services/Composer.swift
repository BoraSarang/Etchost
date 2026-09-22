import CryptoKit
import Foundation

extension SHA256 {
    /// UTF-8 문자열의 SHA-256 16진수 다이제스트.
    static func hex(of string: String) -> String {
        digestHex(SHA256.hash(data: Data(string.utf8)))
    }

    private static func digestHex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 합성기: Profile 본문 + 토글된 프래그먼트 → /etc/hosts 텍스트.
/// Source 합성은 다음 단계에서 `compose(profile:fragments:sources:)`로 확장.
public struct Composer: Sendable {
    public static let shared = Composer()

    private init() {}

    /// 항상 유지되는 기본 loopback 줄 (Apple 기본 hosts와 동일).
    /// 프로필/프래그먼트와 무관하게 강제로 쓰이며, 같은 ip+domain이 본문에 있으면 중복 제거.
    public static let baselineEntries: [HostEntry] = [
        HostEntry(ip: "127.0.0.1", domain: "localhost"),
        HostEntry(ip: "255.255.255.255", domain: "broadcasthost"),
        HostEntry(ip: "::1", domain: "localhost")
    ]

    /// 프로필이 참조하는 프래그먼트만 order 순으로 병합. 끊긴 참조(삭제된 ID)는 무시.
    public func referencedFragments(profile: Profile, fragments: [Fragment]) -> [Fragment] {
        let ids = Set(profile.fragmentIDs)
        return fragments.filter { ids.contains($0.id) }.sorted { $0.order < $1.order }
    }

    public func compose(profile: Profile, fragments: [Fragment] = []) -> String {
        var lines: [String] = []
        lines.append("# Etchost — Profile: \(profile.name)")
        lines.append("# Generated at \(Date().formatted(date: .abbreviated, time: .shortened))")
        lines.append("")

        let refs = referencedFragments(profile: profile, fragments: fragments)
        var present: Set<String> = []
        for entry in profile.entries {
            present.insert("\(entry.ip) \(entry.domain)")
        }
        for fragment in refs {
            for entry in fragment.entries {
                present.insert("\(entry.ip) \(entry.domain)")
            }
        }

        // 1) 강제 기본 줄: 본문(프로필+프래그먼트)에 이미 있으면 생략
        var writtenBaseline = false
        for entry in Self.baselineEntries {
            if present.contains("\(entry.ip) \(entry.domain)") { continue }
            lines.append(entry.line)
            writtenBaseline = true
        }
        if writtenBaseline {
            lines.append("")
        }

        // 2) 프로필 본문
        lines.append("# Profile: \(profile.name)")
        for entry in profile.entries {
            lines.append(entry.line)
        }

        // 3) 참조 프래그먼트
        if !refs.isEmpty {
            lines.append("")
            lines.append("# Fragments")
            for fragment in refs {
                lines.append("# Fragment: \(fragment.name)")
                for entry in fragment.entries {
                    lines.append(entry.line)
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// stale 판정용 지문. 본문 + 토글 ID + 참조 프래그먼트 내용을 모두 포함 —
    /// 프래그먼트 편집/토글만으로 참조 프로필 전체가 `적용 필요`가 됨.
    /// CryptoKit SHA256로 결정적 — `Hasher`(실행마다 랜덤 시드)와 달리 재시작 후에도 일치해야 한다.
    /// 주의: 해싱 방식이 바뀌면 기존 appliedHash와 1회 불일치 → 전체 stale 후 재 적용 시 재시작에도 유지.
    public func fingerprint(profile: Profile, fragments: [Fragment] = []) -> String {
        var parts: [String] = ["composer:baseline-v3", profile.currentHash]
        parts.append(profile.fragmentIDs.sorted().map(\.uuidString).joined(separator: ","))
        for fragment in referencedFragments(profile: profile, fragments: fragments) {
            parts.append(fragment.id.uuidString)
            for entry in fragment.entries {
                parts.append(contentsOf: [entry.ip, entry.domain, entry.comment ?? "", entry.isEnabled ? "1" : "0"])
            }
        }
        // 필드 경계를 확실히 끊어 연결 공격(ip="a b" 등)을 막는다.
        return SHA256.hex(of: parts.joined(separator: "\u{1E}"))
    }
}
