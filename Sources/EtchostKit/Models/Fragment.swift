import Foundation

/// 재사용 hosts 조각. 프로필에서 토글로 끼워 합성 (예: Docker 컨테이너 호스트명 묶음).
public struct Fragment: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var entries: [HostEntry]
    public var order: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        entries: [HostEntry] = [],
        order: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var enabledCount: Int { entries.filter(\.isEnabled).count }

    public mutating func updateName(_ newName: String) {
        name = newName
        updatedAt = Date()
    }

    public mutating func updateEntries(_ newEntries: [HostEntry]) {
        entries = newEntries
        updatedAt = Date()
    }
}
