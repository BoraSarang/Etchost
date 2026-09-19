import SwiftUI

enum EditorMode: String, CaseIterable, Identifiable {
    case edit = "편집"
    case preview = "미리보기"
    var id: String { rawValue }
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
struct HostsLineList: View {
    let text: String
    var minHeight: CGFloat = 280

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
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
