import Foundation

/// UserDefaults 키 상수. App(설정 UI)과 Kit(터널/백업/스캔)가 공유하는 단일 소스.
public enum SettingsKeys {
    public static let showDockIcon = "settings.showDockIcon"
    public static let autoStartTunnelsAtLaunch = "settings.autoStartTunnelsAtLaunch"
    public static let autoRebookTunnels = "settings.autoRebookTunnels"
    public static let customScanPorts = "settings.customScanPorts"
    public static let openHostManagerAtLaunch = "settings.openHostManagerAtLaunch"
    public static let updateCheckFrequency = "settings.updateCheckFrequency"
    public static let updateLastChecked = "settings.updateLastChecked"
    public static let backupRetention = "settings.backupRetention"
    public static let language = "settings.language"

    public static let backupRetentionDefault = 20
    public static let backupRetentionMin = 1
    public static let backupRetentionMax = 100
}

/// 사용자 지정 포트 목록 파서. 쉼표/공백/세미콜론 구분, 1–65535만 유효.
public enum PortList {
    /// 문자열을 유효 포트 목록으로 변환. 유효하지 않은 토큰은 무시(중복 제거 + 오름차순).
    public static func parse(_ input: String, allowed: ClosedRange<Int> = 1...65535) -> [Int] {
        var seen: Set<Int> = []
        var ports: [Int] = []
        for token in input.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            guard let value = Int(token), allowed.contains(value), seen.insert(value).inserted else {
                continue
            }
            ports.append(value)
        }
        return ports.sorted()
    }

    /// 입력 중 유효하지 않은 토큰이 하나라도 있으면 true.
    public static func hasInvalidToken(_ input: String, allowed: ClosedRange<Int> = 1...65535) -> Bool {
        for token in input.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            guard let value = Int(token), allowed.contains(value) else { return true }
        }
        return false
    }
}
