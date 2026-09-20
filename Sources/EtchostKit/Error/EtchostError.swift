import Foundation

public enum EtchostError: Error, LocalizedError, Sendable, Equatable {
    case profileNotFound(UUID)
    case fragmentNotFound(UUID)
    case tunnelNotFound(UUID)
    case invalidHostEntry(String)
    case duplicateProfileName(String)
    case duplicateFragmentName(String)
    case duplicateTunnelLabel(String)
    case cannotDeleteActiveProfile
    case applyFailed(String)
    case dnsFlushFailed(String)
    case backupFailed(String)
    case ioError(String)
    case permissionDenied
    case cloudflaredNotInstalled
    case brewNotInstalled
    case scanFailed(String)
    case noPublishedRelease
    case unknown(String)

    public var code: String {
        switch self {
        case .profileNotFound: return "E-MAC-HOSTS-1001"
        case .fragmentNotFound: return "E-MAC-HOSTS-1002"
        case .tunnelNotFound: return "E-MAC-HOSTS-1003"
        case .invalidHostEntry: return "E-MAC-HOSTS-2001"
        case .duplicateProfileName: return "E-MAC-HOSTS-2002"
        case .duplicateFragmentName: return "E-MAC-HOSTS-2003"
        case .duplicateTunnelLabel: return "E-MAC-HOSTS-2004"
        case .cannotDeleteActiveProfile: return "E-MAC-HOSTS-3001"
        case .applyFailed: return "E-MAC-HOSTS-4001"
        case .dnsFlushFailed: return "E-MAC-HOSTS-4002"
        case .backupFailed: return "E-MAC-HOSTS-4003"
        case .ioError: return "E-MAC-HOSTS-8001"
        case .permissionDenied: return "E-MAC-HOSTS-9001"
        case .cloudflaredNotInstalled: return "E-MAC-HOSTS-9002"
        case .brewNotInstalled: return "E-MAC-HOSTS-9003"
        case .scanFailed: return "E-MAC-HOSTS-9004"
        case .noPublishedRelease: return "E-MAC-HOSTS-9005"
        case .unknown: return "E-MAC-HOSTS-9999"
        }
    }

    /// `.localizedDescription` 사용처를 위해 로컬라이즈드 메시지 제공 (AppModel.describe와 동일).
    public var errorDescription: String? {
        switch self {
        case .duplicateProfileName(let name): return Loc.str("error.duplicateProfileName", name)
        case .duplicateFragmentName(let name): return Loc.str("error.duplicateFragmentName", name)
        case .duplicateTunnelLabel(let name): return Loc.str("error.duplicateTunnelLabel", name)
        case .cannotDeleteActiveProfile: return Loc.str("error.cannotDeleteActiveProfile")
        case .profileNotFound: return Loc.str("error.profileNotFound")
        case .fragmentNotFound: return Loc.str("error.fragmentNotFound")
        case .tunnelNotFound: return Loc.str("error.tunnelNotFound")
        case .cloudflaredNotInstalled: return Loc.str("error.cloudflaredNotInstalled")
        case .brewNotInstalled: return Loc.str("error.brewNotInstalled")
        case .scanFailed(let msg): return Loc.str("error.scanFailed", msg)
        case .noPublishedRelease: return Loc.str("error.noPublishedRelease")
        case .permissionDenied: return Loc.str("error.permissionDenied")
        case .applyFailed(let msg): return Loc.str("error.applyFailed", msg)
        case .dnsFlushFailed(let msg): return Loc.str("error.dnsFlushFailed", msg)
        case .backupFailed(let msg): return Loc.str("error.backupFailed", msg)
        case .ioError(let msg): return Loc.str("error.ioError", msg)
        case .invalidHostEntry(let msg): return Loc.str("error.invalidHostEntry", msg)
        case .unknown(let msg): return Loc.str("error.unknown", msg)
        }
    }
}
