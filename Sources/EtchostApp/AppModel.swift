import EtchostKit
import Foundation
import SwiftUI

/// 코디네이터: 프로필 + 프래그먼트 목록, 선택, 적용 상태 관리.
/// CRUD는 책임별 확장 파일(`AppModel+Profiles` / `AppModel+Fragments` / `AppModel+Apply`)에 분산.
@MainActor
@Observable
public final class AppModel: ObservableObject {
    /// 메인 창·팝오버·메뉴바 라벨이 공유하는 인스턴스.
    public static let shared = AppModel()

    public var profiles: [Profile] = []
    public var fragments: [Fragment] = []
    public var sidebarSection: SidebarSection = .profiles
    public var selectedProfileID: UUID?
    public var selectedFragmentID: UUID?
    public var isApplying = false
    public var applyError: String?
    public var lastBackupURL: URL?
    /// 네트워크 허브(포트 스캔 + cloudflared 터널) 공유 인스턴스.
    public let tunnelManager = TunnelManager.shared

    let store: ProfileStore
    let fragmentStore: FragmentStore

    public init(store: ProfileStore = .shared, fragmentStore: FragmentStore = .shared) {
        self.store = store
        self.fragmentStore = fragmentStore
        refresh()
        if selectedProfileID == nil {
            selectedProfileID = profiles.first { $0.isActive }?.id ?? profiles.first?.id
        }
        if selectedFragmentID == nil {
            selectedFragmentID = fragments.first?.id
        }
    }

    public func refresh() {
        profiles = store.all()
        fragments = fragmentStore.all()
        if let selected = selectedProfileID, store.get(selected) == nil {
            selectedProfileID = profiles.first { $0.isActive }?.id ?? profiles.first?.id
        }
        if let selected = selectedFragmentID, fragmentStore.get(selected) == nil {
            selectedFragmentID = fragments.first?.id
        }
    }

    public var activeProfile: Profile? {
        profiles.first { $0.isActive }
    }

    public var selectedProfile: Profile? {
        guard let id = selectedProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    public var selectedFragment: Fragment? {
        guard let id = selectedFragmentID else { return nil }
        return fragments.first { $0.id == id }
    }

    // MARK: - Stale 판정 (본문 + 토글 + 프래그먼트 내용)

    public func needsReapply(_ profile: Profile) -> Bool {
        guard let appliedHash = profile.appliedHash else { return true }
        return Composer.shared.fingerprint(profile: profile, fragments: fragments) != appliedHash
    }

    public var anyNeedsReapply: Bool {
        profiles.contains { needsReapply($0) }
    }

    // MARK: - 현재 hosts / 네트워크 정보 읽기

    /// 실제 /etc/hosts 내용. 읽기 실패하면 활성 프로필 합성 결과로 폴백.
    /// 파일 읽기는 짧은 TTL 동안 캐시해 뷰 body 반복 평가를 완화 (외부 변경은 최대 2초 지연).
    @ObservationIgnored private var hostsReadCache: (text: String, date: Date)?

    public private(set) var lastHostsIsLive = true
    public var currentHosts: String {
        if let cache = hostsReadCache, Date().timeIntervalSince(cache.date) < 2.0 {
            return cache.text
        }
        let url = URL(fileURLWithPath: "/etc/hosts")
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            lastHostsIsLive = true
            hostsReadCache = (text, Date())
            return text
        }
        lastHostsIsLive = false
        guard let active = store.active() else { return "" }
        let text = Composer.shared.compose(profile: active, fragments: fragmentStore.all())
        hostsReadCache = (text, Date())
        return text
    }

    /// 현재 로컬 IP (네트워크 탭 표시용). 인터페이스 열거가 비싸 5초 TTL 캐시.
    @ObservationIgnored private var ipCache: (value: String?, date: Date)?

    public var currentIP: String? {
        if let cache = ipCache, Date().timeIntervalSince(cache.date) < 5.0 {
            return cache.value
        }
        let value = IPMonitor.primaryIP()
        ipCache = (value, Date())
        return value
    }

    /// 메뉴바 팝오버 표용 행 (그룹/IP/호스트/주석/상태).
    public var hostsTableRows: [HostsTableRow] {
        HostEntry.tableRows(from: currentHosts)
    }

    /// 편집을 스토어 원본으로 되돌림 (= 메모리 목록 새로고침).
    public func cancelEdit(_ id: UUID) {
        refresh()
    }

    public func describe(_ error: Error) -> String {
        if let typed = error as? EtchostError {
            return typed.errorDescription ?? typed.localizedDescription
        }
        return error.localizedDescription
    }

    /// 백업과 무관한 호출부에서는 캐시 무효화 없이 TTL에만 의존.
    public func invalidateHostsCache() {
        hostsReadCache = nil
    }
}
