import EtchostKit
import SwiftUI

/// 우측 에디터: 이름 + hosts 항목 리스트(구조화) + 프래그먼트 토글 + 저장/취소/적용.
struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile

    @State private var name: String = ""
    @State private var entries: [HostEntry] = []
    @State private var saveMessage: String?
    @State private var mode: EditorMode = .edit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorHeader(
                name: $name,
                nameLabel: L.str("editor.profile.name"),
                subtitle: L.str(
                    "editor.profile.subtitle",
                    entries.count,
                    entries.filter(\.isEnabled).count,
                    model.needsReapply(profile) ? L.str("editor.needsReapply") : L.str("editor.applied")
                )
            ) {
                if profile.isActive {
                    Label(L.str("editor.active"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            EditorModePicker(mode: $mode)
            Divider()
            if mode == .edit {
                fragmentToggles
                HostEntryListView(entries: $entries)
            } else {
                EditorPreview(hint: L.str("editor.preview.profileHint"), text: previewText)
            }
            EditorFooter(
                canCancel: isDirty,
                canSave: isDirty && !anyInvalid && !editorNameEmpty(name),
                canApply: !model.isApplying && !anyInvalid,
                applyTitle: profile.isActive ? L.str("editor.apply") : L.str("editor.activateAndApply"),
                error: model.applyError,
                onCancel: {
                    syncFromProfile()
                    model.cancelEdit(profile.id)
                    saveMessage = L.str("editor.cancelled")
                },
                onSave: { save() },
                onApply: {
                    saveIfDirty()
                    Task { await applyFlow() }
                }
            )
        }
        .padding(16)
        .onAppear { syncFromProfile() }
        .onChange(of: profile.id) { syncFromProfile() }
    }

    /// 이 프로필에 끼울 프래그먼트 토글. 변경 즉시 저장 (stale은 지문으로 자동 판정).
    private var fragmentToggles: some View {
        Group {
            if !model.fragments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.str("editor.fragments"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(model.fragments) { fragment in
                        Toggle(
                            fragment.name,
                            isOn: Binding(
                                get: { profile.fragmentIDs.contains(fragment.id) },
                                set: { _ in try? model.toggleFragment(profileID: profile.id, fragmentID: fragment.id) }
                            )
                        )
                        .toggleStyle(.checkbox)
                        .font(.body)
                    }
                }
            }
        }
    }

    private var previewText: String {
        var draft = profile
        draft.updateEntries(entries)
        return Composer.shared.compose(profile: draft, fragments: model.fragments)
    }

    private var anyInvalid: Bool {
        editorAnyInvalid(entries)
    }

    private var isDirty: Bool {
        editorIsDirty(name: name, entries: entries, originalName: profile.name, originalEntries: profile.entries)
    }

    private func syncFromProfile() {
        name = profile.name
        entries = profile.entries
        saveMessage = nil
    }

    private func saveIfDirty() {
        if isDirty, !anyInvalid { save() }
    }

    private func save() {
        guard !anyInvalid else {
            saveMessage = L.str("editor.invalidSave")
            return
        }
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName != profile.name {
                try model.renameProfile(profile.id, to: trimmedName)
            }
            try model.updateEntries(profile.id, entries: entries)
            saveMessage = L.str("editor.saved.profile")
        } catch {
            saveMessage = model.describe(error)
        }
    }

    private func applyFlow() async {
        // 다른 프로필을 보고 있었다면 먼저 활성화 전환
        if !profile.isActive {
            await model.switchAndApply(profile.id)
        } else {
            await model.applyActiveProfile()
        }
        if model.applyError == nil {
            saveMessage = L.str("editor.applied")
            syncFromProfile()
        }
    }
}
