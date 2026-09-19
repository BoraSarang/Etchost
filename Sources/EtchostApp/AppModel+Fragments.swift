import EtchostKit
import Foundation

// MARK: - Fragment CRUD

extension AppModel {
    public func createFragment(name: String) throws {
        let fragment = try fragmentStore.create(name: name)
        refresh()
        sidebarSection = .fragments
        selectedFragmentID = fragment.id
    }

    public func renameFragment(_ id: UUID, to name: String) throws {
        guard var fragment = fragmentStore.get(id) else { throw EtchostError.fragmentNotFound(id) }
        fragment.updateName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        try fragmentStore.update(fragment)
        refresh()
    }

    public func updateFragmentEntries(_ id: UUID, entries: [HostEntry]) throws {
        guard var fragment = fragmentStore.get(id) else { throw EtchostError.fragmentNotFound(id) }
        fragment.updateEntries(entries)
        try fragmentStore.update(fragment)
        refresh()
    }

    /// 삭제 시 켠 프로필에서 자동 해제 (연쇄 해제).
    public func deleteFragment(_ id: UUID) throws {
        guard fragmentStore.get(id) != nil else { throw EtchostError.fragmentNotFound(id) }
        for var profile in profiles where profile.fragmentIDs.contains(id) {
            profile.toggleFragment(id)
            try store.update(profile)
        }
        try fragmentStore.delete(id)
        refresh()
    }

    public func reorderFragments(_ ids: [UUID]) {
        fragmentStore.reorder(ids)
        refresh()
    }

    public func toggleFragment(profileID: UUID, fragmentID: UUID) throws {
        guard var profile = store.get(profileID) else { throw EtchostError.profileNotFound(profileID) }
        guard fragmentStore.get(fragmentID) != nil else { throw EtchostError.fragmentNotFound(fragmentID) }
        profile.toggleFragment(fragmentID)
        try store.update(profile)
        refresh()
    }

    public func profilesUsing(_ fragmentID: UUID) -> [Profile] {
        profiles.filter { $0.fragmentIDs.contains(fragmentID) }
    }
}
