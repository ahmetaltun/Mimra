// ==============================================================================
// Mimra — Status Bar Coordinator
// Manages system menu bar status item, menu actions, history window, and settings.
// Linked Features: F-017, F-025, F-026, F-027
// Test IDs: T-UI-01, T-HIST-01, T-PRIV-06
// ==============================================================================

import AppKit
import SwiftUI

@MainActor
final class StatusBarCoordinator: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    public private(set) var settingsWindow: NSWindow?
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

        // Observe live appearance and menu bar customization changes (P7-02 / F-035, T-UI-09)
        NotificationCenter.default.addObserver(
            forName: AppearanceConfiguration.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusItemAppearance()
            }
        }

        // Observe privacy configuration changes (P7-04 / F-057)
        NotificationCenter.default.addObserver(
            forName: PrivacyConfiguration.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusItemAppearance()
            }
        }
    }

    /// Updates the menu bar icon and accessibility description according to the pause state and preferences.
    public func updateStatusItemAppearance() {
        guard let item = statusItem, let button = item.button else { return }
        let config = AppearanceConfiguration.shared
        let isPaused = monitor.privacyFilter.isPaused

        if config.iconStyle == .hidden {
            item.isVisible = false
            return
        }
        item.isVisible = true

        let iconSymbol = isPaused ? "pause.circle" : (config.iconStyle.systemSymbolName ?? "doc.on.clipboard")
        button.image = NSImage(
            systemSymbolName: iconSymbol,
            accessibilityDescription: isPaused ? "Mimra Clipboard Manager (Capture Paused)" : "Mimra Clipboard Manager"
        )
        button.image?.isTemplate = true

        if config.showRecentCopyInMenuBar, let recent = panelCoordinator.viewModel.items.first {
            let titleSnippet = String(recent.title.prefix(20))
            button.title = " \(titleSnippet)"
        } else {
            button.title = ""
        }

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
        let newPaused = !currentlyPaused
        monitor.privacyFilter.isPaused = newPaused
        PrivacyConfiguration.shared.isPaused = newPaused
        updateStatusItemAppearance()
    }

    @objc public func triggerIgnoreNextCopy() {
        monitor.privacyFilter.ignoreNextCopy = true
        PrivacyConfiguration.shared.ignoreNextCopy = true
    }

    @objc public func clearUnpinned() {
        Task {
            await OCRService.shared.cancelAll()
            if UserDefaults.standard.bool(forKey: "clearSystemClipboard") {
                NSPasteboard.general.clearContents()
            }
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
                if UserDefaults.standard.bool(forKey: "clearSystemClipboard") {
                    NSPasteboard.general.clearContents()
                }
                _ = try? await coreClient.clearAll()
                _ = try? await coreClient.checkpointWal()
                try? await coreClient.vacuumDatabase()
            }
        }
    }

    @objc public func openSettings() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 530),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Mimra Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(coreClient: coreClient))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    public func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing == settingsWindow {
            settingsWindow = nil
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
