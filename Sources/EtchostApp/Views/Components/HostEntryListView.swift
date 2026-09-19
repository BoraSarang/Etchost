import EtchostKit
import SwiftUI

/// hosts 항목 구조화 리스트 편집기: 행 = 활성 토글 + IP/도메인/주석 필드 + 삭제, 드래그로 순서 변경.
struct HostEntryListView: View {
    @Binding var entries: [HostEntry]

    @State private var pendingFocusID: UUID?
    @State private var manualText = ""
    @State private var manualError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("항목 (IP · 도메인 · 주석) — 잘못된 값은 저장을 막습니다")
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
            .frame(minHeight: 150, idealHeight: 260, maxHeight: 340)

            Button {
                addRow()
            } label: {
                Label("항목 추가", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)

            Divider()

            manualRegisterRow
        }
    }

    /// textbox로 한 줄/여러 줄 입력받아 자동 파싱 후 등록.
    private var manualRegisterRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("수동 등록 (ip 도메인 #주석 — 탭/공백 혼용, 여러 줄 붙여넣기 가능)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $manualText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.visible)
                        .onPasteCommand(of: [.plainText]) { providers in
                            guard let provider = providers.first else { return }
                            _ = provider.loadObject(ofClass: String.self) { object, _ in
                                guard let text = object else { return }
                                Task { @MainActor in
                                    manualText = text
                                    registerManual()
                                }
                            }
                        }
                    if manualText.isEmpty {
                        Text("예: 127.0.0.1 example.com # 기본  (여러 줄 붙여넣기하면 한 번에 등록)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 66, maxHeight: 100)
                Button("등록") {
                    registerManual()
                }
                .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let manualError {
                Text(manualError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
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
                ? "\(added)개 등록됨 · 파싱 실패 \(invalidLines.count)줄: \(invalidLines.map(String.init).joined(separator: ", "))"
                : "파싱 실패 \(invalidLines.count)줄: \(invalidLines.map(String.init).joined(separator: ", ")) — ip와 도메인이 필요합니다"
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
                    .help(entry.isEnabled ? "활성" : "비활성 (# disabled:로 저장)")

                TextField("IP", text: ipBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 130)
                    .textFieldStyle(.plain)
                    .fieldBox(color: ipFieldColor)
                    .focused($ipFocused)

                TextField("도메인 (host)", text: domainBinding)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .fieldBox(color: domainFieldColor)

                TextField("주석 (선택)", text: commentBinding)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .fieldBox(color: nil)

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("항목 삭제")
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
            return "IP 오류: 올바른 IPv4(0–255) 또는 IPv6 주소여야 합니다."
        }
        if !entry.domain.isEmpty, !domainValid {
            return "도메인 오류: 공백이나 특수문자를 쓸 수 없습니다."
        }
        if entry.domain.isEmpty {
            return "도메인 입력 필요"
        }
        if isDuplicate {
            return "중복 도메인: 같은 도메인이 여러 줄에 있습니다."
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
