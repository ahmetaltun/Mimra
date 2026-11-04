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
    private var settingsWindow: NSWindow?
    private(set) var contextMenu: NSMenu?

    public let coreClient: CoreClient
    public let monitor: ClipboardMonitor
    public let panelCoordinator: PanelCoordinator

    private var pauseMenuItem: NSMenuItem?

    public var statusItemButton: NSStatusBarButton? {
        return statusItem?.button
    }

    public var isPaused: Bool {
        return monitor.privacyFilter.isPaused
    }

    public var menu: NSMenu? {
        return contextMenu
    }

    init(coreClient: CoreClient, monitor: ClipboardMonitor, panelCoordinator: PanelCoordinator) {
        self.coreClient = coreClient
        self.monitor = monitor
        self.panelCoordinator = panelCoordinator
        super.init()
        self.panelCoordinator.onSettingsRequested = { [weak self] in
            self?.openSettings()
        }
    }

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Mimra Clipboard Manager", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let engineItem = NSMenuItem(title: "RustCore: v\(coreVersion()) (arm64)", action: nil, keyEquivalent: "")
        engineItem.isEnabled = false
        menu.addItem(engineItem)

        menu.addItem(NSMenuItem.separator())

        // Show Clipboard History (Shift-Command-C, F-017)
        let showHistoryItem = NSMenuItem(
            title: "Show Clipboard History...",
            action: #selector(openHistory),
            keyEquivalent: "c"
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

        self.contextMenu = menu
        self.statusItem = item
        updateStatusItemAppearance()
    }

    /// Updates the menu bar icon and accessibility description according to the pause state.
    public func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let isPaused = monitor.privacyFilter.isPaused
        if isPaused {
            button.image = NSImage(
                systemSymbolName: "pause.circle",
                accessibilityDescription: "Mimra Clipboard Manager (Capture Paused)"
            )
        } else {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Mimra Clipboard Manager"
            )
        }
        button.image?.isTemplate = true
        pauseMenuItem?.title = isPaused ? "Resume Capture" : "Pause Capture"
    }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let flags = event?.modifierFlags ?? []
        handleStatusItemClick(isRightClick: isRightClick, modifierFlags: flags)
    }

    /// Handles clicks on the status item with modifier awareness.
    public func handleStatusItemClick(isRightClick: Bool, modifierFlags: NSEvent.ModifierFlags) {
        if modifierFlags.contains(.option) && modifierFlags.contains(.shift) {
            // Option-Shift-click: Open Settings directly (F-027)
            openSettings()
        } else if modifierFlags.contains(.option) {
            // Option-click: Toggle capture pause / resume directly (F-026)
            togglePause()
        } else if isRightClick {
            // Right-click: Show context menu
            showContextMenu()
        } else {
            // Standard left-click: Toggle floating clipboard history panel (F-017, F-018)
            openHistory()
        }
    }

    public func showContextMenu() {
        guard let button = statusItem?.button, let menu = contextMenu else { return }
        updateStatusItemAppearance()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc func openHistory() {
        panelCoordinator.toggle()
    }

    @objc public func togglePause() {
        let currentlyPaused = monitor.privacyFilter.isPaused
        monitor.privacyFilter.isPaused = !currentlyPaused
        updateStatusItemAppearance()
    }

    @objc public func triggerIgnoreNextCopy() {
        monitor.privacyFilter.ignoreNextCopy = true
    }

    @objc public func clearUnpinned() {
        Task {
            await OCRService.shared.cancelAll()
            _ = try? await coreClient.clearUnpinned()
            _ = try? await coreClient.checkpointWal()
        }
    }

    @objc public func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear All Clipboard History?"
        alert.informativeText = "This will permanently remove all items, including pinned clips. This action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await OCRService.shared.cancelAll()
                _ = try? await coreClient.clearAll()
                _ = try? await coreClient.checkpointWal()
                try? await coreClient.vacuumDatabase()
            }
        }
    }

    @objc public func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Mimra Settings"
        window.contentView = NSHostingView(rootView: SettingsView(coreClient: coreClient))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
