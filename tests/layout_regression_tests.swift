// ==============================================================================
// Mimra Tests — Layout Regression & Multi-Monitor Lab (P8-03)
// Linked Features: F-018, F-028, F-032, F-039, F-040
// Test IDs: T-UI-06, T-UI-07, T-PREV-01, T-PREV-02
// Verifies multi-monitor clamping, display disconnection recovery, Stage Manager margins,
// preview bounds calculation and side flipping, and zero stuck mouse interception.
// ==============================================================================

import AppKit
import Foundation

@main
struct LayoutRegressionTests {
    @MainActor
    static func main() async {
        print("=== Running Layout Regression & Multi-Monitor Tests (P8-03 / T-UI-06, T-UI-07, T-PREV-01, T-PREV-02) ===")

        let panelSize = CGSize(width: 380, height: 480)
        let previewSize = CGSize(width: 400, height: 500)

        // -----------------------------------------------------------------
        // Scenario 1: Multi-Monitor Geometry Clamping
        // -----------------------------------------------------------------
        // Primary Screen: 1920x1080 (visibleFrame: 0, 25, 1920, 1055)
        let primaryScreenVF = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        // Secondary Screen (arranged to the right): 2560x1440 (visibleFrame: 1920, 0, 2560, 1440)
        let secondaryScreenVF = CGRect(x: 1920, y: 0, width: 2560, height: 1440)

        // Center on Primary Screen
        let centerPrimary = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: .centerMain,
            mouseLocation: NSPoint(x: 500, y: 500),
            screenVisibleFrame: primaryScreenVF
        )
        assert(centerPrimary.x == round(0 + (1920 - 380) / 2.0), "Primary center X should be 770")
        assert(centerPrimary.y == round(25 + (1055 - 480) / 2.0), "Primary center Y should be 313")
        print("✓ Scenario 1.1: Primary monitor center verified: (\(centerPrimary.x), \(centerPrimary.y))")

        // Center on Secondary Screen
        let centerSecondary = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: .centerActive,
            mouseLocation: NSPoint(x: 2500, y: 800),
            screenVisibleFrame: secondaryScreenVF
        )
        assert(centerSecondary.x == round(1920 + (2560 - 380) / 2.0), "Secondary center X should be 3010")
        assert(centerSecondary.y == round(0 + (1440 - 480) / 2.0), "Secondary center Y should be 480")
        assert(centerSecondary.x >= secondaryScreenVF.minX && centerSecondary.x + panelSize.width <= secondaryScreenVF.maxX)
        print("✓ Scenario 1.2: Secondary monitor center verified: (\(centerSecondary.x), \(centerSecondary.y))")

        // -----------------------------------------------------------------
        // Scenario 2: Display Disconnection Recovery (T-UI-07 / F-032)
        // -----------------------------------------------------------------
        // User had panel positioned on external monitor at (3500, 900).
        // External monitor is disconnected! Only primary screen (0..1920) remains.
        let disconnectedPosition = NSPoint(x: 3500, y: 900)
        let salvagedOrigin = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: .rememberLast,
            mouseLocation: NSPoint(x: 500, y: 500),
            screenVisibleFrame: primaryScreenVF,
            lastPosition: disconnectedPosition
        )

        // Must be clamped safely inside primaryScreenVF, never stranded offscreen
        assert(salvagedOrigin.x >= primaryScreenVF.minX, "Salvaged X must be >= minX")
        assert(salvagedOrigin.x + panelSize.width <= primaryScreenVF.maxX, "Salvaged right edge must not exceed primary screen maxX")
        assert(salvagedOrigin.y >= primaryScreenVF.minY, "Salvaged Y must be >= minY")
        assert(salvagedOrigin.y + panelSize.height <= primaryScreenVF.maxY, "Salvaged top edge must not exceed primary screen maxY")
        assert(salvagedOrigin.x == primaryScreenVF.maxX - panelSize.width, "Must clamp to right edge of remaining display")
        print("✓ Scenario 2: Display disconnection recovery verified. Clamped origin: (\(salvagedOrigin.x), \(salvagedOrigin.y))")

        // -----------------------------------------------------------------
        // Scenario 3: Stage Manager Margin & Notch Clamping
        // -----------------------------------------------------------------
        // In macOS Stage Manager, the left margin is reserved for recent window sets (~80pt).
        // MacBook notch leaves top menubar inset.
        let stageManagerVF = CGRect(x: 80, y: 25, width: 1432, height: 955)

        // Test cursor placed in the Stage Manager reserved left strip (x = 30)
        let cursorInStageMargin = NSPoint(x: 30, y: 500)
        let stageOrigin = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: .atCursor,
            mouseLocation: cursorInStageMargin,
            screenVisibleFrame: stageManagerVF
        )
        assert(stageOrigin.x >= 80, "Panel must never intrude into Stage Manager strip (x >= 80)")
        assert(stageOrigin.y >= 25 && stageOrigin.y + panelSize.height <= stageManagerVF.maxY)
        print("✓ Scenario 3: Stage Manager margin respected: origin.x = \(stageOrigin.x) >= 80")

        // -----------------------------------------------------------------
        // Scenario 4: Preview Bounds & Automatic Side Flipping (T-PREV-01)
        // -----------------------------------------------------------------
        // Parent panel placed near right edge of screen: preview should flip to LEFT side
        let parentNearRight = CGRect(x: 1600, y: 300, width: 300, height: 400)
        let placementLeft = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: parentNearRight,
            previewSize: previewSize,
            screenVisibleFrame: primaryScreenVF,
            gap: 8.0,
            preferredSide: .right
        )
        assert(placementLeft.side == .left, "Preview must flip to left when right side overflows")
        assert(placementLeft.frame.maxX <= parentNearRight.minX, "Left preview must be to the left of parent panel")
        assert(placementLeft.frame.minX >= primaryScreenVF.minX, "Preview must not overflow left screen edge")
        print("✓ Scenario 4.1: Preview right-to-left flip verified. Placement: \(placementLeft.side), frame: \(placementLeft.frame)")

        // Parent panel placed near left edge of screen: preview should attach to RIGHT side
        let parentNearLeft = CGRect(x: 10, y: 300, width: 300, height: 400)
        let placementRight = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: parentNearLeft,
            previewSize: previewSize,
            screenVisibleFrame: primaryScreenVF,
            gap: 8.0,
            preferredSide: .left
        )
        assert(placementRight.side == .right, "Preview must flip to right when left side overflows")
        assert(placementRight.frame.minX >= parentNearLeft.maxX, "Right preview must be to the right of parent panel")
        assert(placementRight.frame.maxX <= primaryScreenVF.maxX, "Preview must not overflow right screen edge")
        print("✓ Scenario 4.2: Preview left-to-right flip verified. Placement: \(placementRight.side), frame: \(placementRight.frame)")

        // -----------------------------------------------------------------
        // Scenario 5: Constrained Display (Neither side fits completely)
        // -----------------------------------------------------------------
        // Screen width is only 800pt. Parent width is 380. Preview is 500.
        let narrowScreenVF = CGRect(x: 0, y: 0, width: 800, height: 600)
        let parentMiddle = CGRect(x: 200, y: 100, width: 380, height: 400)
        let constrainedPlacement = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: parentMiddle,
            previewSize: CGSize(width: 500, height: 400),
            screenVisibleFrame: narrowScreenVF,
            gap: 4.0,
            preferredSide: .right
        )
        assert(constrainedPlacement.frame.minX >= narrowScreenVF.minX, "Must not overflow screen minX")
        assert(constrainedPlacement.frame.maxX <= narrowScreenVF.maxX, "Must not overflow screen maxX")
        assert(constrainedPlacement.frame.minY >= narrowScreenVF.minY, "Must not overflow screen minY")
        assert(constrainedPlacement.frame.maxY <= narrowScreenVF.maxY, "Must not overflow screen maxY")
        print("✓ Scenario 5: Constrained display safe clamping verified. Frame: \(constrainedPlacement.frame)")

        // -----------------------------------------------------------------
        // Scenario 6: Non-Intercepting Mouse Events (T-PREV-02)
        // -----------------------------------------------------------------
        let previewPanel = PreviewPanel(contentRect: NSRect(x: 100, y: 100, width: 300, height: 300))
        assert(!previewPanel.canBecomeKey, "Preview panel must never become key window")
        assert(!previewPanel.canBecomeMain, "Preview panel must never become main window")

        // When mouse interception is disabled (closed/hidden state):
        previewPanel.setMouseInterceptionEnabled(false)
        assert(previewPanel.ignoresMouseEvents, "Hidden preview must ignore mouse events (ignoresMouseEvents = true)")

        // When mouse interception is enabled (visible state):
        previewPanel.setMouseInterceptionEnabled(true)
        assert(!previewPanel.ignoresMouseEvents, "Visible preview must receive mouse events (ignoresMouseEvents = false)")
        print("✓ Scenario 6: Non-intercepting mouse events on preview close verified")

        // -----------------------------------------------------------------
        // Scenario 7: Integer Pixel Alignment (No Fractional Subpixel Fuzz)
        // -----------------------------------------------------------------
        let fractionalScreen = CGRect(x: 0.333, y: 24.667, width: 1511.85, height: 981.4)
        let roundedOrigin = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: .centerMain,
            mouseLocation: NSPoint(x: 500.75, y: 400.25),
            screenVisibleFrame: fractionalScreen
        )
        assert(roundedOrigin.x == round(roundedOrigin.x), "Origin X must be integral")
        assert(roundedOrigin.y == round(roundedOrigin.y), "Origin Y must be integral")
        print("✓ Scenario 7: Pixel alignment and subpixel rounding verified: (\(roundedOrigin.x), \(roundedOrigin.y))")

        print("----------------------------------------------------------------------")
        print("ALL LAYOUT REGRESSION TESTS (P8-03) PASSED!")
        print("----------------------------------------------------------------------")
    }
}
