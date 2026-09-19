import EtchostKit
import Foundation
import Testing

@Suite("HostEntry 파싱")
struct HostEntryTests {
    @Test("기본 줄 파싱")
    func parseBasic() {
        let entry = HostEntry.parse("127.0.0.1\tmyapp.test # 로컬 앱")
        #expect(entry?.ip == "127.0.0.1")
        #expect(entry?.domain == "myapp.test")
        #expect(entry?.comment == "로컬 앱")
        #expect(entry?.isEnabled == true)
    }

    @Test("주석·빈 줄은 nil")
    func parseComments() {
        #expect(HostEntry.parse("# 그냥 주석") == nil)
        #expect(HostEntry.parse("   ") == nil)
        #expect(HostEntry.parse("") == nil)
    }

    @Test("# disabled: 복원")
    func parseDisabled() {
        let entry = HostEntry.parse("# disabled: 127.0.0.1\told.test")
        #expect(entry?.isEnabled == false)
        #expect(entry?.ip == "127.0.0.1")
    }

    @Test("무효 줄 감지")
    func parseAllInvalid() {
        let (entries, invalid) = HostEntry.parseAll("127.0.0.1 ok.test\n이건무효\n::1 localhost")
        #expect(entries.count == 2)
        #expect(invalid == [2])
    }

    @Test("line round-trip")
    func lineRoundTrip() {
        let entry = HostEntry(ip: "127.0.0.1", domain: "a.test", comment: "메모")
        let back = HostEntry.parse(entry.line)
        #expect(back?.ip == "127.0.0.1")
        #expect(back?.comment == "메모")
    }
}

@Suite("Profile 지문(fingerprint)")
struct ProfileHashTests {
    func stale(_ profile: Profile, fragments: [Fragment] = []) -> Bool {
        guard let applied = profile.appliedHash else { return true }
        return Composer.shared.fingerprint(profile: profile, fragments: fragments) != applied
    }

    @Test("markApplied 후 stale=false, 본문 변경 시 true")
    func markApplied() {
        var p = Profile(name: "Dev", entries: [HostEntry(ip: "127.0.0.1", domain: "a.test")])
        #expect(stale(p) == true)
        p.markApplied(fingerprint: Composer.shared.fingerprint(profile: p))
        #expect(stale(p) == false)
        p.updateEntries([HostEntry(ip: "127.0.0.1", domain: "b.test")])
        #expect(stale(p) == true)
    }

    @Test("프래그먼트 토글만으로 stale")
    func fragmentToggleStale() {
        var p = Profile(name: "Dev", entries: [HostEntry(ip: "127.0.0.1", domain: "a.test")])
        let frag = Fragment(name: "Docker", entries: [HostEntry(ip: "127.0.0.1", domain: "db.test")])
        p.markApplied(fingerprint: Composer.shared.fingerprint(profile: p, fragments: [frag]))
        #expect(stale(p, fragments: [frag]) == false)
        p.toggleFragment(frag.id)
        #expect(stale(p, fragments: [frag]) == true)
    }

    @Test("프래그먼트 내용 변경만으로 stale")
    func fragmentContentStale() {
        var p = Profile(
            name: "Dev", entries: [HostEntry(ip: "127.0.0.1", domain: "a.test")], fragmentIDs: [])
        var frag = Fragment(name: "Docker", entries: [HostEntry(ip: "127.0.0.1", domain: "db.test")])
        p.toggleFragment(frag.id)
        p.markApplied(fingerprint: Composer.shared.fingerprint(profile: p, fragments: [frag]))
        #expect(stale(p, fragments: [frag]) == false)
        frag.updateEntries([HostEntry(ip: "127.0.0.1", domain: "db2.test")])
        #expect(stale(p, fragments: [frag]) == true)
    }

    @Test("구버전 JSON(fragmentIDs 없음) 디코딩")
    func legacyDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","entries":[],"order":0,"isActive":false,"createdAt":0,"updatedAt":0}
        """
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(profile.fragmentIDs == [])
        #expect(profile.appliedHash == nil)
    }
}

@Suite("ProfileStore")
struct ProfileStoreTests {
    func makeStore() -> (ProfileStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("profiles.json")
        return (ProfileStore(fileURL: url), dir)
    }

    @Test("기본 프로필 시드 + 단일 active")
    func seed() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.all().count == 1)
        #expect(store.active() != nil)
    }

    @Test("중복 이름 거부")
    func duplicate() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.create(name: "Dev")
        do {
            _ = try store.create(name: "Dev")
            Issue.record("중복 허용됨")
        } catch let e as EtchostError {
            #expect(e == .duplicateProfileName("Dev"))
        }
    }

    @Test("활성 삭제 금지 + 전환 후 삭제 가능")
    func deleteGuard() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dev = try store.create(name: "Dev")
        let active = try #require(store.active())
        do {
            try store.delete(active.id)
            Issue.record("활성 삭제됨")
        } catch let e as EtchostError {
            #expect(e == .cannotDeleteActiveProfile)
        }
        try store.setActive(dev.id)
        #expect(store.active()?.id == dev.id)
        try store.delete(active.id)
        #expect(store.get(active.id) == nil)
    }

    @Test("reorder 순서 반영")
    func reorder() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try store.create(name: "A")
        let b = try store.create(name: "B")
        store.reorder([b.id, a.id])
        let ids = store.all().filter { $0.id == a.id || $0.id == b.id }.map(\.id)
        #expect(ids == [b.id, a.id])
    }

    @Test("손상 파일은 .corrupt 보존 후 시드 복구")
    func corrupt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("profiles.json")
        try "깨진 json {{{".write(to: url, atomically: true, encoding: .utf8)
        let store = ProfileStore(fileURL: url)
        #expect(store.all().count == 1) // 시드 복구
        let corruptFiles = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(corruptFiles.contains { $0.lastPathComponent.hasPrefix("profiles.json.corrupt") })
    }
}

@Suite("HostEntry 구조화 검증")
struct HostEntryValidationTests {
    @Test("IPv4 검증 (옥텟 0–255)")
    func ipv4() {
        #expect(HostEntry.isValidIP("127.0.0.1"))
        #expect(HostEntry.isValidIP("255.255.255.255"))
        #expect(HostEntry.isValidIP("0.0.0.0"))
        #expect(!HostEntry.isValidIP("256.1.1.1"))
        #expect(!HostEntry.isValidIP("1.2.3"))
        #expect(!HostEntry.isValidIP("1.2.3.4.5"))
        #expect(!HostEntry.isValidIP("abc.def.ghi.jkl"))
        #expect(!HostEntry.isValidIP(""))
        #expect(!HostEntry.isValidIP("  "))
    }

    @Test("IPv6 검증")
    func ipv6() {
        #expect(HostEntry.isValidIP("::1"))
        #expect(HostEntry.isValidIP("fe80::1"))
        #expect(HostEntry.isValidIP("2001:db8::1"))
        #expect(HostEntry.isValidIP("::"))
        #expect(!HostEntry.isValidIP("::1:xyz"))
        #expect(!HostEntry.isValidIP("2001::g::1"))
    }

    @Test("도메인 형식 검증")
    func domain() {
        #expect(HostEntry.isWellFormedDomain("example.com"))
        #expect(HostEntry.isWellFormedDomain("*.local"))
        #expect(HostEntry.isWellFormedDomain("my_host-1"))
        #expect(HostEntry.isWellFormedDomain("localhost"))
        #expect(!HostEntry.isWellFormedDomain(""))
        #expect(!HostEntry.isWellFormedDomain("a b"))
        #expect(!HostEntry.isWellFormedDomain("a/b"))
        #expect(!HostEntry.isWellFormedDomain("https://example.com"))
        #expect(!HostEntry.isWellFormedDomain("호스트"))

        #expect(HostEntry.sanitizedDomain("호스트test") == "test")
        #expect(HostEntry.sanitizedDomain("도메인.com") == ".com")
        #expect(HostEntry.sanitizedDomain("my-host.local") == "my-host.local")
        #expect(HostEntry.sanitizedIP("가127.0.0.1나") == "127.0.0.1")
        #expect(HostEntry.sanitizedIP("::1한글") == "::1")
    }

    @Test("붙여넣기 자동 분할")
    func pasted() {
        let p = HostEntry.parsePasted("127.0.0.1\texample.com\t# 기본 사이트")
        #expect(p?.ip == "127.0.0.1")
        #expect(p?.domain == "example.com")
        #expect(p?.comment == "기본 사이트")
        let q = HostEntry.parsePasted("127.0.0.1 example.com")
        #expect(q?.ip == "127.0.0.1")
        #expect(q?.domain == "example.com")
        #expect(q?.comment == nil)
        let disabled = HostEntry.parsePasted("# disabled: ::1 old.local")
        #expect(disabled?.ip == "::1")
        #expect(disabled?.domain == "old.local")
        #expect(HostEntry.parsePasted("127.0.0.1") == nil)
        #expect(HostEntry.parsePasted("") == nil)
    }
}

@Suite("HostEntry 표 파싱")
struct HostsTableRowsTests {
    @Test("그룹 구분 + 비활성")
    func groups() throws {
        let text = """
        # Etchost — Profile: 개발
        127.0.0.1\tlocalhost
        # Profile: 개발
        222.222.222.222\thost
        # Fragments
        # Fragment: DroidRelay
        # disabled: 10.207.33.235\told.test
        """
        let rows = HostEntry.tableRows(from: text)
        #expect(rows.count == 3)
        #expect(rows[0].group == "기본 loopback")
        #expect(rows[0].ip == "127.0.0.1")
        #expect(rows[1].group == "# Profile: 개발")
        #expect(rows[1].host == "host")
        #expect(rows[2].group == "# Fragment: DroidRelay")
        #expect(rows[2].isEnabled == false)
    }

    @Test("주석 포함")
    func comments() throws {
        let rows = HostEntry.tableRows(from: "10.207.33.235\tdroidreply\t# DroidRelay")
        #expect(rows.count == 1)
        #expect(rows[0].comment == "DroidRelay")
    }
}

@Suite("Composer")
struct ComposerTests {
    @Test("헤더 + 비활성 주석 처리")
    func compose() {
        let profile = Profile(
            name: "Dev",
            entries: [
                HostEntry(ip: "127.0.0.1", domain: "a.test"),
                HostEntry(ip: "127.0.0.1", domain: "old.test", isEnabled: false),
            ]
        )
        let text = Composer.shared.compose(profile: profile)
        #expect(text.contains("Profile: Dev"))
        #expect(text.contains("# Profile: Dev"))
        #expect(text.contains("127.0.0.1\ta.test"))
        #expect(text.contains("# disabled:"))
    }

    @Test("토글된 프래그먼트만 병합")
    func composeFragments() {
        let on = Fragment(name: "Docker", entries: [HostEntry(ip: "127.0.0.1", domain: "db.test")])
        let off = Fragment(name: "Studio", entries: [HostEntry(ip: "127.0.0.1", domain: "st.test")])
        var profile = Profile(name: "Dev", entries: [HostEntry(ip: "127.0.0.1", domain: "a.test")])
        profile.toggleFragment(on.id)
        let text = Composer.shared.compose(profile: profile, fragments: [on, off])
        #expect(text.contains("# Fragment: Docker"))
        #expect(text.contains("db.test"))
        #expect(!text.contains("st.test"))
        #expect(!text.contains("# Fragment: Studio"))
    }

    @Test("기본 loopback 줄 강제 포함 + 중복 제거")
    func baselineForced() throws {
        let empty = Profile(name: "Empty", entries: [])
        let text = Composer.shared.compose(profile: empty)
        #expect(text.contains("127.0.0.1\tlocalhost"))
        #expect(text.contains("255.255.255.255\tbroadcasthost"))
        #expect(text.contains("::1\tlocalhost"))
        let withLocal = Profile(name: "Full", entries: [HostEntry(ip: "127.0.0.1", domain: "localhost")])
        let text2 = Composer.shared.compose(profile: withLocal)
        let count = text2.components(separatedBy: "\n").filter { $0.hasPrefix("127.0.0.1") }.count
        #expect(count == 1)
    }

    @Test("끊긴 참조 ID는 무시")
    func danglingReference() {
        let profile = Profile(
            name: "Dev", entries: [HostEntry(ip: "127.0.0.1", domain: "a.test")],
            fragmentIDs: [UUID()])
        let text = Composer.shared.compose(profile: profile, fragments: [])
        #expect(text.contains("a.test"))
        #expect(!text.contains("# Fragment:"))
    }

    @Test("합성 순서: 기본 loopback → 프로필 → 프래그먼트")
    func order() throws {
        let frag = Fragment(name: "Docker", entries: [HostEntry(ip: "10.0.0.8", domain: "db.test")])
        var profile = Profile(name: "Dev", entries: [HostEntry(ip: "10.0.0.9", domain: "app.test")])
        profile.toggleFragment(frag.id)
        let lines = Composer.shared.compose(profile: profile, fragments: [frag])
            .components(separatedBy: "\n")
        func firstLine(_ token: String) -> Int {
            lines.firstIndex { $0.hasPrefix(token) } ?? -1
        }
        let baseline = firstLine("127.0.0.1\tlocalhost")
        let profileLine = firstLine("10.0.0.9\tapp.test")
        let fragmentLine = firstLine("10.0.0.8\tdb.test")
        #expect(baseline >= 0)
        #expect(profileLine > baseline)
        #expect(fragmentLine > profileLine)
    }
}

@Suite("FragmentStore")
struct FragmentStoreTests {
    func makeStore() -> (FragmentStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("fragments.json")
        return (FragmentStore(fileURL: url), dir)
    }

    @Test("빈 시작 + 중복 거부")
    func createDuplicate() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.all().isEmpty)
        _ = try store.create(name: "Docker")
        do {
            _ = try store.create(name: "Docker")
            Issue.record("중복 허용됨")
        } catch let e as EtchostError {
            #expect(e == .duplicateFragmentName("Docker"))
        }
    }

    @Test("껍데기 파일은 .corrupt 보존 후 빈 시작")
    func garbageRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fragments.json")
        try "2".write(to: url, atomically: true, encoding: .utf8)
        let store = FragmentStore(fileURL: url)
        #expect(store.all().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent.hasPrefix("fragments.json.corrupt") })
    }

    @Test("삭제·재정렬")
    func deleteReorder() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try store.create(name: "A")
        let b = try store.create(name: "B")
        try store.delete(a.id)
        #expect(store.get(a.id) == nil)
        let c = try store.create(name: "C")
        store.reorder([c.id, b.id])
        #expect(store.all().map(\.id) == [c.id, b.id])
    }
}
