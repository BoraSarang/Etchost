import AppKit
import EtchostKit
import SwiftUI

/// 메뉴바 팝오버: 상태카드 + 프로필 빠른 전환 + 터널 + 현재 적용된 호스트 표.
struct MenuBarPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(AppSettings.self) private var settings
    @ObservedObject private var tunnels: TunnelManager
    @State private var tableRows: [HostsTableRow] = []
    @State private var isLive = true
    @State private var hoveredDomain: String?
    @State private var dismissWorkItem: DispatchWorkItem?
    private let buildTag = "v0.6.1"

    init() {
        _tunnels = ObservedObject(wrappedValue: TunnelManager.shared)
    }

    var body: some View {
        VStack(spacing: 8) {
            statusCard
            Divider()
            profileSwitcher
            Divider()
            tunnelSection
            Divider()
            hostsTable
            Divider()
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 430, alignment: .top)
        .onAppear {
            reload()
            logMenuState()
            Task {
                await settings.maybeAutoCheckForUpdate()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hostsApplied)) { _ in reload() }
    }

    // MARK: - 상태카드

    private var statusCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.activeProfile?.name ?? L.str("menu.noProfile"))
                        .font(.headline)
                    if let active = model.activeProfile {
                        if model.needsReapply(active) {
                            Text(L.str("menu.needsReapply"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text(L.str("menu.applied"))
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
                Text(isLive ? L.str("menu.status.active") : L.str("menu.status.preview"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L.str("menu.refresh"))
            Button {
                Task { await model.applyActiveProfile() }
            } label: {
                Text(model.isApplying ? L.str("menu.applying") : L.str("menu.apply"))
            }
            .disabled(model.activeProfile == nil || model.isApplying)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 프로필 빠른 전환

    private var profileSwitcher: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.str("menu.profileSection"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.profiles.isEmpty {
                Text(L.str("menu.noProfile"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.profiles) { profile in
                        let reapply = model.needsReapply(profile)
                        Button {
                            Task { await model.switchAndApply(profile.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(StatusDots.profile(isActive: profile.isActive, reapply: reapply))
                                    .frame(width: 7, height: 7)
                                Text(profile.name)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer()
                                if reapply {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                if profile.isActive {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .background(
                                profile.isActive ? Color.gray.opacity(0.2) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled((profile.isActive && !reapply) || model.isApplying)
                    }
                }
            }
            .frame(height: 76)
            .scrollIndicators(.visible)
        }
    }

    // MARK: - 터널 (프로필과 동일 스타일, 3개 표시 + 스크롤)

    private var tunnelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L.str("menu.tunnelSection", runningTunnelCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if tunnels.tunnels.count > 3 {
                    Text(L.str("menu.tunnel.more", tunnels.tunnels.count - 3))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if tunnels.tunnels.isEmpty {
                Text(L.str("menu.tunnel.noneHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tunnels.tunnels) { tunnel in
                            tunnelRow(tunnel)
                        }
                    }
                }
                .frame(height: tunnelListHeight())
                .scrollIndicators(.visible)
            }
        }
        .popover(isPresented: domainPopoverBinding, arrowEdge: .top) {
            domainPopover
        }
    }

    private var domainPopoverBinding: Binding<Bool> {
        Binding(
            get: { hoveredDomain != nil },
            set: { if !$0 {
                dismissWorkItem?.cancel()
                hoveredDomain = nil
            } }
        )
    }

    private func tunnelListHeight() -> CGFloat {
        let rows = min(tunnels.tunnels.count, 3)
        return CGFloat(rows) * 30 + CGFloat(max(rows - 1, 0)) * 2
    }

    private func tunnelRow(_ tunnel: ManagedTunnel) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(StatusDots.tunnel(tunnel.status))
                .frame(width: 7, height: 7)
            Text(tunnel.label)
                .font(.body)
                .lineLimit(1)
            Text("\(tunnel.ip):\(tunnel.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()

            if tunnels.cloudflaredPath == nil {
                Text(L.str("menu.tunnel.cloudflareMissing"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            switch tunnel.status {
            case .stopped, .error:
                Button(L.str("menu.tunnel.start")) {
                    tunnels.startTunnel(tunnel.id)
                }
            case .running:
                Button(L.str("menu.tunnel.stop")) {
                    tunnels.stopTunnel(tunnel.id)
                }
            default:
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            tunnel.status.isActive ? Color.gray.opacity(0.2) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { hovering in
            hoverChanged(hovering, domain: tunnel.publicDomain)
        }
    }

    // MARK: - 도메인 팝오버 (섹션 고정 앵커, 방향 불변)

    private func hoverChanged(_ hovering: Bool, domain: String?) {
        dismissWorkItem?.cancel()
        if hovering, let domain {
            hoveredDomain = domain
        } else {
            // 즉시 닫으면 버튼 클릭으로 이동하는 중 팝오버가 사라짐 → 지연 닫기.
            let item = DispatchWorkItem { hoveredDomain = nil }
            dismissWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
    }

    @ViewBuilder
    private var domainPopover: some View {
        if let domain = hoveredDomain {
            VStack(spacing: 10) {
                Text(domain)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(domain, forType: .string)
                    } label: {
                        Label(L.str("menu.domain.copy"), systemImage: "doc.on.doc")
                    }
                    Button {
                        NSWorkspace.shared.open(Self.url(for: domain))
                    } label: {
                        Label(L.str("menu.domain.open"), systemImage: "arrow.up.right.square")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(12)
            .onHover { hovering in
                // 팝오버 위에 마우스가 있으면 닫기 예약 취소.
                if hovering {
                    dismissWorkItem?.cancel()
                }
            }
        }
    }

    // MARK: - 현재 적용된 호스트 표

    private var hostsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isLive ? L.str("menu.hosts.titleLive") : L.str("menu.hosts.titlePreview"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if tableRows.isEmpty {
                Text(L.str("menu.hosts.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(tableRows) {
                    TableColumn(L.str("menu.hosts.column.group"), value: \.group)
                        .width(min: 95, ideal: 120, max: 170)
                    TableColumn(L.str("menu.hosts.column.ip"), value: \.ip)
                        .width(min: 90, ideal: 115)
                    TableColumn(L.str("menu.hosts.column.host"), value: \.host)
                        .width(min: 80, ideal: 130)
                    TableColumn(L.str("menu.hosts.column.comment"), value: \.comment)
                    TableColumn(L.str("menu.hosts.column.status")) { row in
                        Circle()
                            .fill(row.isEnabled ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                    }
                    .width(28)
                }
                .tableStyle(.automatic)
                .frame(height: 126)
            }
        }
    }

    // MARK: - 하단

    private var footer: some View {
        HStack(spacing: 12) {
            Button(L.str("menu.openMain")) {
                // StatusItemController.handleOpenMainWindow가 팝오버 닫기 → 창 열기를 처리.
                // (직접 openMain 중복 호출 제거: synchronous post로 먼저 처리됨)
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            }
            Spacer()
            versionOrUpdateView
            SettingsLink {
                Text(L.str("menu.settings"))
            }
            Button(L.str("menu.quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - 헬퍼

    /// 하단 버전 표시. 새 버전이 있으면 주황색 표시 + 클릭 시 업데이트 창.
    @ViewBuilder
    private var versionOrUpdateView: some View {
        if let update = settings.availableUpdate {
            Button {
                NotificationCenter.default.post(name: .showUpdateSheet, object: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(L.str("menu.updateAvailable", update.tag))
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(L.str("settings.update.details"))
        } else {
            Text("Etchost \(buildTag)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var runningTunnelCount: Int {
        tunnels.tunnels.filter { $0.status.isActive }.count
    }

    private func reload() {
        tableRows = model.hostsTableRows
        isLive = model.lastHostsIsLive
    }

    /// 베어 도메인(스킴 없음)은 https:// 를 붙여 연다. (P2-1: 조용한 실패 수정)
    static func url(for domain: String) -> URL {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://"), let url = URL(string: trimmed) {
            return url
        }
        return URL(string: "https://\(trimmed)") ?? URL(string: "https://localhost")!
    }

    /// 팝오버가 열릴 때 메뉴 상태를 파일에 기록 (원격 진단용).
    private func logMenuState() {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("Etchost/debug.log")
        let rows = model.profiles.map { "\($0.name):active=\($0.isActive),reapply=\(model.needsReapply($0))" }
            .joined(separator: " | ")
        let line = "\(Date().ISO8601Format()) [\(buildTag)] rows=[\(rows)] applying=\(model.isApplying)\n"
        guard let data = line.data(using: .utf8) else { return }
        if fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
