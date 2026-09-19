import AppKit
import EtchostKit
import SwiftUI

/// hosts 항목 구조화 리스트 편집기: 행 = 활성 토글 + IP/도메인/주석 필드 + 삭제, 드래그로 순서 변경.
struct HostEntryListView: View {
    @Binding var entries: [HostEntry]

    @State private var pendingFocusID: UUID?
    @State private var manualText = ""
    @State private var manualError: String?
    @State private var editorWidth: CGFloat = 0

    private struct EditorWidthKey: PreferenceKey {
        nonisolated(unsafe) static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.str("hosts.title"))
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(entries.indices, id: \.self) { idx in
                    HostEntryRow(
                        entry: $entries[idx],
                        autoFocus: entries[idx].id == pendingFocusID,
                        isDuplicate: duplicateDomainCount(entries[idx].domain) > 1,
                        onDelete: { entries.remove(at: idx) }
                    )
                }
                .onMove { from, to in
                    entries.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.visible)
            .frame(minHeight: 150, maxHeight: .infinity)

            Button {
                addRow()
            } label: {
                Label(L.str("hosts.add"), systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)

            Divider()

            manualRegisterRow
        }
    }

    /// textbox로 한 줄/여러 줄 입력받아 자동 파싱 후 등록.
    private var manualRegisterRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.str("hosts.manual"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    HostMultilineTextView(text: $manualText) {
                        registerManual()
                    }
                    if manualText.isEmpty {
                        Text(L.str("hosts.manual.placeholder"))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .frame(height: manualEditorHeight)
                Button(L.str("hosts.register")) {
                    registerManual()
                }
                .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: EditorWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(EditorWidthKey.self) { width in
                editorWidth = width
            }
            if let manualError {
                Text(manualError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// 1~4줄 자동 높이: 입력량에 따라 늘어나고 4줄 초과는 편집기 내부 스크롤.
    private var manualEditorHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let lineHeight = NSAttributedString(string: "Ag", attributes: [.font: font]).size().height
        guard editorWidth > 40, !manualText.isEmpty else { return lineHeight + 12 }
        let attr = NSAttributedString(string: manualText, attributes: [.font: font])
        let bounds = attr.boundingRect(
            with: CGSize(width: editorWidth - 24, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        let lines = max(1, Int(ceil(bounds.height / lineHeight)))
        let capped = min(lines, 4)
        return CGFloat(capped) * lineHeight + 12
    }

    private func registerManual() {
        let lines = manualText.components(separatedBy: .newlines)
        var added = 0
        var invalidLines: [Int] = []
        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || (trimmed.hasPrefix("#") && !trimmed.hasPrefix("# disabled:")) { continue }
            if let entry = HostEntry.parse(raw) {
                entries.append(entry)
                added += 1
            } else {
                invalidLines.append(idx + 1)
            }
        }
        if added > 0 {
            manualText = ""
            manualError = nil
        }
        if !invalidLines.isEmpty {
            manualError = added > 0
                ? L.str("hosts.register.success", added, invalidLines.count, invalidLines.map(String.init).joined(separator: ", "))
                : L.str("hosts.register.failed", invalidLines.count, invalidLines.map(String.init).joined(separator: ", "))
        }
    }

    private func duplicateDomainCount(_ domain: String) -> Int {
        // localhost/broadcasthost는 IPv4+IPv6 두 줄이 정상이라 중복 검사 제외
        let d = domain.lowercased()
        if d == "localhost" || d == "broadcasthost" { return 0 }
        return entries.filter { $0.domain.lowercased() == d }.count
    }

    private func addRow() {
        let id = UUID()
        withAnimation {
            entries.append(HostEntry(id: id, ip: "", domain: ""))
        }
        pendingFocusID = id
        DispatchQueue.main.async {
            pendingFocusID = nil
        }
    }
}

/// 개별 행: 필드별 인라인 검증 표시 + 삭제.
struct HostEntryRow: View {
    @Binding var entry: HostEntry
    let autoFocus: Bool
    let isDuplicate: Bool
    var onDelete: () -> Void

    @FocusState private var ipFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle("", isOn: $entry.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(entry.isEnabled ? L.str("hosts.row.enabled") : L.str("hosts.row.disabled"))

                TextField(L.str("hosts.field.ip"), text: ipBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 130)
                    .textFieldStyle(.plain)
                    .fieldBox(color: ipFieldColor)
                    .focused($ipFocused)

                TextField(L.str("hosts.field.domain"), text: domainBinding)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .fieldBox(color: domainFieldColor)

                TextField(L.str("hosts.field.comment"), text: commentBinding)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .fieldBox(color: nil)

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L.str("hosts.row.delete"))
            }
            if let note = note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .opacity(entry.isEnabled ? 1 : 0.55)
        .onAppear {
            if autoFocus { ipFocused = true }
        }
    }

    private var commentBinding: Binding<String> {
        Binding(
            get: { entry.comment ?? "" },
            set: { entry.comment = $0.isEmpty ? nil : $0 }
        )
    }

    /// 한글 등 비허용 문자를 타이핑 즉시 제거 (도메인 필드).
    private var domainBinding: Binding<String> {
        Binding(
            get: { entry.domain },
            set: { entry.domain = HostEntry.sanitizedDomain($0) }
        )
    }

    /// IP 필드 정제: 숫자/점/콜론/16진만 허용.
    private var ipBinding: Binding<String> {
        Binding(
            get: { entry.ip },
            set: { entry.ip = HostEntry.sanitizedIP($0) }
        )
    }

    private var ipValid: Bool {
        HostEntry.isValidIP(entry.ip)
    }

    private var domainValid: Bool {
        HostEntry.isWellFormedDomain(entry.domain)
    }

    private var ipFieldColor: Color? {
        if entry.ip.isEmpty { return nil }
        return ipValid ? .green.opacity(0.4) : .red.opacity(0.5)
    }

    private var domainFieldColor: Color? {
        if entry.domain.isEmpty { return nil }
        return domainValid ? .green.opacity(0.4) : .red.opacity(0.5)
    }

    private var note: String? {
        if !entry.ip.isEmpty, !ipValid {
            return L.str("hosts.error.ip")
        }
        if !entry.domain.isEmpty, !domainValid {
            return L.str("hosts.error.domain")
        }
        if entry.domain.isEmpty {
            return L.str("hosts.error.domainRequired")
        }
        if isDuplicate {
            return L.str("hosts.error.duplicate")
        }
        return nil
    }
}

private extension View {
    func fieldBox(color: Color?) -> some View {
        self
            .padding(4)
            .background(color.map { $0.opacity(0.18) } ?? Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if let color {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(color, lineWidth: 1)
                }
            }
    }
}

/// NSTextView 기반 다중 줄 텍스트 편집기.
/// textContainerInset(6,6) + lineFragmentPadding(0)으로 인해 텍스트/커서가
/// 박스 좌상단 (6,6)에서 시작해 SwiftUI placeholder와 정확히 겹친다.
/// 입력량에 따라 높이가 자동 늘어나고, 4줄 초과는 내부 스크롤(휠 지원).
struct HostMultilineTextView: NSViewRepresentable {
    @Binding var text: String
    var onMultiLinePaste: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = AutoRegisterTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onPastedMultiLine = { [weak coordinator] in coordinator?.multiLinePasted() }
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HostMultilineTextView
        weak var textView: NSTextView?

        init(_ parent: HostMultilineTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, parent.text != textView.string else { return }
            parent.text = textView.string
        }

        func multiLinePasted() {
            parent.onMultiLinePaste?()
        }
    }
}

/// 여러 줄 붙여넣기 감지 → 자동 등록 트리거.
private final class AutoRegisterTextView: NSTextView {
    var onPastedMultiLine: (() -> Void)?

    override func paste(_ sender: Any?) {
        let before = string
        super.paste(sender)
        if string != before, string.components(separatedBy: .newlines).count > 1 {
            onPastedMultiLine?()
        }
    }
}
