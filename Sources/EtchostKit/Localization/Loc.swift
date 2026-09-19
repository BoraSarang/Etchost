import Foundation

/// EtchostKit 로컬라이즈드 문자열 헬퍼.
/// ko.lproj/en.lproj의 Localizable.strings에서 조회하며, `swift test`(SPM)에서는
/// `Bundle.module`, Xcode 빌드에서는 EtchostKit.framework 번들 대상으로 동작한다.
public enum Loc {
    /// 팟 번들 확보용 마커 클래스 (Xcode 프레임워크 빌드 경로용).
    private final class _LocBundle {}

    private static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: _LocBundle.self)
        #endif
    }

    public static func str(_ key: String, _ args: CVarArg...) -> String {
        let base = bundle.localizedString(forKey: key, value: nil, table: nil)
        guard !args.isEmpty else { return base }
        return String(format: base, locale: Locale.current, arguments: args)
    }
}
