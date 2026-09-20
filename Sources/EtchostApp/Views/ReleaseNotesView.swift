import SwiftUI

/// 릴리스 노트용 경량 마크다운 렌더러.
/// 한 줄씩 블록(제목·목록·인용·코드·문단)으로 나눠 표시하고, 인라인(굵기·기울임·코드)만
/// 파싱해 개행을 보존한다. 전체 구문 파싱은 블록 경계가 SwiftUI Text에서 줄바꿈으로
/// 그려지지 않아 한 덩어리로 붙어버리므로 쓰지 않는다.
struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - 블록 뷰

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.styledInline(text, size: level <= 2 ? 15 : 14, bold: true))
                .padding(.top, 2)
        case let .bullet(text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(Self.styledInline(text, size: 13))
            }
        case let .ordered(index, text):
            HStack(alignment: .top, spacing: 6) {
                Text("\(index).")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(Self.styledInline(text, size: 13))
            }
        case let .quote(text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 3)
                Text(Self.styledInline(text, size: 13))
                    .foregroundStyle(.secondary)
            }
        case let .code(body):
            Text(body)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .hr:
            Divider()
        case let .paragraph(text):
            Text(Self.styledInline(text, size: 13))
        }
    }

    // MARK: - 인라인 스타일

    /// 인라인 구문만 해석하고 글자 크기를 run마다 직접 기록한다.
    /// View 뒤의 `.font()`는 볼드 특성을 덮어버리므로 여기서만 지정한다.
    static func styledInline(_ s: String, size: CGFloat, bold: Bool = false) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attr = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in attr.runs {
            var font = Font.system(size: size)
            let intent = run.inlinePresentationIntent
            if bold || intent?.contains(.stronglyEmphasized) == true {
                font = font.bold()
            }
            if intent?.contains(.emphasized) == true {
                font = font.italic()
            }
            if intent?.contains(.code) == true {
                font = Font.system(size: size, design: .monospaced)
            }
            attr[run.range].font = font
        }
        return attr
    }

    // MARK: - 블록 파서

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case ordered(index: Int, text: String)
        case quote(text: String)
        case code(body: String)
        case hr
        case paragraph(text: String)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flushPara() {
            if !para.isEmpty {
                blocks.append(.paragraph(text: para.joined(separator: "\n")))
                para = []
            }
        }
        for rawLine in markdown.components(separatedBy: "\n") {
            if var current = code {
                if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(body: current.joined(separator: "\n")))
                    code = nil
                } else {
                    current.append(rawLine)
                    code = current
                }
                continue
            }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushPara()
                code = []
                continue
            }
            if line.isEmpty {
                flushPara()
                continue
            }
            if let heading = headingOf(line) {
                flushPara()
                blocks.append(heading)
                continue
            }
            if line == "---" || line == "***" {
                flushPara()
                blocks.append(.hr)
                continue
            }
            if line.hasPrefix(">") {
                flushPara()
                blocks.append(.quote(text: line.dropFirst().trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let bullet = bulletOf(rawLine) {
                flushPara()
                blocks.append(bullet)
                continue
            }
            para.append(line)
        }
        flushPara()
        if let rest = code {
            blocks.append(.code(body: rest.joined(separator: "\n")))
        }
        return blocks
    }

    private static func headingOf(_ line: String) -> Block? {
        var level = 0
        for char in line {
            guard char == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") else { return nil }
        let body = line.dropFirst(level + 1).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return .heading(level: level, text: body)
    }

    private static func bulletOf(_ rawLine: String) -> Block? {
        let spaces = rawLine.prefix(while: { $0 == " " }).count
        let body = String(rawLine.dropFirst(spaces))
        if body.hasPrefix("- ") || body.hasPrefix("* ") {
            return .bullet(text: String(body.dropFirst(2)))
        }
        var digits = 0
        for char in body {
            guard char.isNumber else { break }
            digits += 1
        }
        if digits > 0 {
            let rest = body.dropFirst(digits)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .ordered(index: Int(body.prefix(digits)) ?? 1, text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }
}
