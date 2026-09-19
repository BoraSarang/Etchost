import AppKit
import EtchostKit
import SwiftUI

/// 네트워크 허브: localhost/LAN 포트 스캔 + cloudflared quick tunnel 관리.
struct NetworkView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var tunnels: TunnelManager

    @State private var hostInput = ""
    @State private var scanResults: [PortScanResult] = []
    @State private var selectedResult: PortScanResult.ID?
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var lastTarget: String?
    @State private var scanCompleted = 0
    @State private var scanTotal = 0
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
                TextField(L.str("network.scan.inputPlaceholder"), text: $hostInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Button(L.str("network.scan.localhost")) {
                    startScan(hosts: ["127.0.0.1"])
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
                Button(L.str("network.scan.custom")) {
                    let ip = hostInput.trimmingCharacters(in: .whitespaces)
                    startScan(hosts: ip.isEmpty ? ["127.0.0.1"] : [ip])
                }
                .disabled(isScanning)
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
                    Text(L.str("network.scan.checking", scanCompleted, scanTotal))
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
            TableColumn(L.str("network.scan.table.ip")) { Text($0.ip) }
            TableColumn(L.str("network.scan.table.port")) { Text("\($0.port)") }
            TableColumn(L.str("network.scan.table.service")) { Text($0.service) }
            TableColumn(L.str("network.scan.table.http")) { Text($0.httpServer ?? "–") }
        }
        .frame(height: 160)
    }

    private func startScan(hosts: [String]) {
        guard !hosts.isEmpty else { return }
        let ports = AppSettings.shared.configuredScanPorts ?? NetworkScanner.commonPorts
        scanError = nil
        isScanning = true
        scanResults = []
        scanCompleted = 0
        scanTotal = hosts.count * ports.count
        let started = Date()
        Task { @MainActor in
            var seen: Set<String> = []
            let results = await NetworkScanner.shared.scan(
                hosts: hosts,
                ports: ports,
                timeout: 1.0,
                fingerprint: true
            ) { result in
                guard seen.insert("\(result.ip):\(result.port)").inserted else { return }
                scanResults.append(result)
            } onProgress: { progress in
                scanCompleted = progress.completed
            }
            logScanDiagnostics(hosts: hosts, results: results, started: started, ownIP: NetworkScanner.localIPv4Addresses().first)
            scanResults = results
            lastTarget = hosts.count > 1 ? L.str("network.scan.lastTarget.lan", hosts.count) : hosts.first
            cacheInfo = nil
            saveCachedScan(hosts: hosts, ownIP: NetworkScanner.localIPv4Addresses().first, results: results)
            isScanning = false
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
        guard let own = NetworkScanner.localIPv4Addresses().first else { return [] }
        return NetworkScanner.subnetIPv4Addresses(from: own)
    }

    // MARK: - 터널 만들기

    private func createTunnel(for result: PortScanResult) {
        let base = result.service.isEmpty ? "port-\(result.port)" : result.service
        // 같은 서비스 포트가 여러 개여도 이름 충돌 없도록 ip:port를 포함해 유니크하게.
        let label = L.str("network.tunnel.labelFormat", base, result.ip, result.port)
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
        Table(tunnels.tunnels) {
            TableColumn(L.str("network.tunnel.table.name")) { Text($0.label).lineLimit(1) }
            TableColumn(L.str("network.tunnel.table.target")) { Text("\($0.ip):\($0.port)") }
            TableColumn(L.str("network.tunnel.table.status")) { tunnel in
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor(tunnel.status))
                        .frame(width: 8, height: 8)
                    Text(tunnel.status.title)
                }
            }
            TableColumn(L.str("network.tunnel.table.url")) { tunnel in
                if let domain = tunnel.publicDomain {
                    HStack(spacing: 6) {
                        Text(domain)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
            TableColumn(L.str("network.tunnel.table.control")) { tunnel in
                controls(for: tunnel)
            }
        }
        .frame(minHeight: 120, maxHeight: .infinity)
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
