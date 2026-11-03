// ==============================================================================
// Mimra — Floating Panel & Panel Coordinator
// Custom borderless, floating, non-activating NSPanel and screen coordinator.
// Linked Features: F-018, F-019
// Test IDs: T-UI-02, T-UI-03
// ==============================================================================

import AppKit
import SwiftUI

/// Custom native NSPanel subclass designed for instant summoning over full-screen
/// spaces and standard applications without stealing active application status.
@MainActor
open class FloatingPanel: NSPanel {
    public var onResignKey: (() -> Void)?
    public var onEscapePressed: (() -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .nonactivatingPanel,
                .titled,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]
        self.minSize = NSSize(width: 340, height: 320)
        self.maxSize = NSSize(width: 800, height: 1000)
        self.isReleasedWhenClosed = false
    }

    /// The panel can become key window so that text inputs inside receive keyboard focus.
    open override var canBecomeKey: Bool {
        return true
    }

    /// The panel should never become main window, ensuring Mimra does not disrupt
    /// the frontmost document window hierarchy of the target application.
    open override var canBecomeMain: Bool {
        return false
    }

    /// Automatically dismiss the panel when the user clicks elsewhere.
    open override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Intercept Escape key to dismiss the panel.
    open override func cancelOperation(_ sender: Any?) {
        if let onEscape = onEscapePressed {
            onEscape()
        } else {
            super.cancelOperation(sender)
        }
    }
}

/// Nonisolated, thread-safe wrapper holding the local NSEvent key monitor reference.
final class KeyMonitorState: @unchecked Sendable {
    var monitor: Any?

    func remove() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit {
        remove()
    }
}

/// Coordinates the lifecycle, active screen positioning (Option A), keyboard navigation,
/// and presentation of the FloatingPanel.
@MainActor
public final class PanelCoordinator: NSObject, NSWindowDelegate {
    public let coreClient: CoreClient
    public let viewModel: PanelViewModel
    public let pasteCoordinator: PasteCoordinator
    public private(set) var panel: FloatingPanel?
    public private(set) var targetApp: NSRunningApplication?
    public var onSettingsRequested: (() -> Void)?
    public var onPasteRequested: ((HistoryItemSummaryDto) -> Void)?
    public var onPasteResult: ((PasteResult) -> Void)?

    private let keyMonitorState = KeyMonitorState()

    public init(coreClient: CoreClient, pasteCoordinator: PasteCoordinator? = nil) {
        self.coreClient = coreClient
        self.viewModel = PanelViewModel(coreClient: coreClient)
        self.pasteCoordinator = pasteCoordinator ?? PasteCoordinator(coreClient: coreClient)
        super.init()

        viewModel.onDismiss = { [weak self] in
            self?.hide()
        }
        viewModel.onOpenSettings = { [weak self] in
            self?.hide()
        }
        viewModel.onCommitItem = { [weak self] item, mode, forcePaste in
            self?.handleItemCommit(item: item, mode: mode, forcePaste: forcePaste)
        }
        setupKeyMonitor()
    }

    private func setupKeyMonitor() {
        guard keyMonitorState.monitor == nil else { return }
        keyMonitorState.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isKeyWindow else {
                return event
            }
            if self.handlePanelKeyDown(event: event) {
                return nil
            }
            return event
        }
    }

    /// Handles keyboard events directed at the floating panel.
    public func handlePanelKeyDown(event: NSEvent) -> Bool {
        // 1. Escape key
        if event.keyCode == 53 {
            hide()
            return true
        }

        // 2. Command-, (Settings)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "," {
            hide()
            onSettingsRequested?()
            return true
        }

        // 3. Command-1 .. Command-9 (Quick-picks)
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           let num = Int(chars), num >= 1 && num <= 9 {
            let isOption = event.modifierFlags.contains(.option)
            let isShift = event.modifierFlags.contains(.shift)
            let mode: PasteMode = isShift ? .plainText : .original
            let forcePaste: Bool? = isOption ? !pasteCoordinator.pasteAutomatically : nil
            viewModel.quickPick(number: num, mode: mode, forcePaste: forcePaste)
            return true
        }

        // 4. Up Arrow
        if event.keyCode == 126 {
            viewModel.selectPrevious()
            return true
        }

        // 5. Down Arrow
        if event.keyCode == 125 {
            viewModel.selectNext()
            return true
        }

        // 6. Return / Keypad Enter
        if event.keyCode == 36 || event.keyCode == 76 {
            let isOption = event.modifierFlags.contains(.option)
            let isShift = event.modifierFlags.contains(.shift)
            let mode: PasteMode = isShift ? .plainText : .original
            let forcePaste: Bool? = isOption ? !pasteCoordinator.pasteAutomatically : nil
            viewModel.commitSelection(mode: mode, forcePaste: forcePaste)
            return true
        }

        return false
    }

    /// Handles committing a selected item.
    public func handleItemCommit(
        item: HistoryItemSummaryDto,
        mode: PasteMode = .original,
        forcePaste: Bool? = nil
    ) {
        let target = self.targetApp
        hide()
        Task {
            do {
                let result = try await pasteCoordinator.paste(
                    itemId: item.id,
                    mode: mode,
                    targetApp: target,
                    forcePaste: forcePaste
                )
                onPasteResult?(result)
            } catch {
                // Failure already logged with descriptive typed error
            }
        }
        onPasteRequested?(item)
    }

    /// Ensures the floating panel instance is created and configured.
    @discardableResult
    public func getOrCreatePanel() -> FloatingPanel {
        if let existing = self.panel {
            return existing
        }

        let initialRect = NSRect(x: 0, y: 0, width: 440, height: 540)
        let panel = FloatingPanel(contentRect: initialRect)
        panel.delegate = self

        let rootView = FloatingPanelView(viewModel: viewModel)
        panel.contentView = NSHostingView(rootView: rootView)

        panel.onResignKey = { [weak self] in
            self?.hide()
        }
        panel.onEscapePressed = { [weak self] in
            self?.hide()
        }

        self.panel = panel
        return panel
    }

    /// Toggles visibility of the panel.
    public func toggle() {
        if let p = panel, p.isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Shows the floating panel, centered on the display containing the cursor (Option A).
    public func show() {
        let p = getOrCreatePanel()

        // 1. Record the current frontmost application before showing the panel
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != ClipboardProvenance.mimraBundleIdentifier {
            self.targetApp = frontmost
        }

        // 2. Reload data and reset search
        Task {
            await viewModel.loadData()
        }

        // 3. Center on the active screen containing the mouse cursor
        centerOnActiveScreen(panel: p)

        // 4. Make key and order front
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hides the floating panel without losing state.
    public func hide() {
        panel?.orderOut(nil)
        if !viewModel.searchText.isEmpty {
            viewModel.searchText = ""
        }
    }

    /// Centers the panel on the active screen (Option A).
    public func centerOnActiveScreen(panel: FloatingPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = targetScreen else { return }
        let vf = screen.visibleFrame
        let panelSize = panel.frame.size

        let originX = round(vf.origin.x + (vf.width - panelSize.width) / 2.0)
        let originY = round(vf.origin.y + (vf.height - panelSize.height) / 2.0)

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
