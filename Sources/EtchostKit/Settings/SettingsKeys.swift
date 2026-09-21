import Foundation

/// UserDefaults 키 상수. App(설정 UI)과 Kit(터널/백업/스캔)가 공유하는 단일 소스.
public enum SettingsKeys {
    public static let showDockIcon = "settings.showDockIcon"
    public static let autoStartTunnelsAtLaunch = "settings.autoStartTunnelsAtLaunch"
    public static let autoRebookTunnels = "settings.autoRebookTunnels"
    public static let customScanPorts = "settings.customScanPorts"
    public static let defaultScanPorts = "settings.defaultScanPorts"
    public static let openHostManagerAtLaunch = "settings.openHostManagerAtLaunch"
    public static let updateCheckFrequency = "settings.updateCheckFrequency"
    public static let updateLastChecked = "settings.updateLastChecked"
    public static let backupRetention = "settings.backupRetention"
    public static let language = "settings.language"
    /// 원격 프래그먼트 자동 동기화 마스터 스위치 (끄면 수동 동기화만).
    public static let remoteSyncAutoSync = "settings.remoteSyncAutoSync"

    public static let backupRetentionDefault = 20
    public static let backupRetentionMin = 1
    public static let backupRetentionMax = 100
}

/// 사용자 지정 포트 목록 파서. 쉼표/공백/세미콜론 구분, 1–65535만 유효.
/// 단일 포트(80) + 대역(8000-8100) 혼합 지원. 예: "80, 443, 8000-8010".
public enum PortList {
    public static let maxRangeSpan = 65535

    /// 문자열을 유효 포트 목록으로 변환. 유효하지 않은 토큰은 무시(중복 제거 + 오름차순).
    public static func parse(_ input: String, allowed: ClosedRange<Int> = 1...65535) -> [Int] {
        var seen: Set<Int> = []
        var ports: [Int] = []
        for token in input.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            guard let expanded = expand(token: String(token), allowed: allowed) else { continue }
            for port in expanded where seen.insert(port).inserted {
                ports.append(port)
            }
        }
        return ports.sorted()
    }

    /// 입력 중 유효하지 않은 토큰이 하나라도 있으면 true.
    public static func hasInvalidToken(_ input: String, allowed: ClosedRange<Int> = 1...65535) -> Bool {
        let tokens = input.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        // 빈 입력은 유효(기본 포트 의미)
        for raw in tokens where expand(token: String(raw), allowed: allowed) == nil { return true }
        return false
    }

    /// 단일 토큰 전개. 유효하면 포트 배열, 무효면 nil.
    /// "80" → [80], "8000-8010" → [8000...8010]. 역범위/범위초과/비숫자는 nil.
    private static func expand(token: String, allowed: ClosedRange<Int>) -> [Int]? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains("-") {
            let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2,
                  let lo = Int(parts[0]), let hi = Int(parts[1]),
                  allowed.contains(lo), allowed.contains(hi),
                  lo <= hi,
                  hi - lo <= maxRangeSpan
            else { return nil }
            return Array(lo...hi)
        }
        guard let value = Int(trimmed), allowed.contains(value) else { return nil }
        return [value]
    }
}
