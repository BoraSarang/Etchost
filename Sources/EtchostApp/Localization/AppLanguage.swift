import Foundation

/// 앱 표시 언어 선택. 시스템 기본값을 따르거나 ko/en을 명시적으로 고정한다.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case ko
    case en

    public var id: String { rawValue }

    /// 선택값을 AppleLanguages에 주입할 ISO 언어 코드 (system이면 nil).
    var appleLanguageCode: String? {
        switch self {
        case .system: return nil
        case .ko: return "ko"
        case .en: return "en"
        }
    }

    var title: String {
        switch self {
        case .system: return L.str("settings.language.system")
        case .ko: return L.str("settings.language.ko")
        case .en: return L.str("settings.language.en")
        }
    }
}
