import EtchostKit
import SwiftUI

/// 메뉴바 팝오버: 상태카드 + 프로필 빠른 전환 + 현재 적용된 호스트 표.
struct MenuBarPopover: View {
    @EnvironmentObject var model: AppModel
    @State private var tableRows: [HostsTableRow] = []
    @State private var isLive = true
    private let buildTag = "v0.5.0"

    var body: some View {
        VStack(spacing: 8) {
            statusCard
            Divider()
            profileSwitcher
            Divider()
            hostsTable
            Divider()
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 430, height: 360, alignment: .top)
        .onAppear {
            reload()
            logMenuState()
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
                    Text(model.activeProfile?.name ?? "프로필 없음")
                        .font(.headline)
                    if let active = model.activeProfile {
                        if model.needsReapply(active) {
                            Text("적용 필요")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("적용됨")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
                Text(isLive ? "활성 프로필" : "미리보기 (파일 읽기 실패)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("새로고침")
            Button {
                Task { await model.applyActiveProfile() }
            } label: {
                Text(model.isApplying ? "적용 중…" : "적용")
            }
            .disabled(model.activeProfile == nil || model.isApplying)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 프로필 빠른 전환

    private var profileSwitcher: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("프로필 (클릭 즉시 적용)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.profiles.isEmpty {
                Text("프로필 없음")
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
                                    .fill(dotColor(isActive: profile.isActive, reapply: reapply))
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

    // MARK: - 현재 적용된 호스트 표

    private var hostsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isLive ? "현재 적용된 호스트 (/etc/hosts)" : "미리보기 (파일 읽기 실패 폴백)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if tableRows.isEmpty {
                Text("표시할 항목 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(tableRows) {
                    TableColumn("그룹", value: \.group)
                        .width(min: 95, ideal: 120, max: 170)
                    TableColumn("IP", value: \.ip)
                        .width(min: 90, ideal: 115)
                    TableColumn("호스트", value: \.host)
                        .width(min: 80, ideal: 130)
                    TableColumn("주석", value: \.comment)
                    TableColumn("상태") { row in
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
            Button("메인 창 열기") {
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            SettingsLink {
                Text("설정…")
            }
            Text("Etchost \(buildTag)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 헬퍼

    private func dotColor(isActive: Bool, reapply: Bool) -> Color {
        if isActive { return reapply ? .orange : .green }
        return reapply ? .orange.opacity(0.6) : .gray.opacity(0.5)
    }

    private func reload() {
        tableRows = model.hostsTableRows
        isLive = model.lastHostsIsLive
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
            try? handle.seekToEnd()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
