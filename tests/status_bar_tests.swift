// ==============================================================================
// Mimra Tests — Status Bar Coordinator Verification
// Linked Features: F-017, F-025, F-026, F-027
// Test IDs: T-UI-01, T-HIST-01, T-PRIV-06
// ==============================================================================

import AppKit
import Foundation

@main
struct StatusBarTests {
    @MainActor
    static func main() async {
        print("=== Running StatusBarCoordinator Tests (T-UI-01, T-HIST-01, T-PRIV-06) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_status_bar_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.db").path

        let core = try! CoreClient(databasePath: dbPath)
        let monitor = ClipboardMonitor(coreClient: core)
        let panelCoordinator = PanelCoordinator(coreClient: core)

        let coordinator = StatusBarCoordinator(
            coreClient: core,
            monitor: monitor,
            panelCoordinator: panelCoordinator
        )
        coordinator.setup()

        // 1. Verify Status Item and Context Menu Setup
        guard let button = coordinator.statusItemButton else {
            fatalError("FAIL: Status bar button was not created")
        }
        assert(button.image != nil, "FAIL: Status bar button must have an icon")

        guard let menu = coordinator.menu else {
            fatalError("FAIL: Context menu was not created")
        }
        assert(menu.items.count >= 9, "FAIL: Context menu must contain all required action items")

        let menuTitles = menu.items.map { $0.title }
        assert(menuTitles.contains("Show Clipboard History..."), "FAIL: Missing Show Clipboard History")
        assert(menuTitles.contains("Pause Capture"), "FAIL: Missing Pause Capture")
        assert(menuTitles.contains("Ignore Next Copy"), "FAIL: Missing Ignore Next Copy")
        assert(menuTitles.contains("Clear Unpinned History"), "FAIL: Missing Clear Unpinned History")
        assert(menuTitles.contains("Clear All History..."), "FAIL: Missing Clear All History")
        assert(menuTitles.contains("Settings..."), "FAIL: Missing Settings...")
        assert(menuTitles.contains("Check for Updates..."), "FAIL: Missing Check for Updates...")
        assert(menuTitles.contains("Quit Mimra"), "FAIL: Missing Quit Mimra")
        print("✓ T-UI-01: Status item and context menu items verified")

        // 2. Test Standard Left-Click: Toggles Floating Panel (F-017, F-018)
        let panel = panelCoordinator.getOrCreatePanel()
        assert(!panel.isVisible, "FAIL: Panel should initially be hidden")

        coordinator.handleStatusItemClick(isRightClick: false, modifierFlags: [])
        assert(panel.isVisible, "FAIL: Left-click should show the floating history panel")

        coordinator.handleStatusItemClick(isRightClick: false, modifierFlags: [])
        assert(!panel.isVisible, "FAIL: Second left-click should hide the floating history panel")
        print("✓ T-UI-01: Left-click toggles floating panel visibility")

        // 3. Test Option-Click: Toggles Capture Pause / Resume Directly (F-026, T-PRIV-06)
        assert(!coordinator.isPaused, "FAIL: Capture should not be paused initially")

        coordinator.handleStatusItemClick(isRightClick: false, modifierFlags: [.option])
        assert(coordinator.isPaused, "FAIL: Option-click should pause capture")
        assert(coordinator.statusItemButton?.image?.accessibilityDescription?.contains("Paused") == true,
               "FAIL: Button image accessibility description must reflect paused state")

        // Re-toggle back
        coordinator.handleStatusItemClick(isRightClick: false, modifierFlags: [.option])
        assert(!coordinator.isPaused, "FAIL: Second Option-click should resume capture")
        print("✓ T-PRIV-06: Option-click toggles capture pause/resume state and updates visual icon")

        // 4. Test Option-Shift-Click & Footer Gear Button: Opens Settings Directly in Front (F-027)
        panelCoordinator.show()
        panelCoordinator.targetApp = NSRunningApplication.current
        var targetActivatedDuringSettings = false
        panelCoordinator.onTargetAppActivated = { _ in
            targetActivatedDuringSettings = true
        }

        // Trigger Settings from the floating panel bottom-right footer button callback
        panelCoordinator.viewModel.onOpenSettings?()
        assert(!targetActivatedDuringSettings,
               "FAIL: Clicking Settings icon in floating panel footer must NOT reactivate previous targetApp")
        assert(!panel.isVisible, "FAIL: Floating panel must be ordered out when Settings window opens")

        guard let win = coordinator.settingsWindow else {
            fatalError("FAIL: Settings window was not created")
        }
        assert(win.isVisible, "FAIL: Settings window must be visible")
        assert(win.isKeyWindow, "FAIL: Settings window must be key window after opening from panel footer")
        let contentRect = win.contentRect(forFrameRect: win.frame)
        assert(contentRect.width == 720, "FAIL: Settings window content width must be 720, got \(contentRect.width)")
        assert(contentRect.height == 530, "FAIL: Settings window content height must be 530, got \(contentRect.height)")
        assert(win.level == .normal, "FAIL: Settings window level must be .normal, got \(win.level)")
        assert(SettingsCategory.allCases.count == 7, "FAIL: SettingsCategory must have 7 categories")

        // Also verify Option-Shift-Click while panel is visible hides panel without activating targetApp
        panelCoordinator.show()
        panelCoordinator.targetApp = NSRunningApplication.current
        coordinator.handleStatusItemClick(isRightClick: false, modifierFlags: [.option, .shift])
        assert(!targetActivatedDuringSettings,
               "FAIL: Option-Shift-click to open Settings while panel is open must NOT reactivate targetApp")
        assert(!panel.isVisible, "FAIL: Floating panel must be hidden when Option-Shift-clicking status item")
        assert(win.isVisible && win.isKeyWindow, "FAIL: Existing Settings window must remain visible and key")
        panelCoordinator.onTargetAppActivated = nil
        print("✓ T-UI-01 / F-027: Footer settings icon and Option-Shift-click open Settings window in front at 720x530 (.normal level) without targetApp focus theft")

        // 5. Test Ignore Next Copy Action (F-026)
        assert(!monitor.privacyFilter.ignoreNextCopy, "FAIL: ignoreNextCopy should be false initially")
        coordinator.triggerIgnoreNextCopy()
        assert(monitor.privacyFilter.ignoreNextCopy, "FAIL: triggerIgnoreNextCopy did not activate ignoreNextCopy")
        print("✓ T-PRIV-06: Ignore Next Copy menu action verified")

        // 6. Test Clear Unpinned Action (F-025, T-HIST-01)
        coordinator.clearUnpinned()
        print("✓ T-HIST-01: Clear unpinned history action triggered without error")

        try? FileManager.default.removeItem(at: tempDir)

        print("✓ ALL StatusBarCoordinator Tests PASSED!")
    }
}
