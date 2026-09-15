//
//  AppDelegate.swift
//  occuporto
//
//  Manages the menu bar status item directly via AppKit. This is
//  necessary (rather than SwiftUI's `MenuBarExtra`) because
//  `MenuBarExtra` doesn't support distinct left-click vs. right-click
//  behavior — left-click always opens the same content, with no way to
//  show a separate context menu on right-click. `NSStatusItem` gives us
//  that control directly.
//

import SwiftUI
import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            let icon = NSImage(
                systemSymbolName: "cable.connector.horizontal",
                accessibilityDescription: "Occuporto"
            )?.withSymbolConfiguration(symbolConfig)
            icon?.isTemplate = true
            button.image = icon
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = statusItem

        let hostingController = NSHostingController(rootView: PortListView())
        hostingController.sizingOptions = [.intrinsicContentSize]

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hostingController
        self.popover = popover
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Temporarily assigns a menu to the status item and triggers it to
    /// show immediately, then clears it so subsequent left-clicks go back
    /// through `statusItemClicked` (and toggle the popover) instead of
    /// always opening this menu.
    private func showContextMenu() {
        let menu = NSMenu()

        let launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Occuporto", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Occuporto: failed to toggle launch-at-login: \(error.localizedDescription)")
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
