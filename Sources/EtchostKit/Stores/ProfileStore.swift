import Foundation

/// 프로필 영속화 스토어. JSON 파일 + barrier 동시성.
/// `fileURL` 주입 가능 → 단위테스트에서 임시 디렉토리 사용.
public final class ProfileStore: @unchecked Sendable {
    public static let shared = ProfileStore()

    private let queue = DispatchQueue(label: "com.borasarang.etchost.profileStore", attributes: .concurrent)
    private var profiles: [UUID: Profile] = [:]
    private let fileURL: URL
    private var lastSaveError: Error?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            guard let supportDir = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
            else {
                // fatalError 대신 임시 디렉터리 폴백 (앱 크래시 방지)
                NSLog("[Etchost] ProfileStore: Application Support directory not found — using temporary directory")
                let appDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Etchost", isDirectory: true)
                try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
                self.fileURL = appDir.appendingPathComponent("profiles.json")
                load()
                ensureDefaultProfile()
                return
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
                // 중복 UUID가 있어도 크래시하지 않도록 후행 항목 유지 (수동 편집/복원 방어)
                profiles = decoded.reduce(into: [:]) { result, profile in
                    if result[profile.id] != nil {
                        NSLog("[Etchost] ProfileStore: duplicate id \(profile.id) — keeping last")
                    }
                    result[profile.id] = profile
                }
            } catch {
                // Fail-closed: 손상본 보존 후 빈 상태로 시작 (원본을 먼저 백업)
                quarantineCorruptFile()
                profiles = [:]
            }
        }
    }

    /// 손상본을 `.corrupt-<ts>`로 이동. 이동 실패 시 복사+삭제로 대체하여
    /// 이후 시드/저장이 원본을 덮어써도 백업이 남도록 한다.
    private func quarantineCorruptFile() {
        let corruptURL = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.moveItem(at: fileURL, to: corruptURL)
            return
        } catch {
            do {
                let data = try Data(contentsOf: fileURL)
                try data.write(to: corruptURL)
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                NSLog("[Etchost] ProfileStore: corrupt quarantine failed for \(fileURL.path): \(error)")
            }
        }
    }

    /// 디스크 쓰기. 실패 시 `lastSaveError` 기록 후 throw — 메모리 변경은 호출부에서 롤백한다.
    private func saveLocked() throws {
        let ordered = profiles.values.sorted { $0.order < $1.order }
        do {
            let data = try JSONEncoder().encode(ordered)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            lastSaveError = nil
        } catch {
            lastSaveError = error
            NSLog("[Etchost] ProfileStore: save failed for \(fileURL.path): \(error)")
            throw EtchostError.ioError("profiles.json: \(error.localizedDescription)")
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
                try? saveLocked()
            } else if !profiles.values.contains(where: { $0.isActive }) {
                if let key = profiles.values.min(by: { $0.order < $1.order })?.id, var first = profiles[key] {
                    first.isActive = true
                    profiles[key] = first
                    try? saveLocked()
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

    /// 마지막 저장 실패 원인 (nil이면 최근 저장 성공).
    public var saveFailure: Error? {
        queue.sync { lastSaveError }
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
            do {
                try saveLocked()
            } catch {
                profiles.removeValue(forKey: profile.id)
                throw error
            }
            return profile
        }
    }

    public func update(_ profile: Profile) throws {
        try queue.sync(flags: .barrier) {
            guard let previous = profiles[profile.id] else {
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
            do {
                try saveLocked()
            } catch {
                profiles[profile.id] = previous
                throw error
            }
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
            do {
                try saveLocked()
            } catch {
                profiles[id] = profile
                throw error
            }
        }
    }

    public func setActive(_ id: UUID) throws {
        try queue.sync(flags: .barrier) {
            guard profiles[id] != nil else {
                throw EtchostError.profileNotFound(id)
            }
            let snapshot = profiles
            for (key, var profile) in profiles {
                profile.isActive = (key == id)
                profiles[key] = profile
            }
            do {
                try saveLocked()
            } catch {
                profiles = snapshot
                throw error
            }
        }
    }

    public func reorder(_ ids: [UUID]) {
        queue.sync(flags: .barrier) {
            let snapshot = profiles
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
            do {
                try saveLocked()
            } catch {
                profiles = snapshot
            }
        }
    }
}
