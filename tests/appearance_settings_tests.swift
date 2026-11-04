// ==============================================================================
// Mimra — Appearance Settings Integration Tests (P7-02 / F-028, F-032, F-034, F-035, F-058)
// Verified test runner for visual customization, theme switching, positioning
// modes, display disconnect resilience, menu bar icons, and sizing constraints.
// ==============================================================================

import AppKit
import Foundation
import CoreGraphics

@MainActor
final class AppearanceSettingsTestsRunner {
    static func runAll() async {
        print("--- Running Appearance Settings Integration Tests (P7-02) ---")

        await testThemeSwitchingAndApplication()
        await testPanelPositioningGeometryAndScreenClamping()
        await testDisplayDisconnectRecovery()
        await testMenuBarIconStylesAndSnippetToggle()
        await testElementVisibilityAndDefaultFallbacks()
        await testDimensionsAndSizingConstraints()

        print("✓ All Appearance Settings integration tests PASSED!")
    }

    // 1. Theme switching and NSApp.appearance application (F-034, T-UI-08)
    static func testThemeSwitchingAndApplication() async {
        print("  Testing AppearanceTheme switching and NSApp.appearance...")

        final class NotificationFlag: @unchecked Sendable {
            var received: Bool = false
        }

        let suiteName = "MimraAppearanceThemeTest_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let config = AppearanceConfiguration(userDefaults: testDefaults)

        // Default should be system
        assert(config.theme == .system, "FAIL: Default theme must be .system")

        let flag = NotificationFlag()
        let observer = NotificationCenter.default.addObserver(
            forName: AppearanceConfiguration.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            flag.received = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Switch to Dark
        flag.received = false
        config.theme = .dark
        assert(testDefaults.string(forKey: AppearanceConfiguration.themeKey) == "dark", "FAIL: Dark theme must persist to UserDefaults")
        assert(flag.received, "FAIL: Notification must be broadcast on theme change")
        assert(NSApp.appearance?.name == .darkAqua, "FAIL: NSApp.appearance must be darkAqua when theme is dark")

        // Switch to Light
        config.theme = .light
        assert(testDefaults.string(forKey: AppearanceConfiguration.themeKey) == "light", "FAIL: Light theme must persist to UserDefaults")
        assert(NSApp.appearance?.name == .aqua, "FAIL: NSApp.appearance must be aqua when theme is light")

        // Switch back to System
        config.theme = .system
        assert(NSApp.appearance == nil, "FAIL: NSApp.appearance must be nil when theme is system")

        testDefaults.removePersistentDomain(forName: suiteName)
        print("  ✓ AppearanceTheme switching verified")
    }

    // 2. Pure geometric placement calculation for all positioning modes (F-032, T-UI-07)
    static func testPanelPositioningGeometryAndScreenClamping() async {
        print("  Testing panel positioning geometry and screen clamping...")

        let panelSize = CGSize(width: 440, height: 540)
        let visibleFrame = CGRect(x: 0, y: 30, width: 1440, height: 870)

        // A. Center of Active Screen
        let centerOrigin = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: .centerActive,
            mouseLocation: NSPoint(x: 500, y: 500),
            screenVisibleFrame: visibleFrame
        )
        let expectedCenterX = round(0.0 + (1440.0 - 440.0) / 2.0)
        let expectedCenterY = round(30.0 + (870.0 - 540.0) / 2.0)
        assert(centerOrigin.x == expectedCenterX, "FAIL: Expected center X \(expectedCenterX), got: \(centerOrigin.x)")
        assert(centerOrigin.y == expectedCenterY, "FAIL: Expected center Y \(expectedCenterY), got: \(centerOrigin.y)")

        // B. At Mouse Cursor (within screen)
        let cursorLocation = NSPoint(x: 300, y: 700)
        let cursorOrigin = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: .atCursor,
            mouseLocation: cursorLocation,
            screenVisibleFrame: visibleFrame
        )
        assert(cursorOrigin.x >= visibleFrame.minX && cursorOrigin.x + panelSize.width <= visibleFrame.maxX,
               "FAIL: At-cursor panel must be within screen horizontal bounds")
        assert(cursorOrigin.y >= visibleFrame.minY && cursorOrigin.y + panelSize.height <= visibleFrame.maxY,
               "FAIL: At-cursor panel must be within screen vertical bounds")

        // C. At Mouse Cursor (Edge overflow clamping)
        let edgeCursor = NSPoint(x: 1430, y: 40) // Near bottom right corner
        let clampedOrigin = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: .atCursor,
            mouseLocation: edgeCursor,
            screenVisibleFrame: visibleFrame
        )
        assert(clampedOrigin.x + panelSize.width <= visibleFrame.maxX, "FAIL: Panel must clamp within screen maxX")
        assert(clampedOrigin.y >= visibleFrame.minY, "FAIL: Panel must clamp within screen minY")

        // D. Under Status Item
        let statusItemRect = CGRect(x: 1200, y: 876, width: 30, height: 24)
        let statusOrigin = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: .underStatusItem,
            mouseLocation: NSPoint.zero,
            screenVisibleFrame: visibleFrame,
            statusItemFrame: statusItemRect
        )
        assert(statusOrigin.x + panelSize.width <= visibleFrame.maxX, "FAIL: Status item panel must clamp within screen maxX")
        assert(statusOrigin.y + panelSize.height <= statusItemRect.minY, "FAIL: Panel must be below status item")

        print("  ✓ Panel positioning geometry and clamping verified")
    }

    // 3. Display Disconnect Recovery (T-UI-07, F-032)
    static func testDisplayDisconnectRecovery() async {
        print("  Testing display disconnect recovery and last position clamping...")

        let panelSize = CGSize(width: 440, height: 540)
        // Primary built-in display visible frame
        let internalScreenVisible = CGRect(x: 0, y: 30, width: 1440, height: 870)

        // Last saved position was on an external display at x: 2200, y: 400
        let externalPosition = NSPoint(x: 2200, y: 400)

        // When external display is disconnected, origin must safely clamp to internal display
        let recoveredOrigin = AppearanceConfiguration.computePanelOrigin(
            panelSize: panelSize,
            mode: .rememberLast,
            mouseLocation: NSPoint.zero,
            screenVisibleFrame: internalScreenVisible,
            lastPosition: externalPosition
        )

        assert(recoveredOrigin.x + panelSize.width <= internalScreenVisible.maxX,
               "FAIL: Recovered origin must be clamped inside visible frame maxX: \(recoveredOrigin.x)")
        assert(recoveredOrigin.x >= internalScreenVisible.minX,
               "FAIL: Recovered origin must be >= visible frame minX")
        assert(recoveredOrigin.y >= internalScreenVisible.minY,
               "FAIL: Recovered origin must be >= visible frame minY")
        assert(recoveredOrigin.y + panelSize.height <= internalScreenVisible.maxY,
               "FAIL: Recovered origin must be <= visible frame maxY")

        print("  ✓ Display disconnect recovery verified")
    }

    // 4. Menu Bar Icon Styles & Snippet Toggle (F-035, T-UI-09)
    static func testMenuBarIconStylesAndSnippetToggle() async {
        print("  Testing MenuBarIconStyle and showRecentCopyInMenuBar...")

        let suiteName = "MimraMenuBarIconTest_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let config = AppearanceConfiguration(userDefaults: testDefaults)

        assert(config.iconStyle == .defaultIcon, "FAIL: Default icon style must be .defaultIcon")
        assert(config.iconStyle.systemSymbolName == "doc.on.clipboard", "FAIL: Default icon symbol must be doc.on.clipboard")
        assert(!config.showRecentCopyInMenuBar, "FAIL: showRecentCopyInMenuBar should be false by default")

        // Switch to minimal paperclip
        config.iconStyle = .minimal
        assert(testDefaults.string(forKey: AppearanceConfiguration.iconStyleKey) == "minimal", "FAIL: Icon style must persist to UserDefaults")
        assert(config.iconStyle.systemSymbolName == "paperclip", "FAIL: Minimal icon symbol must be paperclip")

        // Switch to scissors
        config.iconStyle = .scissors
        assert(config.iconStyle.systemSymbolName == "scissors", "FAIL: Scissors icon symbol must be scissors")

        // Switch to hidden
        config.iconStyle = .hidden
        assert(config.iconStyle.systemSymbolName == nil, "FAIL: Hidden icon symbol must be nil")

        // Enable recent copy snippet
        config.showRecentCopyInMenuBar = true
        assert(testDefaults.bool(forKey: AppearanceConfiguration.showRecentCopyInMenuBarKey) == true, "FAIL: showRecentCopyInMenuBar must persist to UserDefaults")

        testDefaults.removePersistentDomain(forName: suiteName)
        print("  ✓ MenuBarIconStyle and snippet toggle verified")
    }

    // 5. Visibility Elements & Default Fallbacks (F-028, T-UI-05)
    static func testElementVisibilityAndDefaultFallbacks() async {
        print("  Testing element visibility toggles (search, title, footer)...")

        let suiteName = "MimraVisibilityTest_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let config = AppearanceConfiguration(userDefaults: testDefaults)

        // Defaults: Search = true, Title = false, Footer = true
        assert(config.showSearchField == true, "FAIL: showSearchField must default to true")
        assert(config.showTitle == false, "FAIL: showTitle must default to false")
        assert(config.showFooter == true, "FAIL: showFooter must default to true")

        // Toggle search off
        config.showSearchField = false
        assert(testDefaults.bool(forKey: AppearanceConfiguration.showSearchFieldKey) == false, "FAIL: showSearchField false must persist")

        // Toggle title on
        config.showTitle = true
        assert(testDefaults.bool(forKey: AppearanceConfiguration.showTitleKey) == true, "FAIL: showTitle true must persist")

        // Toggle footer off
        config.showFooter = false
        assert(testDefaults.bool(forKey: AppearanceConfiguration.showFooterKey) == false, "FAIL: showFooter false must persist")

        testDefaults.removePersistentDomain(forName: suiteName)
        print("  ✓ Element visibility toggles verified")
    }

    // 6. Dimensions and Sizing Constraints (F-058, T-SET-03)
    static func testDimensionsAndSizingConstraints() async {
        print("  Testing panel and preview dimensions...")

        let suiteName = "MimraDimensionsTest_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let config = AppearanceConfiguration(userDefaults: testDefaults)

        // Defaults
        assert(config.panelWidth == 440, "FAIL: Default panel width must be 440")
        assert(config.panelHeight == 540, "FAIL: Default panel height must be 540")
        assert(config.previewWidth == 360, "FAIL: Default preview width must be 360")

        // Update sizes
        config.panelWidth = 520
        config.panelHeight = 650
        config.previewWidth = 420

        assert(testDefaults.double(forKey: AppearanceConfiguration.panelWidthKey) == 520, "FAIL: panelWidth must persist")
        assert(testDefaults.double(forKey: AppearanceConfiguration.panelHeightKey) == 650, "FAIL: panelHeight must persist")
        assert(testDefaults.double(forKey: AppearanceConfiguration.previewWidthKey) == 420, "FAIL: previewWidth must persist")

        // Test lower bounds clamping fallback
        testDefaults.set(100.0, forKey: AppearanceConfiguration.panelWidthKey) // Invalid tiny width
        assert(config.panelWidth == 440, "FAIL: panelWidth below 320 must fallback to default 440")

        testDefaults.removePersistentDomain(forName: suiteName)
        print("  ✓ Dimensions and sizing constraints verified")
    }
}

// Entrypoint
@main
struct AppearanceSettingsTestsMain {
    static func main() async {
        await AppearanceSettingsTestsRunner.runAll()
    }
}
