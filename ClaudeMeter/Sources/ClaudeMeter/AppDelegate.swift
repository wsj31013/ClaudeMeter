import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        UsageService.shared.startAutoRefresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuBarIcon),
            name: .usageDataDidUpdate,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func onSystemWake() {
        Task { await UsageService.shared.fetchUsage() }
    }

    @MainActor
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "⬤ Claude"
            button.font = NSFont.systemFont(ofSize: 12)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @MainActor
    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 200)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
    }

    @MainActor
    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @MainActor
    @objc private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        let service = UsageService.shared
        if let data = service.usageData {
            let maxPercent = max(data.fiveHour.percent, data.sevenDay.percent)
            let pctText = String(format: "%.0f%%", maxPercent)
            let icon: String
            if maxPercent >= 95 { icon = "🔴" }
            else if maxPercent >= 80 { icon = "🟡" }
            else { icon = "🟢" }
            button.title = "\(icon) \(pctText)"
        } else if service.error != nil {
            button.title = "⚠️ Claude"
        }
    }
}

extension Notification.Name {
    static let usageDataDidUpdate = Notification.Name("usageDataDidUpdate")
}
