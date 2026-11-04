// ==============================================================================
// Mimra — Preview Panel
// Non-activating, attached slideout NSPanel for displaying full item previews.
// Linked Feature: F-039 (T-PREV-01)
// ==============================================================================

import AppKit

/// Native NSPanel subclass for the slideout item preview.
/// Designed to attach seamlessly alongside `FloatingPanel` without stealing keyboard
/// focus or blocking underlying mouse clicks when closed.
@MainActor
open class PreviewPanel: NSPanel {

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
        if #available(macOS 11.0, *) {
            self.titlebarSeparatorStyle = .none
        }
        self.isMovableByWindowBackground = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]
        self.minSize = NSSize(width: 260, height: 260)
        self.maxSize = NSSize(width: 1200, height: 1600)
        self.isReleasedWhenClosed = false
        self.ignoresMouseEvents = false

        hideStandardWindowButtons()
    }

    /// Hides and disables all standard window buttons.
    public func hideStandardWindowButtons() {
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = self.standardWindowButton(buttonType) {
                button.isHidden = true
                button.isEnabled = false
            }
        }
    }

    /// Ensures standard window buttons always report hidden if requested.
    open override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? {
        let btn = super.standardWindowButton(b)
        btn?.isHidden = true
        return btn
    }

    /// Re-applies button hiding whenever the window performs layout.
    open override func layoutIfNeeded() {
        super.layoutIfNeeded()
        hideStandardWindowButtons()
    }

    /// The preview panel does not steal key window status by default so that
    /// the main panel's search field and keyboard navigation remain uninterrupted.
    open override var canBecomeKey: Bool {
        return false
    }

    /// The preview panel must never become main window.
    open override var canBecomeMain: Bool {
        return false
    }

    /// Disables mouse event interception completely when closed or hidden (DoD requirement).
    public func setMouseInterceptionEnabled(_ enabled: Bool) {
        self.ignoresMouseEvents = !enabled
    }
}
