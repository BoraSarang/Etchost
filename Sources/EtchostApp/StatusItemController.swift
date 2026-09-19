import AppKit
import SwiftUI

/// 수동 NSStatusItem: 메뉴바 아이콘(템플릿) + 클릭 시 아이콘 **아래 중앙**에 팝오버 표시.
/// MenuBarExtra(.window)와 달리 위치를 직접 제어한다.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    init(model: AppModel) {
        self.model = model
        super.init()
        setupStatusItem()
        setupPopover()
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
            rootView: MenuBarPopover().environmentObject(model)
        )
        // 콘텐츠 크기에 맞춰 자동 조절 (프로필/터널/호스트 수가 늘어나도 잘리지 않음).
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.animates = true
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
