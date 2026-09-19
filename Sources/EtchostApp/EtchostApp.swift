import SwiftUI

@main
struct EtchostApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Etchost", id: "main") {
            ContentView()
                .environmentObject(AppModel.shared)
                .frame(minWidth: 760, minHeight: 480)
                .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                    openWindow(id: "main")
                }
        }
        .defaultSize(width: 920, height: 600)

        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
        }
    }
}

/// 메인 창 제외 상태 아이템 및 팝오버를 소유. LSUIElement 앱 수명 유지.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(model: AppModel.shared)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("상태") {
                Text(model.activeProfile.map { "활성: \($0.name)" } ?? "프로필 없음")
                if let backup = model.lastBackupURL {
                    Text("최근 백업: \(backup.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("백업 위치: ~/Library/Application Support/Etchost/Backups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 220)
    }
}
