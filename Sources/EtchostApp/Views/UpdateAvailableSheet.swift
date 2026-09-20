import AppKit
import SwiftUI

/// 새 버전 발견 시 표시하는 시트: 릴리스 노트(마크다운) + 업데이트 방법 + 다운로드/닫기.
struct UpdateAvailableSheet: View {
    let tag: String
    let htmlURL: String
    let notes: String
    let currentVersion: String
    /// 설정 시트가 아닐 때(별도 윈도우) 닫기 동작. nil이면 dismiss 사용.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L.str("settings.update.sheet.title", tag))
                    .font(.headline)
                Text(L.str("settings.update.sheet.current", currentVersion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(L.str("settings.update.sheet.notes"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView {
                if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L.str("settings.update.sheet.notesEmpty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    ReleaseNotesView(markdown: notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
            .frame(height: 170)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .scrollIndicators(.visible)

            Divider()

            Text(L.str("settings.update.sheet.howto"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(L.str("settings.update.sheet.howto.body"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button(L.str("settings.update.close")) {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                if let url = URL(string: htmlURL) {
                    Button(L.str("settings.update.download")) {
                        NSWorkspace.shared.open(url)
                        if let onClose {
                            onClose()
                        } else {
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
