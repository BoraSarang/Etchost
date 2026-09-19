import EtchostKit
import Foundation
import Testing

@Suite("로컬라이즈 키 무결성")
struct LocalizationTests {
    private static let sampleKeys = [
        "hosts.group.baseline",
        "tunnel.status.running",
        "network.service.other",
        "network.service.http.dev",
        "tunnel.install.doneWithVersion",
        "applier.prompt",
        "error.duplicateProfileName",
        "error.duplicateFragmentName",
        "error.duplicateTunnelLabel",
        "error.cannotDeleteActiveProfile",
        "error.profileNotFound",
        "error.fragmentNotFound",
        "error.tunnelNotFound",
        "error.cloudflaredNotInstalled",
        "error.brewNotInstalled",
        "error.scanFailed",
        "error.permissionDenied",
        "error.applyFailed",
        "error.dnsFlushFailed",
        "error.backupFailed",
        "error.ioError",
        "error.invalidHostEntry",
        "error.unknown",
        "error.releaseURLFailed",
        "error.releaseFetchFailed",
    ]

    @Test("Kit 키가 키 이름 자체로 새지는 않음 (번역 존재)")
    func keysResolve() {
        for key in Self.sampleKeys {
            let value = Loc.str(key)
            #expect(value != key)
            #expect(!value.isEmpty)
        }
    }

    @Test("포맷 인자 보간")
    func formatInterpolation() {
        let message = "boom"
        #expect(Loc.str("tunnel.status.error", message).contains(message))
        #expect(Loc.str("tunnel.install.doneWithVersion", "2025.1.0").contains("2025.1.0"))
    }
}