import Combine
import Foundation

/// 현재 로컬 IP(en0/en1) 주기 감시. 변경 시 `onChange` 콜백.
@MainActor
public final class IPMonitor: ObservableObject {
    public struct Change: Equatable, Sendable {
        public let old: String?
        public let new: String
    }

    /// 메인 액터에서 호출되는 변경 콜백.
    public var onChange: (@MainActor (Change) -> Void)?

    private var timer: Timer?
    private let interval: TimeInterval
    private var lastPrimary: String?

    public init(interval: TimeInterval = 10) {
        self.interval = interval
    }

    public var currentPrimaryIP: String? {
        lastPrimary
    }

    /// 감시 시작 (호출 즉시 초기값 1회 기록).
    public func start() {
        stop()
        lastPrimary = Self.primaryIP()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkTick()
            }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 첫 번째(en0 우선, 없으면 첫 주소) 로컬 IPv4.
    public static func primaryIP() -> String? {
        NetworkScanner.localIPv4Addresses().first
    }

    private func checkTick() {
        guard let current = Self.primaryIP(), current != lastPrimary else { return }
        let change = Change(old: lastPrimary, new: current)
        lastPrimary = current
        onChange?(change)
    }
}
