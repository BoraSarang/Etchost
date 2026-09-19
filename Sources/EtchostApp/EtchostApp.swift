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
                .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                    openWindow(id: "main")
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

/// 메인 창 제외 상태 아이템 및 팝오버를 소유. LSUIElement 앱 수명 유지.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyOnLaunch()
        statusController = StatusItemController(model: AppModel.shared)
    }

    func applicationWillTerminate(_ notification: Notification) {
        TunnelManager.shared.networkCleanup()
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(AppSettings.self) private var settings

    private let retentionOptions = [10, 20, 50, 100]
    private static let defaultPortCount = NetworkScanner.commonPorts.count
    @State private var languageChanged = false

    var body: some View {
        Form {
            generalSection
            networkSection
            backupsSection
            statusSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle(L.str("settings.title"))
        .frame(width: 470, height: 660)
    }

    // MARK: - 일반

    private var generalSection: some View {
        Section(L.str("settings.section.general")) {
            Picker(
                L.str("settings.language"),
                selection: Binding(
                    get: { settings.language },
                    set: {
                        settings.setLanguage($0)
                        languageChanged = true
                    }
                )
            ) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.title).tag(lang)
                }
            }

            if languageChanged {
                HStack(spacing: 8) {
                    Text(L.str("settings.language.restartMessage"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L.str("settings.language.restart")) {
                        settings.restartApp()
                    }
                    .controlSize(.small)
                }
            }

            Toggle(
                L.str("settings.loginItem"),
                isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                )
            )
            if let message = settings.launchAtLoginMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle(
                L.str("settings.showDockIcon"),
                isOn: Binding(
                    get: { settings.showDockIcon },
                    set: { settings.setShowDockIcon($0) }
                )
            )
            Text(L.str("settings.showDockIcon.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 네트워크

    private var networkSection: some View {
        Section {
            Toggle(
                L.str("settings.autoStartTunnels"),
                isOn: Binding(
                    get: { settings.autoStartTunnelsAtLaunch },
                    set: { settings.setAutoStartTunnelsAtLaunch($0) }
                )
            )
            Toggle(
                L.str("settings.autoRebook"),
                isOn: Binding(
                    get: { settings.autoRebookTunnels },
                    set: { settings.setAutoRebookTunnels($0) }
                )
            )

            TextField(
                L.str("settings.scanPorts.placeholder"),
                text: Binding(
                    get: { settings.customScanPortsInput },
                    set: { settings.setCustomScanPortsInput($0) }
                )
            )
            .textFieldStyle(.roundedBorder)

            if settings.customPortsHasInvalid {
                Label(L.str("settings.scanPorts.invalid"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let ports = settings.configuredScanPorts {
                Text(L.str("settings.scanPorts.applied", ports.count, ports.map(String.init).joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L.str("settings.scanPorts.default", Self.defaultPortCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L.str("settings.section.network"))
        }
    }

    // MARK: - 백업

    private var backupsSection: some View {
        Section {
            Picker(
                L.str("settings.backupRetention"),
                selection: Binding(
                    get: { settings.backupRetention },
                    set: { settings.setBackupRetention($0) }
                )
            ) {
                ForEach(retentionOptions, id: \.self) { count in
                    Text(L.str("settings.backupRetention.count", count)).tag(count)
                }
            }
            .pickerStyle(.segmented)

            Text(L.str("settings.backup.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(L.str("settings.section.backups"))
        }
    }

    // MARK: - 상태

    private var statusSection: some View {
        Section {
            Text(model.activeProfile.map { L.str("settings.activeProfile", $0.name) } ?? L.str("settings.activeProfile.none"))
            if let backup = model.lastBackupURL {
                Text(L.str("settings.lastBackup", backup.lastPathComponent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(L.str("settings.backupLocation", BackupManager.shared.backupDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L.str("settings.open")) {
                    openBackupFolder()
                }
                .controlSize(.small)
            }
        }
    }

    private func openBackupFolder() {
        let url = BackupManager.shared.backupDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - 정보

    private var aboutSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Etchost")
                        .font(.headline)
                    Text(L.str("settings.about.version", settings.appBundleVersion))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L.str("settings.about.copyright"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)

            if let repo = ReleaseChecker.repositoryURL {
                Link(destination: repo) {
                    Label(L.str("settings.github"), systemImage: "link")
                }
            }
            if let issues = ReleaseChecker.issuesURL {
                Link(destination: issues) {
                    Label(L.str("settings.issues"), systemImage: "exclamationmark.bubble")
                }
            }

            updateCheckRow
        } header: {
            Text(L.str("settings.section.about"))
        }
    }

    @ViewBuilder
    private var updateCheckRow: some View {
        switch settings.updateState {
        case .idle:
            HStack(spacing: 8) {
                Label(L.str("settings.update.check"), systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Button(L.str("settings.update.button")) {
                    Task { await settings.checkForUpdate() }
                }
                .controlSize(.small)
            }
        case .checking:
            HStack(spacing: 8) {
                Label(L.str("settings.update.check"), systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        case .upToDate:
            HStack(spacing: 8) {
                Label(L.str("settings.update.check"), systemImage: "checkmark.circle.fill")
                Spacer()
                Text(L.str("settings.update.upToDate"))
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case let .updateAvailable(tag, htmlURL):
            HStack(spacing: 8) {
                Label(L.str("settings.update.check"), systemImage: "arrow.down.circle.fill")
                Spacer()
                Text(L.str("settings.update.available", tag))
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let url = URL(string: htmlURL) {
                    Link(L.str("settings.update.download"), destination: url)
                        .controlSize(.small)
                }
            }
        case .unavailable(let message):
            HStack(spacing: 8) {
                Label(L.str("settings.update.check"), systemImage: "exclamationmark.triangle.fill")
                Spacer()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L.str("settings.update.retry")) {
                    Task { await settings.checkForUpdate() }
                }
                .controlSize(.small)
            }
        }
    }
}
