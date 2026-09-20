import Foundation

/// GitHub Releases 최신 버전 조회 (공개 저장소, 인증 불필요).
public struct GitHubRelease: Codable, Sendable, Equatable {
    public let tagName: String
    public let htmlURL: String
    public let name: String?
    public let body: String?

    public init(tagName: String, htmlURL: String, name: String? = nil, body: String? = nil) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.name = name
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
        case body
    }
}

public enum ReleaseChecker {
    public static let repository = "BoraSarang/Etchost"

    /// 리포지토리 상세 URL (저장소/이슈).
    public static var repositoryURL: URL? {
        URL(string: "https://github.com/\(repository)")
    }

    public static var issuesURL: URL? {
        URL(string: "https://github.com/\(repository)/issues")
    }

    public static func releasesURL(tag: String) -> URL? {
        URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")
    }

    /// 최신 릴리스 정보를 GitHub API로 조회.
    public static func fetchLatest() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw EtchostError.scanFailed(Loc.str("error.releaseURLFailed"))
        }
        var request = URLRequest(url: url)
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        request.setValue("Etchost/\(version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EtchostError.scanFailed(Loc.str("error.releaseFetchFailed"))
        }
        if http.statusCode == 404 {
            throw EtchostError.noPublishedRelease
        }
        guard (200...299).contains(http.statusCode) else {
            throw EtchostError.scanFailed(Loc.str("error.releaseFetchFailed"))
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// 태그가 현재 버전보다 새로운지 비교 ("v1.2.3" 형태).
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        compare(tag, current) == .orderedDescending
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let av = versionComponents(a)
        let bv = versionComponents(b)
        let count = max(av.count, bv.count)
        for index in 0..<count {
            let x = index < av.count ? av[index] : 0
            let y = index < bv.count ? bv[index] : 0
            if x != y { return x > y ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }

    private static func versionComponents(_ tag: String) -> [Int] {
        let cleaned = tag.trimmingCharacters(in: CharacterSet.letters.union(.whitespaces))
        return cleaned.split(separator: ".").compactMap { Int($0) }
    }
}
