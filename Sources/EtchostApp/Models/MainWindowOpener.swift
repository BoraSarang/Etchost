import AppKit
import Foundation

/// SwiftUI `openWindow(id:)` 클로저를 창 외부(메뉴바 팝오버, Dock 재오픈)에서도
/// 호출할 수 있게 보관. 창이 닫히면 Window 내부 `onReceive`가 사라지므로,
/// 열려 있을 때 등록된 클로저 + NSApp 윈도우 직접 전면화 폴백을 병행한다.
/// (LSUIElement=Y인 메뉴바 상주 앱에서 닫힌 창 재오픈이 조용히 무시되던 P0 수정)
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()

    private var opener: ((String) -> Void)?

    private init() {}

    func register(_ opener: @escaping (String) -> Void) {
        self.opener = opener
    }

    func openMain() {
        // 1. 이미 존재하는 창이 있으면 직접 앞으로 (stale opener 무관).
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 2. 없으면 SwiftUI에 생성 요청.
        opener?("main")
        // 3. openWindow는 비동기 생성 → 다음 런루프에 활성화 + 전면화 재시도.
        //    opener 미등록(nil) 상태에서도 기존 창이 늦게 생기면 잡는다.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                NSLog("[Etchost] MainWindowOpener: main window not found after open request (opener=%@)", self.opener == nil ? "nil" : "set")
            }
        }
    }
}
