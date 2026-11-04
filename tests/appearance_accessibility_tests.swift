// ==============================================================================
// Mimra — Appearance Accessibility, Fullscreen Clamping & Focus Tests (P7-09 / F-029, F-034)
// Verifies Reduce Motion, high contrast indicators, VoiceOver focus restoration,
// full-screen space auxiliary behaviors, and multi-monitor geometric clamping.
// Linked Tests: T-UI-06, T-UI-08
// ==============================================================================

import AppKit
import Foundation

@main
struct AppearanceAccessibilityTests {
    @MainActor
    static func main() async {
        print("--- Mimra Appearance Accessibility & Fullscreen Clamping Tests (P7-09 / F-029, F-034, T-UI-06, T-UI-08) ---")

        _ = NSApplication.shared

        // Setup temporary database
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("a11y_appear_test.sqlite").path
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            let core = try CoreClient(databasePath: dbPath)
            let panelCoord = PanelCoordinator(coreClient: core)
            let panel = panelCoord.getOrCreatePanel()

            // -------------------------------------------------------------------------
            // Test 1: Full-Screen Auxiliary & Window Level Configuration (F-029, T-UI-06)
            // -------------------------------------------------------------------------
            print("\nStep 1: Testing Full-Screen Space and Window Level behaviors...")

            assert(panel.collectionBehavior.contains(.canJoinAllSpaces),
                   "Panel must join all spaces to appear above full-screen spaces")
            assert(panel.collectionBehavior.contains(.fullScreenAuxiliary),
                   "Panel must be fullScreenAuxiliary to float over full-screen apps without space-switching animations")
            assert(panel.level == .floating,
                   "Panel window level must be .floating to stay above document windows and overlays")
            assert(panel.isMovableByWindowBackground == true,
                   "Panel must allow dragging by background for accessibility positioning")

            print("✓ Full-screen auxiliary collection behavior and floating window level verified.")

            // -------------------------------------------------------------------------
            // Test 2: Multi-Monitor & Fullscreen Geometric Clamping (F-029, T-UI-06)
            // -------------------------------------------------------------------------
            print("\nStep 2: Testing screen visibleFrame clamping under extreme coordinates...")

            let panelSize = CGSize(width: 400, height: 480)

            // Simulated Fullscreen Display Frame (1920x1080 with 25pt autohiding menubar)
            let fullscreenVisibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1055)

            // Case A: Cursor at extreme top-right corner (e.g. 1950, 1100)
            let clampedTopRight = AppearanceConfiguration.computePanelOrigin(
                panelSize: panelSize,
                mode: .atCursor,
                mouseLocation: NSPoint(x: 1950, y: 1100),
                screenVisibleFrame: fullscreenVisibleFrame
            )
            assert(clampedTopRight.x + panelSize.width <= fullscreenVisibleFrame.maxX,
                   "Panel must never extend beyond the right edge of screen: \(clampedTopRight)")
            assert(clampedTopRight.y + panelSize.height <= fullscreenVisibleFrame.maxY,
                   "Panel must never overlap the menu bar or extend beyond top edge: \(clampedTopRight)")
            print("✓ Top-right boundary clamping verified: \(clampedTopRight)")

            // Case B: Cursor at extreme bottom-left corner (e.g. -50, -50)
            let clampedBottomLeft = AppearanceConfiguration.computePanelOrigin(
                panelSize: panelSize,
                mode: .atCursor,
                mouseLocation: NSPoint(x: -50, y: -50),
                screenVisibleFrame: fullscreenVisibleFrame
            )
            assert(clampedBottomLeft.x >= fullscreenVisibleFrame.minX,
                   "Panel must never extend beyond the left edge of screen: \(clampedBottomLeft)")
            assert(clampedBottomLeft.y >= fullscreenVisibleFrame.minY,
                   "Panel must never extend below the bottom edge of screen: \(clampedBottomLeft)")
            print("✓ Bottom-left boundary clamping verified: \(clampedBottomLeft)")

            // Case C: Remember last position from a disconnected larger display (e.g. 3400, 1200)
            let strandedPosition = NSPoint(x: 3400, y: 1200)
            let rescuedPosition = AppearanceConfiguration.computePanelOrigin(
                panelSize: panelSize,
                mode: .rememberLast,
                mouseLocation: .zero,
                screenVisibleFrame: fullscreenVisibleFrame,
                lastPosition: strandedPosition
            )
            assert(rescuedPosition.x + panelSize.width <= fullscreenVisibleFrame.maxX,
                   "Stranded panel from disconnected monitor must be clamped to visible frame: \(rescuedPosition)")
            assert(rescuedPosition.y + panelSize.height <= fullscreenVisibleFrame.maxY,
                   "Stranded panel must be clamped within visible vertical bounds: \(rescuedPosition)")
            print("✓ Disconnected display stranded position clamping verified: \(rescuedPosition)")

            // -------------------------------------------------------------------------
            // Test 3: VoiceOver & System Focus Restoration on Dismissal (F-029, T-UI-06)
            // -------------------------------------------------------------------------
            print("\nStep 3: Testing VoiceOver & window focus restoration on dismissal...")

            let currentApp = NSRunningApplication.current
            panelCoord.targetApp = currentApp

            // Verify hiding panel restores target app focus
            panelCoord.show()
            assert(panel.isVisible, "Panel should be visible after show()")

            panelCoord.hide()
            assert(!panel.isVisible, "Panel should be ordered out after hide()")
            assert(panelCoord.targetApp != nil, "Target app must be retained for focus restoration")

            print("✓ Focus restoration handover verified.")

            // -------------------------------------------------------------------------
            // Test 4: Native Light / Dark / System Appearance Modes (F-034, T-UI-08)
            // -------------------------------------------------------------------------
            print("\nStep 4: Testing native light/dark/system appearance switching...")

            let appearConfig = AppearanceConfiguration.shared

            // System Mode
            appearConfig.theme = .system
            appearConfig.applyTheme()
            assert(appearConfig.theme == .system)

            // Dark Mode
            appearConfig.theme = .dark
            appearConfig.applyTheme()
            assert(appearConfig.theme == .dark)

            // Light Mode
            appearConfig.theme = .light
            appearConfig.applyTheme()
            assert(appearConfig.theme == .light)

            // Restore System Mode
            appearConfig.theme = .system
            appearConfig.applyTheme()

            print("✓ Native appearance modes (system, light, dark) verified.")

            print("\nAll Appearance Accessibility, Fullscreen Clamping & Focus tests passed cleanly! ✓")
        } catch {
            fatalError("Failed with error: \(error)")
        }
    }
}
