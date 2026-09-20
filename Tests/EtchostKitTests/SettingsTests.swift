import EtchostKit
import Foundation
import Testing

@Suite("PortList")
struct PortListTests {
    @Test("쉼표/공백/세미콜론 분리 + 정렬")
    func parseBasics() {
        #expect(PortList.parse("80, 443 3000;8080") == [80, 443, 3000, 8080])
    }

    @Test("중복 제거")
    func dedupe() {
        #expect(PortList.parse("80,80, 443 80") == [80, 443])
    }

    @Test("무효/범위 밖 토큰 무시")
    func invalidIgnored() {
        #expect(PortList.parse("80, banana, 70000, 0, -1") == [80])
        #expect(PortList.parse("65535") == [65535])
    }

    @Test("빈 입력")
    func empty() {
        #expect(PortList.parse("") == [])
        #expect(PortList.parse(" ,, ; ") == [])
    }

    @Test("유효하지 않은 토큰 감지")
    func invalidToken() {
        #expect(PortList.hasInvalidToken("80, 70000"))
        #expect(PortList.hasInvalidToken("abc"))
        #expect(!PortList.hasInvalidToken("80,443 3000"))
        #expect(!PortList.hasInvalidToken(""))
    }
}

@Suite("ReleaseChecker")
struct ReleaseCheckerTests {
    @Test("버전 비교")
    func compare() {
        #expect(ReleaseChecker.compare("v1.2.3", "v1.2.3") == .orderedSame)
        #expect(ReleaseChecker.compare("v1.3.0", "v1.2.9") == .orderedDescending)
        #expect(ReleaseChecker.compare("v2.0.0", "v1.99.99") == .orderedDescending)
        #expect(ReleaseChecker.compare("v1.2.0", "v1.2.1") == .orderedAscending)
    }

    @Test("isNewer")
    func isNewer() {
        #expect(ReleaseChecker.isNewer("v1.0.1", than: "1.0.0"))
        #expect(!ReleaseChecker.isNewer("v1.0.0", than: "1.0.1"))
        #expect(!ReleaseChecker.isNewer("v1.0.0", than: "1.0.0"))
    }
}

@Suite("EtchostError 로컬라이즈드 메시지")
struct EtchostErrorDescriptionTests {
    @Test("localizedDescription 매핑")
    func localizedDescription() {
        #expect(EtchostError.duplicateProfileName("abc").localizedDescription == Loc.str("error.duplicateProfileName", "abc"))
        #expect(EtchostError.scanFailed("x").localizedDescription == Loc.str("error.scanFailed", "x"))
        #expect(EtchostError.permissionDenied.localizedDescription == Loc.str("error.permissionDenied"))
        #expect(EtchostError.unknown("z").localizedDescription == Loc.str("error.unknown", "z"))
    }
}

@Suite("BackupManager 보존 설정")
struct BackupRetentionTests {
    @Test("보존 개수 설정값을 따름")
    func retention() {
        let key = SettingsKeys.backupRetention
        let original = UserDefaults.standard.integer(forKey: key)
        defer {
            if original >= SettingsKeys.backupRetentionMin {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(3, forKey: key)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EtchostTests-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = BackupManager(backupDir: dir)

        for _ in 0..<5 {
            #expect(manager.backupCurrentHosts() != nil)
        }
        #expect(manager.listBackups().count == 3)
    }

    @Test("파일명에 콜론 없음 (Finder에서 슬래시로 보임)")
    func fileNameHasNoColon() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EtchostTests-filename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = BackupManager(backupDir: dir)

        #expect(manager.backupCurrentHosts() != nil)
        let names = manager.listBackups().map(\.lastPathComponent)
        #expect(names.count == 1)
        #expect(!names[0].contains(":"))
        #expect(!names[0].contains("/"))
        #expect(names[0].hasPrefix("hosts-"))
        #expect(names[0].hasSuffix(".backup"))
    }
}