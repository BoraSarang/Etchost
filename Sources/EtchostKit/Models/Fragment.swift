import Foundation

/// 재사용 hosts 조각. 프로필에서 토글로 끼워 합성 (예: Docker 컨테이너 호스트명 묶음).
public struct Fragment: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var entries: [HostEntry]
    public var order: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// nil이면 로컬 프래그먼트. 값이 있으면 원격 URL에서 동기화되며 항목 직접 편집은 UI에서 막는다.
    public var remote: RemoteSource?

    public init(
        id: UUID = UUID(),
        name: String,
        entries: [HostEntry] = [],
        order: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        remote: RemoteSource? = nil
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.remote = remote
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, entries, order, createdAt, updatedAt, remote
    }

    /// 구버전 fragments.json(remote 키 없음) 마이그레이션: 키가 없으면 로컬로 취급.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        entries = try container.decode([HostEntry].self, forKey: .entries)
        order = try container.decode(Int.self, forKey: .order)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        remote = try container.decodeIfPresent(RemoteSource.self, forKey: .remote)
    }

    public var isRemote: Bool { remote != nil }

    public var enabledCount: Int { entries.filter(\.isEnabled).count }

    public mutating func updateName(_ newName: String) {
        name = newName
        updatedAt = Date()
    }

    public mutating func updateEntries(_ newEntries: [HostEntry]) {
        entries = newEntries
        updatedAt = Date()
    }

    /// 원격 동기화 결과 반영. 캐시 교체 + 동기화 시각 기록 + 이전 오류 해소.
    /// 합성 지문(`Composer.fingerprint`)이 항목 내용을 포함하므로 참조 프로필은 자동 stale 판정.
    public mutating func applySync(entries newEntries: [HostEntry], at date: Date = Date()) {
        entries = newEntries
        updatedAt = date
        if remote != nil {
            remote?.lastSyncedAt = date
            remote?.lastError = nil
        }
    }

    public mutating func recordSyncError(_ message: String) {
        remote?.lastError = message
    }
}
