import Foundation

/// 원격 hosts 텍스트 가져오기. URLSession 직접 사용 대신 프로토콜로 분리해 테스트에서 stub 가능.
public protocol RemoteFetching: Sendable {
    func fetch(url: URL) async throws -> Data
}

/// URLSession 기반 fetcher. 타임아웃 30초, 캐시 무시(항상 최신).
public struct URLSessionRemoteFetcher: RemoteFetching {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    public init() {}

    public func fetch(url: URL) async throws -> Data {
        do {
            let (data, response) = try await Self.session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw EtchostError.remoteSyncFailed(
                    Loc.str("error.remoteSyncHTTP", http.statusCode, url.host ?? ""))
            }
            return data
        } catch let typed as EtchostError {
            throw typed
        } catch {
            throw EtchostError.remoteSyncFailed(
                Loc.str("error.remoteSyncNetwork", error.localizedDescription))
        }
    }
}

/// 동기화 진행 단계. UI 진행 표시용으로 방출된다.
public enum SyncProgress: Equatable, Sendable {
    /// 다운로드 시작 (URL 호스트 표시용)
    case downloading(host: String)
    /// 다운로드 완료 → 파싱 중 (수신 바이트)
    case parsing(bytes: Int)
    /// 파싱 완료 → 저장 중 (항목 수)
    case saving(count: Int)
}

/// 원격 hosts 동기화. 가져오기 → 크기 제한 → 텍스트 파싱 → 결과 반환.
/// 저장은 호출자(AppModel/FragmentStore)가 담당. 실패 시 throw이므로 호출자가 기존 캐시 유지.
/// 진행 상황은 `onProgress`로 단계별 보고 (nil이면 생략).
public struct RemoteSyncService: Sendable {
    /// 비정상 대용량 응답 방지 상한 (1MB). 초과 URL은 사용 불가.
    public static let maxBytes = 1_000_000
    /// 원격 항목 수 상한. 초과 시 동기화 거부 (UI·검증 부하 방지).
    public static let maxEntries = 100

    private let fetcher: any RemoteFetching
    private let onProgress: (@Sendable (SyncProgress) -> Void)?

    public init(
        fetcher: any RemoteFetching = URLSessionRemoteFetcher(),
        onProgress: (@Sendable (SyncProgress) -> Void)? = nil
    ) {
        self.fetcher = fetcher
        self.onProgress = onProgress
    }

    public struct SyncResult: Equatable, Sendable {
        public let entries: [HostEntry]
        public let invalidLines: [Int]
        public let rawText: String
    }

    public func sync(url: URL) async throws -> SyncResult {
        onProgress?(.downloading(host: url.host ?? url.absoluteString))
        let data = try await fetcher.fetch(url: url)
        guard data.count <= Self.maxBytes else {
            throw EtchostError.remoteSyncFailed(Loc.str("error.remoteSyncTooLarge"))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EtchostError.remoteSyncFailed(Loc.str("error.remoteSyncEncoding"))
        }
        onProgress?(.parsing(bytes: data.count))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EtchostError.remoteSyncFailed(Loc.str("error.remoteSyncEmpty"))
        }
        let (entries, invalid) = HostEntry.parseAll(text)
        // 실질 항목이 하나도 없으면 빈 응답 취급 (주석뿐인 경우 포함).
        // 캐시를 빈 목록으로 덮어쓰는 사고를 방지한다.
        guard !entries.isEmpty else {
            throw EtchostError.remoteSyncFailed(Loc.str("error.remoteSyncEmpty"))
        }
        // 항목 수 상한 초과 시 거부. 잘라서 받지 않고 통째로 거부한다.
        guard entries.count <= Self.maxEntries else {
            throw EtchostError.remoteSyncFailed(
                Loc.str("error.remoteSyncTooMany", entries.count, Self.maxEntries))
        }
        // 오류 페이지(HTML) 오인 방지: 선행 주석을 건너뛰고 첫 실질 내용이 태그면 거부.
        let firstContent = trimmed.components(separatedBy: .newlines).first { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        if let first = firstContent,
            first.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<") {
            throw EtchostError.remoteSyncFailed(Loc.str("error.remoteSyncNotHosts"))
        }
        let result = SyncResult(entries: entries, invalidLines: invalid, rawText: text)
        onProgress?(.saving(count: entries.count))
        return result
    }
}
