import Foundation

public enum EtchostError: Error, Sendable, Equatable {
    case profileNotFound(UUID)
    case fragmentNotFound(UUID)
    case invalidHostEntry(String)
    case duplicateProfileName(String)
    case duplicateFragmentName(String)
    case cannotDeleteActiveProfile
    case applyFailed(String)
    case dnsFlushFailed(String)
    case backupFailed(String)
    case ioError(String)
    case permissionDenied
    case unknown(String)

    public var code: String {
        switch self {
        case .profileNotFound: return "E-MAC-HOSTS-1001"
        case .fragmentNotFound: return "E-MAC-HOSTS-1002"
        case .invalidHostEntry: return "E-MAC-HOSTS-2001"
        case .duplicateProfileName: return "E-MAC-HOSTS-2002"
        case .duplicateFragmentName: return "E-MAC-HOSTS-2003"
        case .cannotDeleteActiveProfile: return "E-MAC-HOSTS-3001"
        case .applyFailed: return "E-MAC-HOSTS-4001"
        case .dnsFlushFailed: return "E-MAC-HOSTS-4002"
        case .backupFailed: return "E-MAC-HOSTS-4003"
        case .ioError: return "E-MAC-HOSTS-8001"
        case .permissionDenied: return "E-MAC-HOSTS-9001"
        case .unknown: return "E-MAC-HOSTS-9999"
        }
    }
}
