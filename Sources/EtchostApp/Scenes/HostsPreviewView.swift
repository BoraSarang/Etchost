import EtchostKit
import SwiftUI

/// 실제 /etc/hosts에 반영된 내용을 앱 안에서 표시 (cat 대체).
struct HostsPreviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var text: String = ""
    @State private var isLive = true
    @State private var loadedOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if !loadedOnce {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if text.isEmpty {
                ContentUnavailableView(
                    L.str("content.noHosts.title"),
                    systemImage: "doc.text",
                    description: Text(L.str("content.noHosts.description"))
                )
            } else {
                HostsLineList(text: text, minHeight: 0)
            }
        }
        .padding(16)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .hostsApplied)) { _ in reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(L.str("content.previewLabel"), systemImage: "doc.text.magnifyingglass")
                    .font(.title2.bold())
                Spacer()
                if let active = model.activeProfile {
                    if model.needsReapply(active) {
                        Label(L.str("menu.needsReapply"), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Label(L.str("menu.applied"), systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Button {
                    reload()
                } label: {
                    Label(L.str("menu.refresh"), systemImage: "arrow.clockwise")
                }
            }
            HStack(spacing: 6) {
                Text(isLive ? L.str("menu.hosts.titleLive") : L.str("menu.hosts.titlePreview"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let active = model.activeProfile {
                    Text(L.str("sidebar.activeProfile", active.name))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reload() {
        text = model.currentHosts
        isLive = model.lastHostsIsLive
        loadedOnce = true
    }
}
