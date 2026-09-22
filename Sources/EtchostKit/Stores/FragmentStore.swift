import Foundation

/// 프래그먼트 영속화 스토어. JSON 파일 + barrier 동시성. ProfileStore와 동일 패턴.
/// `fileURL` 주입 가능 → 단위테스트에서 임시 디렉토리 사용. 시드 없음 (빈 시작).
public final class FragmentStore: @unchecked Sendable {
    public static let shared = FragmentStore()

    private let queue = DispatchQueue(label: "com.borasarang.etchost.fragmentStore", attributes: .concurrent)
    private var fragments: [UUID: Fragment] = [:]
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
                NSLog("[Etchost] FragmentStore: Application Support directory not found — using temporary directory")
                let appDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Etchost", isDirectory: true)
                try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
                self.fileURL = appDir.appendingPathComponent("fragments.json")
                load()
                return
            }
            let appDir = supportDir.appendingPathComponent("Etchost", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.fileURL = appDir.appendingPathComponent("fragments.json")
        }
        load()
    }

    private func load() {
        queue.sync(flags: .barrier) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                // 구버전 껍데기 파일(예: "2" 같은 비JSON)도 corrupt 처리 후 빈 시작으로 복구
                guard let decoded = try? JSONDecoder().decode([Fragment].self, from: data) else {
                    throw EtchostError.ioError("fragments.json decode failed")
                }
                fragments = decoded.reduce(into: [:]) { result, fragment in
                    if result[fragment.id] != nil {
                        NSLog("[Etchost] FragmentStore: duplicate id \(fragment.id) — keeping last")
                    }
                    result[fragment.id] = fragment
                }
            } catch {
                quarantineCorruptFile()
                fragments = [:]
            }
        }
    }

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
                NSLog("[Etchost] FragmentStore: corrupt quarantine failed for \(fileURL.path): \(error)")
            }
        }
    }

    private func saveLocked() throws {
        let ordered = fragments.values.sorted { $0.order < $1.order }
        do {
            let data = try JSONEncoder().encode(ordered)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            lastSaveError = nil
        } catch {
            lastSaveError = error
            NSLog("[Etchost] FragmentStore: save failed for \(fileURL.path): \(error)")
            throw EtchostError.ioError("fragments.json: \(error.localizedDescription)")
        }
    }

    public func all() -> [Fragment] {
        queue.sync { fragments.values.sorted { $0.order < $1.order } }
    }

    public func get(_ id: UUID) -> Fragment? {
        queue.sync { fragments[id] }
    }

    public var saveFailure: Error? {
        queue.sync { lastSaveError }
    }

    @discardableResult
    public func create(name: String, entries: [HostEntry] = []) throws -> Fragment {
        try queue.sync(flags: .barrier) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw EtchostError.invalidHostEntry("empty fragment name") }
            guard !fragments.values.contains(where: { $0.name == trimmed }) else {
                throw EtchostError.duplicateFragmentName(trimmed)
            }
            let nextOrder = (fragments.values.map(\.order).max() ?? -1) + 1
            let fragment = Fragment(name: trimmed, entries: entries, order: nextOrder)
            fragments[fragment.id] = fragment
            do {
                try saveLocked()
            } catch {
                fragments.removeValue(forKey: fragment.id)
                throw error
            }
            return fragment
        }
    }

    public func update(_ fragment: Fragment) throws {
        try queue.sync(flags: .barrier) {
            guard let previous = fragments[fragment.id] else {
                throw EtchostError.fragmentNotFound(fragment.id)
            }
            let trimmed = fragment.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw EtchostError.invalidHostEntry("empty fragment name") }
            guard !fragments.values.contains(where: { $0.name == trimmed && $0.id != fragment.id }) else {
                throw EtchostError.duplicateFragmentName(trimmed)
            }
            var next = fragment
            next.name = trimmed
            fragments[fragment.id] = next
            do {
                try saveLocked()
            } catch {
                fragments[fragment.id] = previous
                throw error
            }
        }
    }

    public func delete(_ id: UUID) throws {
        try queue.sync(flags: .barrier) {
            guard let fragment = fragments[id] else {
                throw EtchostError.fragmentNotFound(id)
            }
            fragments.removeValue(forKey: id)
            do {
                try saveLocked()
            } catch {
                fragments[id] = fragment
                throw error
            }
        }
    }

    /// 원격 동기화 성공 반영: 항목 교체 + 동기화 시각 기록.
    public func applySyncResult(_ id: UUID, entries: [HostEntry], at date: Date = Date()) throws {
        try queue.sync(flags: .barrier) {
            guard var fragment = fragments[id] else {
                throw EtchostError.fragmentNotFound(id)
            }
            let previous = fragment
            fragment.applySync(entries: entries, at: date)
            fragments[id] = fragment
            do {
                try saveLocked()
            } catch {
                fragments[id] = previous
                throw error
            }
        }
    }

    /// 원격 동기화 실패 기록: 캐시는 유지하고 오류 메시지만 남긴다.
    public func recordSyncError(_ id: UUID, message: String) {
        queue.sync(flags: .barrier) {
            guard var fragment = fragments[id] else { return }
            let previous = fragment
            fragment.recordSyncError(message)
            fragments[id] = fragment
            do {
                try saveLocked()
            } catch {
                fragments[id] = previous
            }
        }
    }

    public func reorder(_ ids: [UUID]) {
        queue.sync(flags: .barrier) {
            let snapshot = fragments
            for (index, id) in ids.enumerated() {
                if var fragment = fragments[id] {
                    fragment.order = index
                    fragments[id] = fragment
                }
            }
            let rest = fragments.values.filter { !ids.contains($0.id) }.sorted { $0.order < $1.order }
            for (offset, fragment) in rest.enumerated() {
                var next = fragment
                next.order = ids.count + offset
                fragments[fragment.id] = next
            }
            do {
                try saveLocked()
            } catch {
                fragments = snapshot
            }
        }
    }
}
