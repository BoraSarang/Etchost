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
        22, 80, 443, 8443, 3000, 3001, 3002, 3003, 5173, 8080, 8081, 5000,
        5432, 6379, 2375, 2376, 9000, 8000, 9090, 3306, 5555
    ]

    private static let serviceByPort: [Int: String] = [
        22: "SSH", 80: "HTTP", 443: "HTTPS", 8443: "HTTPS",
        3000: "HTTP", 3001: "HTTP", 3002: "HTTP", 3003: "HTTP", 5173: Loc.str("network.service.http.dev"),
        8080: "HTTP", 8081: "HTTP", 5000: "HTTP",
        5432: "PostgreSQL", 6379: "Redis",
        2375: "Docker API", 2376: "Docker(TLS)",
        9000: "HTTP", 8000: "HTTP", 9090: "HTTP", 3306: "MySQL", 5555: "adb"
    ]

    /// 스캔 결과 정렬: 1차 IP(옥텟 숫자 비교) → 2차 포트 ASC.
    /// 문자열 정렬 함정("10.19.190.1" < "10.19.9.1") 회피.
    public static func sortResults(_ results: [PortScanResult]) -> [PortScanResult] {
        results.sorted {
            if $0.ip != $1.ip { return compareIP($0.ip, $1.ip) }
            return $0.port < $1.port
        }
    }

    private static func compareIP(_ a: String, _ b: String) -> Bool {
        let ao = a.split(separator: ".").compactMap { Int($0) }
        let bo = b.split(separator: ".").compactMap { Int($0) }
        if ao.count == 4, bo.count == 4, ao != bo {
            for (x, y) in zip(ao, bo) where x != y { return x < y }
        }
        return a < b
    }

    /// TLS 핸드셰이크가 필요한 포트. 평문 GET 실패 시 TLS로 재시도 (개발용 자체서명 인증서 허용).
    private static let tlsPorts: Set<Int> = [443, 8443]

    /// 실제 프로브 결과 우선 서비스명 판정. 평문 응답 → HTTP, TLS 응답 → HTTPS.
    /// 포트번호 매핑(HTTP/HTTPS/기타)은 실측과 모순되면 실측으로 교정.
    /// (예: 8443 매핑 HTTPS라도 평문으로 응답하면 HTTP)
    static func resolveService(port: Int, info: String?, usedTLS: Bool) -> String {
        let observed: String? = info == nil ? nil : (usedTLS ? "HTTPS" : "HTTP")
        guard let mapped = serviceByPort[port] else {
            return observed ?? Loc.str("network.service.other")
        }
        if mapped == "HTTP" || mapped == "HTTPS" || mapped == Loc.str("network.service.other"),
           let observed {
            return observed
        }
        return mapped
    }

    public static func serviceName(for port: Int) -> String {
        serviceByPort[port] ?? Loc.str("network.service.other")
    }

    // MARK: - 주소 탐색

    /// en0/en1 IPv4 주소 + 넷마스크. (ip, netmask) 튜플.
    public static func localInterfaces() -> [(ip: String, netmask: String)] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var current = ifaddr
        while let cursor = current {
            defer { current = cursor.pointee.ifa_next }
            guard let addr = cursor.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(cursor.pointee.ifa_flags) & IFF_LOOPBACK) == 0
            else { continue }
            let name = Self.cString(from: cursor.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            guard let mask = cursor.pointee.ifa_netmask else { continue }
            let ipString = sockaddrInToString(addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr })
            let maskAddr = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let maskString = sockaddrInToString(maskAddr)
            guard !ipString.isEmpty, !maskString.isEmpty else { continue }
            result.append((ipString, maskString))
        }
        return result
    }

    private static func sockaddrInToString(_ addr: in_addr) -> String {
        var copy = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN))
        return Self.cString(from: buffer)
    }

    /// 기본 게이트웨이 (route -n get default 파싱). 없으면 nil.
    public static func defaultGateway() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/route")
        proc.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                let gw = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
                if !gw.isEmpty { return gw }
            }
        }
        return nil
    }

    /// en0/en1 IPv4 주소 목록.
    public static func localIPv4Addresses() -> [String] {
        localInterfaces().map(\.ip)
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

    /// 해당 주소의 /24 서브넷 호스트 주소 (network/broadcast 제외). 레거시 호환용.
    public static func subnetIPv4Addresses(from ip: String) -> [String] {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return [] }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        return (1...254).map { prefix + String($0) }
    }

    /// 실제 넷마스크 기반 서브넷 호스트 열거 (network/broadcast 제외, 최대 2048개 cap).
    /// 마스크 파싱 실패 시 /24로 폴백.
    public static func subnetIPv4Addresses(from ip: String, netmask: String, maxHosts: Int = 2048) -> [String] {
        guard let ipNum = ipv4ToUInt32(ip), let maskNum = ipv4ToUInt32(netmask), maskNum != 0 else {
            return subnetIPv4Addresses(from: ip)
        }
        let network = ipNum & maskNum
        let broadcast = network | ~maskNum
        // /31, /32 같은 특수 케이스는 /24 폴백
        guard broadcast > network + 1 else { return subnetIPv4Addresses(from: ip) }
        var hosts: [String] = []
        hosts.reserveCapacity(min(Int(broadcast - network - 1), maxHosts))
        var current = network + 1
        while current < broadcast, hosts.count < maxHosts {
            hosts.append(uint32ToIPv4(current))
            // 오버플로우 방지 (0xFFFFFFFF에서 중단)
            if current == UInt32.max { break }
            current &+= 1
        }
        return hosts
    }

    /// 첫 번째 en 인터페이스의 (ip, netmask) 기준 서브넷 호스트.
    public static func localSubnetHosts() -> [String] {
        guard let info = localInterfaces().first else { return [] }
        return subnetIPv4Addresses(from: info.ip, netmask: info.netmask)
    }

    private static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    private static func uint32ToIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    // MARK: - 생존 호스트 필터 (arp + ping sweep)

    /// `arp -a` 캐시에서 읽은 IP 집합.
    public static func arpHosts() -> Set<String> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        proc.arguments = ["-a"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return [] }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var hosts: Set<String> = []
        for line in output.components(separatedBy: "\n") {
            // "? (10.19.190.1) at 0:1:2:3:4:5 on en0 ..."
            guard let open = line.firstIndex(of: "("),
                  let close = line.firstIndex(of: ")"),
                  open < close
            else { continue }
            let ip = String(line[line.index(after: open)..<close])
            if ipv4ToUInt32(ip) != nil { hosts.insert(ip) }
        }
        return hosts
    }

    /// 단일 ping (블로킹, 백그라운드 큐 전용). 응답 오면 true.
    private static func blockingPing(host: String, timeoutMS: Int) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/ping")
        proc.arguments = ["-c", "1", "-W", "\(timeoutMS)", "-t", "2", host]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private func pingAlive(host: String, timeoutMS: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.blockingPing(host: host, timeoutMS: timeoutMS))
            }
        }
    }

    /// 후보 중 살아있는 호스트만 반환. arp 히트 + ping 응답.
    /// ping이 전부 실패하면 arp 히트라도 반환(빈 결과 방지), 둘 다 없으면 빈 배열.
    /// onProgress(확인완료, 전체)는 200ms 스로틀로 백그라운드에서 호출.
    public func aliveHosts(
        candidates: [String],
        timeoutMS: Int = 300,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [String] {
        guard !candidates.isEmpty else { return [] }
        let arp = Self.arpHosts()
        let candidateSet = Set(candidates)
        let arpHit = candidates.filter { arp.contains($0) }
        let rest = candidates.filter { !arp.contains($0) }
        onProgress?(candidates.count - rest.count, candidates.count)
        guard !rest.isEmpty else { return arpHit }

        let limiter = ConcurrencyLimiter(limit: 96)
        var pinged: [String] = []
        var checked = candidates.count - rest.count
        var lastReport = Date.distantPast
        await withTaskGroup(of: String?.self) { group in
            for host in rest {
                group.addTask {
                    await limiter.acquire()
                    defer { Task { await limiter.release() } }
                    let ok = await self.pingAlive(host: host, timeoutMS: timeoutMS)
                    return ok ? host : nil
                }
            }
            for await found in group {
                checked += 1
                if let found, candidateSet.contains(found) { pinged.append(found) }
                if let onProgress, Date().timeIntervalSince(lastReport) >= 0.2 {
                    lastReport = Date()
                    onProgress(min(checked, candidates.count), candidates.count)
                }
            }
        }
        onProgress?(candidates.count, candidates.count)
        let combined = arpHit + pinged
        if combined.isEmpty { return [] }
        // 후보 순서 유지 (중복 후보가 있어도 크래시하지 않도록 후행 우선)
        let order = candidates.enumerated().reduce(into: [String: Int]()) { result, pair in
            result[pair.element] = pair.offset
        }
        return combined.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
    }

    // MARK: - 스캔

    /// 여러 호스트 × 포트를 병렬 스캔. 오픈된 포트만 결과로 반환.
    /// onFind/onProgress는 백그라운드 컨텍스트에서 호출되며(메인 스레드 보장 없음),
    /// 진행 보고는 150ms 스로틀. 호출자가 MainActor 발행 주기를自行 batch할 것.
    public func scan(
        hosts: [String],
        ports: [Int],
        timeout: TimeInterval = 0.5,
        fingerprint: Bool = true,
        onFind: (@Sendable (PortScanResult) -> Void)? = nil,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
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
                    // 열린 포트는 번호와 무관하게 HTTP 핑거프린트 시도.
                    // 평문 GET에 응답하면 Server 헤더 + <title>을 수집하고 서비스명을 HTTP로 교정.
                    // (SSH/DB 등 비HTTP 서비스는 무응답 → 기존 매핑/기타 유지, 단일 GET이라 무해)
                    let probed: (info: String?, tls: Bool)
                    if fingerprint {
                        probed = await tlsAwareFingerprint(host: host, port: port, timeout: timeout)
                    } else {
                        probed = (nil, false)
                    }
                    return PortScanResult(
                        ip: host,
                        port: port,
                        service: Self.resolveService(port: port, info: probed.info, usedTLS: probed.tls),
                        httpServer: probed.info
                    )
                }
            }
            var completed = 0
            var lastReport = Date.distantPast
            for await result in group {
                completed += 1
                if let result {
                    pooled.append(result)
                    onFind?(result)
                }
                let now = Date()
                if let onProgress, now.timeIntervalSince(lastReport) >= 0.15 {
                    lastReport = now
                    onProgress(ScanProgress(completed: completed, total: candidates.count, found: pooled.count))
                }
            }
            if let onProgress {
                onProgress(ScanProgress(completed: candidates.count, total: candidates.count, found: pooled.count))
            }
        }

        var seen: Set<String> = []
        return Self.sortResults(pooled.filter { seen.insert("\($0.ip):\($0.port)").inserted })
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

    /// 평문 HTTP 먼저, 실패하면 TLS 포트에 한해 TLS로 재시도.
    /// (info, tls=true면 TLS로 응답) 반환.
    private func tlsAwareFingerprint(host: String, port: Int, timeout: TimeInterval) async -> (info: String?, tls: Bool) {
        if let plain = await httpFingerprint(host: host, port: port, timeout: timeout),
           !plain.isEmpty {
            return (plain, false)
        }
        guard Self.tlsPorts.contains(port) else { return (nil, false) }
        let tls = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.blockingTLSFingerprint(host: host, port: port, timeout: timeout))
            }
        }
        return (tls, tls != nil)
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

        let parts = [server, parseTitle(text)].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// HTML <title> 추출 (평문/TLS 핑거프린트 공용).
    private static func parseTitle(_ text: String) -> String? {
        guard let range = text.range(of: "<title[^>]*>", options: .regularExpression) else { return nil }
        let searchRange = text.index(after: range.lowerBound)..<text.endIndex
        guard let end = text.range(of: "</title>", options: .caseInsensitive, range: searchRange) else { return nil }
        let title = String(text[range.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// TLS 포트용 핑거프린트. 개발용 자체서명 인증서도 허용하고 Server 헤더 + <title> 수집.
    /// 백그라운드 큐 전용 (블로킹).
    private static func blockingTLSFingerprint(host: String, port: Int, timeout: TimeInterval) -> String? {
        guard let url = URL(string: "https://\(host):\(port)/") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        let delegate = TrustAllSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let output = LockedValue<String?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: url) { data, response, _ in
            defer { semaphore.signal() }
            guard let data, let http = response as? HTTPURLResponse else { return }
            var server: String?
            for (key, value) in http.allHeaderFields where "\(key)".lowercased() == "server" {
                if let text = value as? String, !text.isEmpty { server = text }
                break
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let parts = [server, parseTitle(body)].compactMap { $0?.isEmpty == false ? $0 : nil }
            output.value = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 2)
        return output.value
    }
}

/// 세마포어 동기화용 단순 값 상자 (Sendable 클로저 캡처용).
private final class LockedValue<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// 개발용 자체서명 인증서도 신뢰하는 URLSession delegate (HTTPS 핑거프린트용).
private final class TrustAllSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
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
