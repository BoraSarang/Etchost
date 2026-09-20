import Foundation

/// SwiftUI `openWindow(id:)` 클로저를 창 외부(메뉴바 팝오버, Dock 재오픈)에서도
/// 호출할 수 있게 보관. 창이 닫히면 Window 내부 `onReceive`가 사라지므로,
/// 열려 있을 때 등록된 클로저를 재사용한다.
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()

    private var opener: ((String) -> Void)?

    private init() {}

    func register(_ opener: @escaping (String) -> Void) {
        self.opener = opener
    }

    func openMain() {
        opener?("main")
    }
}
