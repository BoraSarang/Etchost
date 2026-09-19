import Foundation

/// 프로필 영속화 스토어. JSON 파일 + barrier 동시성.
/// `fileURL` 주입 가능 → 단위테스트에서 임시 디렉토리 사용.
public final class ProfileStore: @unchecked Sendable {
    public static let shared = ProfileStore()

    private let queue = DispatchQueue(label: "com.borasarang.etchost.profileStore", attributes: .concurrent)
    private var profiles: [UUID: Profile] = [:]
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            guard let supportDir = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
            else {
                fatalError("Application Support directory not found")
            }
            let appDir = supportDir.appendingPathComponent("Etchost", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.fileURL = appDir.appendingPathComponent("profiles.json")
        }
        load()
        ensureDefaultProfile()
    }

    // MARK: - Persistence

    private func load() {
        queue.sync(flags: .barrier) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode([Profile].self, from: data)
                profiles = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
            } catch {
                // Fail-closed: 손상본 보존 후 빈 상태로 시작 (덮어쓰기 금지)
                let corruptURL = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
                profiles = [:]
            }
        }
    }

    private func saveLocked() {
        let ordered = profiles.values.sorted { $0.order < $1.order }
        do {
            let data = try JSONEncoder().encode(ordered)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            // 저장 실패는 조용히 무시 (호출부가 throw하지 않는 reorder 경로 보호)
        }
    }

    private func ensureDefaultProfile() {
        queue.sync(flags: .barrier) {
            if profiles.isEmpty {
                let seed = Profile(
                    name: "System Default",
                    entries: [
                        HostEntry(ip: "127.0.0.1", domain: "localhost"),
                        HostEntry(ip: "255.255.255.255", domain: "broadcasthost"),
                        HostEntry(ip: "::1", domain: "localhost")
                    ],
                    order: 0,
                    isActive: true
                )
                profiles[seed.id] = seed
                saveLocked()
            } else if !profiles.values.contains(where: { $0.isActive }) {
                if let key = profiles.values.min(by: { $0.order < $1.order })?.id, var first = profiles[key] {
                    first.isActive = true
                    profiles[key] = first
                    saveLocked()
                }
            }
        }
    }

    // MARK: - Reads

    public func all() -> [Profile] {
        queue.sync { profiles.values.sorted { $0.order < $1.order } }
    }

    public func get(_ id: UUID) -> Profile? {
        queue.sync { profiles[id] }
    }

    public func active() -> Profile? {
        queue.sync { profiles.values.first { $0.isActive } }
    }

    // MARK: - Writes

    @discardableResult
    public func create(name: String, entries: [HostEntry] = []) throws -> Profile {
        try queue.sync(flags: .barrier) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw EtchostError.invalidHostEntry("empty profile name") }
            guard !profiles.values.contains(where: { $0.name == trimmed }) else {
                throw EtchostError.duplicateProfileName(trimmed)
            }
            let nextOrder = (profiles.values.map(\.order).max() ?? -1) + 1
            let profile = Profile(name: trimmed, entries: entries, order: nextOrder)
            profiles[profile.id] = profile
            saveLocked()
            return profile
        }
    }

    public func update(_ profile: Profile) throws {
        try queue.sync(flags: .barrier) {
            guard profiles[profile.id] != nil else {
                throw EtchostError.profileNotFound(profile.id)
            }
            let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw EtchostError.invalidHostEntry("empty profile name") }
            guard !profiles.values.contains(where: { $0.name == trimmed && $0.id != profile.id }) else {
                throw EtchostError.duplicateProfileName(trimmed)
            }
            var next = profile
            next.name = trimmed
            profiles[profile.id] = next
            saveLocked()
        }
    }

    public func delete(_ id: UUID) throws {
        try queue.sync(flags: .barrier) {
            guard let profile = profiles[id] else {
                throw EtchostError.profileNotFound(id)
            }
            guard !profile.isActive else {
                throw EtchostError.cannotDeleteActiveProfile
            }
            profiles.removeValue(forKey: id)
            saveLocked()
        }
    }

    public func setActive(_ id: UUID) throws {
        try queue.sync(flags: .barrier) {
            guard profiles[id] != nil else {
                throw EtchostError.profileNotFound(id)
            }
            for (key, var profile) in profiles {
                profile.isActive = (key == id)
                profiles[key] = profile
            }
            saveLocked()
        }
    }

    public func reorder(_ ids: [UUID]) {
        queue.sync(flags: .barrier) {
            for (index, id) in ids.enumerated() {
                if var profile = profiles[id] {
                    profile.order = index
                    profiles[id] = profile
                }
            }
            // 목록에 없는 잔여 프로필은 뒤로 밀기
            let rest = profiles.values.filter { !ids.contains($0.id) }.sorted { $0.order < $1.order }
            for (offset, profile) in rest.enumerated() {
                var next = profile
                next.order = ids.count + offset
                profiles[profile.id] = next
            }
            saveLocked()
        }
    }
}
