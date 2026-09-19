import Foundation

/// 터널 영속화 스토어. ProfileStore/FragmentStore와 동일 패턴 (JSON + barrier 동시성).
public final class TunnelStore: @unchecked Sendable {
    public static let shared = TunnelStore()

    private let queue = DispatchQueue(label: "com.borasarang.etchost.tunnelStore", attributes: .concurrent)
    private var tunnels: [UUID: Tunnel] = [:]
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
            self.fileURL = appDir.appendingPathComponent("tunnels.json")
        }
        load()
    }

    // MARK: - Persistence

    private func load() {
        queue.sync(flags: .barrier) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                guard let decoded = try? JSONDecoder().decode([Tunnel].self, from: data) else {
                    throw EtchostError.ioError("tunnels.json decode failed")
                }
                tunnels = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
            } catch {
                let corruptURL = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
                tunnels = [:]
            }
        }
    }

    private func saveLocked() {
        let ordered = tunnels.values.sorted { $0.order < $1.order }
        do {
            let data = try JSONEncoder().encode(ordered)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            // 저장 실패는 조용히 무시
        }
    }

    // MARK: - Reads

    public func all() -> [Tunnel] {
        queue.sync { tunnels.values.sorted { $0.order < $1.order } }
    }

    public func get(_ id: UUID) -> Tunnel? {
        queue.sync { tunnels[id] }
    }

    // MARK: - Writes

    @discardableResult
    public func create(label: String, ip: String, port: Int) throws -> Tunnel {
        try queue.sync(flags: .barrier) {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeLabel = trimmed.isEmpty ? "\(ip):\(port)" : trimmed
            guard !tunnels.values.contains(where: { $0.label == safeLabel }) else {
                throw EtchostError.duplicateProfileName(safeLabel)
            }
            let nextOrder = (tunnels.values.map(\.order).max() ?? -1) + 1
            let tunnel = Tunnel(label: safeLabel, ip: ip, port: port, order: nextOrder)
            tunnels[tunnel.id] = tunnel
            saveLocked()
            return tunnel
        }
    }

    public func update(_ tunnel: Tunnel) throws {
        try queue.sync(flags: .barrier) {
            guard tunnels[tunnel.id] != nil else {
                throw EtchostError.tunnelNotFound(tunnel.id)
            }
            var next = tunnel
            next.updatedAt = Date()
            tunnels[tunnel.id] = next
            saveLocked()
        }
    }

    public func delete(_ id: UUID) throws {
        try queue.sync(flags: .barrier) {
            guard tunnels[id] != nil else {
                throw EtchostError.tunnelNotFound(id)
            }
            tunnels.removeValue(forKey: id)
            saveLocked()
        }
    }
}
