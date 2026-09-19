import EtchostKit
import Foundation
import SwiftUI

public enum SidebarSection: String, CaseIterable, Identifiable {
    case profiles
    case fragments

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .profiles: return "프로필"
        case .fragments: return "프래그먼트"
        }
    }

    public var systemImage: String {
        switch self {
        case .profiles: return "square.stack.3d.up"
        case .fragments: return "puzzlepiece"
        }
    }
}

/// 코디네이터: 프로필 + 프래그먼트 목록, 선택, 적용 상태 관리.
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

    private let store: ProfileStore
    private let fragmentStore: FragmentStore

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

    /// 실제 /etc/hosts 내용. 읽기 실패하면 활성 프로필 합성 결과로 폴백.
    public private(set) var lastHostsIsLive = true
    public var currentHosts: String {
        let url = URL(fileURLWithPath: "/etc/hosts")
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            lastHostsIsLive = true
            return text
        }
        lastHostsIsLive = false
        guard let active = store.active() else { return "" }
        return Composer.shared.compose(profile: active, fragments: fragmentStore.all())
    }

    /// 메뉴바 팝오버 표용 행 (그룹/IP/호스트/주석/상태).
    public var hostsTableRows: [HostsTableRow] {
        HostEntry.tableRows(from: currentHosts)
    }

    public func profilesUsing(_ fragmentID: UUID) -> [Profile] {
        profiles.filter { $0.fragmentIDs.contains(fragmentID) }
    }

    // MARK: - Profile CRUD

    public func createProfile(name: String) throws {
        let profile = try store.create(name: name)
        refresh()
        sidebarSection = .profiles
        selectedProfileID = profile.id
    }

    public func renameProfile(_ id: UUID, to name: String) throws {
        guard var profile = store.get(id) else { throw EtchostError.profileNotFound(id) }
        profile.updateName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        try store.update(profile)
        refresh()
    }

    public func updateEntries(_ id: UUID, entries: [HostEntry]) throws {
        guard var profile = store.get(id) else { throw EtchostError.profileNotFound(id) }
        profile.updateEntries(entries)
        try store.update(profile)
        refresh()
    }

    public func deleteProfile(_ id: UUID) throws {
        try store.delete(id)
        refresh()
    }

    public func reorderProfiles(_ ids: [UUID]) {
        store.reorder(ids)
        refresh()
    }

    public func cancelEdit(_ id: UUID) {
        // 스토어 원본으로 되돌림 = 메모리 목록 새로고침
        refresh()
    }

    // MARK: - Fragment CRUD

    public func createFragment(name: String) throws {
        let fragment = try fragmentStore.create(name: name)
        refresh()
        sidebarSection = .fragments
        selectedFragmentID = fragment.id
    }

    public func renameFragment(_ id: UUID, to name: String) throws {
        guard var fragment = fragmentStore.get(id) else { throw EtchostError.fragmentNotFound(id) }
        fragment.updateName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        try fragmentStore.update(fragment)
        refresh()
    }

    public func updateFragmentEntries(_ id: UUID, entries: [HostEntry]) throws {
        guard var fragment = fragmentStore.get(id) else { throw EtchostError.fragmentNotFound(id) }
        fragment.updateEntries(entries)
        try fragmentStore.update(fragment)
        refresh()
    }

    /// 삭제 시 켠 프로필에서 자동 해제 (연쇄 해제).
    public func deleteFragment(_ id: UUID) throws {
        guard fragmentStore.get(id) != nil else { throw EtchostError.fragmentNotFound(id) }
        for var profile in profiles where profile.fragmentIDs.contains(id) {
            profile.toggleFragment(id)
            try store.update(profile)
        }
        try fragmentStore.delete(id)
        refresh()
    }

    public func reorderFragments(_ ids: [UUID]) {
        fragmentStore.reorder(ids)
        refresh()
    }

    public func toggleFragment(profileID: UUID, fragmentID: UUID) throws {
        guard var profile = store.get(profileID) else { throw EtchostError.profileNotFound(profileID) }
        guard fragmentStore.get(fragmentID) != nil else { throw EtchostError.fragmentNotFound(fragmentID) }
        profile.toggleFragment(fragmentID)
        try store.update(profile)
        refresh()
    }

    // MARK: - 메뉴바 즉시 적용 경로

    /// 메뉴바 클릭 시: setActive + /etc/hosts 쓰기. 암호 프롬프트 1회.
    public func switchAndApply(_ id: UUID) async {
        do {
            try store.setActive(id)
            refresh()
            selectedProfileID = id
            await applyActiveProfile()
        } catch {
            applyError = describe(error)
        }
    }

    public func applyActiveProfile() async {
        guard let active = store.active() else {
            applyError = "활성 프로필이 없습니다."
            return
        }
        isApplying = true
        applyError = nil
        defer { isApplying = false }

        let allFragments = fragmentStore.all()
        let content = Composer.shared.compose(profile: active, fragments: allFragments)
        lastBackupURL = BackupManager.shared.backupCurrentHosts()

        do {
            try await Applier.shared.apply(content)
            var updated = active
            updated.markApplied(
                fingerprint: Composer.shared.fingerprint(profile: active, fragments: allFragments))
            try store.update(updated)
            refresh()
            NotificationCenter.default.post(name: .hostsApplied, object: nil)
        } catch {
            applyError = describe(error)
        }
    }

    public func describe(_ error: Error) -> String {
        if let typed = error as? EtchostError {
            switch typed {
            case .duplicateProfileName(let name): return "이미 존재하는 프로필 이름입니다: \(name)"
            case .duplicateFragmentName(let name): return "이미 존재하는 프래그먼트 이름입니다: \(name)"
            case .cannotDeleteActiveProfile: return "활성 프로필은 삭제할 수 없습니다."
            case .profileNotFound: return "프로필을 찾을 수 없습니다."
            case .fragmentNotFound: return "프래그먼트를 찾을 수 없습니다."
            case .permissionDenied: return "관리자 권한이 필요합니다. 비밀번호를 확인하세요."
            case .applyFailed(let msg): return "/etc/hosts 적용에 실패했습니다: \(msg)"
            case .dnsFlushFailed(let msg): return "DNS 캐시 플러시에 실패했습니다: \(msg)"
            case .backupFailed(let msg): return "백업 생성에 실패했습니다: \(msg)"
            case .ioError(let msg): return "파일 입출력 오류: \(msg)"
            case .invalidHostEntry(let msg): return "잘못된 호스트 항목입니다: \(msg)"
            case .unknown(let msg): return "알 수 없는 오류: \(msg)"
            @unknown default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

public extension Notification.Name {
    static let openMainWindow = Notification.Name("etchost.openMainWindow")
}
