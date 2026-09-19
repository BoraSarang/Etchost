import EtchostKit
import Foundation

// MARK: - 적용 경로

extension AppModel {
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
            applyError = L.str("error.noActiveProfile")
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
            invalidateHostsCache()
            NotificationCenter.default.post(name: .hostsApplied, object: nil)
        } catch {
            applyError = describe(error)
        }
    }
}
