import EtchostKit
import Foundation

// MARK: - 원격 프래그먼트 동기화

extension AppModel {
    /// 현재 동기화 중인 프래그먼트 ID (nil이면 유휴).
    public var isSyncingRemote: Bool { syncingFragmentID != nil }
    /// 단일 원격 프래그먼트 동기화. 성공 시 항목 교체(참조 프로필 자동 stale),
    /// 실패 시 기존 캐시 유지 + 오류 기록. 비밀번호 프롬프트 없음.
    /// 진행 단계는 `syncPhase`에 게시되어 에디터에서 ProgressView로 표시한다.
    @discardableResult
    public func syncRemoteFragment(_ id: UUID) async -> Bool {
        guard let fragment = fragmentStore.get(id),
              let remote = fragment.remote,
              let url = remote.cleanedURL
        else { return false }
        syncingFragmentID = id
        syncPhase = .downloading(host: url.host ?? "")
        defer {
            syncingFragmentID = nil
            syncPhase = nil
        }
        do {
            let service = RemoteSyncService { [weak self] phase in
                // 진행 콜백은 백그라운드에서 올 수 있어 메인으로 홉.
                Task { @MainActor in self?.syncPhase = phase }
            }
            let result = try await service.sync(url: url)
            syncPhase = .saving(count: result.entries.count)
            try fragmentStore.applySyncResult(id, entries: result.entries)
            refresh()
            return true
        } catch {
            fragmentStore.recordSyncError(id, message: describe(error))
            refresh()
            return false
        }
    }

    /// 실행·주기 대상 일괄 동기화. 마스터 스위치가 꺼져 있으면 건너뛴다.
    public func syncDueRemoteFragments() async {
        guard UserDefaults.standard.object(forKey: SettingsKeys.remoteSyncAutoSync) as? Bool ?? true else {
            return
        }
        let now = Date()
        let due = fragmentStore.all().filter {
            guard let remote = $0.remote else { return false }
            switch remote.interval {
            case .manual:
                return false
            case .atLaunch:
                return remote.lastSyncedAt == nil
            case .hourly, .daily:
                return remote.interval.isDue(lastSyncedAt: remote.lastSyncedAt, now: now)
            @unknown default:
                return false
            }
        }
        for fragment in due {
            _ = await syncRemoteFragment(fragment.id)
        }
    }

    /// 원격 소스 설정 변경. URL을 비우면 로컬로 전환(항목 유지).
    public func updateFragmentRemote(_ id: UUID, url: String, interval: RemoteSource.Interval) throws {
        guard var fragment = fragmentStore.get(id) else { throw EtchostError.fragmentNotFound(id) }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            fragment.remote = nil
        } else {
            let source = RemoteSource(
                url: trimmed,
                interval: interval,
                lastSyncedAt: fragment.remote?.lastSyncedAt,
                lastError: fragment.remote?.lastError)
            guard source.cleanedURL != nil else {
                throw EtchostError.invalidHostEntry(trimmed)
            }
            fragment.remote = source
        }
        try fragmentStore.update(fragment)
        refresh()
    }
}
