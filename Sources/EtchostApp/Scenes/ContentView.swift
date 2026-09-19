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
                            L.str("content.noProfile.title"),
                            systemImage: "server.rack",
                            description: Text(L.str("content.noProfile.description"))
                        )
                    }
                case .fragments:
                    if let selected = model.selectedFragment {
                        FragmentEditor(fragment: selected)
                            .id(selected.id)
                    } else {
                        ContentUnavailableView(
                            L.str("content.noFragment.title"),
                            systemImage: "puzzlepiece",
                            description: Text(L.str("content.noFragment.description"))
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
                        model.isApplying ? L.str("content.applying") : L.str("content.apply"),
                        systemImage: "checkmark.seal"
                    )
                }
                .disabled(model.activeProfile == nil || model.isApplying)

                Button {
                    showingHostsPreview.toggle()
                } label: {
                    Label(L.str("content.previewLabel"), systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .onChange(of: model.sidebarSection) { showingHostsPreview = false }
        .onChange(of: model.selectedProfileID) { showingHostsPreview = false }
        .onChange(of: model.selectedFragmentID) { showingHostsPreview = false }
    }
}
