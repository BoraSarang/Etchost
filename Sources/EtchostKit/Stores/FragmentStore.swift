import Foundation

/// 프래그먼트 영속화 스토어. JSON 파일 + barrier 동시성. ProfileStore와 동일 패턴.
/// `fileURL` 주입 가능 → 단위테스트에서 임시 디렉토리 사용. 시드 없음 (빈 시작).
public final class FragmentStore: @unchecked Sendable {
    public static let shared = FragmentStore()

    private let queue = DispatchQueue(label: "com.borasarang.etchost.fragmentStore", attributes: .concurrent)
    private var fragments: [UUID: Fragment] = [:]
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
                fragments = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
            } catch {
                let corruptURL = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
                fragments = [:]
            }
        }
    }

    private func saveLocked() {
        let ordered = fragments.values.sorted { $0.order < $1.order }
        do {
            let data = try JSONEncoder().encode(ordered)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            // 저장 실패는 조용히 무시
        }
    }

    public func all() -> [Fragment] {
        queue.sync { fragments.values.sorted { $0.order < $1.order } }
    }

    public func get(_ id: UUID) -> Fragment? {
        queue.sync { fragments[id] }
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
            saveLocked()
            return fragment
        }
    }

    public func update(_ fragment: Fragment) throws {
        try queue.sync(flags: .barrier) {
            guard fragments[fragment.id] != nil else {
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
            saveLocked()
        }
    }

    public func delete(_ id: UUID) throws {
        try queue.sync(flags: .barrier) {
            guard fragments[id] != nil else {
                throw EtchostError.fragmentNotFound(id)
            }
            fragments.removeValue(forKey: id)
            saveLocked()
        }
    }

    public func reorder(_ ids: [UUID]) {
        queue.sync(flags: .barrier) {
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
            saveLocked()
        }
    }
}
