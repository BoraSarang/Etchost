import Foundation

/// 원격 hosts 소스. 프래그먼트가 URL에서 내용을 가져오는 경우의 메타데이터.
/// `entries` 자체는 `Fragment.entries`에 캐시되며, 동기화 실패 시 기존 캐시를 유지한다.
public struct RemoteSource: Codable, Equatable, Hashable, Sendable {
    public enum Interval: String, Codable, CaseIterable, Sendable {
        case manual
        case atLaunch
        case hourly
        case daily

        /// 마지막 동기화 시각 기준 동기화 필요 여부.
        public func isDue(lastSyncedAt: Date?, now: Date = Date()) -> Bool {
            switch self {
            case .manual:
                return false
            case .atLaunch:
                return lastSyncedAt == nil
            case .hourly:
                guard let last = lastSyncedAt else { return true }
                return now.timeIntervalSince(last) >= 3600
            case .daily:
                guard let last = lastSyncedAt else { return true }
                return now.timeIntervalSince(last) >= 86400
            }
        }
    }

    public var url: String
    public var interval: Interval
    public var lastSyncedAt: Date?
    public var lastError: String?

    public init(
        url: String,
        interval: Interval = .manual,
        lastSyncedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.url = url
        self.interval = interval
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
    }

    public var cleanedURL: URL? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parsed.host != nil
        else { return nil }
        return parsed
    }
}
