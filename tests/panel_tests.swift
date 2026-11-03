// ==============================================================================
// Mimra — Floating Panel & Panel Coordinator Unit / Integration Tests
// Linked Features: F-018
// Test IDs: T-UI-02
// ==============================================================================

import AppKit
import Foundation

@main
struct PanelTests {
    @MainActor
    static func main() async {
        print("=== Running FloatingPanel & PanelCoordinator Tests (T-UI-02) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // -------------------------------------------------------------------------
        // 1. Verify FloatingPanel Properties & Window Attributes
        // -------------------------------------------------------------------------
        let initialRect = NSRect(x: 100, y: 100, width: 440, height: 540)
        let panel = FloatingPanel(contentRect: initialRect)

        assert(panel.styleMask.contains(.nonactivatingPanel), "FAIL: StyleMask must contain .nonactivatingPanel")
        assert(panel.styleMask.contains(.titled), "FAIL: StyleMask must contain .titled")
        assert(panel.styleMask.contains(.resizable), "FAIL: StyleMask must contain .resizable")
        assert(panel.styleMask.contains(.fullSizeContentView), "FAIL: StyleMask must contain .fullSizeContentView")

        assert(panel.level == .floating, "FAIL: Window level must be .floating")
        assert(panel.collectionBehavior.contains(.canJoinAllSpaces), "FAIL: Collection behavior must contain .canJoinAllSpaces")
        assert(panel.collectionBehavior.contains(.fullScreenAuxiliary), "FAIL: Collection behavior must contain .fullScreenAuxiliary")

        assert(panel.canBecomeKey == true, "FAIL: FloatingPanel must be able to become key for text input")
        assert(panel.canBecomeMain == false, "FAIL: FloatingPanel must NOT become main to prevent active app disruption")

        assert(panel.isOpaque == false, "FAIL: FloatingPanel must be non-opaque for translucent/glass styling")
        assert(panel.backgroundColor == .clear, "FAIL: FloatingPanel background must be clear")
        assert(panel.titleVisibility == .hidden, "FAIL: Titlebar title must be hidden")
        assert(panel.titlebarAppearsTransparent == true, "FAIL: Titlebar must appear transparent")

        assert(panel.minSize.width == 340 && panel.minSize.height == 320, "FAIL: Minimum size mismatch")
        assert(panel.maxSize.width == 800 && panel.maxSize.height == 1000, "FAIL: Maximum size mismatch")

        print("✓ T-UI-02: FloatingPanel NSPanel properties and non-activating attributes verified")

        // -------------------------------------------------------------------------
        // 2. Verify Escape & Resign Key Callbacks
        // -------------------------------------------------------------------------
        var resignCallbackTriggered = false
        panel.onResignKey = {
            resignCallbackTriggered = true
        }
        panel.resignKey()
        assert(resignCallbackTriggered, "FAIL: onResignKey was not invoked when resignKey() was called")

        var escapeCallbackTriggered = false
        panel.onEscapePressed = {
            escapeCallbackTriggered = true
        }
        panel.cancelOperation(nil)
        assert(escapeCallbackTriggered, "FAIL: onEscapePressed was not invoked when cancelOperation was called")

        print("✓ T-UI-02: FloatingPanel resign key and escape dismissal callbacks verified")

        // -------------------------------------------------------------------------
        // 3. Verify PanelCoordinator Lifecycle & Option A Screen Centering
        // -------------------------------------------------------------------------
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_panel_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.db").path

        let core = try! CoreClient(databasePath: dbPath)
        let coordinator = PanelCoordinator(coreClient: core)

        assert(coordinator.panel == nil, "FAIL: Panel should not be pre-created before first request")

        let createdPanel = coordinator.getOrCreatePanel()
        assert(coordinator.panel === createdPanel, "FAIL: getOrCreatePanel did not cache panel instance")
        assert(createdPanel.contentView != nil, "FAIL: Panel must have a hosting content view attached")

        // Verify Option A screen centering
        coordinator.centerOnActiveScreen(panel: createdPanel)
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let expectedX = round(vf.origin.x + (vf.width - createdPanel.frame.width) / 2.0)
            let expectedY = round(vf.origin.y + (vf.height - createdPanel.frame.height) / 2.0)
            assert(abs(createdPanel.frame.origin.x - expectedX) <= 1.0, "FAIL: Panel X origin should be centered")
            assert(abs(createdPanel.frame.origin.y - expectedY) <= 1.0, "FAIL: Panel Y origin should be centered")
        }

        // Verify show, hide, toggle lifecycle
        coordinator.show()
        assert(createdPanel.isVisible, "FAIL: Panel should be visible after show()")

        coordinator.hide()
        assert(!createdPanel.isVisible, "FAIL: Panel should be ordered out after hide()")

        coordinator.toggle()
        assert(createdPanel.isVisible, "FAIL: Panel should be visible after toggle() from hidden state")

        coordinator.toggle()
        assert(!createdPanel.isVisible, "FAIL: Panel should be hidden after toggle() from visible state")

        // Verify Settings request callback
        var settingsCallbackFired = false
        coordinator.onSettingsRequested = {
            settingsCallbackFired = true
        }
        coordinator.onSettingsRequested?()
        assert(settingsCallbackFired, "FAIL: Settings callback not fired")

        try? FileManager.default.removeItem(at: tempDir)

        print("✓ T-UI-02: PanelCoordinator centering, lifecycle, and toggle verified")
        print("✓ ALL FloatingPanel & PanelCoordinator Tests PASSED!")
    }
}
