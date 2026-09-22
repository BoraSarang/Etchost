import EtchostKit
import SwiftUI

/// 적용 전 diff 미리보기. 현재 /etc/hosts(old) vs 합성 결과(new) 비교.
/// 변경이 없으면 안내 문구만, 있으면 요약(+N −M)과 변경 줄 목록(최대 200줄)을 표시.
/// 대용량(5000줄 초과)은 diff 계산 자체를 생략한다.
struct DiffPreviewView: View {
    let oldText: String
    let newText: String
    private static let maxRows = 200
    private static let maxLines = 5000

    private var isSkipped: Bool {
        lineCount > Self.maxLines
    }

    private var lineCount: Int {
        // 줄 수만 필요하므로 전체 배열 대신 개행 개수 + 1로 계산.
        newText.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
    }

    var body: some View {
        // body 1회에 diff 1회만 — 요약/목록이各自 diff를 부르던 중복 계산 제거.
        let lines = isSkipped ? [] : HostsDiffer.diff(old: oldText, new: newText, contextLines: 1)
        let summary = HostsDiffer.summary(of: lines)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(L.str("editor.diff.title"), systemImage: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isSkipped {
                    Text(L.str("editor.diff.skipped", lineCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if summary.isEmpty {
                    Text(L.str("editor.diff.empty"))
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(L.str("editor.diff.summary", summary.added, summary.removed))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if !lines.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        // 인덱스 identity — HostsDiffLine.id는 매 계산 신규 UUID라 ForEach 전면 교체 유발.
                        ForEach(Array(lines.prefix(Self.maxRows).enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(line.kind == .added ? .green : line.kind == .removed ? .red : .secondary)
                                    .frame(width: 12)
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(line.kind == .context ? .secondary : .primary)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                            }
                        }
                        if lines.count > Self.maxRows {
                            Text(L.str("editor.diff.more", lines.count - Self.maxRows))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// 합성 텍스트 검증 경고 목록. 저장을 막지 않는다. 접기 가능.
/// 검증은 백그라운드에서 디바운스 실행 — 8만 개 전체 검사가 화면 갱신 때마다
/// 메인스레드를 막아 클릭 지연을 일으켰던 문제를 해소한다.
struct MemoizedValidationView: View {
    let entries: [HostEntry]
    @State private var issues: [ValidationIssue] = []

    var body: some View {
        ValidationWarningsView(issues: issues)
            .task(id: entries) {
                // 연속 변경 시 이전 계산 취소 → 입력 멈춤 후 0.3초 뒤 1회만 실행.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let snapshot = entries
                // .task는 MainActor에서 돈다 — 대용량 검증이 화면 블록을 막지 않도록 백그라운드로.
                let result = await Task.detached(priority: .userInitiated) {
                    HostsValidator().validate(entries: snapshot)
                }.value
                guard !Task.isCancelled else { return }
                issues = result
            }
    }
}

/// 합성 텍스트 검증 경고 목록. 저장을 막지 않는다. 접기 가능.
struct ValidationWarningsView: View {
    let issues: [ValidationIssue]

    var body: some View {
        if !issues.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues.prefix(8)) { issue in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: issue.severity == .error ? "xmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(issue.severity == .error ? .red : .orange)
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if issues.count > 8 {
                        Text(L.str("editor.diff.more", issues.count - 8))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            } label: {
                Label(L.str("editor.validation.title", issues.count), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
