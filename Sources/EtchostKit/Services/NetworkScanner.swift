import Darwin
import Foundation

/// 스캔 진행 상황 (완료 프로브 수 / 전체 프로브 수 / 발견 포트 수).
public struct ScanProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let found: Int

    public init(completed: Int, total: Int, found: Int) {
        self.completed = completed
        self.total = total
        self.found = found
    }
}

/// 로컬 네트워크 TCP 포트 스캐너 (외부 의존성 없음).
/// non-blocking connect + select 타임아웃으로 동작하며, 호출은 전용 큐에서 실행되어
/// cooperative 스레드풀을 막지 않는다. 동시성은 `ConcurrencyLimiter`로 상한.
public struct NetworkScanner: Sendable {
    public static let shared = NetworkScanner()

    /// 개발자가 자주 쓰는 포트 사전 세트.
    public static let commonPorts = [
        22, 80, 443, 3000, 3001, 3002, 5173, 8080, 8081, 5000,
        5432, 6379, 2375, 2376, 9000, 8000, 9090, 3306, 5555
    ]

    private static let serviceByPort: [Int: String] = [
        22: "SSH", 80: "HTTP", 443: "HTTPS",
        3000: "HTTP", 3001: "HTTP", 3002: "HTTP", 5173: Loc.str("network.service.http.dev"),
        8080: "HTTP", 8081: "HTTP", 5000: "HTTP",
        5432: "PostgreSQL", 6379: "Redis",
        2375: "Docker API", 2376: "Docker(TLS)",
        9000: "HTTP", 8000: "HTTP", 9090: "HTTP", 3306: "MySQL", 5555: "adb"
    ]

    private static let fingerprintPorts: Set<Int> = Set([
        80, 443, 3000, 3001, 3002, 5173, 8080, 8081, 5000, 9000, 8000, 9090
    ])

    public static func serviceName(for port: Int) -> String {
        serviceByPort[port] ?? Loc.str("network.service.other")
    }

    // MARK: - 주소 탐색

    /// en0/en1 IPv4 주소 목록.
    public static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var current = ifaddr
        while let cursor = current {
            defer { current = cursor.pointee.ifa_next }
            let family = cursor.pointee.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET), (Int32(cursor.pointee.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            let name = Self.cString(from: cursor.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var addr = cursor.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            addresses.append(Self.cString(from: buffer))
        }
        return addresses
    }

    /// 널 종료 C 문자열을 String으로 (deprecated `String(cString:)` 대체).
    private static func cString(from buffer: [CChar]) -> String {
        guard let null = buffer.firstIndex(of: 0) else { return "" }
        return String(bytes: buffer[..<null].map(UInt8.init), encoding: .utf8) ?? ""
    }

    private static func cString(from pointer: UnsafePointer<CChar>) -> String {
        var end = 0
        while pointer[end] != 0 { end += 1 }
        return String(bytes: (0..<end).map { UInt8(bitPattern: pointer[$0]) }, encoding: .utf8) ?? ""
    }

    /// 해당 주소의 /24 서브넷 호스트 주소 (network/broadcast 제외).
    public static func subnetIPv4Addresses(from ip: String) -> [String] {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return [] }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        return (1...254).map { prefix + String($0) }
    }

    // MARK: - 스캔

    /// 여러 호스트 × 포트를 병렬 스캔. 오픈된 포트만 결과로 반환.
    public func scan(
        hosts: [String],
        ports: [Int],
        timeout: TimeInterval = 0.5,
        fingerprint: Bool = true,
        onFind: (@MainActor (PortScanResult) -> Void)? = nil,
        onProgress: (@MainActor (ScanProgress) -> Void)? = nil
    ) async -> [PortScanResult] {
        guard !hosts.isEmpty, !ports.isEmpty else { return [] }
        let limiter = ConcurrencyLimiter(limit: 256)
        let candidates = hosts.flatMap { host in ports.map { (host, $0) } }
        var pooled: [PortScanResult] = []

        await withTaskGroup(of: PortScanResult?.self) { group in
            for (host, port) in candidates {
                group.addTask {
                    await limiter.acquire()
                    defer { Task { await limiter.release() } }
                    let open = await isPortOpen(host: host, port: port, timeout: timeout)
                    guard open else { return nil }
                    let server = fingerprint && Self.fingerprintPorts.contains(port)
                        ? await httpFingerprint(host: host, port: port, timeout: timeout)
                        : nil
                    return PortScanResult(
                        ip: host,
                        port: port,
                        service: Self.serviceName(for: port),
                        httpServer: server
                    )
                }
            }
            var completed = 0
            let reportStride = max(1, candidates.count / 100)
            for await result in group {
                completed += 1
                if let result {
                    pooled.append(result)
                    if let onFind {
                        await MainActor.run { onFind(result) }
                    }
                }
                if let onProgress, completed % reportStride == 0 {
                    let progress = ScanProgress(completed: completed, total: candidates.count, found: pooled.count)
                    await MainActor.run { onProgress(progress) }
                }
            }
            if let onProgress {
                let progress = ScanProgress(completed: candidates.count, total: candidates.count, found: pooled.count)
                await MainActor.run { onProgress(progress) }
            }
        }

        var seen: Set<String> = []
        return pooled
            .filter { seen.insert("\($0.ip):\($0.port)").inserted }
            .sorted { ($0.ip, $0.port) < ($1.ip, $1.port) }
    }

    public func scanLocalhost(ports: [Int] = NetworkScanner.commonPorts, timeout: TimeInterval = 0.35)
        async -> [PortScanResult] {
        await scan(hosts: ["127.0.0.1"], ports: ports, timeout: timeout)
    }

    public func scanLAN(ports: [Int] = NetworkScanner.commonPorts, timeout: TimeInterval = 0.6)
        async -> [PortScanResult] {
        guard let own = Self.localIPv4Addresses().first else { return [] }
        let hosts = Self.subnetIPv4Addresses(from: own)
        guard !hosts.isEmpty else { return [] }
        return await scan(hosts: hosts, ports: ports, timeout: timeout)
    }

    // MARK: - 프라이빗 (전용 큐에서 실행)

    private func isPortOpen(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.blockingProbe(host: host, port: port, timeout: timeout))
            }
        }
    }

    private func httpFingerprint(host: String, port: Int, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.blockingHTTP(host: host, port: port, timeout: timeout))
            }
        }
    }

    // MARK: - POSIX 블로킹 헬퍼 (백그라운드 큐 전용)

    private static func resolveAddress(host: String, port: Int) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        guard let ai = first.pointee.ai_addr else { return nil }
        var addr = sockaddr_in()
        _ = memcpy(&addr, ai, MemoryLayout<sockaddr_in>.size)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        return addr
    }

    private static func createNonBlockingSocket() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return fd
    }

    private static func tryConnect(_ fd: Int32, to addr: sockaddr_in) -> Int32 {
        withUnsafePointer(to: addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                connect(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func blockingProbe(host: String, port: Int, timeout: TimeInterval) -> Bool {
        guard let addr = resolveAddress(host: host, port: port) else { return false }
        guard let fd = createNonBlockingSocket() else { return false }
        defer { close(fd) }

        let result = tryConnect(fd, to: addr)
        let savedErrno = errno
        if result == 0 { return socketError(fd) == 0 }
        guard savedErrno == EINPROGRESS || savedErrno == EWOULDBLOCK else { return false }
        guard selectWritable(fd, timeout: timeout) else { return false }
        return socketError(fd) == 0
    }

    private static func selectWritable(_ fd: Int32, timeout: TimeInterval) -> Bool {
        waitOnPoll(fd, events: POLLOUT, timeout: timeout)
    }

    private static func socketError(_ fd: Int32) -> Int32 {
        var error: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) != 0 { return -1 }
        return error
    }

    /// 간단한 HTTP GET → Server 헤더 + <title> 수집.
    private static func blockingHTTP(host: String, port: Int, timeout: TimeInterval) -> String? {
        guard let addr = resolveAddress(host: host, port: port) else { return nil }
        guard let fd = createNonBlockingSocket() else { return nil }
        defer { close(fd) }

        let result = tryConnect(fd, to: addr)
        let savedErrno = errno
        let connected: Bool
        if result == 0 {
            connected = socketError(fd) == 0
        } else if savedErrno == EINPROGRESS || savedErrno == EWOULDBLOCK {
            connected = selectWritable(fd, timeout: timeout) && socketError(fd) == 0
        } else {
            connected = false
        }
        guard connected else { return nil }

        let request = "GET / HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        request.withCString { requestPointer in
            var sent = 0
            let length = strlen(requestPointer)
            while sent < length {
                let n = send(fd, requestPointer.advanced(by: sent), length - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var receiveBuffer = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 16 * 1024, Date() < deadline {
            guard selectReadable(fd, timeout: deadline.timeIntervalSinceNow) else { break }
            let n = read(fd, &receiveBuffer, receiveBuffer.count)
            if n <= 0 { break }
            buffer.append(contentsOf: receiveBuffer.prefix(n))
        }
        return parseHTTPInfo(buffer)
    }

    private static func selectReadable(_ fd: Int32, timeout: TimeInterval) -> Bool {
        waitOnPoll(fd, events: POLLIN, timeout: timeout)
    }

    /// poll 기반 fd 대기 — Darwin select의 FD_ZERO/FD_SET 매크로(스위프트 미노출)를 피함.
    private static func waitOnPoll(_ fd: Int32, events: Int32, timeout: TimeInterval) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(events), revents: 0)
        let millis = Int32(min(max(timeout, 0) * 1000, Double(Int32.max)))
        let result = poll(&pfd, 1, millis)
        guard result > 0 else { return false }
        return Int32(pfd.revents) & (events | POLLHUP | POLLERR) != 0
    }

    private static func parseHTTPInfo(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let headerEnd = text.range(of: "\r\n\r\n")?.upperBound ?? text.startIndex

        var server: String?
        let headers = text[..<headerEnd]
        for line in headers.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("server:") {
            server = line.dropFirst("server:".count).trimmingCharacters(in: .whitespaces)
            break
        }

        var title: String?
        if let range = text.range(of: "<title[^>]*>", options: .regularExpression) {
            let searchRange = text.index(after: range.lowerBound)..<text.endIndex
            if let end = text.range(of: "</title>", options: .caseInsensitive, range: searchRange) {
                title = String(text[range.upperBound..<end.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let parts = [server, title].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 동시 실행 상한을 보장하는 세마포어 (actor).
private actor ConcurrencyLimiter {
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else if inFlight > 0 {
            inFlight -= 1
        }
    }
}
