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
            header
            Picker("모드", selection: $mode) {
                ForEach(EditorMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            if mode == .edit {
                HostEntryListView(entries: $entries)
            } else {
                draftPreview
            }
            footer
        }
        .padding(16)
        .onAppear { syncFromFragment() }
        .onChange(of: fragment.id) { syncFromFragment() }
    }

    /// 편집 중 조각을 기준으로, 활성 프로필 합성 결과(또는 조각 단독 섹션)를 미리봄.
    private var draftPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(activeTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            HostsLineList(text: previewText)
        }
    }

    private var activeTitle: String {
        guard let active = model.activeProfile else {
            return "활성 프로필이 없어 조각 내용만 표시"
        }
        return "이 조각을 적용하면 \(active.name) 프로필에 들어가는 예상 내용"
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

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                TextField("프래그먼트 이름", text: $name)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                Text("\(entries.count) 항목 · \(entries.filter(\.isEnabled).count) 활성 · \(usageText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("조각", systemImage: "puzzlepiece")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var usageText: String {
        let users = model.profilesUsing(fragment.id)
        return users.isEmpty ? "사용 중인 프로필 없음" : users.map(\.name).joined(separator: ", ") + "에서 사용"
    }

    private var footer: some View {
        HStack {
            Button("취소") {
                syncFromFragment()
                model.cancelEdit(fragment.id)
                saveMessage = "변경 취소됨"
            }
            .keyboardShortcut(.cancelAction)
            .disabled(!isDirty)

            Spacer()

            if let err = model.applyError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Button("저장") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || anyInvalid || name.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("활성 프로필에 적용") {
                saveIfDirty()
                Task {
                    await model.applyActiveProfile()
                    if model.applyError == nil {
                        saveMessage = "활성 프로필에 적용됨"
                        syncFromFragment()
                    }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(model.isApplying || anyInvalid || model.activeProfile == nil)
        }
    }

    private var anyInvalid: Bool {
        entries.contains { !HostEntry.isValidIP($0.ip) || !HostEntry.isWellFormedDomain($0.domain) }
    }

    private var isDirty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != fragment.name || entries != fragment.entries
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
            saveMessage = "무효한 항목이 있어 저장할 수 없습니다."
            return
        }
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName != fragment.name {
                try model.renameFragment(fragment.id, to: trimmedName)
            }
            try model.updateFragmentEntries(fragment.id, entries: entries)
            saveMessage = "저장됨 — 참조 프로필은 적용 필요 상태가 됩니다"
        } catch {
            saveMessage = model.describe(error)
        }
    }
}
