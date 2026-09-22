@testable import EtchostKit
import Foundation
import Testing

@Suite("CloudflareLogParser")
struct CloudflareLogParserTests {
    @Test("실행 로그에서 도메인 추출")
    func parseDomain() {
        let line = "2026-09-20T10:00:00Z INF +--------------------------------------------------------------------------------------------+"
        let line2 = "2026-09-20T10:00:01Z INF |  https://abc-123-def.trycloudflare.com  |"
        let output = "\(line)\n\(line2)\n"
        #expect(CloudflareLogParser.parseDomain(from: output) == "https://abc-123-def.trycloudflare.com")
        #expect(CloudflareLogParser.parseDomainExclusive(from: line2) == "https://abc-123-def.trycloudflare.com")
    }

    @Test("도메인 없으면 nil")
    func parseDomainNil() {
        let line = "2026-09-20T10:00:00Z INF connecting to edge"
        #expect(CloudflareLogParser.parseDomain(from: line) == nil)
    }

    @Test("버전 파싱")
    func parseVersion() {
        let output = "cloudflared version 2026.9.1 (built 2026-09-01-2020 UTC, go1.23.2)"
        #expect(CloudflareLogParser.parseVersion(from: output) == "2026.9.1")
    }
}

@Suite("TunnelStore")
struct TunnelStoreTests {
    private func tempStore() throws -> TunnelStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EtchostTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TunnelStore(fileURL: dir.appendingPathComponent("tunnels.json"))
    }

    @Test("빈 시작 + 생성 + 중복 거부")
    func createAndDuplicate() throws {
        let store = try tempStore()
        #expect(store.all().isEmpty)

        let added = try store.create(label: "httptest", ip: "127.0.0.1", port: 3000)
        #expect(store.all().map(\.id) == [added.id])

        #expect(throws: EtchostError.self) {
            try store.create(label: "httptest", ip: "127.0.0.1", port: 8080)
        }
    }

    @Test("같은 라벨 중복은 터널 전용 오류")
    func duplicateLabelError() throws {
        let store = try tempStore()
        try store.create(label: "HTTP 도메인", ip: "127.0.0.1", port: 3000)
        #expect(throws: EtchostError.duplicateTunnelLabel("HTTP 도메인")) {
            try store.create(label: "HTTP 도메인", ip: "127.0.0.1", port: 3002)
        }
        // ip:port가 라벨에 포함되면 충돌 없이 추가 가능
        try store.create(label: "HTTP 도메인 (127.0.0.1:3002)", ip: "127.0.0.1", port: 3002)
        #expect(store.all().count == 2)
    }

    @Test("삭제 + 없는 id 삭제 오류")
    func delete() throws {
        let store = try tempStore()
        let tunnel = try store.create(label: "dev", ip: "127.0.0.1", port: 80)
        try store.delete(tunnel.id)
        #expect(store.all().isEmpty)
        #expect(throws: EtchostError.self) {
            try store.delete(UUID())
        }
    }
}

@Suite("NetworkScanner")
struct NetworkScannerTests {
    @Test("서비스 이름 맵핑")
    func serviceName() {
        #expect(NetworkScanner.serviceName(for: 22) == "SSH")
        #expect(NetworkScanner.serviceName(for: 3000) == "HTTP")
        #expect(NetworkScanner.serviceName(for: 22_222) == Loc.str("network.service.other"))
    }

    @Test("지정 IP 기준 /24 서브넷 (broadcast/network 제외)")
    func subnet() {
        let addresses = NetworkScanner.subnetIPv4Addresses(from: "192.168.1.13")
        #expect(addresses.count == 254)
        #expect(addresses.contains("192.168.1.1"))
        #expect(addresses.contains("192.168.1.254"))
        #expect(!addresses.contains("192.168.1.0"))
        #expect(!addresses.contains("192.168.1.255"))
        #expect(addresses.contains("192.168.1.13"))
    }

    @Test("무효 IP 서브넷 → 빈 배열")
    func subnetInvalid() {
        #expect(NetworkScanner.subnetIPv4Addresses(from: "banana").isEmpty)
    }
}

@Suite("TunnelManager IP 변경")
struct TunnelManagerIPChangeTests {
    private func tempStore() throws -> TunnelStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EtchostTunnelIPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TunnelStore(fileURL: dir.appendingPathComponent("tunnels.json"))
    }

    @Test("이전 로컬 IP 터널만 갱신, 원격 터널은 유지")
    @MainActor
    func onlyMatchingIPUpdated() throws {
        // 자동 시작 플래그가 켜져 있으면 테스트 중 실제 cloudflared가 뜨므로 강제 OFF.
        let key = SettingsKeys.autoStartTunnelsAtLaunch
        let prev = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let prev {
                UserDefaults.standard.set(prev, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = try tempStore()
        let local = try store.create(label: "local", ip: "10.0.0.1", port: 3000)
        let remote = try store.create(label: "remote", ip: "10.0.0.99", port: 3010)
        let manager = TunnelManager(store: store, monitor: IPMonitor())
        defer { manager.networkCleanup() }

        manager.updateAllForIPChange(old: "10.0.0.1", new: "10.0.0.2")

        #expect(store.get(local.id)?.ip == "10.0.0.2")
        #expect(store.get(remote.id)?.ip == "10.0.0.99")
    }

    @Test("이전 IP를 모르면 아무 것도 갱신하지 않음")
    @MainActor
    func unknownOldIPSkips() throws {
        let key = SettingsKeys.autoStartTunnelsAtLaunch
        let prev = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let prev {
                UserDefaults.standard.set(prev, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = try tempStore()
        let local = try store.create(label: "local", ip: "10.0.0.1", port: 3000)
        let manager = TunnelManager(store: store, monitor: IPMonitor())
        defer { manager.networkCleanup() }

        manager.updateAllForIPChange(old: nil, new: "10.0.0.2")

        #expect(store.get(local.id)?.ip == "10.0.0.1")
    }
}

@Suite("NetworkScanner 정렬")
struct NetworkScannerSortTests {
    private func row(_ ip: String, _ port: Int) -> PortScanResult {
        PortScanResult(ip: ip, port: port, service: "HTTP")
    }

    @Test("1차 IP(숫자 비교) → 2차 포트 ASC")
    func ipFirstThenPort() {
        let rows = [
            row("10.233.247.205", 3010),
            row("10.19.190.121", 3000),
            row("10.19.190.121", 53),
            row("10.19.9.200", 80),
        ]
        let sorted = NetworkScanner.sortResults(rows)
        #expect(sorted.map { "\($0.ip):\($0.port)" } == [
            "10.19.9.200:80",
            "10.19.190.121:53",
            "10.19.190.121:3000",
            "10.233.247.205:3010",
        ])
    }
}

@Suite("Tunnel 모델")
struct TunnelModelTests {
    @Test("상태 제목")
    func statusTitles() {
        #expect(TunnelStatus.stopped.title == Loc.str("tunnel.status.stopped"))
        #expect(TunnelStatus.running.title == Loc.str("tunnel.status.running"))
        #expect(TunnelStatus.error("x").title == Loc.str("tunnel.status.error", "x"))
        #expect(TunnelStatus.running.isActive == true)
        #expect(TunnelStatus.stopped.isActive == false)
    }
}

@Suite("NetworkScanner 실측 판정·서브넷")
struct NetworkScannerResolveTests {
    @Test("실측 우선 서비스명 (8443 평문이면 HTTP)")
    func resolveServiceObserved() {
        #expect(NetworkScanner.resolveService(port: 8443, info: "nginx", usedTLS: false) == "HTTP")
        #expect(NetworkScanner.resolveService(port: 8443, info: "nginx", usedTLS: true) == "HTTPS")
        // 비HTTP 매핑(SSH)은 실측에 흔들리지 않음
        #expect(NetworkScanner.resolveService(port: 22, info: "x", usedTLS: true) == "SSH")
        // 미매핑 포트는 실측 우선, 실측 없으면 기타
        #expect(NetworkScanner.resolveService(port: 22_222, info: "x", usedTLS: true) == "HTTPS")
        #expect(NetworkScanner.resolveService(port: 22_222, info: "x", usedTLS: false) == "HTTP")
        #expect(
            NetworkScanner.resolveService(port: 22_222, info: nil, usedTLS: false)
                == Loc.str("network.service.other"))
    }

    @Test("넷마스크 기반 서브넷 (/24 동일, /20 cap 2048)")
    func subnetWithNetmask() {
        let slash24 = NetworkScanner.subnetIPv4Addresses(from: "192.168.1.13", netmask: "255.255.255.0")
        #expect(slash24.count == 254)
        #expect(slash24.first == "192.168.1.1")
        #expect(slash24.last == "192.168.1.254")

        let slash20 = NetworkScanner.subnetIPv4Addresses(from: "10.19.190.13", netmask: "255.255.240.0")
        #expect(slash20.count == 2048)
        #expect(slash20.first == "10.19.176.1")

        // 무효 마스크·/31은 /24 폴백
        #expect(NetworkScanner.subnetIPv4Addresses(from: "192.168.1.13", netmask: "banana").count == 254)
        #expect(
            NetworkScanner.subnetIPv4Addresses(from: "192.168.1.13", netmask: "255.255.255.254").count == 254)
    }
}

@Suite("로케일 잔상 마이그레이션·설치 로그")
struct LocaleRemnantTests {
    @Test("구버전 터널 라벨 콤마 제거 (1회성)")
    func migrateLabel() {
        #expect(
            TunnelStore.migrateLabel("HTTP 도메인 (127.0.0.1:3,003)")
                == "HTTP 도메인 (127.0.0.1:3003)")
        #expect(TunnelStore.migrateLabel("dev (127.0.0.1:3000)") == "dev (127.0.0.1:3000)")
        #expect(TunnelStore.migrateLabel("plain,label") == "plain,label")
    }

    @Test("brew 설치 노이즈 걸러내기")
    func installDisplayLine() async {
        let noise = "==> Downloading https://example.com/a 50%\n█░ progress\n\nUp and running\n"
        await #expect(TunnelManager.installDisplayLine(from: noise) == "Up and running")
        await #expect(TunnelManager.installDisplayLine(from: "   \n█░░\n") == nil)
        let ansi = "\u{1B}[32m==> Pouring cloudflared\u{1B}[0m\n"
        await #expect(TunnelManager.installDisplayLine(from: ansi) == "==> Pouring cloudflared")
    }
}