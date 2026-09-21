import AppKit
import EtchostKit
import SwiftUI

/// 네트워크 허브: localhost/LAN 포트 스캔 + cloudflared quick tunnel 관리.
struct NetworkView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var tunnels: TunnelManager

    @State private var hostInput = ""
    @State private var portMode: PortScanMode = .defaultPorts
    @State private var portText = ""
    @State private var scanResults: [PortScanResult] = []
    @State private var selectedResult: PortScanResult.ID?
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var lastTarget: String?
    @State private var scanCompleted = 0
    @State private var scanTotal = 0
    @State private var scanStageAlive = false
    @State private var scanElapsed: TimeInterval?
    @State private var cacheInfo: String?
    @State private var logTunnelID: TunnelLogSelection?

    private struct CachedScan: Codable {
        let target: String
        let scannedAt: Date
        let ownIP: String
        let results: [PortScanResult]
    }

    private struct TunnelLogSelection: Identifiable {
        var id: UUID { tunnelID }
        let tunnelID: UUID
    }

    /// 스캔 포트 모드 3종.
    private enum PortScanMode: String, CaseIterable, Identifiable {
        case defaultPorts, custom, range
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .defaultPorts: return "network.scan.ports.mode.default"
            case .custom: return "network.scan.ports.mode.custom"
            case .range: return "network.scan.ports.mode.range"
            }
        }
    }

    /// 포트 모드 표시명. 기본 모드는 개수 동적 반영.
    private func portModeTitle(_ mode: PortScanMode) -> String {
        if mode == .defaultPorts {
            return L.str(mode.titleKey, AppSettings.shared.effectiveDefaultScanPorts.count)
        }
        return L.str(mode.titleKey)
    }

    init() {
        _tunnels = ObservedObject(wrappedValue: TunnelManager.shared)
    }

    var body: some View {
        VStack(spacing: 12) {
            cloudflaredBanner
            ipChangeBanner
            Divider()
            scannerSection
            Divider()
            tunnelSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .onAppear { loadCachedScanIfEmpty() }
        .sheet(item: $logTunnelID) { selection in
            TunnelLogSheet(tunnels: tunnels, id: selection.tunnelID)
        }
    }

    // MARK: - cloudflared 상태 배너

    private var cloudflaredBanner: some View {
        HStack(spacing: 8) {
            if tunnels.cloudflaredPath != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L.str("network.cloudflare.badge", tunnels.cloudflaredVersion ?? L.str("network.cloudflare.installed")))
                    .font(.callout)
                Text(L.str("network.currentIP", model.currentIP ?? L.str("network.ip.checking")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if tunnels.isInstalling {
                ProgressView()
                    .controlSize(.small)
                Text(tunnels.installMessage ?? L.str("network.cloudflare.installing"))
                    .font(.callout)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(L.str("network.cloudflare.missing"))
                            .font(.callout)
                        Spacer()
                        Button(L.str("network.cloudflare.install")) {
                            Task { try? await tunnels.installCloudflared() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if let message = tunnels.installMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var ipChangeBanner: some View {
if let change = tunnels.lastIPChange {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    Text(L.str("network.ipChange", change.old ?? L.str("network.ipChange.none"), change.new))
                        .font(.caption)
                    Spacer()
                }
            }
    }

    // MARK: - 스캐너

    private var scannerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.str("network.scan.title"))
                    .font(.headline)
                Spacer()
                if let elapsed = scanElapsed, !isScanning {
                    Text(String(format: "%.1fs", elapsed))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let target = lastTarget {
                    Text(target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let cacheInfo {
                    Text(cacheInfo)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 8) {
                Button(L.str("network.scan.localhost")) {
                    startScan(hosts: ["127.0.0.1"])
                }
                .disabled(isScanning)
                Button(L.str("network.scan.gateway")) {
                    scanError = nil
                    guard let gw = NetworkScanner.defaultGateway() else {
                        scanError = L.str("network.scan.gatewayError")
                        return
                    }
                    startScan(hosts: [gw])
                }
                .disabled(isScanning)
                Button(L.str("network.scan.lan")) {
                    scanError = nil
                    let hosts = lanHosts()
                    guard !hosts.isEmpty else {
                        scanError = L.str("network.scan.lanError")
                        return
                    }
                    startScan(hosts: hosts)
                }
                .disabled(isScanning)
                TextField(L.str("network.scan.inputPlaceholder"), text: $hostInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Button(L.str("network.scan.custom")) {
                    let ip = hostInput.trimmingCharacters(in: .whitespaces)
                    startScan(hosts: ip.isEmpty ? ["127.0.0.1"] : [ip])
                }
                .disabled(isScanning)
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(PortScanMode.allCases) { mode in
                        Button(portModeTitle(mode)) { portMode = mode }
                    }
                } label: {
                    Label(portModeTitle(portMode), systemImage: "chevron.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isScanning)
                .help(portModeTitle(portMode))

                if portMode != .defaultPorts {
                    TextField(
                        portMode == .custom
                            ? L.str("network.scan.ports.customPlaceholder")
                            : L.str("network.scan.ports.rangePlaceholder"),
                        text: $portText
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .disabled(isScanning)
                } else {
                    // 기본 포트 목록 표시 (중복 타이틀 대신 실제 포트 나열).
                    Text(AppSettings.shared.effectiveDefaultScanPorts.map(String.init).joined(separator: ", "))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if isScanning {
                HStack(spacing: 10) {
                    ProgressView(
                        value: Double(scanCompleted),
                        total: Double(max(scanTotal, 1))
                    )
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                    Text(percentLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(
                        scanStageAlive
                            ? L.str("network.scan.aliveChecking", scanCompleted, scanTotal)
                            : L.str("network.scan.checking", scanCompleted, scanTotal)
                    )
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(L.str("network.scan.found", scanResults.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }

            if let error = scanError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            scanResultsTable

            HStack {
                if let result = selectedScanResult {
                    Text(L.str("network.scan.selected", "\(result.ip):\(result.port)", result.service))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L.str("network.scan.createTunnel")) {
                        createTunnel(for: result)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(tunnels.cloudflaredPath == nil)
                    .help(tunnels.cloudflaredPath == nil
                        ? L.str("error.cloudflaredNotInstalled")
                        : L.str("network.scan.createTunnel"))
                } else {
                    Spacer()
                    Text(L.str("network.scan.selectHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scanResultsTable: some View {
        Table(scanResults, selection: $selectedResult) {
            TableColumn(L.str("network.scan.table.ip")) { result in
                Text(result.ip)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 100, max: 120)
            TableColumn(L.str("network.scan.table.port")) { result in
                // 천단위 구분자 없이 (5,555 → 5555)
                Text(String(result.port))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(56)
            TableColumn(L.str("network.scan.table.service")) { result in
                Text(result.service)
                    .lineLimit(1)
            }
            .width(min: 90, max: 120)
            TableColumn(L.str("network.scan.table.info")) { result in
                Text(result.httpServer ?? "–")
                    .foregroundStyle(result.httpServer == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(height: 160)
    }

    private func startScan(hosts: [String]) {
        guard !hosts.isEmpty else { return }
        // 포트 3종: 기본 / 지정 / 대역 (지정·대역은 PortList 파서 공유).
        let mode = portMode
        let input = portText
        let ports: [Int]
        switch mode {
        case .defaultPorts:
            ports = AppSettings.shared.effectiveDefaultScanPorts
        case .custom:
            // 비우면常用 포트 전체(1~10000). 49152 위는 ephemeral이라 제외.
            // LAN 전체에선 tooMany 가드로 차단됨.
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                ports = Array(1...10000)
                break
            }
            let parsed = PortList.parse(trimmed)
            guard !parsed.isEmpty, !PortList.hasInvalidToken(trimmed) else {
                scanError = L.str("settings.scanPorts.invalid")
                return
            }
            ports = parsed
        case .range:
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                scanError = L.str("network.scan.ports.empty")
                return
            }
            let parsed = PortList.parse(trimmed)
            guard !parsed.isEmpty, !PortList.hasInvalidToken(trimmed) else {
                scanError = L.str("settings.scanPorts.invalid")
                return
            }
            ports = parsed
        }
        // 가드: LAN 전체 × 대역 폭발 차단. 풀 대역(65,535)은 단일 IP에서만.
        if hosts.count > 16, ports.count > 500 {
            scanError = L.str("network.scan.tooMany", hosts.count * ports.count)
            return
        }
        scanError = nil
        isScanning = true
        // 누적 머지: 스캔 대상 호스트는 새 결과로 교체, 대상 밖은 유지.
        let previous = scanResults
        let scannedSet = Set(hosts)
        scanCompleted = 0
        scanTotal = hosts.count * ports.count
        scanElapsed = nil
        let started = Date()
        // 백그라운드 스캔: 무거운 작업이 메인스레드를 막지 않음.
        // UI 발행은 0.5초 배치로 스로틀 (행걸림/스크롤 버벅 방지).
        Task {
            // 같은 네트워크 전체면 생존 필터 먼저 (20초 → 2~3초).
            // 1단계 진행률(생존 확인)도 표시해서 0% 정체처럼 보이지 않게.
            var targets = hosts
            var timeout: TimeInterval = hosts.count > 1 ? 0.5 : 0.8
            if hosts.count > 16 {
                await MainActor.run {
                    scanStageAlive = true
                    scanCompleted = 0
                    scanTotal = hosts.count
                }
                let alive = await NetworkScanner.shared.aliveHosts(candidates: hosts) { done, total in
                    Task { await MainActor.run {
                        scanCompleted = done
                        scanTotal = total
                    } }
                }
                if !alive.isEmpty {
                    targets = alive
                    let total = alive.count * ports.count
                    await MainActor.run {
                        scanStageAlive = false
                        scanCompleted = 0
                        scanTotal = total
                    }
                } else {
                    timeout = 0.35
                    await MainActor.run { scanStageAlive = false }
                }
            }
            let drain = ScanDrain(seen: Set(previous.map { "\($0.ip):\($0.port)" }))
            let results = await NetworkScanner.shared.scan(
                hosts: targets,
                ports: ports,
                timeout: timeout,
                fingerprint: true
            ) { result in
                drain.append(result)
            } onProgress: { progress in
                let batch = drain.popBatchIfDue(interval: 0.5)
                Task { await MainActor.run {
                    if !batch.isEmpty { scanResults.append(contentsOf: batch) }
                    scanCompleted = progress.completed
                } }
            }
            let tail = drain.popAll()
            let elapsed = Date().timeIntervalSince(started)
            let ownIP = NetworkScanner.localIPv4Addresses().first
            await MainActor.run {
                scanElapsed = elapsed
                scanStageAlive = false
                logScanDiagnostics(hosts: targets, results: results, started: started, ownIP: ownIP)
                // 재스캔 머지: 스캔한 호스트 중 새 결과에 없으면(닫힘) 삭제.
                let kept = previous.filter { !scannedSet.contains($0.ip) }
                // 포트 번호 ASC 정렬 (포트 → IP).
                let merged = (kept + results).sorted { ($0.port, $0.ip) < ($1.port, $1.ip) }
                var dedup: Set<String> = []
                scanResults = merged.filter { dedup.insert("\($0.ip):\($0.port)").inserted }
                _ = tail
                lastTarget = targets.count > 1 ? L.str("network.scan.lastTarget.lan", targets.count) : targets.first
                cacheInfo = nil
                saveCachedScan(hosts: targets, ownIP: ownIP, results: scanResults)
                isScanning = false
            }
        }
    }

    private var percentLabel: String {
        guard scanTotal > 0 else { return "–" }
        return "\(Int(Double(scanCompleted) / Double(scanTotal) * 100))%"
    }

    // MARK: - 스캔 결과 캐시

    private var scanCacheURL: URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Etchost-LastScan.json")
        }
        let dir = base.appendingPathComponent("Etchost", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("LastScan.json")
    }

    private func loadCachedScanIfEmpty() {
        guard !isScanning, scanResults.isEmpty else { return }
        guard let data = try? Data(contentsOf: scanCacheURL),
              let cached = try? JSONDecoder().decode(CachedScan.self, from: data),
              !cached.results.isEmpty else { return }
        scanResults = cached.results
        lastTarget = cached.target
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let time = formatter.string(from: cached.scannedAt)
        cacheInfo = L.str("network.scan.cache", time, cached.ownIP)
    }

    private func saveCachedScan(hosts: [String], ownIP: String?, results: [PortScanResult]) {
        guard !hosts.isEmpty else { return }
        guard let first = hosts.first else { return }
        let target = hosts.count > 1 ? L.str("network.scan.lastTarget.lan", hosts.count) : first
        let cached = CachedScan(target: target, scannedAt: Date(), ownIP: ownIP ?? "", results: results)
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: scanCacheURL)
        }
    }

    private func logScanDiagnostics(hosts: [String], results: [PortScanResult], started: Date, ownIP: String?) {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("Etchost/debug.log")
        let found = results.map { "\($0.ip):\($0.port)" }.joined(separator: " ")
        let elapsed = Date().timeIntervalSince(started)
        let line = "\(Date().ISO8601Format()) [scan] own=\(ownIP ?? "-") range=\(hosts.first ?? "-")..\(hosts.last ?? "-") hosts=\(hosts.count) elapsed=\(String(format: "%.1f", elapsed))s found=[\(found)]\n"
        guard let data = line.data(using: .utf8) else { return }
        if fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func lanHosts() -> [String] {
        // 실제 넷마스크 기반 (회사망 /20 등 대응, 최대 2048 cap).
        let hosts = NetworkScanner.localSubnetHosts()
        if !hosts.isEmpty { return hosts }
        guard let own = NetworkScanner.localIPv4Addresses().first else { return [] }
        return NetworkScanner.subnetIPv4Addresses(from: own)
    }

    // MARK: - 터널 만들기

    private func createTunnel(for result: PortScanResult) {
        let base = result.service.isEmpty ? "port-\(result.port)" : result.service
        // 같은 서비스 포트가 여러 개여도 이름 충돌 없도록 ip:port를 포함해 유니크하게.
        // 포트 천단위 구분자 방지: %@ + 문자열 전달 (로케일 %d 그룹핑 회피).
        let label = L.str("network.tunnel.labelFormat", base, result.ip, String(result.port))
        do {
            try tunnels.createTunnel(label: label, ip: result.ip, port: result.port, start: true)
        } catch {
            scanError = error.localizedDescription
        }
    }

    // MARK: - 터널 목록

    private var tunnelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.str("network.tunnel.title"))
                    .font(.headline)
                Spacer()
                if !tunnels.tunnels.isEmpty {
                    Text(L.str("network.tunnel.connected", model.currentIP ?? L.str("network.ip.checking")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if tunnels.tunnels.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.str("network.tunnel.none"))
                            .font(.body)
                        Text(L.str("network.tunnel.noneHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.vertical, 4)
            } else {
                tunnelTable
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var tunnelTable: some View {
        // 중요도순: 제어 → 상태 → 포트 → URL → 대상 → 이름 (좁으면 오른쪽부터 잘림).
        Table(tunnels.tunnels) {
            TableColumn(L.str("network.tunnel.table.control")) { tunnel in
                controls(for: tunnel)
            }
            .width(108)
            TableColumn(L.str("network.tunnel.table.status")) { tunnel in
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor(tunnel.status))
                        .frame(width: 8, height: 8)
                    Text(tunnel.status.title)
                }
                .help(tunnel.status.title)
            }
            .width(88)
            TableColumn(L.str("network.tunnel.table.port")) { tunnel in
                Text(String(tunnel.port))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("\(tunnel.ip):\(tunnel.port)")
            }
            .width(56)
            TableColumn(L.str("network.tunnel.table.url")) { tunnel in
                if let domain = tunnel.publicDomain {
                    HStack(spacing: 6) {
                        Text(shortDomain(domain))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(domain)
                        Button {
                            copyToPasteboard(domain)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            openInBrowser(domain)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Text("–")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 150, ideal: 220)
            TableColumn(L.str("network.tunnel.table.target")) { tunnel in
                Text(tunnel.ip)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(tunnel.ip)
            }
            .width(min: 110, max: 140)
            TableColumn(L.str("network.tunnel.table.name")) { tunnel in
                Text(tunnel.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(tunnel.label)
            }
            .width(min: 120, max: 180)
        }
        .frame(minHeight: 120, maxHeight: .infinity)
    }

    /// `https://xxx.trycloudflare.com` → `xxx.trycloudflare.com` 단축 표시.
    private func shortDomain(_ urlString: String) -> String {
        if let url = URL(string: urlString), let host = url.host, !host.isEmpty {
            return host
        }
        return urlString
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private func controls(for tunnel: ManagedTunnel) -> some View {
        HStack {
            Button {
                logTunnelID = TunnelLogSelection(tunnelID: tunnel.id)
            } label: {
                Image(systemName: "terminal")
            }
            .help(L.str("network.tunnel.control.log"))
            switch tunnel.status {
            case .running:
                Button {
                    tunnels.stopTunnel(tunnel.id)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .help(L.str("network.tunnel.control.stop"))
            case .starting, .stopping:
                ProgressView()
                    .controlSize(.small)
            default:
                Button {
                    tunnels.startTunnel(tunnel.id)
                } label: {
                    Image(systemName: "play.circle")
                }
                .help(L.str("network.tunnel.control.start"))
            }
            Button {
                try? tunnels.deleteTunnel(tunnel.id)
            } label: {
                Image(systemName: "trash")
            }
            .help(L.str("network.tunnel.control.delete"))
        }
    }

    private func statusColor(_ status: TunnelStatus) -> Color {
        switch status {
        case .running: return .green
        case .error: return .red
        case .stopped: return .gray.opacity(0.5)
        case .starting, .stopping: return .orange
        default: return .gray
        }
    }
}

private extension NetworkView {
    var selectedScanResult: PortScanResult? {
        guard let id = selectedResult else { return nil }
        return scanResults.first { $0.id == id }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openInBrowser(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 스캔 발견 버퍼. 스캐너 콜백(단일 consumer 루프에서 직렬 호출)용.
/// UI 발행은 0.5초 배치로 스로틀해서 Table 재렌더/스크롤 버벅을 방지.
private final class ScanDrain: @unchecked Sendable {
    private var pending: [PortScanResult] = []
    private var seen: Set<String>
    private var lastFlush = Date()

    init(seen: Set<String>) { self.seen = seen }

    func append(_ result: PortScanResult) {
        guard seen.insert("\(result.ip):\(result.port)").inserted else { return }
        pending.append(result)
    }

    /// 마지막 flush 후 interval이 지났으면 대기분 반환, 아니면 빈 배열.
    func popBatchIfDue(interval: TimeInterval) -> [PortScanResult] {
        guard !pending.isEmpty, Date().timeIntervalSince(lastFlush) >= interval else { return [] }
        lastFlush = Date()
        let batch = pending
        pending = []
        return batch
    }

    func popAll() -> [PortScanResult] {
        lastFlush = Date()
        let batch = pending
        pending = []
        return batch
    }
}

/// 터널 cloudflared 로그 시트. 표시 중 0.7초마다 로그를 갱신한다.
struct TunnelLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tunnels: TunnelManager
    let id: UUID
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.str("network.tunnel.log.title"))
                    .font(.headline)
                Spacer()
                Button {
                    copyToPasteboard(text)
                } label: {
                    Label(L.str("network.tunnel.log.copy"), systemImage: "doc.on.doc")
                }
                Button(L.str("network.tunnel.log.close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(text.isEmpty ? L.str("network.tunnel.log.empty") : text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(width: 560, height: 360)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .overlay(alignment: .bottomTrailing) {
                if text.isEmpty {
                    Text(L.str("network.tunnel.log.auto"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
        }
        .padding(16)
        .onAppear {
            text = tunnels.logText(for: id)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                text = tunnels.logText(for: id)
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
