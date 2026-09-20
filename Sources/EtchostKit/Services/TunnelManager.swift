import Combine
import Foundation

/// 사용자에게 노출되는 터널 런타임 스냅샷.
public struct ManagedTunnel: Identifiable, Equatable, Sendable {
    public let tunnel: Tunnel
    public var status: TunnelStatus
    public var publicDomain: String?
    public var errorMessage: String?

    public var id: UUID { tunnel.id }

    public var label: String { tunnel.label }
    public var ip: String { tunnel.ip }
    public var port: Int { tunnel.port }
}

/// cloudflared quick tunnel 관리자.
/// 터널별 자식 프로세스를 실행하고 stdout/stderr에서 공개 도메인을 추출한다.
/// IP 변경 감지 시 실행 중 터널을 새 IP로 재시작한다.
@MainActor
public final class TunnelManager: ObservableObject {
    public static let shared = TunnelManager()

    /// 터널 + 런타임 세션.
    private struct Session {
        var tunnel: Tunnel
        var status: TunnelStatus = .stopped
        var publicDomain: String?
        var errorMessage: String?
        var process: Process?
        var buffer = ""
    }

    @Published public private(set) var tunnels: [ManagedTunnel] = []
    @Published public private(set) var cloudflaredPath: String?
    @Published public private(set) var cloudflaredVersion: String?
    @Published public private(set) var isInstalling = false
    @Published public private(set) var installMessage: String?
    @Published public private(set) var lastIPChange: IPMonitor.Change?

    private var sessions: [UUID: Session] = [:]
    private let store: TunnelStore
    private let monitor: IPMonitor
    private var cancellables: Set<AnyCancellable> = []
    private let knownPaths = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
    private static let maxLogBytes = 200_000

    public init(store: TunnelStore = .shared, monitor: IPMonitor = IPMonitor()) {
        self.store = store
        self.monitor = monitor
        for tunnel in store.all() {
            sessions[tunnel.id] = Session(tunnel: tunnel)
        }
        publish()
        monitor.onChange = { [weak self] change in
            self?.handleIPChange(change)
        }
        monitor.start()
        Task { await self.refreshCloudflared() }
    }

    /// 앱 종료 시 전체 터널 프로세스 정리 (AppDelegate.applicationWillTerminate 경유).
    public func networkCleanup() {
        for (_, session) in sessions {
            session.process?.terminate()
        }
        monitor.stop()
    }

    @discardableResult
    public func publish() -> [ManagedTunnel] {
        tunnels = sessions.values
            .sorted { $0.tunnel.order < $1.tunnel.order }
            .map { ManagedTunnel(
                tunnel: $0.tunnel,
                status: $0.status,
                publicDomain: $0.publicDomain,
                errorMessage: $0.errorMessage
            ) }
        return tunnels
    }

    /// 터널의 최근 stdout/stderr 로그 (콘솔 뷰용). 최대 접두어는 버퍼 상한에서 관리.
    public func logText(for id: UUID) -> String {
        sessions[id]?.buffer ?? ""
    }

    // MARK: - cloudflared 확인/설치/버전

    /// 현재 PATH + 알려진 경로에서 cloudflared 찾기.
    public func detectCloudflared() -> String? {
        for path in knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public var isCloudflaredInstalled: Bool {
        cloudflaredPath != nil
    }

    public func refreshCloudflared() async {
        cloudflaredPath = detectCloudflared()
        guard let path = cloudflaredPath else {
            cloudflaredVersion = nil
            return
        }
        if let output = runCapture(executable: path, arguments: ["--version"]) {
            cloudflaredVersion = CloudflareLogParser.parseVersion(from: output)
        } else {
            cloudflaredVersion = nil
        }
        maybeAutoStartTunnels()
    }

    /// 설정(앱 시작 시 자동 시작)이 켜져 있으면 저장된 전체 터널 시작.
    private func maybeAutoStartTunnels() {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.autoStartTunnelsAtLaunch),
              cloudflaredPath != nil else { return }
        for id in sessions.keys where sessions[id]?.status == .stopped {
            startTunnel(id)
        }
    }

    public func ensureCloudflared() async throws {
        if cloudflaredPath == nil {
            cloudflaredPath = detectCloudflared()
        }
        guard cloudflaredPath != nil else {
            throw EtchostError.cloudflaredNotInstalled
        }
    }

    /// brew install cloudflared 실행 (진행 출력 일부만 저장, 메인 액터 비차단).
    public func installCloudflared() async throws {
        guard !isInstalling else { return }
        guard cloudflaredPath == nil else { return }

        let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/usr/bin/env"]
        guard let brew = brewCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            installMessage = Loc.str("error.brewNotInstalled")
            throw EtchostError.brewNotInstalled
        }

        installMessage = nil
        isInstalling = true
        installMessage = Loc.str("tunnel.install.installing")
        defer { isInstalling = false }

        let process = Process()
        if brew.hasSuffix("/env") {
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["brew", "install", "cloudflared"]
        } else {
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install", "cloudflared"]
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] stream in
            let data = stream.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                guard let self, !text.isEmpty else { return }
                let tail = String(text.split(whereSeparator: \.isNewline).last.map { String($0.suffix(64)) } ?? "")
                if !tail.isEmpty {
                    self.installMessage = tail
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        handle.readabilityHandler = nil

        await refreshCloudflared()
        if let version = cloudflaredVersion {
            installMessage = Loc.str("tunnel.install.doneWithVersion", version)
        } else if cloudflaredPath != nil {
            installMessage = Loc.str("tunnel.install.done")
        } else {
            installMessage = Loc.str("tunnel.install.failed")
        }
    }

    // MARK: - CRUD

    @discardableResult
    public func createTunnel(label: String, ip: String, port: Int, start: Bool = true) throws -> Tunnel {
        let tunnel = try store.create(label: label, ip: ip, port: port)
        sessions[tunnel.id] = Session(tunnel: tunnel)
        publish()
        if start {
            startTunnel(tunnel.id)
        }
        return tunnel
    }

    public func updateTunnelIP(_ id: UUID, ip: String) throws {
        guard var session = sessions[id] else { throw EtchostError.tunnelNotFound(id) }
        session.tunnel.ip = ip
        sessions[id] = session
        try store.update(session.tunnel)
        publish()
    }

    public func deleteTunnel(_ id: UUID) throws {
        stopTunnel(id)
        sessions[id]?.process?.terminate()
        sessions.removeValue(forKey: id)
        try store.delete(id)
        publish()
    }

    // MARK: - 실행 제어

    public func startTunnel(_ id: UUID) {
        guard let path = cloudflaredPath else { return }
        guard var session = sessions[id], session.process == nil || session.status == .stopped else { return }
        session.status = .starting
        session.publicDomain = nil
        session.errorMessage = nil
        session.buffer = ""
        sessions[id] = session

        let url = "http://\(session.tunnel.ip):\(session.tunnel.port)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["tunnel", "--url", url]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                self?.consumeOutput(id, text)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                self?.consumeOutput(id, text)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.terminationDidOccur(id)
            }
        }

        do {
            try process.run()
            sessions[id]?.process = process
        } catch {
            sessions[id]?.status = .error(error.localizedDescription)
        }
        publish()
    }

    public func stopTunnel(_ id: UUID) {
        guard let session = sessions[id], session.process != nil else { return }
        sessions[id]?.status = .stopping
        sessions[id]?.process?.terminate()
        sessions[id]?.process = nil
        sessions[id]?.status = .stopped
        sessions[id]?.publicDomain = nil
        publish()
    }

    public func stopAll() {
        for id in sessions.keys {
            stopTunnel(id)
        }
    }

    /// 새 IP로 모든 터널 갱신 + 실행 중 터널 재시작.
    public func updateAllForIPChange(_ newIP: String) {
        for id in sessions.keys {
            var session = sessions[id]
            session?.tunnel.ip = newIP
            sessions[id] = session
            if let tunnel = session?.tunnel {
                try? store.update(tunnel)
            }
            if session?.status.isActive == true {
                stopTunnel(id)
                startTunnel(id)
            }
        }
        publish()
    }

    private func handleIPChange(_ change: IPMonitor.Change) {
        lastIPChange = change
        updateAllForIPChange(change.new)
    }

    // MARK: - 출력/종료

    private func consumeOutput(_ id: UUID, _ text: String) {
        guard var session = sessions[id] else { return }
        // 로그 버퍼 상한 유지 (전역 접근 배타성 위해 로컬 복사 후 재삽입).
        session.buffer.append(text)
        if session.buffer.count > Self.maxLogBytes {
            session.buffer.removeFirst(session.buffer.count - Self.maxLogBytes)
        }
        sessions[id] = session

        if sessions[id]?.publicDomain == nil,
           let domain = CloudflareLogParser.parseDomain(from: text) {
            sessions[id]?.publicDomain = domain
            if sessions[id]?.status == .starting {
                sessions[id]?.status = .running
            }
        }
        if let msg = firstErrorIn(text) {
            sessions[id]?.errorMessage = msg
        }
        publish()
    }

    private func firstErrorIn(_ text: String) -> String? {
        guard let marker = text.range(of: "ERR") ?? text.range(of: "error", options: .caseInsensitive) else {
            return nil
        }
        let line = text[marker.lowerBound...].split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard !line.isEmpty else { return nil }
        return String(line.prefix(160))
    }

    private func terminationDidOccur(_ id: UUID) {
        guard var session = sessions[id] else { return }
        let wasActive = session.status == .running || session.status == .starting
        session.process = nil
        if wasActive {
            session.status = session.publicDomain != nil ? .stopped : .error(Loc.str("tunnel.terminated"))
        } else if session.status == .stopping {
            session.status = .stopped
        }
        sessions[id] = session
        publish()
        // 자동 재연결 설정이 켜져 있고, 정지 명령이 아니라 예기치 않은 종료였을 때만 재시작.
        if wasActive, UserDefaults.standard.bool(forKey: SettingsKeys.autoRebookTunnels) {
            startTunnel(id)
        }
    }

    // MARK: - 헬퍼

    private func runCapture(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
