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
                    "내용 없음",
                    systemImage: "doc.text",
                    description: Text("아직 반영된 내용이 없습니다.")
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
                Label("반영 내용", systemImage: "doc.text.magnifyingglass")
                    .font(.title2.bold())
                Spacer()
                if let active = model.activeProfile {
                    if model.needsReapply(active) {
                        Label("적용 필요", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Label("적용됨", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Button {
                    reload()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
            }
            HStack(spacing: 6) {
                Text(isLive ? "/etc/hosts 실제 파일" : "미리보기 (파일 읽기 실패 폴백)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let active = model.activeProfile {
                    Text("· 활성: \(active.name)")
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

public extension Notification.Name {
    static let hostsApplied = Notification.Name("etchost.hostsApplied")
}
