import Foundation

/// 적용 전 백업 관리자. 현재 /etc/hosts 파일 내용을 Backups에 복사.
/// 권한 상승 없이 읽기만 하므로 실패해도 조용히 nil 반환 (적용 자체는 계속).
public final class BackupManager: @unchecked Sendable {
    public static let shared = BackupManager()

    private let backupDir: URL
    private let hostsPath = "/etc/hosts"

    /// 백업 디렉터리 경로 (Finder 등에서 열기용).
    public var backupDirectory: URL { backupDir }

    public init(backupDir: URL? = nil) {
        if let backupDir {
            self.backupDir = backupDir
        } else if let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appDir = supportDir.appendingPathComponent("Etchost", isDirectory: true)
            self.backupDir = appDir.appendingPathComponent("Backups", isDirectory: true)
        } else {
            self.backupDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("Etchost-Backups", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.backupDir, withIntermediateDirectories: true)
    }

    /// 현재 /etc/hosts를 타임스탬프 백업으로 저장.
    /// 파일명: hosts-2026-09-20_153022-a1b2c3.backup (로컬 시간, Finder에서 콜론이 슬래시로 보이는 문제 회피).
    @discardableResult
    public func backupCurrentHosts() -> URL? {
        guard let content = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: Date())
        let name = "hosts-\(stamp)-\(UUID().uuidString.lowercased().prefix(6)).backup"
        let url = backupDir.appendingPathComponent(name)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            pruneOldBackups()
            return url
        } catch {
            return nil
        }
    }

    /// .backup 파일만 최신순으로 반환. 파일명 내림차순(시간순과 일치)이 기준이라
    /// 복사·복원으로 파일 생성일이 바뀌어도 순서가 깨지지 않는다.
    public func listBackups() -> [URL] {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: backupDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            return urls
                .filter { $0.pathExtension == "backup" }
                .sorted { lhs, rhs in
                    if lhs.lastPathComponent != rhs.lastPathComponent {
                        return lhs.lastPathComponent > rhs.lastPathComponent
                    }
                    let ld = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    let rd = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return ld > rd
                }
        } catch {
            return []
        }
    }

    /// 보존 개수 초과분을 삭제. 앱 실행 시에도 호출되어 예전 초과분이 쌓이지 않게 한다.
    public func pruneOldBackups() {
        for backup in listBackups().dropFirst(backupRetentionLimit()) {
            try? FileManager.default.removeItem(at: backup)
        }
    }

    /// 설정(settings.backupRetention) 기준 보존 개수. 무효 값이면 기본값.
    private func backupRetentionLimit() -> Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKeys.backupRetention)
        guard stored >= SettingsKeys.backupRetentionMin else {
            return SettingsKeys.backupRetentionDefault
        }
        return min(stored, SettingsKeys.backupRetentionMax)
    }
}
