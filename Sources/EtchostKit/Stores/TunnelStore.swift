import Foundation

/// 터널 영속화 스토어. ProfileStore/FragmentStore와 동일 패턴 (JSON + barrier 동시성).
public final class TunnelStore: @unchecked Sendable {
    public static let shared = TunnelStore()

    private let queue = DispatchQueue(label: "com.borasarang.etchost.tunnelStore", attributes: .concurrent)
    private var tunnels: [UUID: Tunnel] = [:]
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
                NSLog("[Etchost] TunnelStore: Application Support directory not found — using temporary directory")
                let appDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Etchost", isDirectory: true)
                try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
                self.fileURL = appDir.appendingPathComponent("tunnels.json")
                load()
                return
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
                var migrated = false
                tunnels = decoded.reduce(into: [:]) { result, item in
                    var next = item
                    let fixed = Self.migrateLabel(next.label)
                    if fixed != next.label {
                        next.label = fixed
                        next.updatedAt = Date()
                        migrated = true
                    }
                    if result[next.id] != nil {
                        NSLog("[Etchost] TunnelStore: duplicate id \(next.id) — keeping last")
                    }
                    result[next.id] = next
                }
                if migrated { try? saveLocked() }
            } catch {
                quarantineCorruptFile()
                tunnels = [:]
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
                NSLog("[Etchost] TunnelStore: corrupt quarantine failed for \(fileURL.path): \(error)")
            }
        }
    }

    /// 구버전 로케일 그룹핑(`:3,003`)으로 저장된 라벨의 포트 콤마 제거. 1회성 마이그레이션.
    static func migrateLabel(_ label: String) -> String {
        guard label.contains(","),
              let regex = try? NSRegularExpression(pattern: ":(\\d{1,3}(?:,\\d{3})+)")
        else { return label }
        var fixed = label
        let matches = regex.matches(in: fixed, range: NSRange(fixed.startIndex..., in: fixed))
        for match in matches.reversed() where match.numberOfRanges > 1 {
            if let range = Range(match.range(at: 1), in: fixed) {
                fixed.replaceSubrange(range, with: fixed[range].replacingOccurrences(of: ",", with: ""))
            }
        }
        return fixed
    }

    private func saveLocked() throws {
        let ordered = tunnels.values.sorted { $0.order < $1.order }
        do {
            let data = try JSONEncoder().encode(ordered)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            lastSaveError = nil
        } catch {
            lastSaveError = error
            NSLog("[Etchost] TunnelStore: save failed for \(fileURL.path): \(error)")
            throw EtchostError.ioError("tunnels.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Reads

    public func all() -> [Tunnel] {
        queue.sync { tunnels.values.sorted { $0.order < $1.order } }
    }

    public func get(_ id: UUID) -> Tunnel? {
        queue.sync { tunnels[id] }
    }

    public var saveFailure: Error? {
        queue.sync { lastSaveError }
    }

    // MARK: - Writes

    @discardableResult
    public func create(label: String, ip: String, port: Int) throws -> Tunnel {
        try queue.sync(flags: .barrier) {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeLabel = trimmed.isEmpty ? "\(ip):\(port)" : trimmed
            guard !tunnels.values.contains(where: { $0.label == safeLabel }) else {
                throw EtchostError.duplicateTunnelLabel(safeLabel)
            }
            let nextOrder = (tunnels.values.map(\.order).max() ?? -1) + 1
            let tunnel = Tunnel(label: safeLabel, ip: ip, port: port, order: nextOrder)
            tunnels[tunnel.id] = tunnel
            do {
                try saveLocked()
            } catch {
                tunnels.removeValue(forKey: tunnel.id)
                throw error
            }
            return tunnel
        }
    }

    public func update(_ tunnel: Tunnel) throws {
        try queue.sync(flags: .barrier) {
            guard let previous = tunnels[tunnel.id] else {
                throw EtchostError.tunnelNotFound(tunnel.id)
            }
            let trimmed = tunnel.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeLabel = trimmed.isEmpty ? "\(tunnel.ip):\(tunnel.port)" : trimmed
            guard !tunnels.values.contains(where: { $0.label == safeLabel && $0.id != tunnel.id }) else {
                throw EtchostError.duplicateTunnelLabel(safeLabel)
            }
            var next = tunnel
            next.label = safeLabel
            next.updatedAt = Date()
            tunnels[tunnel.id] = next
            do {
                try saveLocked()
            } catch {
                tunnels[tunnel.id] = previous
                throw error
            }
        }
    }

    public func delete(_ id: UUID) throws {
        try queue.sync(flags: .barrier) {
            guard let tunnel = tunnels[id] else {
                throw EtchostError.tunnelNotFound(id)
            }
            tunnels.removeValue(forKey: id)
            do {
                try saveLocked()
            } catch {
                tunnels[id] = tunnel
                throw error
            }
        }
    }
}
