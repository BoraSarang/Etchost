import AppKit
import SwiftUI

/// 수동 NSStatusItem: 메뉴바 아이콘(템플릿) + 클릭 시 아이콘 **아래 중앙**에 팝오버 표시.
/// MenuBarExtra(.window)와 달리 위치를 직접 제어한다.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var updateWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
        setupStatusItem()
        setupPopover()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowUpdateSheet),
            name: .showUpdateSheet,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenMainWindow),
            name: .openMainWindow,
            object: nil
        )
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Etchost - 호스트갈이"
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPopover() {
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: MenuBarPopover()
                .environmentObject(model)
                .environment(AppSettings.shared)
        )
        // 콘텐츠 크기에 맞춰 자동 조절 (프로필/터널/호스트 수가 늘어나도 잘리지 않음).
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.animates = true
    }

    /// 호스트 관리 열기 요청: transient 팝오버를 먼저 닫고 창을 연다.
    /// (팝오버 열린 채 activate → 포커스 경합으로 새 창이 뒤에 가리던 P1-4 수정)
    @objc private func handleOpenMainWindow() {
        if popover.isShown {
            popover.performClose(nil)
        }
        MainWindowOpener.shared.openMain()
    }

    /// 팝오버 하단 업데이트 표시에서 요청: 별도 윈도우로 업데이트 시트를 연다.
    /// 설정 시트와 달리 dismiss가 없으므로 onClose로 윈도우를 직접 닫는다.
    @objc private func handleShowUpdateSheet() {
        guard let update = AppSettings.shared.availableUpdate else { return }
        let sheet = UpdateAvailableSheet(
            tag: update.tag,
            htmlURL: update.htmlURL,
            notes: update.notes,
            currentVersion: AppSettings.shared.appBundleVersion,
            onClose: { [weak self] in self?.updateWindow?.close() }
        )
        if let window = updateWindow,
           let hosting = window.contentViewController as? NSHostingController<UpdateAvailableSheet> {
            hosting.rootView = sheet
            window.makeKeyAndOrderFront(nil)
        } else {
            let hosting = NSHostingController(rootView: sheet)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Etchost"
            window.styleMask = [.titled, .closable]
            window.center()
            window.isReleasedWhenClosed = false
            updateWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
