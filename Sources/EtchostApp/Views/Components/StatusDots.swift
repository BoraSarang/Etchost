import EtchostKit
import SwiftUI

/// 프로필/터널 상태 점 색상 공통 헬퍼.
/// (MenuBarPopover ↔ ProfileSidebar 중복 dotColor/tunnelStatusColor 통합)
enum StatusDots {
    /// 프로필 활성 + 재적용 필요 여부 → 점 색상.
    static func profile(isActive: Bool, reapply: Bool) -> Color {
        if isActive { return reapply ? .orange : .green }
        return reapply ? .orange.opacity(0.6) : .gray.opacity(0.5)
    }

    /// 터널 상태 → 점 색상.
    static func tunnel(_ status: TunnelStatus) -> Color {
        switch status {
        case .running: return .green
        case .error: return .red
        case .stopped: return .gray.opacity(0.5)
        case .starting, .stopping: return .orange
        @unknown default: return .gray
        }
    }
}
