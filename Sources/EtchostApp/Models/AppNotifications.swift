import Foundation

/// 앱 전역 앱 간 (메뉴바 ↔ 창) 통신용 알림 이름.
public extension Notification.Name {
    static let openMainWindow = Notification.Name("etchost.openMainWindow")
    static let hostsApplied = Notification.Name("etchost.hostsApplied")
    static let showUpdateSheet = Notification.Name("etchost.showUpdateSheet")
}
