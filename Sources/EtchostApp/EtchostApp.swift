import EtchostKit
import SwiftUI

@main
struct EtchostApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Etchost", id: "main") {
            ContentView()
                .environmentObject(AppModel.shared)
                .environment(AppSettings.shared)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear {
                    MainWindowOpener.shared.register { id in openWindow(id: id) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                    MainWindowOpener.shared.openMain()
                }
        }
        .defaultSize(width: 920, height: 600)

        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
                .environment(AppSettings.shared)
        }
    }
}

/// 호스트 관리 창 + 상태 아이템 및 팝오버를 소유. LSUIElement 앱 수명 유지.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyOnLaunch()
        statusController = StatusItemController(model: AppModel.shared)
        BackupManager.shared.pruneOldBackups()
        Task {
            await AppSettings.shared.maybeAutoCheckForUpdate()
        }
        Task {
            await AppModel.shared.syncDueRemoteFragments()
        }
        if !AppSettings.shared.openHostManagerAtLaunch {
            // SwiftUI Window 생성 타이밍과 레이스 → 즉시 1회 + 지연 재시도로 닫기 보장.
            // (생성 전이면 first가 nil이라 no-op이 되던 P1-1 수정)
            DispatchQueue.main.async {
                Self.closeMainWindowIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Self.closeMainWindowIfNeeded()
            }
        }
    }

    private static func closeMainWindowIfNeeded() {
        NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.close()
    }

    /// 마지막 창을 닫아도 메뉴바 상주를 위해 종료하지 않는다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock 표시 상태에서 Dock 클릭 시 호스트 관리 창을 열거나 맨 앞으로 가져온다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowOpener.shared.openMain()
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        TunnelManager.shared.networkCleanup()
    }
}
