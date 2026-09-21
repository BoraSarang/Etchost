import Foundation

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
    /// 대용량 프래그먼트에서도 거대 문자열을 만들지 않고 항목 단위로 해싱한다.
    /// 주의: 해싱 방식 변경으로 기존 appliedHash와 불일치 → 업데이트 1회성 전체 stale (다시 적용 필요).
    public func fingerprint(profile: Profile, fragments: [Fragment] = []) -> String {
        var hasher = Hasher()
        hasher.combine("composer:baseline-v2")
        hasher.combine(profile.currentHash)
        hasher.combine(profile.fragmentIDs.sorted().map(\.uuidString).joined(separator: ","))
        for fragment in referencedFragments(profile: profile, fragments: fragments) {
            hasher.combine(fragment.id.uuidString)
            for entry in fragment.entries {
                hasher.combine(entry.ip)
                hasher.combine(entry.domain)
                hasher.combine(entry.comment ?? "")
                hasher.combine(entry.isEnabled)
            }
        }
        return String(hasher.finalize(), radix: 16)
    }
}
