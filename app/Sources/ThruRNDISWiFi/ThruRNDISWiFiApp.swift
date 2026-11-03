// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import AppKit
import Combine
import SwiftUI

@main
struct ThruRNDISWiFiApp: App {
    @NSApplicationDelegateAdaptor(StatusItemController.self) private var controller

    var body: some Scene {
        // The menu is an NSPopover owned by StatusItemController; an App
        // still needs a scene.
        Settings { EmptyView() }
    }
}

/// Menu bar icon and its popover. Unlike MenuBarExtra's window, an NSPopover
/// stays attached to the icon and grows or shrinks downward from it when the
/// content changes, without leaving its old shadow behind.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let form = JoinForm()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var statusObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSHostingController(rootView: MenuView(model: model, form: form))
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.behavior = .transient

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        updateIcon(model.status)
        statusObserver = model.$status.sink { [weak self] status in self?.updateIcon(status) }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // An accessory app has to be active for the text fields to get keys.
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateIcon(_ status: GuestAPI.Status?) {
        let symbol: String
        if let status {
            symbol = status.isAssociated && status.route_ready ? "wifi" : "wifi.exclamationmark"
        } else {
            symbol = "wifi.slash"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ThruRNDIS-Wi-Fi")
    }
}
