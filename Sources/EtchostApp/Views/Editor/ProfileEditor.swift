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
                fragmentToggles
                HostEntryListView(entries: $entries)
            } else {
                draftPreview
            }
            footer
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
                    Text("프래그먼트")
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

    /// 편집 중 내용을 실제 합성 규칙(기본 loopback + 프래그먼트)으로 렌더링한 미리보기.
    private var draftPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("이대로 적용하면 /etc/hosts에 쓰일 내용 (저장 전 편집 상태 반영)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HostsLineList(text: previewText)
        }
    }

    private var previewText: String {
        var draft = profile
        draft.updateEntries(entries)
        return Composer.shared.compose(profile: draft, fragments: model.fragments)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                TextField("프로필 이름", text: $name)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                Text("\(entries.count) 항목 · \(entries.filter(\.isEnabled).count) 활성 · \(model.needsReapply(profile) ? "적용 필요" : "적용됨")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if profile.isActive {
                Label("활성", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("취소") {
                syncFromProfile()
                model.cancelEdit(profile.id)
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

            Button(profile.isActive ? "다시 적용" : "활성화 + 적용") {
                saveIfDirty()
                Task { await applyFlow() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(model.isApplying || anyInvalid)
        }
    }

    private var anyInvalid: Bool {
        entries.contains { !HostEntry.isValidIP($0.ip) || !HostEntry.isWellFormedDomain($0.domain) }
    }

    private var isDirty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != profile.name || entries != profile.entries
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
            saveMessage = "무효한 항목이 있어 저장할 수 없습니다."
            return
        }
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName != profile.name {
                try model.renameProfile(profile.id, to: trimmedName)
            }
            try model.updateEntries(profile.id, entries: entries)
            saveMessage = "저장됨 — 적용하면 /etc/hosts에 반영됩니다"
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
            saveMessage = "적용됨"
            syncFromProfile()
        }
    }
}
