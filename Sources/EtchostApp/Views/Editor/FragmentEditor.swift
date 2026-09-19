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
            if mode == .edit {
                HostEntryListView(entries: $entries)
            } else {
                EditorPreview(hint: activeTitle, text: previewText)
            }
            EditorFooter(
                canCancel: isDirty,
                canSave: isDirty && !anyInvalid && !editorNameEmpty(name),
                canApply: !model.isApplying && !anyInvalid && model.activeProfile != nil,
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
        .onAppear { syncFromFragment() }
        .onChange(of: fragment.id) { syncFromFragment() }
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

    private var anyInvalid: Bool {
        editorAnyInvalid(entries)
    }

    private var isDirty: Bool {
        editorIsDirty(name: name, entries: entries, originalName: fragment.name, originalEntries: fragment.entries)
    }

    private func syncFromFragment() {
        name = fragment.name
        entries = fragment.entries
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
            if trimmedName != fragment.name {
                try model.renameFragment(fragment.id, to: trimmedName)
            }
            try model.updateFragmentEntries(fragment.id, entries: entries)
            saveMessage = L.str("editor.saved.fragment")
        } catch {
            saveMessage = model.describe(error)
        }
    }
}
