import SwiftUI

enum EditorMode: CaseIterable, Identifiable {
    case edit
    case preview

    var id: String {
        switch self {
        case .edit: return "edit"
        case .preview: return "preview"
        }
    }

    var title: String {
        switch self {
        case .edit: return L.str("editor.mode.edit")
        case .preview: return L.str("editor.mode.preview")
        }
    }
}

/// hosts 파일 한 줄의 판독형 행: 주석=회색, 비활성=주황, 정상 항목=모노스페이스 기본색.
struct HostsLineRow: View {
    let line: String

    var body: some View {
        if line.isEmpty {
            Color.clear.frame(height: 4)
        } else {
            Text(line)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var color: Color {
        if line.hasPrefix("# disabled") { return .orange }
        if line.hasPrefix("#") { return .secondary }
        return .primary
    }
}

/// 줄 목록을 스크롤 가능한 텍스트로 렌더링 (복사 가능).
/// 대용량 텍스트는 앞부분만 렌더한다 (8만 줄 전체 Text 생성 방지).
struct HostsLineList: View {
    let text: String
    var minHeight: CGFloat = 280
    static let maxLines = 1000

    private var allLines: [String] {
        text.components(separatedBy: "\n")
    }

    private var isCapped: Bool {
        // 줄 수만 필요하므로 전체 배열 대신 개행 개수 + 1로 계산.
        text.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } } > Self.maxLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isCapped {
                Text(L.str("editor.preview.capped", allLines.count, Self.maxLines))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(allLines.prefix(Self.maxLines).enumerated()), id: \.offset) { _, line in
                        HostsLineRow(line: line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(6)
            }
            .background(.background)
            .border(.quaternary)
            .frame(minHeight: minHeight, maxHeight: .infinity)
        }
    }
}
