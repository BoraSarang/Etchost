import EtchostKit
import Foundation

// MARK: - Profile CRUD

extension AppModel {
    public func createProfile(name: String) throws {
        let profile = try store.create(name: name)
        refresh()
        sidebarSection = .profiles
        selectedProfileID = profile.id
    }

    public func renameProfile(_ id: UUID, to name: String) throws {
        guard var profile = store.get(id) else { throw EtchostError.profileNotFound(id) }
        profile.updateName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        try store.update(profile)
        refresh()
    }

    public func updateEntries(_ id: UUID, entries: [HostEntry]) throws {
        guard var profile = store.get(id) else { throw EtchostError.profileNotFound(id) }
        profile.updateEntries(entries)
        try store.update(profile)
        refresh()
    }

    public func deleteProfile(_ id: UUID) throws {
        try store.delete(id)
        refresh()
    }

    public func reorderProfiles(_ ids: [UUID]) {
        store.reorder(ids)
        refresh()
    }
}
