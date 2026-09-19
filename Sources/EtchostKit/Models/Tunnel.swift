import Foundation

/// cloudflared 터널의 영속 대상. ip:port → 공개 도메인(.trycloudflare.com) 생성.
public struct Tunnel: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var label: String
    public var ip: String
    public var port: Int
    public var order: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        ip: String,
        port: Int,
        order: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.ip = ip
        self.port = port
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 터널 실행 상태 머신.
public enum TunnelStatus: Equatable, Hashable, Sendable, Codable {
    case stopped
    case starting
    case running
    case stopping
    case error(String)

    public var isActive: Bool { self == .starting || self == .running }

    public var title: String {
        switch self {
        case .stopped: return Loc.str("tunnel.status.stopped")
        case .starting: return Loc.str("tunnel.status.starting")
        case .running: return Loc.str("tunnel.status.running")
        case .stopping: return Loc.str("tunnel.status.stopping")
        case .error(let msg): return Loc.str("tunnel.status.error", msg)
        }
    }
}

/// 스캔 결과 행. ip:port 단위.
public struct PortScanResult: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let ip: String
    public let port: Int
    public let service: String
    public let httpServer: String?

    public init(
        id: UUID = UUID(),
        ip: String,
        port: Int,
        service: String,
        httpServer: String? = nil
    ) {
        self.id = id
        self.ip = ip
        self.port = port
        self.service = service
        self.httpServer = httpServer
    }
}
