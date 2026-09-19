import EtchostKit
import SwiftUI

// MARK: - 공통 헬퍼 (ProfileEditor / FragmentEditor 공용)

/// 편집 중 항목 검증: IP/도메인 형식이 하나라도 잘못되면 true.
func editorAnyInvalid(_ entries: [HostEntry]) -> Bool {
    entries.contains { !HostEntry.isValidIP($0.ip) || !HostEntry.isWellFormedDomain($0.domain) }
}

/// 스토어 원본과 편집 상태 비교 (이름 트림 포함).
func editorIsDirty(
    name: String,
    entries: [HostEntry],
    originalName: String,
    originalEntries: [HostEntry]
) -> Bool {
    name.trimmingCharacters(in: .whitespacesAndNewlines) != originalName || entries != originalEntries
}

/// 빈 이름(공백만)인지 검사.
func editorNameEmpty(_ name: String) -> Bool {
    name.trimmingCharacters(in: .whitespaces).isEmpty
}

// MARK: - 공통 컴포넌트

/// 에디터 공통: 이름 TextField + 상태 캡션 + 우측 배지.
struct EditorHeader<Badge: View>: View {
    @Binding var name: String
    let nameLabel: String
    let subtitle: String
    let badge: () -> Badge

    init(
        name: Binding<String>,
        nameLabel: String,
        subtitle: String,
        @ViewBuilder badge: @escaping () -> Badge
    ) {
        self._name = name
        self.nameLabel = nameLabel
        self.subtitle = subtitle
        self.badge = badge
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                TextField(nameLabel, text: $name)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            badge()
        }
    }
}

/// 에디터 공통: 편집/미리보기 모드 선택기.
struct EditorModePicker: View {
    @Binding var mode: EditorMode

    var body: some View {
        Picker(L.str("editor.mode"), selection: $mode) {
            ForEach(EditorMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// 에디터 공통: 편집 중 합성 결과 미리보기.
struct EditorPreview: View {
    let hint: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            HostsLineList(text: text)
        }
    }
}

/// 에디터 공통: 하단 동작 바 (취소/저장/적용).
struct EditorFooter: View {
    let canCancel: Bool
    let canSave: Bool
    let canApply: Bool
    let applyTitle: String
    let error: String?
    let onCancel: () -> Void
    let onSave: () -> Void
    let onApply: () -> Void

    var body: some View {
        HStack {
            Button(L.str("editor.cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(!canCancel)

            Spacer()

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Button(L.str("editor.save")) { onSave() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)

            Button(applyTitle) { onApply() }
                .keyboardShortcut("r", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
        }
    }
}
