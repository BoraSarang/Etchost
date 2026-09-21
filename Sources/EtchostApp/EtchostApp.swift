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
            DispatchQueue.main.async {
                NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.close()
            }
        }
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

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(AppSettings.self) private var settings

    private let retentionOptions = [10, 20, 50, 100]
    @State private var languageChanged = false
    @State private var showUpdateSheet = false
    @State private var addPortText = ""
    @State private var addPortError: String?

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
        .sheet(isPresented: $showUpdateSheet) {
            if let update = settings.availableUpdate {
                UpdateAvailableSheet(
                    tag: update.tag,
                    htmlURL: update.htmlURL,
                    notes: update.notes,
                    currentVersion: settings.appBundleVersion
                )
            }
        }
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

            Toggle(
                L.str("settings.openHostManagerAtLaunch"),
                isOn: Binding(
                    get: { settings.openHostManagerAtLaunch },
                    set: { settings.setOpenHostManagerAtLaunch($0) }
                )
            )
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
                Text(L.str("settings.scanPorts.default", settings.defaultScanPorts.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 기본 포트 목록 편집 (삭제 × / 추가 / 복원).
            Text(L.str("settings.scanPorts.defaultsTitle", settings.defaultScanPorts.count))
                .font(.headline)
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 6) {
                ForEach(settings.defaultScanPorts, id: \.self) { port in
                    HStack(spacing: 2) {
                        Text(String(port))
                            .font(.system(.body, design: .monospaced))
                        Button {
                            settings.removeDefaultPort(port)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(String(port))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.gray.opacity(0.15), in: Capsule())
                }
            }
            HStack(spacing: 8) {
                TextField(
                    L.str("settings.scanPorts.addPlaceholder"),
                    text: $addPortText
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { addDefaultPorts() }
                Button(L.str("settings.scanPorts.add")) {
                    addDefaultPorts()
                }
                .controlSize(.small)
                if settings.defaultPortsCustomized {
                    Button(L.str("settings.scanPorts.reset")) {
                        settings.resetDefaultPorts()
                    }
                    .controlSize(.small)
                }
            }
            if let error = addPortError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(L.str("settings.section.network"))
        }
    }

    private func addDefaultPorts() {
        let trimmed = addPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parsed = PortList.parse(trimmed)
        guard !parsed.isEmpty, !PortList.hasInvalidToken(trimmed) else {
            addPortError = L.str("settings.scanPorts.invalid")
            return
        }
        settings.addDefaultPorts(trimmed)
        addPortText = ""
        addPortError = nil
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

            Toggle(
                L.str("settings.remoteSyncAutoSync"),
                isOn: Binding(
                    get: { settings.remoteSyncAutoSync },
                    set: { settings.setRemoteSyncAutoSync($0) }
                )
            )
            Text(L.str("settings.remoteSyncAutoSync.description"))
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
            Picker(
                L.str("settings.update.frequency"),
                selection: Binding(
                    get: { settings.updateCheckFrequency },
                    set: { settings.setUpdateCheckFrequency($0) }
                )
            ) {
                ForEach(AppSettings.UpdateCheckFrequency.allCases) { frequency in
                    Text(frequency.title).tag(frequency)
                }
            }
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
                    Task {
                        await settings.checkForUpdate()
                        if settings.availableUpdate != nil {
                            showUpdateSheet = true
                        }
                    }
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
        case let .updateAvailable(tag, htmlURL, _):
            HStack(spacing: 8) {
                Label(L.str("settings.update.check"), systemImage: "arrow.down.circle.fill")
                Spacer()
                Button {
                    showUpdateSheet = true
                } label: {
                    Text(L.str("settings.update.available", tag))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(L.str("settings.update.details"))
                        .font(.caption)
                }
                .buttonStyle(.plain)
                if URL(string: htmlURL) != nil {
                    Button(L.str("settings.update.download")) {
                        showUpdateSheet = true
                    }
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
                    Task {
                        await settings.checkForUpdate()
                        if settings.availableUpdate != nil {
                            showUpdateSheet = true
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
