import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingHostsPreview = false

    var body: some View {
        NavigationSplitView {
            ProfileSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if showingHostsPreview {
                HostsPreviewView()
            } else {
                switch model.sidebarSection {
                case .profiles:
                    if let selected = model.selectedProfile {
                        ProfileEditor(profile: selected)
                            .id(selected.id)
                    } else {
                        ContentUnavailableView(
                            "프로필 없음",
                            systemImage: "server.rack",
                            description: Text("좌측 + 버튼으로 첫 프로필을 만드세요.")
                        )
                    }
                case .fragments:
                    if let selected = model.selectedFragment {
                        FragmentEditor(fragment: selected)
                            .id(selected.id)
                    } else {
                        ContentUnavailableView(
                            "프래그먼트 없음",
                            systemImage: "puzzlepiece",
                            description: Text("좌측 + 버튼으로 첫 조각을 만드세요.")
                        )
                    }
                case .network:
                    NetworkView()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.applyActiveProfile() }
                } label: {
                    Label(
                        model.isApplying ? "적용 중…" : "적용",
                        systemImage: "checkmark.seal"
                    )
                }
                .disabled(model.activeProfile == nil || model.isApplying)

                Button {
                    showingHostsPreview.toggle()
                } label: {
                    Label("반영 내용", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .onChange(of: model.sidebarSection) { showingHostsPreview = false }
        .onChange(of: model.selectedProfileID) { showingHostsPreview = false }
        .onChange(of: model.selectedFragmentID) { showingHostsPreview = false }
    }
}
