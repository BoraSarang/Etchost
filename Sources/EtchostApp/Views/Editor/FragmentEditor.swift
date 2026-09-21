import EtchostKit
import SwiftUI

/// 프래그먼트 에디터: 이름 + hosts 항목 리스트(구조화) + 저장/취소.
struct FragmentEditor: View {
    @EnvironmentObject var model: AppModel
    let fragment: Fragment

    @State private var name: String = ""
    @State private var entries: [HostEntry] = []
    @State private var saveMessage: String?
    @State private var mode: EditorMode = .edit
    @State private var remoteURL: String = ""
    @State private var remoteInterval: RemoteSource.Interval = .manual
    @State private var isSyncing = false
    @State private var syncMessage: String?

    /// 이 조각을 동기화 중이면 진행 단계, 아니면 nil.
    private var activeSyncPhase: SyncProgress? {
        model.syncingFragmentID == fragment.id ? model.syncPhase : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorHeader(
                name: $name,
                nameLabel: L.str("editor.fragment.name"),
                subtitle: L.str(
                    "editor.fragment.subtitle",
                    entries.count,
                    entries.filter(\.isEnabled).count,
                    usageText
                )
            ) {
                Label(L.str("editor.fragment"), systemImage: "puzzlepiece")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            EditorModePicker(mode: $mode)
            Divider()
            remoteSection
            if let phase = activeSyncPhase {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(syncPhaseText(phase))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if mode == .edit {
                HostEntryListView(entries: $entries, readOnly: isRemoteOn)
                if isRemoteOn {
                    Text(L.str("editor.remote.readonly"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                MemoizedValidationView(entries: entries)
            } else {
                EditorPreview(hint: activeTitle, text: previewText)
                MemoizedValidationView(entries: entries)
            }
            EditorFooter(
                canCancel: isDirty,
                canSave: isDirty && !anyInvalid && !editorNameEmpty(name) && remoteURLValid,
                canApply: !model.isApplying && !anyInvalid && remoteURLValid && model.activeProfile != nil,
                applyTitle: L.str("editor.applyToActive"),
                error: model.applyError,
                onCancel: {
                    syncFromFragment()
                    model.cancelEdit(fragment.id)
                    saveMessage = L.str("editor.cancelled")
                },
                onSave: { save() },
                onApply: {
                    saveIfDirty()
                    Task {
                        await model.applyActiveProfile()
                        if model.applyError == nil {
                            saveMessage = L.str("editor.appliedToActive")
                            syncFromFragment()
                        }
                    }
                }
            )
        }
        .padding(16)
        .onAppear {
            syncFromFragment()
            model.requestEditorSave = { saveIfDirty(); return !isDirty }
        }
        .onDisappear {
            model.requestEditorSave = nil
            model.editorDirty = false
        }
        .onChange(of: fragment.id) { syncFromFragment() }
        .onChange(of: isDirty) { model.editorDirty = isDirty }
    }

    private func syncPhaseText(_ phase: SyncProgress) -> String {
        switch phase {
        case .downloading(let host):
            return L.str("sync.phase.downloading", host)
        case .parsing(let bytes):
            return L.str("sync.phase.parsing", bytes)
        case .saving(let count):
            return L.str("sync.phase.saving", count)
        @unknown default:
            return L.str("editor.remote.syncing")
        }
    }

    private var activeTitle: String {
        guard let active = model.activeProfile else {
            return L.str("editor.preview.fragmentNoActive")
        }
        return L.str("editor.preview.fragmentExpected", active.name)
    }

    private var previewText: String {
        var draft = fragment
        draft.updateEntries(entries)
        if let active = model.activeProfile {
            var fragments = model.fragments
            if let idx = fragments.firstIndex(where: { $0.id == fragment.id }) {
                fragments[idx] = draft
            }
            return Composer.shared.compose(profile: active, fragments: fragments)
        }
        var lines = ["# Fragment: \(fragment.name)"]
        lines += draft.entries.map(\.line)
        return lines.joined(separator: "\n")
    }

    private var usageText: String {
        let users = model.profilesUsing(fragment.id)
        return users.isEmpty ? L.str("fragment.usage.none") : L.str("fragment.usage.in", users.map(\.name).joined(separator: ", "))
    }

    // MARK: - 원격 소스

    /// URL 입력이 비어 있지 않으면 원격 모드 (저장 시 fragment.remote 반영).
    private var isRemoteOn: Bool {
        !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var remoteURLValid: Bool {
        !isRemoteOn || RemoteSource(url: remoteURL).cleanedURL != nil
    }

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.str("editor.remote.title"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(L.str("editor.remote.url.placeholder"), text: $remoteURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Picker(L.str("editor.remote.interval"), selection: $remoteInterval) {
                    ForEach(RemoteSource.Interval.allCases, id: \.self) { interval in
                        Text(remoteIntervalTitle(interval)).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(!isRemoteOn)
                Button(isSyncing ? L.str("editor.remote.syncing") : L.str("editor.remote.sync")) {
                    Task { await syncNow() }
                }
                .controlSize(.small)
                .disabled(!isRemoteOn || !remoteURLValid || isSyncing)
            }
            HStack(spacing: 6) {
                if !remoteURLValid {
                    Label(L.str("editor.remote.url.invalid"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let error = fragment.remote?.lastError, !isSyncing {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let synced = fragment.remote?.lastSyncedAt {
                    Text(L.str("editor.remote.lastSync", synced.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isRemoteOn {
                    Text(L.str("editor.remote.neverSynced"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = syncMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func remoteIntervalTitle(_ interval: RemoteSource.Interval) -> String {
        switch interval {
        case .manual: return L.str("editor.remote.interval.manual")
        case .atLaunch: return L.str("editor.remote.interval.atLaunch")
        case .hourly: return L.str("editor.remote.interval.hourly")
        case .daily: return L.str("editor.remote.interval.daily")
        @unknown default: return L.str("editor.remote.interval.manual")
        }
    }

    private func syncNow() async {
        saveRemoteIfDirty()
        guard fragment.remote != nil, model.fragments.contains(where: { $0.id == fragment.id }) else {
            syncMessage = nil
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let ok = await model.syncRemoteFragment(fragment.id)
        if ok, let updated = model.fragments.first(where: { $0.id == fragment.id }) {
            entries = updated.entries
            syncMessage = L.str("editor.remote.synced", updated.entries.count)
        } else {
            syncMessage = nil
        }
    }

    private var isRemoteDirty: Bool {
        let currentURL = fragment.remote?.url ?? ""
        let currentInterval = fragment.remote?.interval ?? .manual
        return remoteURL.trimmingCharacters(in: .whitespacesAndNewlines) != currentURL
            || (isRemoteOn && remoteInterval != currentInterval)
    }

    private func saveRemoteIfDirty() {
        if isRemoteDirty, remoteURLValid {
            try? model.updateFragmentRemote(fragment.id, url: remoteURL, interval: remoteInterval)
        }
    }

    private var anyInvalid: Bool {
        // 원격 모드에서는 항목 직접 저장을 건너뛰므로 매번 8만 개 검사를 반복하지 않는다.
        guard !isRemoteOn else { return false }
        return editorAnyInvalid(entries)
    }

    private var isDirty: Bool {
        editorIsDirty(name: name, entries: entries, originalName: fragment.name, originalEntries: fragment.entries)
            || isRemoteDirty
    }

    private func syncFromFragment() {
        name = fragment.name
        entries = fragment.entries
        remoteURL = fragment.remote?.url ?? ""
        remoteInterval = fragment.remote?.interval ?? .manual
        syncMessage = nil
        saveMessage = nil
    }

    private func saveIfDirty() {
        if isDirty, !anyInvalid, remoteURLValid { save() }
    }

    private func save() {
        guard !anyInvalid, remoteURLValid else {
            saveMessage = L.str("editor.invalidSave")
            return
        }
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName != fragment.name {
                try model.renameFragment(fragment.id, to: trimmedName)
            }
            saveRemoteIfDirty()
            // 원격 모드에서는 항목이 동기화 캐시이므로 직접 저장을 건너뛴다.
            if !isRemoteOn {
                try model.updateFragmentEntries(fragment.id, entries: entries)
            }
            saveMessage = L.str("editor.saved.fragment")
        } catch {
            saveMessage = model.describe(error)
        }
    }
}
