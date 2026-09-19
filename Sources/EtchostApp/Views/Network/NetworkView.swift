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

    init() {
        _tunnels = ObservedObject(wrappedValue: TunnelManager.shared)
    }

    var body: some View {
        VStack(spacing: 0) {
            cloudflaredBanner
            ipChangeBanner
            Divider()
            scannerSection
            Divider()
            tunnelSection
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - cloudflared 상태 배너

    private var cloudflaredBanner: some View {
        HStack(spacing: 8) {
            if tunnels.cloudflaredPath != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("cloudflared \(tunnels.cloudflaredVersion ?? "설치됨")")
                    .font(.callout)
                Text("· 현재 IP \(model.currentIP ?? "확인 중")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if tunnels.isInstalling {
                ProgressView()
                    .controlSize(.small)
                Text(tunnels.installMessage ?? "cloudflared 설치 중…")
                    .font(.callout)
                Spacer()
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("cloudflared가 없습니다 — 터널을 만들려면 설치가 필요합니다.")
                    .font(.callout)
                Spacer()
                Button("설치") {
                    Task { try? await tunnels.installCloudflared() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
    }

    @ViewBuilder
    private var ipChangeBanner: some View {
        if let change = tunnels.lastIPChange {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                Text("IP 변경 \(change.old ?? "없음") → \(change.new) — 실행 중 터널 자동 재시작")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.12))
        }
    }

    // MARK: - 스캐너

    private var scannerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("포트 스캔")
                    .font(.headline)
                Spacer()
                if let target = lastTarget {
                    Text(target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                TextField("스캔 IP (비우면 localhost)", text: $hostInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Button("localhost 스캔") {
                    startScan(hosts: ["127.0.0.1"])
                }
                .disabled(isScanning)
                Button("LAN 스캔") {
                    startScan(hosts: lanHosts())
                }
                .disabled(isScanning)
                Button("지정 IP") {
                    let ip = hostInput.trimmingCharacters(in: .whitespaces)
                    startScan(hosts: ip.isEmpty ? ["127.0.0.1"] : [ip])
                }
                .disabled(isScanning)
                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = scanError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            scanResultsTable

            HStack {
                if let result = selectedScanResult {
                    Text("선택: \(result.ip):\(result.port) (\(result.service))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("터널 만들기") {
                        createTunnel(for: result)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Spacer()
                    Text("결과 행을 선택하면 터널을 만들 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private var scanResultsTable: some View {
        Table(scanResults, selection: $selectedResult) {
            TableColumn("IP") { Text($0.ip) }
            TableColumn("포트") { Text("\($0.port)") }
            TableColumn("서비스") { Text($0.service) }
            TableColumn("HTTP") { Text($0.httpServer ?? "–") }
        }
        .frame(height: 160)
    }

    private func startScan(hosts: [String]) {
        guard !hosts.isEmpty else { return }
        scanError = nil
        isScanning = true
        Task { @MainActor in
            let results = await NetworkScanner.shared.scan(
                hosts: hosts,
                ports: NetworkScanner.commonPorts,
                timeout: 1.0,
                fingerprint: true
            )
            scanResults = results
            lastTarget = hosts.count > 1 ? "LAN \(hosts.count)개 호스트" : hosts.first
            isScanning = false
        }
    }

    private func lanHosts() -> [String] {
        guard let own = NetworkScanner.localIPv4Addresses().first else { return [] }
        return NetworkScanner.subnetIPv4Addresses(from: own)
    }

    // MARK: - 터널 만들기

    private func createTunnel(for result: PortScanResult) {
        let base = result.service.isEmpty ? "port-\(result.port)" : result.service
        let label = "\(base) 도메인"
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
                Text("cloudflared 터널")
                    .font(.headline)
                Spacer()
                if !tunnels.tunnels.isEmpty {
                    Text("IP \(model.currentIP ?? "확인 중")에 연결됨")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if tunnels.tunnels.isEmpty {
                ContentUnavailableView(
                    "터널 없음",
                    systemImage: "network",
                    description: Text("스캔 결과 행을 선택하고 '터널 만들기'를 누르세요.")
                )
            } else {
                tunnelTable
            }
        }
        .padding(12)
    }

    private var tunnelTable: some View {
        Table(tunnels.tunnels) {
            TableColumn("이름") { Text($0.label).lineLimit(1) }
            TableColumn("대상") { Text("\($0.ip):\($0.port)") }
            TableColumn("상태") { tunnel in
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor(tunnel.status))
                        .frame(width: 8, height: 8)
                    Text(tunnel.status.title)
                }
            }
            TableColumn("공개 URL") { tunnel in
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
            TableColumn("제어") { tunnel in
                controls(for: tunnel)
            }
        }
        .frame(minHeight: 120)
    }

    private func controls(for tunnel: ManagedTunnel) -> some View {
        HStack {
            switch tunnel.status {
            case .stopped, .error:
                Button("시작") {
                    tunnels.startTunnel(tunnel.id)
                }
            case .running:
                Button("정지") {
                    tunnels.stopTunnel(tunnel.id)
                }
            case .starting, .stopping:
                ProgressView()
                    .controlSize(.small)
            default:
                Button("시작") {
                    tunnels.startTunnel(tunnel.id)
                }
            }
            Button("삭제", role: .destructive) {
                try? tunnels.deleteTunnel(tunnel.id)
            }
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
