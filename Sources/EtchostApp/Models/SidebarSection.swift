import Foundation

/// 사이드바 상단 섹션 탭.
public enum SidebarSection: String, CaseIterable, Identifiable {
    case profiles
    case fragments
    case network

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .profiles: return L.str("sidebar.profiles")
        case .fragments: return L.str("sidebar.fragments")
        case .network: return L.str("sidebar.network")
        }
    }

    public var systemImage: String {
        switch self {
        case .profiles: return "square.stack.3d.up"
        case .fragments: return "puzzlepiece"
        case .network: return "network"
        }
    }
}
