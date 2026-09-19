import EtchostKit
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
        #expect(NetworkScanner.serviceName(for: 22_222) == "기타")
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

@Suite("Tunnel 모델")
struct TunnelModelTests {
    @Test("상태 제목")
    func statusTitles() {
        #expect(TunnelStatus.stopped.title == "정지")
        #expect(TunnelStatus.running.title == "실행 중")
        #expect(TunnelStatus.error("x").title.contains("오류"))
        #expect(TunnelStatus.running.isActive == true)
        #expect(TunnelStatus.stopped.isActive == false)
    }
}