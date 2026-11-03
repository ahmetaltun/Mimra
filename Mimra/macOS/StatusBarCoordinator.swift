// ==============================================================================
// Mimra — Status Bar Coordinator
// Manages system menu bar status item, menu actions, history window, and settings.
// Linked Features: F-017, F-025, F-026, F-027
// Test IDs: T-UI-01, T-HIST-01, T-PRIV-06
// ==============================================================================

import AppKit
import SwiftUI

@MainActor
final class StatusBarCoordinator: NSObject {
    private var statusItem: NSStatusItem?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?

    public let coreClient: CoreClient
    public let monitor: ClipboardMonitor

    private var pauseMenuItem: NSMenuItem?

    init(coreClient: CoreClient, monitor: ClipboardMonitor) {
        self.coreClient = coreClient
        self.monitor = monitor
        super.init()
    }

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Mimra Clipboard Manager"
            )
        }

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Mimra Clipboard Manager", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let engineItem = NSMenuItem(title: "RustCore: v\(coreVersion()) (arm64)", action: nil, keyEquivalent: "")
        engineItem.isEnabled = false
        menu.addItem(engineItem)

        menu.addItem(NSMenuItem.separator())

        let showHistoryItem = NSMenuItem(
            title: "Show Clipboard History...",
            action: #selector(openHistory),
            keyEquivalent: "v"
        )
        showHistoryItem.keyEquivalentModifierMask = [.command, .shift]
        showHistoryItem.target = self
        menu.addItem(showHistoryItem)

        menu.addItem(NSMenuItem.separator())

        // Pause/Resume capture toggle (F-026)
        let pauseItem = NSMenuItem(
            title: monitor.privacyFilter.isPaused ? "Resume Capture" : "Pause Capture",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)
        self.pauseMenuItem = pauseItem

        // Ignore next copy action (F-026)
        let ignoreNextItem = NSMenuItem(
            title: "Ignore Next Copy",
            action: #selector(triggerIgnoreNextCopy),
            keyEquivalent: ""
        )
        ignoreNextItem.target = self
        menu.addItem(ignoreNextItem)

        menu.addItem(NSMenuItem.separator())

        // Clear actions (F-025)
        let clearUnpinnedItem = NSMenuItem(
            title: "Clear Unpinned History",
            action: #selector(clearUnpinned),
            keyEquivalent: ""
        )
        clearUnpinnedItem.target = self
        menu.addItem(clearUnpinnedItem)

        let clearAllItem = NSMenuItem(
            title: "Clear All History...",
            action: #selector(clearAll),
            keyEquivalent: ""
        )
        clearAllItem.target = self
        menu.addItem(clearAllItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Mimra",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    @objc func openHistory() {
        if let existing = historyWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Mimra Clipboard History"
        window.contentView = NSHostingView(rootView: HistoryView(coreClient: coreClient))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.historyWindow = window
    }

    @objc private func togglePause() {
        let currentlyPaused = monitor.privacyFilter.isPaused
        monitor.privacyFilter.isPaused = !currentlyPaused
        pauseMenuItem?.title = monitor.privacyFilter.isPaused ? "Resume Capture" : "Pause Capture"
    }

    @objc private func triggerIgnoreNextCopy() {
        monitor.privacyFilter.ignoreNextCopy = true
    }

    @objc private func clearUnpinned() {
        Task {
            _ = try? await coreClient.clearUnpinned()
        }
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear All Clipboard History?"
        alert.informativeText = "This will permanently remove all items, including pinned clips. This action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                _ = try? await coreClient.clearAll()
            }
        }
    }

    @objc private func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Mimra Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
