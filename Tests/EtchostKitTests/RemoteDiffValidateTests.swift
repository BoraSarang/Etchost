import EtchostKit
import Foundation
import Testing

// MARK: - RemoteSource

@Suite("RemoteSource 동기화 주기")
struct RemoteSourceTests {
    @Test("manual은 항상 due=false")
    func manualNeverDue() {
        #expect(RemoteSource.Interval.manual.isDue(lastSyncedAt: nil) == false)
        #expect(RemoteSource.Interval.manual.isDue(lastSyncedAt: Date()) == false)
    }

    @Test("atLaunch는 첫 동기화 전만 due")
    func atLaunchFirstOnly() {
        #expect(RemoteSource.Interval.atLaunch.isDue(lastSyncedAt: nil) == true)
        #expect(RemoteSource.Interval.atLaunch.isDue(lastSyncedAt: Date()) == false)
    }

    @Test("hourly/daily 경계")
    func hourlyDaily() {
        let twoHoursAgo = Date(timeIntervalSinceNow: -7200)
        #expect(RemoteSource.Interval.hourly.isDue(lastSyncedAt: twoHoursAgo) == true)
        #expect(RemoteSource.Interval.hourly.isDue(lastSyncedAt: Date()) == false)
        #expect(RemoteSource.Interval.daily.isDue(lastSyncedAt: twoHoursAgo) == false)
        #expect(RemoteSource.Interval.daily.isDue(lastSyncedAt: Date(timeIntervalSinceNow: -90000)) == true)
    }

    @Test("URL 정제: http(s)만 허용")
    func cleanedURL() {
        #expect(RemoteSource(url: "https://example.com/hosts").cleanedURL?.host == "example.com")
        #expect(RemoteSource(url: "ftp://example.com/hosts").cleanedURL == nil)
        #expect(RemoteSource(url: "not a url").cleanedURL == nil)
        #expect(RemoteSource(url: "").cleanedURL == nil)
    }

    @Test("구버전 JSON(remote 없음) 디코딩 → 로컬")
    func legacyDecode() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Docker","entries":[],"order":0,\
        "createdAt":774000000,"updatedAt":774000000}
        """.data(using: .utf8)!
        let fragment = try JSONDecoder().decode(Fragment.self, from: legacy)
        #expect(fragment.remote == nil)
        #expect(fragment.isRemote == false)
    }

    @Test("applySync는 참조 프로필 지문을 바꾼다")
    func syncChangesFingerprint() {
        var fragment = Fragment(
            name: "Block",
            entries: [HostEntry(ip: "0.0.0.0", domain: "ads.test")],
            remote: RemoteSource(url: "https://example.com/hosts"))
        var profile = Profile(name: "Dev", fragmentIDs: [fragment.id])
        let before = Composer.shared.fingerprint(profile: profile, fragments: [fragment])
        profile.markApplied(fingerprint: before)
        fragment.applySync(entries: [HostEntry(ip: "0.0.0.0", domain: "ads2.test")])
        #expect(Composer.shared.fingerprint(profile: profile, fragments: [fragment]) != before)
        #expect(fragment.remote?.lastSyncedAt != nil)
        #expect(fragment.remote?.lastError == nil)
    }
}

// MARK: - RemoteSyncService

struct StubFetcher: RemoteFetching {
    let data: Data
    func fetch(url: URL) async throws -> Data { data }
}

struct FailingFetcher: RemoteFetching {
    let error: Error
    func fetch(url: URL) async throws -> Data { throw error }
}

@Suite("RemoteSyncService 동기화")
struct RemoteSyncServiceTests {
    private func service(text: String) -> RemoteSyncService {
        RemoteSyncService(fetcher: StubFetcher(data: Data(text.utf8)))
    }

    @Test("정상 hosts 파싱")
    func parsesHosts() async throws {
        let result = try await service(text: "127.0.0.1 app.test # 로컬\n0.0.0.0 ads.test\n").sync(
            url: URL(string: "https://example.com/hosts")!)
        #expect(result.entries.count == 2)
        #expect(result.invalidLines.isEmpty)
    }

    @Test("빈 응답은 오류 (캐시 유지 유도)")
    func emptyIsError() async {
        await #expect(throws: EtchostError.self) {
            try await self.service(text: "   \n# 주석만\n").sync(url: URL(string: "https://example.com/h")!)
        }
    }

    @Test("HTML 오류 페이지는 거부")
    func htmlRejected() async {
        await #expect(throws: EtchostError.self) {
            try await self.service(text: "<html><body>404</body></html>").sync(
                url: URL(string: "https://example.com/h")!)
        }
    }

    @Test("비-UTF8은 오류")
    func nonUTF8IsError() async {
        let service = RemoteSyncService(fetcher: StubFetcher(data: Data([0xFF, 0xFE, 0x00])))
        await #expect(throws: EtchostError.self) {
            try await service.sync(url: URL(string: "https://example.com/h")!)
        }
    }

    @Test("네트워크 실패는 그대로 전파")
    func networkErrorPropagates() async {
        let service = RemoteSyncService(
            fetcher: FailingFetcher(error: EtchostError.remoteSyncFailed("down")))
        await #expect(throws: EtchostError.self) {
            try await service.sync(url: URL(string: "https://example.com/h")!)
        }
    }

    @Test("101개 초과 시 통째로 거부")
    func tooManyRejected() async {
        let big = (1...101).map { "127.0.0.1 host\($0).test" }.joined(separator: "\n")
        let service = RemoteSyncService(fetcher: StubFetcher(data: Data(big.utf8)))
        await #expect(throws: EtchostError.self) {
            try await service.sync(url: URL(string: "https://example.com/h")!)
        }
    }

    @Test("100개까지 허용")
    func hundredAllowed() async throws {
        let hundred = (1...100).map { "127.0.0.1 host\($0).test" }.joined(separator: "\n")
        let service = RemoteSyncService(fetcher: StubFetcher(data: Data(hundred.utf8)))
        let result = try await service.sync(url: URL(string: "https://example.com/h")!)
        #expect(result.entries.count == 100)
    }

    @Test("HTTP 비대응 상태 코드는 오류")
    func httpError() async {
        struct HTTPFailer: RemoteFetching {
            func fetch(url: URL) async throws -> Data {
                throw EtchostError.remoteSyncFailed("x")
            }
        }
        let service = RemoteSyncService(fetcher: HTTPFailer())
        await #expect(throws: EtchostError.self) {
            try await service.sync(url: URL(string: "https://example.com/h")!)
        }
    }

    @Test("진행 단계가 순서대로 보고됨")
    func progressPhases() async throws {
        let phases = LockedPhases()
        let service = RemoteSyncService(
            fetcher: StubFetcher(data: Data("127.0.0.1 a.test\n".utf8)),
            onProgress: { phases.append($0) })
        _ = try await service.sync(url: URL(string: "https://example.com/hosts")!)
        let got = phases.values
        #expect(got.count == 3)
        #expect(got[0] == .downloading(host: "example.com"))
        if case .parsing = got[1] {} else { Issue.record("parsing 단계 누락") }
        if case .saving(let count) = got[2] {
            #expect(count == 1)
        } else {
            Issue.record("saving 단계 누락")
        }
    }
}

private final class LockedPhases: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [SyncProgress] = []
    var values: [SyncProgress] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(_ phase: SyncProgress) {
        lock.lock()
        defer { lock.unlock() }
        _values.append(phase)
    }
}

// MARK: - HostsDiffer

@Suite("HostsDiffer diff")
struct HostsDifferTests {
    @Test("동일 내용은 빈 diff")
    func identical() {
        let text = "127.0.0.1 localhost\n::1 localhost"
        #expect(HostsDiffer.diff(old: text, new: text).isEmpty)
    }

    @Test("추가·삭제 검출")
    func addedRemoved() {
        let lines = HostsDiffer.diff(
            old: "127.0.0.1 a.test\n127.0.0.1 b.test",
            new: "127.0.0.1 a.test\n127.0.0.1 c.test",
            contextLines: 0)
        let summary = HostsDiffer.summary(of: lines)
        #expect(summary.added == 1)
        #expect(summary.removed == 1)
        #expect(lines.contains(where: { $0.kind == .added && $0.text.contains("c.test") }))
        #expect(lines.contains(where: { $0.kind == .removed && $0.text.contains("b.test") }))
    }

    @Test("context=0이면 변경 줄만")
    func noContext() {
        let lines = HostsDiffer.diff(
            old: "a\nb\nc",
            new: "a\nB\nc",
            contextLines: 0)
        #expect(lines.allSatisfy { $0.kind != .context })
        #expect(HostsDiffer.summary(of: lines) == HostsDiffer.Summary(added: 1, removed: 1))
    }

    @Test("대용량 폴백도 동작")
    func largeFallback() {
        let old = (0..<3000).map { "127.0.0.1 host\($0).test" }.joined(separator: "\n")
        let new = old + "\n127.0.0.1 extra.test"
        let lines = HostsDiffer.diff(old: old, new: new)
        #expect(HostsDiffer.summary(of: lines).added == 1)
    }
}

// MARK: - HostsValidator

@Suite("HostsValidator 검증")
struct HostsValidatorTests {
    private let validator = HostsValidator()

    @Test("정상 항목은 이슈 없음")
    func clean() {
        let issues = validator.validate(entries: [HostEntry(ip: "127.0.0.1", domain: "app.test")])
        #expect(issues.isEmpty)
    }

    @Test("잘못된 IP·도메인은 error")
    func invalidFormat() {
        let issues = validator.validate(entries: [
            HostEntry(ip: "999.1.1.1", domain: "app.test"),
            HostEntry(ip: "127.0.0.1", domain: "한글 도메인"),
        ])
        #expect(issues.contains(where: { $0.severity == .error && $0.kind == .invalidIP }))
        #expect(issues.contains(where: { $0.severity == .error && $0.kind == .invalidDomain }))
    }

    @Test("같은 도메인 다른 IP는 충돌 경고")
    func conflicting() {
        let issues = validator.validate(entries: [
            HostEntry(ip: "127.0.0.1", domain: "app.test"),
            HostEntry(ip: "192.168.1.5", domain: "app.test"),
        ])
        #expect(issues.contains(where: { $0.kind == .conflictingIP }))
    }

    @Test("완전 중복은 중복 경고")
    func duplicate() {
        let issues = validator.validate(entries: [
            HostEntry(ip: "127.0.0.1", domain: "app.test"),
            HostEntry(ip: "127.0.0.1", domain: "app.test"),
        ])
        #expect(issues.contains(where: { $0.kind == .duplicateDomain }))
    }

    @Test("비활성 항목은 중복 검사 제외")
    func disabledExcluded() {
        let issues = validator.validate(entries: [
            HostEntry(ip: "127.0.0.1", domain: "app.test"),
            HostEntry(ip: "192.168.1.5", domain: "app.test", isEnabled: false),
        ])
        #expect(!issues.contains(where: { $0.kind == .conflictingIP }))
    }

    @Test("유명 도메인 사설 IP는 하이잭 의심")
    func suspicious() {
        let issues = validator.validate(entries: [
            HostEntry(ip: "192.168.1.5", domain: "google.com"),
            HostEntry(ip: "127.0.0.1", domain: "myapp.test"),
        ])
        #expect(issues.contains(where: { $0.kind == .suspiciousRedirect && $0.domain == "google.com" }))
        #expect(!issues.contains(where: { $0.domain == "myapp.test" }))
    }

    @Test("서브도메인도 탐지, 일반 공인 IP는 정상")
    func subdomainAndPublic() {
        let issues = validator.validate(entries: [
            HostEntry(ip: "10.0.0.1", domain: "mail.google.com"),
            HostEntry(ip: "142.250.0.1", domain: "google.com"),
        ])
        #expect(issues.contains(where: { $0.kind == .suspiciousRedirect && $0.domain == "mail.google.com" }))
        #expect(!issues.contains(where: { $0.kind == .suspiciousRedirect && $0.domain == "google.com" }))
    }

    @Test("0.0.0.0 단일 매핑은 차단 관례로 제외")
    func zeroIPExcluded() {
        let issues = validator.validate(entries: [
            HostEntry(ip: "0.0.0.0", domain: "ads.google.com"),
            HostEntry(ip: "0.0.0.0", domain: "ad.naver.com"),
        ])
        #expect(!issues.contains(where: { $0.kind == .suspiciousRedirect }))
    }

    @Test("루프백·사설 IP는 계속 의심")
    func loopbackStillSuspicious() {
        let issues = validator.validate(entries: [
            HostEntry(ip: "127.0.0.1", domain: "google.com"),
        ])
        #expect(issues.contains(where: { $0.kind == .suspiciousRedirect }))
    }
}
