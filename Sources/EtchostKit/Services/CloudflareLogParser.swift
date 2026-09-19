import Foundation

/// cloudflared 출력 로그 파싱 (순수 함수 → 단위테스트).
public enum CloudflareLogParser {
    /// quick tunnel 로그의 공개 도메인 (예: https://aaa-bbb-ccc.trycloudflare.com)
    public static let tryCloudflareURLPattern = #"https://[a-z0-9]+(-[a-z0-9]+)*\.trycloudflare\.com"#
    /// `cloudflared --version` 출력의 버전 (예: `cloudflared version 2026.9.1 (...)` → 2026.9.1)
    public static let versionPattern = #"version\s+(\d+\.\d+\.\d+)"#

    private static let tryCloudflareURLRegex = try? NSRegularExpression(pattern: tryCloudflareURLPattern)
    private static let versionRegex = try? NSRegularExpression(pattern: versionPattern)

    /// 전체 로그 블록에서 첫 번째 도메인 URL 추출.
    public static func parseDomain(from output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            if let url = parseDomainExclusive(from: line) { return url }
        }
        return nil
    }

    /// 실행 중 스트리밍되는 줄 단위 출력에 대한 파싱 (도메인만 있으면 반환).
    public static func parseDomainExclusive(from line: String) -> String? {
        let ns = line as NSString
        guard let regex = tryCloudflareURLRegex,
              let match = regex.firstMatch(
                  in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range)
    }

    /// 버전 문자열 추출.
    public static func parseVersion(from output: String) -> String? {
        let ns = output as NSString
        guard let regex = versionRegex,
              let match = regex.firstMatch(
                  in: output, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}
