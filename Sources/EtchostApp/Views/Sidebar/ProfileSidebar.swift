import EtchostKit
import SwiftUI

/// 좌측 사이드바: 상태카드 + 프로필/프래그먼트 탭(50%씩) + 선택 탭 목록.
struct ProfileSidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var renamingID: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            statusCard
                .padding(8)

            tabBar
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            switch model.sidebarSection {
            case .profiles:
                profileList
            case .fragments:
                fragmentList
            case .network:
                tunnelList
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.sidebarSection != .network {
                    Button {
                        switch model.sidebarSection {
                        case .profiles:
                            createProfile()
                        case .fragments:
                            createFragment()
                        case .network:
                            break
                        }
                    } label: {
                        Label(L.str("sidebar.add"), systemImage: "plus")
                    }
                }
            }
        }
    }

    // MARK: - 탭 바 (한 줄, 균등 분할)

    private var tabBar: some View {
        HStack(spacing: 2) {
            tabButton(.profiles)
            tabButton(.fragments)
            tabButton(.network)
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tabButton(_ section: SidebarSection) -> some View {
        let isSelected = model.sidebarSection == section
        return Button {
            model.sidebarSection = section
        } label: {
            Text(section.title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.gray.opacity(0.25) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 프로필 목록

    private var profileList: some View {
        List(selection: $model.selectedProfileID) {
            ForEach(model.profiles) { profile in
                profileRow(profile)
                    .tag(profile.id)
            }
            .onMove { from, to in
                var ids = model.profiles.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                model.reorderProfiles(ids)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - 프래그먼트 목록

    private var fragmentList: some View {
        List(selection: $model.selectedFragmentID) {
            ForEach(model.fragments) { fragment in
                fragmentRow(fragment)
                    .tag(fragment.id)
            }
            .onMove { from, to in
                var ids = model.fragments.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                model.reorderFragments(ids)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - 프로필 행

    private func profileRow(_ profile: Profile) -> some View {
        let reapply = model.needsReapply(profile)
        return HStack(spacing: 8) {
            Circle()
                .fill(dotColor(isActive: profile.isActive, reapply: reapply))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                if renamingID == profile.id {
                    TextField(L.str("sidebar.profileName"), text: $renameText, onCommit: {
                        commitProfileRename(profile)
                    })
                    .textFieldStyle(.roundedBorder)
                    .onExitCommand { renamingID = nil }
                } else {
                    Text(profile.name)
                        .font(.body)
                }
                Text(subtitle(profile: profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if reapply {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            if profile.isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .contextMenu {
            Button(L.str("sidebar.activateAndApply")) {
                Task { await model.switchAndApply(profile.id) }
            }
            .disabled(profile.isActive)
            Button(L.str("sidebar.rename")) {
                renamingID = profile.id
                renameText = profile.name
            }
            Button(L.str("sidebar.delete"), role: .destructive) {
                try? model.deleteProfile(profile.id)
            }
            .disabled(profile.isActive)
        }
    }

    private func subtitle(profile: Profile) -> String {
        var parts = [L.str("sidebar.subtitle.entries", profile.entries.count, profile.enabledCount)]
        if !profile.fragmentIDs.isEmpty {
            let names = profile.fragmentIDs.compactMap { id in
                model.fragments.first { $0.id == id }?.name
            }
            parts.append(names.isEmpty ? L.str("sidebar.subtitle.fragmentCount", profile.fragmentIDs.count) : names.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 프래그먼트 행

    private func fragmentRow(_ fragment: Fragment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece")
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                if renamingID == fragment.id {
                    TextField(L.str("sidebar.fragmentName"), text: $renameText, onCommit: {
                        commitFragmentRename(fragment)
                    })
                    .textFieldStyle(.roundedBorder)
                    .onExitCommand { renamingID = nil }
                } else {
                    Text(fragment.name)
                        .font(.body)
                }
                Text(fragmentUsage(fragment))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .contextMenu {
            Button(L.str("sidebar.rename")) {
                renamingID = fragment.id
                renameText = fragment.name
            }
            Button(L.str("sidebar.delete"), role: .destructive) {
                try? model.deleteFragment(fragment.id)
            }
        }
    }

    private func fragmentUsage(_ fragment: Fragment) -> String {
        let users = model.profilesUsing(fragment.id)
        var parts = [L.str("sidebar.subtitle.entries", fragment.entries.count, fragment.enabledCount)]
        if !users.isEmpty {
            parts.append(L.str("sidebar.subtitle.usedBy", users.map(\.name).joined(separator: ", ")))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 네트워크 목록

private var tunnelList: some View {
    List {
        if model.tunnelManager.tunnels.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.str("sidebar.tunnel.none"))
                        .font(.body)
                    Text(L.str("sidebar.tunnel.scanHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } else {
            ForEach(model.tunnelManager.tunnels) { tunnel in
                tunnelRow(tunnel)
            }
        }
    }
    .listStyle(.sidebar)
}

    private func tunnelRow(_ tunnel: ManagedTunnel) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tunnelStatusColor(tunnel.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.label)
                    .font(.body)
                    .lineLimit(1)
                Text("\(tunnel.ip):\(tunnel.port) · \(tunnel.status.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
    }

    private func tunnelStatusColor(_ status: TunnelStatus) -> Color {
        switch status {
        case .running: return .green
        case .error: return .red
        case .stopped: return .gray.opacity(0.5)
        case .starting, .stopping: return .orange
        default: return .gray
        }
    }

    // MARK: - 상태카드

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(L.str("sidebar.status"), systemImage: "server.rack")
                    .font(.body)
                Spacer()
                Circle()
                    .fill(headerColor)
                    .frame(width: 8, height: 8)
                Text(headerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L.str("sidebar.activeProfile", model.activeProfile?.name ?? L.str("sidebar.active.none")))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var headerColor: Color {
        guard model.activeProfile != nil else { return .gray }
        return model.anyNeedsReapply ? .orange : .green
    }

    private var headerText: String {
        guard model.activeProfile != nil else { return L.str("sidebar.status.noProfile") }
        return model.anyNeedsReapply ? L.str("sidebar.status.needsReapply") : L.str("sidebar.status.applied")
    }

    private func dotColor(isActive: Bool, reapply: Bool) -> Color {
        if isActive { return reapply ? .orange : .green }
        return reapply ? .orange.opacity(0.6) : .gray.opacity(0.5)
    }

    // MARK: - 생성·이름변경

    private func createProfile() {
        let name = L.str("sidebar.newProfile", model.profiles.count + 1)
        try? model.createProfile(name: name)
        if let fresh = model.profiles.first(where: { $0.name == name }) {
            renamingID = fresh.id
            renameText = fresh.name
        }
    }

    private func createFragment() {
        let name = L.str("sidebar.newFragment", model.fragments.count + 1)
        try? model.createFragment(name: name)
        if let fresh = model.fragments.first(where: { $0.name == name }) {
            renamingID = fresh.id
            renameText = fresh.name
        }
    }

    private func commitProfileRename(_ profile: Profile) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { renamingID = nil }
        guard !trimmed.isEmpty, trimmed != profile.name else { return }
        try? model.renameProfile(profile.id, to: trimmed)
    }

    private func commitFragmentRename(_ fragment: Fragment) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { renamingID = nil }
        guard !trimmed.isEmpty, trimmed != fragment.name else { return }
        try? model.renameFragment(fragment.id, to: trimmed)
    }
}
