// ==============================================================================
// Mimra — Floating Panel & Panel Coordinator
// Custom borderless, floating, non-activating NSPanel and screen coordinator.
// Linked Features: F-018, F-019
// Test IDs: T-UI-02, T-UI-03
// ==============================================================================

import AppKit
import Carbon
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

    /// Extracts a quick-pick number (1..9) from an NSEvent (forwarded to PanelCoordinator).
    public static func quickPickNumber(for event: NSEvent) -> Int? {
        return PanelCoordinator.quickPickNumber(for: event)
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
    public let previewCoordinator: PreviewCoordinator
    public private(set) var panel: FloatingPanel?
    public var targetApp: NSRunningApplication?
    public var onSettingsRequested: (() -> Void)?
    public var onPasteRequested: ((HistoryItemSummaryDto) -> Void)?
    public var onItemCommitted: ((HistoryItemSummaryDto, PasteMode, Bool?) -> Void)?
    public var onPasteResult: ((PasteResult) -> Void)?

    // Summon key configuration and cycle mode state (P5-06 / F-023, F-031, T-KEY-02, T-KEY-04)
    public var summonKeyCode: UInt32 = UInt32(kVK_ANSI_C)
    public var summonModifiers: NSEvent.ModifierFlags = [.command, .shift]
    public var cycleModeEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "cycleModeEnabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "cycleModeEnabled")
        }
    }
    public private(set) var isCycleActive: Bool = false

    public var onCycleChanged: ((Int, HistoryItemSummaryDto?) -> Void)?
    public var onCycleCommitted: ((HistoryItemSummaryDto) -> Void)?
    public var onCycleCancelled: (() -> Void)?
    public var statusItemFrame: CGRect? = nil

    private let keyMonitorState = KeyMonitorState()

    public init(coreClient: CoreClient, pasteCoordinator: PasteCoordinator? = nil, previewCoordinator: PreviewCoordinator? = nil) {
        self.coreClient = coreClient
        self.viewModel = PanelViewModel(coreClient: coreClient)
        self.pasteCoordinator = pasteCoordinator ?? PasteCoordinator(coreClient: coreClient)
        self.previewCoordinator = previewCoordinator ?? PreviewCoordinator(coreClient: coreClient)
        super.init()

        viewModel.onDismiss = { [weak self] in
            self?.hide()
        }
        viewModel.onOpenSettings = { [weak self] in
            self?.hide()
            self?.onSettingsRequested?()
        }
        viewModel.onCommitItem = { [weak self] item, mode, forcePaste in
            self?.handleItemCommit(item: item, mode: mode, forcePaste: forcePaste)
        }
        viewModel.onSelectionChanged = { [weak self] item in
            guard let self = self else { return }
            let p = self.getOrCreatePanel()
            self.previewCoordinator.handleSelectionChanged(item: item, parent: p)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, let p = self.panel, p.isVisible else { return }
                self.positionPanel(panel: p)
            }
        }
        setupKeyMonitor()
    }

    private func setupKeyMonitor() {
        guard keyMonitorState.monitor == nil else { return }
        keyMonitorState.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isKeyWindow else {
                return event
            }
            if event.type == .flagsChanged {
                self.handlePanelFlagsChanged(event: event)
                return event
            }
            if self.handlePanelKeyDown(event: event) {
                return nil
            }
            return event
        }
    }

    /// Determines the primary modifier that must be held during cycling (Command > Option > Control > Shift).
    public var primarySummonModifier: NSEvent.ModifierFlags {
        if summonModifiers.contains(.command) {
            return .command
        } else if summonModifiers.contains(.option) {
            return .option
        } else if summonModifiers.contains(.control) {
            return .control
        } else if summonModifiers.contains(.shift) {
            return .shift
        } else {
            return summonModifiers
        }
    }

    /// Handles the global summon hotkey invocation.
    /// If panel is not visible, shows the panel.
    /// If panel is visible and cycleModeEnabled is true, advances selection in cycle mode (P5-06 / F-023, F-031, T-KEY-04).
    /// If panel is visible and cycleModeEnabled is false, hides the panel.
    public func handleSummonHotkey() {
        if let p = panel, p.isVisible {
            if cycleModeEnabled {
                cycleNext()
            } else {
                hide()
            }
        } else {
            show()
        }
    }

    /// Advances selection to the next item and marks cycle mode active (P5-06 / F-031, T-KEY-04).
    public func cycleNext() {
        guard cycleModeEnabled else { return }
        isCycleActive = true
        viewModel.selectNext()
        onCycleChanged?(viewModel.selectedIndex, viewModel.selectedItem)
    }

    /// Moves selection to the previous item in cycle mode.
    public func cyclePrevious() {
        guard cycleModeEnabled else { return }
        isCycleActive = true
        viewModel.selectPrevious()
        onCycleChanged?(viewModel.selectedIndex, viewModel.selectedItem)
    }

    /// Cancels cycle mode without committing.
    public func cancelCycle() {
        if isCycleActive {
            isCycleActive = false
            onCycleCancelled?()
        }
    }

    /// Commits the currently selected item on modifier release.
    public func commitCycle() {
        guard isCycleActive else { return }
        isCycleActive = false
        if let selected = viewModel.selectedItem {
            onCycleCommitted?(selected)
            viewModel.commitSelection(mode: .original, forcePaste: nil)
        } else {
            hide()
        }
    }

    /// Handles modifier flag changes when the panel is key window.
    /// Detects release of the primary summon modifier to commit cycle mode (P5-06 / F-031, T-KEY-04).
    public func handlePanelFlagsChanged(event: NSEvent) {
        guard isCycleActive else { return }

        let primary = primarySummonModifier
        let isPrimaryHeld = event.modifierFlags.contains(primary)

        if !isPrimaryHeld {
            commitCycle()
        }
    }

    /// Extracts a quick-pick number (1..9) from an NSEvent, checking hardware virtual
    /// keycodes (top-row 1-9 and keypad 1-9) first for layout/shift independence,
    /// with character fallback (P5-05 / F-022, T-KEY-01).
    public static func quickPickNumber(for event: NSEvent) -> Int? {
        // 1. Hardware virtual keycode mapping (reliable across Shift, Option, and international layouts like AZERTY)
        switch event.keyCode {
        case 18, 83: return 1 // '1' or Keypad 1
        case 19, 84: return 2 // '2' or Keypad 2
        case 20, 85: return 3 // '3' or Keypad 3
        case 21, 86: return 4 // '4' or Keypad 4
        case 23, 87: return 5 // '5' or Keypad 5
        case 22, 88: return 6 // '6' or Keypad 6
        case 26, 89: return 7 // '7' or Keypad 7
        case 28, 91: return 8 // '8' or Keypad 8
        case 25, 92: return 9 // '9' or Keypad 9
        default: break
        }

        // 2. Direct character parse fallback (useful in synthetic headless test events)
        if let chars = event.charactersIgnoringModifiers ?? event.characters,
           let first = chars.first,
           let num = Int(String(first)), num >= 1 && num <= 9 {
            return num
        }

        return nil
    }

    /// Provider hook for testing or inspecting whether IME marked text is currently active (P7-06 / F-033, T-I18N-01).
    public var isImeComposingOverride: (() -> Bool)? = nil

    /// Checks whether the active window's first responder has active IME marked text (composition in progress).
    public var isImeComposing: Bool {
        if let override = isImeComposingOverride {
            return override()
        }
        guard let window = panel else { return false }
        if let responder = window.firstResponder as? NSTextInputClient {
            return responder.hasMarkedText()
        }
        if let fieldEditor = window.fieldEditor(false, for: nil) as? NSTextInputClient {
            return fieldEditor.hasMarkedText()
        }
        return false
    }

    /// Handles keyboard events directed at the floating panel.
    public func handlePanelKeyDown(event: NSEvent) -> Bool {
        // -1. Active IME Composition Protection (P7-06 / F-033, T-I18N-01)
        // If the user has active marked text composition in progress (e.g. Japanese Hiragana/Kanji or
        // Chinese Pinyin candidate conversion), pass keystrokes directly to NSTextInputClient so Return/Space
        // commits candidates and Escape cancels marked text without dismissing or committing the panel.
        if isImeComposing {
            return false
        }

        // 0. Active Pin Editing Shortcuts (P5-04 / F-045, T-PIN-02)
        if viewModel.editingPinItem != nil {
            if event.keyCode == 53 { // Escape cancels edit
                viewModel.cancelEditing()
                return true
            }
            if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) { // ⌘↵ saves edit
                Task {
                    _ = await viewModel.commitEditing()
                }
                return true
            }
            return false
        }

        // 1. Escape key (Cancels cycle mode, closes panel without committing: P5-06 / F-031, T-KEY-04)
        if event.keyCode == 53 {
            cancelCycle()
            hide()
            return true
        }

        // 2. Summon Key Repeat / In-Panel Summon Shortcut (P5-06 / F-023, F-031, T-KEY-04)
        if event.keyCode == summonKeyCode {
            let required = summonModifiers.intersection([.command, .shift, .option, .control])
            if event.modifierFlags.contains(required) {
                if cycleModeEnabled {
                    if event.modifierFlags.contains(.shift) && !summonModifiers.contains(.shift) {
                        cyclePrevious()
                    } else {
                        cycleNext()
                    }
                    return true
                } else {
                    hide()
                    return true
                }
            }
        }

        // 3. Command-, (Settings)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "," {
            cancelCycle()
            hide()
            onSettingsRequested?()
            return true
        }

        // 4. Command-E (Edit Selected Pinned Item, P5-04 / F-045, T-PIN-02)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "e" {
            cancelCycle()
            if let selected = viewModel.selectedItem, selected.isPinned {
                Task {
                    await viewModel.startEditing(item: selected)
                }
                return true
            }
        }

        // 5. Command-1 .. Command-9 / Control-1 .. Control-9 (Quick-picks: P5-05 / F-022, T-KEY-01)
        if (event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)),
           let num = PanelCoordinator.quickPickNumber(for: event) {
            cancelCycle()
            let isOption = event.modifierFlags.contains(.option)
            let isShift = event.modifierFlags.contains(.shift)
            let mode: PasteMode = isShift ? .plainText : .original
            let forcePaste: Bool? = isOption ? !pasteCoordinator.pasteAutomatically : nil
            viewModel.quickPick(number: num, mode: mode, forcePaste: forcePaste)
            return true
        }

        // 6. Pin Reordering: Option-Command-Up / Option-Command-Down (P5-03 / F-046, T-PIN-03)
        if event.keyCode == 126 && event.modifierFlags.contains(.option) && event.modifierFlags.contains(.command) {
            cancelCycle()
            Task {
                _ = await viewModel.moveSelectedPinUp()
            }
            return true
        }

        if event.keyCode == 125 && event.modifierFlags.contains(.option) && event.modifierFlags.contains(.command) {
            cancelCycle()
            Task {
                _ = await viewModel.moveSelectedPinDown()
            }
            return true
        }

        // 7. Up Arrow (Allows manual navigation during cycle mode or normal mode)
        if event.keyCode == 126 {
            viewModel.selectPrevious()
            if isCycleActive {
                onCycleChanged?(viewModel.selectedIndex, viewModel.selectedItem)
            }
            return true
        }

        // 8. Down Arrow (Allows manual navigation during cycle mode or normal mode)
        if event.keyCode == 125 {
            viewModel.selectNext()
            if isCycleActive {
                onCycleChanged?(viewModel.selectedIndex, viewModel.selectedItem)
            }
            return true
        }

        // 9. Return / Keypad Enter
        if event.keyCode == 36 || event.keyCode == 76 {
            cancelCycle()
            let isOption = event.modifierFlags.contains(.option)
            let plainShortcut = HotkeyConfiguration.shared.plainPasteShortcut
            let isPlainShortcut = (event.keyCode == plainShortcut.keyCode && event.modifierFlags.contains(plainShortcut.modifierFlags))
            let isShift = event.modifierFlags.contains(.shift) || isPlainShortcut
            let mode: PasteMode = isShift ? .plainText : .original
            let forcePaste: Bool? = isOption ? !pasteCoordinator.pasteAutomatically : nil
            viewModel.commitSelection(mode: mode, forcePaste: forcePaste)
            return true
        }

        // 10. Page Up (keyCode 116, T-KEY-03)
        if event.keyCode == 116 {
            cancelCycle()
            viewModel.selectPageUp()
            return true
        }

        // 11. Page Down (keyCode 121, T-KEY-03)
        if event.keyCode == 121 {
            cancelCycle()
            viewModel.selectPageDown()
            return true
        }

        // 12. Home (keyCode 115)
        if event.keyCode == 115 {
            cancelCycle()
            viewModel.selectFirst()
            return true
        }

        // 13. End (keyCode 119)
        if event.keyCode == 119 {
            cancelCycle()
            viewModel.selectLast()
            return true
        }

        // 14. Delete Selected Item (P7-05 / F-023, T-KEY-03)
        // Only Option + Backspace (or configured deleteShortcut) deletes the item.
        // Command + Backspace must NOT delete items (reserved for delete-to-beginning-of-line in search field).
        let deleteShortcut = HotkeyConfiguration.shared.deleteShortcut
        let isConfiguredDelete = (event.keyCode == deleteShortcut.keyCode &&
                                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == deleteShortcut.modifierFlags)
        let isOptionBackspace = (event.keyCode == 51 &&
                                 event.modifierFlags.contains(.option) &&
                                 !event.modifierFlags.contains(.command))
        let matchesDelete = isConfiguredDelete || isOptionBackspace
        if matchesDelete {
            cancelCycle()
            Task {
                _ = await viewModel.deleteSelectedItem()
            }
            return true
        }

        // 15. Toggle Pin/Unpin on Selected Item (P5-01 / P7-05 / F-020, F-023, F-024, T-PIN-01)
        let pinShortcut = HotkeyConfiguration.shared.pinShortcut
        let matchesPin = (event.keyCode == pinShortcut.keyCode && event.modifierFlags.contains(pinShortcut.modifierFlags)) ||
                         (event.modifierFlags.contains(.option) && event.charactersIgnoringModifiers?.lowercased() == "p")
        if matchesPin {
            cancelCycle()
            Task {
                _ = await viewModel.togglePinSelectedItem()
            }
            return true
        }

        // 16. Option + <pin_key> (Summon/Paste pinned item by assigned shortcut, P5-01 / P5-02 / F-024)
        if event.modifierFlags.contains(.option) {
            let keyChar = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let rawChar = event.characters?.lowercased() ?? ""

            // Exclude Option-P which is reserved for pin/unpin toggling
            if keyChar != "p" && (!keyChar.isEmpty || !rawChar.isEmpty) {
                if let matchedItem = viewModel.items.first(where: { item in
                    guard item.isPinned, let pk = item.pinKey?.lowercased() else { return false }
                    return pk == keyChar || pk == rawChar
                }) {
                    cancelCycle()
                    let isShift = event.modifierFlags.contains(.shift)
                    let mode: PasteMode = isShift ? .plainText : .original
                    let forcePaste: Bool? = !pasteCoordinator.pasteAutomatically
                    handleItemCommit(item: matchedItem, mode: mode, forcePaste: forcePaste)
                    return true
                }
            }
        }

        // 17. Toggle Slideout Preview (P6-01 / P6-02 / P7-05 / F-023, F-039, T-PREV-01)
        let previewShortcut = HotkeyConfiguration.shared.previewShortcut
        let isConfiguredPreview = (event.keyCode == previewShortcut.keyCode && event.modifierFlags.contains(previewShortcut.modifierFlags))
        let isControlOrOptionSpace = (event.keyCode == 49 && (event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option)))
        let isCommandY = (event.keyCode == 16 && event.modifierFlags.contains(.command)) // ⌘Y Quick Look
        let isSpaceWhenSearchEmpty = (event.keyCode == 49 &&
                                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty &&
                                      viewModel.searchText.isEmpty)

        if isConfiguredPreview || isControlOrOptionSpace || isCommandY || isSpaceWhenSearchEmpty {
            cancelCycle()
            togglePreview()
            return true
        }

        // Any other non-handled key (such as typing into search field or Backspace)
        // disarms cycle mode so that subsequent modifier release won't commit.
        if isCycleActive {
            cancelCycle()
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
        onItemCommitted?(item, mode, forcePaste)
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

        let width = AppearanceConfiguration.shared.panelWidth
        let height = AppearanceConfiguration.shared.panelHeight
        let initialRect = NSRect(x: 0, y: 0, width: width, height: height)
        let panel = FloatingPanel(contentRect: initialRect)
        panel.delegate = self

        let rootView = FloatingPanelView(viewModel: viewModel)
        panel.contentView = NSHostingView(rootView: rootView)

        panel.onResignKey = { [weak self] in
            self?.cancelCycle()
            self?.hide()
        }
        panel.onEscapePressed = { [weak self] in
            self?.cancelCycle()
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

        // 0. Reset cycle state and reset selection to first item
        cancelCycle()
        viewModel.selectFirst()

        // 1. Record the current frontmost application before showing the panel
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != ClipboardProvenance.mimraBundleIdentifier {
            self.targetApp = frontmost
        }

        // 2. Reload data and reset search
        Task {
            await viewModel.loadData()
        }

        // 3. Position the panel according to AppearanceConfiguration (F-032, T-UI-07)
        positionPanel(panel: p)

        // 4. Make key and order front
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hides the floating panel without losing state.
    public func hide() {
        cancelCycle()
        previewCoordinator.hide()
        panel?.orderOut(nil)
        if !viewModel.searchText.isEmpty {
            viewModel.searchText = ""
        }
        // VoiceOver & system focus restoration: reactivate target application (P7-09 / F-029, T-UI-06)
        if let target = targetApp, !target.isTerminated {
            target.activate()
        }
    }

    /// Toggles the slideout preview panel for the currently selected item.
    public func togglePreview() {
        let p = getOrCreatePanel()
        previewCoordinator.toggle(for: viewModel.selectedItem, parent: p)
    }

    /// NSWindowDelegate: Keep preview aligned and record last position when parent moves.
    public func windowDidMove(_ notification: Notification) {
        if let p = panel {
            AppearanceConfiguration.shared.saveLastPosition(origin: p.frame.origin)
        }
        previewCoordinator.updateLayout()
    }

    /// NSWindowDelegate: Keep preview aligned when parent resizes.
    public func windowDidResize(_ notification: Notification) {
        previewCoordinator.updateLayout()
    }

    /// Positions the floating panel on the target display according to active AppearanceConfiguration.
    public func positionPanel(panel: FloatingPanel) {
        let config = AppearanceConfiguration.shared
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen: NSScreen?
        if config.positionMode == .centerMain {
            targetScreen = NSScreen.main ?? NSScreen.screens.first
        } else {
            targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
        }

        guard let screen = targetScreen else { return }
        let vf = screen.visibleFrame
        let panelSize = panel.frame.size

        let lastPos = config.lastSavedPosition()
        let origin = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: config.positionMode,
            mouseLocation: mouseLocation,
            screenVisibleFrame: vf,
            statusItemFrame: statusItemFrame,
            lastPosition: lastPos
        )

        panel.setFrameOrigin(origin)
        previewCoordinator.updateLayout()
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
        previewCoordinator.updateLayout()
    }
}
