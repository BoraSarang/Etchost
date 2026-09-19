import AppKit
import EtchostKit
import Observation
import ServiceManagement
import SwiftUI

/// 앱 전역 설정 단일 소스. 값은 UserDefaults에 영속화되고, 변경 즉시 부수 효과 적용
/// (Dock 아이콘 정책 전환, SMAppService 로그인 항목 등록 등).
/// @Observable이므로 didSet 미지원 → 모든 setter는 명시 메서드로 구현.
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    /// Dock 아이콘 표시 여부. ULSIElement(메뉴바 전용) 앱이지만 런타임 정책만 전환한다.
    public private(set) var showDockIcon = false

    public private(set) var autoStartTunnelsAtLaunch = false
    public private(set) var autoRebookTunnels = false
    public private(set) var customScanPortsInput = ""
    public private(set) var backupRetention = SettingsKeys.backupRetentionDefault

    /// 선택한 (사용자가 고른) 앱 언어. 시스템 기본이면 .system.
    public private(set) var language: AppLanguage = .system

    /// 지금 실행 중인 이 프로세스가 실제로 사용 중인 언어 (선택과 다르면 재시작 필요).
    public private(set) var appliedLanguage: AppLanguage = .system

    /// 로그인 항목 오류/알림 문구 (nil이면 정상).
    public private(set) var launchAtLoginMessage: String?

    // MARK: - 업데이트 확인 상태

    public enum UpdateState: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case updateAvailable(tag: String, htmlURL: String)
        case unavailable(String)
    }

    public private(set) var updateState: UpdateState = .idle
    public private(set) var updateCheckedAt: Date?

    /// 실행 중인 앱 버전 (CFBundle). 읽기 실패 시 "0.0.0".
    public var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    public var appBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }

    public var appBundleVersion: String {
        appBuild == "0" ? appVersion : "\(appVersion) (\(appBuild))"
    }

    private init() {
        let defaults = UserDefaults.standard
        showDockIcon = defaults.bool(forKey: SettingsKeys.showDockIcon)
        autoStartTunnelsAtLaunch = defaults.bool(forKey: SettingsKeys.autoStartTunnelsAtLaunch)
        autoRebookTunnels = defaults.bool(forKey: SettingsKeys.autoRebookTunnels)
        customScanPortsInput = defaults.string(forKey: SettingsKeys.customScanPorts) ?? ""
        let storedRetention = defaults.integer(forKey: SettingsKeys.backupRetention)
        backupRetention = storedRetention >= SettingsKeys.backupRetentionMin
            ? min(storedRetention, SettingsKeys.backupRetentionMax)
            : SettingsKeys.backupRetentionDefault
        language = AppLanguage(rawValue: defaults.string(forKey: SettingsKeys.language) ?? "") ?? .system
        appliedLanguage = Self.currentAppliedLanguage()
    }

    // MARK: - Dock 아이콘

    public func setShowDockIcon(_ on: Bool) {
        guard showDockIcon != on else { return }
        showDockIcon = on
        UserDefaults.standard.set(on, forKey: SettingsKeys.showDockIcon)
        NSApp.setActivationPolicy(on ? .regular : .accessory)
    }

    public func applyOnLaunch() {
        if showDockIcon {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - 로그인 시 자동 실행 (정석: SMAppService.mainApp)

    public var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginMessage = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            if on, SMAppService.mainApp.status != .enabled {
                launchAtLoginMessage = L.str("settings.loginItem.message.notRegistered")
            }
        } catch {
            launchAtLoginMessage = L.str("settings.loginItem.message.failed", error.localizedDescription)
        }
    }

    public func dismissLaunchAtLoginMessage() {
        launchAtLoginMessage = nil
    }

    // MARK: - 네트워크 설정

    public func setAutoStartTunnelsAtLaunch(_ on: Bool) {
        guard autoStartTunnelsAtLaunch != on else { return }
        autoStartTunnelsAtLaunch = on
        UserDefaults.standard.set(on, forKey: SettingsKeys.autoStartTunnelsAtLaunch)
    }

    public func setAutoRebookTunnels(_ on: Bool) {
        guard autoRebookTunnels != on else { return }
        autoRebookTunnels = on
        UserDefaults.standard.set(on, forKey: SettingsKeys.autoRebookTunnels)
    }

    public func setCustomScanPortsInput(_ input: String) {
        customScanPortsInput = input
        UserDefaults.standard.set(input, forKey: SettingsKeys.customScanPorts)
    }

    /// 유효한 커스텀 포트 목록. 비어 있으면 nil (기본값 사용 의미).
    public var configuredScanPorts: [Int]? {
        let ports = PortList.parse(customScanPortsInput)
        return ports.isEmpty ? nil : ports
    }

    public var customPortsHasInvalid: Bool {
        !customScanPortsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && PortList.hasInvalidToken(customScanPortsInput)
    }

    // MARK: - 앱 언어

    public func setLanguage(_ value: AppLanguage) {
        guard language != value else { return }
        language = value
        UserDefaults.standard.set(value.rawValue, forKey: SettingsKeys.language)
        if let code = value.appleLanguageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// 실행 중 번들이 실제로 쓰는 언어. 명시 오버라이드(UserDefaults AppleLanguages)가
    /// 있으면 그것을 우선하고, 없으면 시스템 선호를 따른다.
    private static func currentAppliedLanguage() -> AppLanguage {
        if let overrides = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
           let first = overrides.first?.lowercased() {
            if first.hasPrefix("ko") { return .ko }
            if first.hasPrefix("en") { return .en }
        }
        guard let first = Bundle.main.preferredLocalizations.first?.lowercased() else { return .system }
        if first.hasPrefix("ko") { return .ko }
        if first.hasPrefix("en") { return .en }
        return .system
    }

    public func restartApp() {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        NSApp.terminate(nil)
    }

    // MARK: - 백업

    public func setBackupRetention(_ value: Int) {
        let clamped = min(max(value, SettingsKeys.backupRetentionMin), SettingsKeys.backupRetentionMax)
        guard backupRetention != clamped else { return }
        backupRetention = clamped
        UserDefaults.standard.set(clamped, forKey: SettingsKeys.backupRetention)
    }

    // MARK: - 업데이트 확인

    public func checkForUpdate() async {
        updateState = .checking
        do {
            let release = try await ReleaseChecker.fetchLatest()
            updateCheckedAt = Date()
            if ReleaseChecker.isNewer(release.tagName, than: appVersion) {
                updateState = .updateAvailable(tag: release.tagName, htmlURL: release.htmlURL)
            } else {
                updateState = .upToDate
            }
        } catch {
            updateCheckedAt = Date()
            updateState = .unavailable(L.str("settings.update.unavailable"))
        }
    }
}
