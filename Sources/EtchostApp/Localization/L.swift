import Foundation

// swiftlint:disable type_name
/// App 번들 로컬라이즈드 문자열 헬퍼.
/// 앱 번들의 ko.lproj/en.lproj Localizable.strings에서 조회한다.
enum L {
// swiftlint:enable type_name
    static func str(_ key: String, _ args: CVarArg...) -> String {
        let base = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        guard !args.isEmpty else { return base }
        return String(format: base, locale: Locale.current, arguments: args)
    }
}
