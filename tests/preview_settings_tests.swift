// ==============================================================================
// Mimra — Preview Settings & Auto-Open Debounce Tests
// Verifies local shortcut isolation, configurable auto-open debounce timers,
// rapid navigation cancellation, and panel dismissal safety (P6-02 / F-040, T-PREV-02).
// ==============================================================================

import AppKit
import Foundation
import SwiftUI

@main
@MainActor
struct PreviewSettingsTestsRunner {
    static func main() async {
        print("=== Running Preview Settings & Auto-Open Tests (T-PREV-02 / P6-02) ===")

        testLocalShortcutIsolationNoGlobalRegistration()
        testAutoOpenDisabledByDefault()
        await testAutoOpenTimerFiresAfterDelay()
        await testRapidNavigationCancelsDebounceTimer()
        await testPanelDismissalCancelsAutoOpenTimer()
        testImmediateUpdateWhenAlreadyVisible()
        testUserDefaultsPersistence()

        print("=== All Preview Settings & Auto-Open Tests PASSED (7/7) ===")
    }

    // MARK: - Test 1: Local Shortcut Isolation

    static func testLocalShortcutIsolationNoGlobalRegistration() {
        print("  [Test 1] Local shortcut isolation: Control-Space is never globally registered...")

        let hotkeyManager = HotkeyManager()
        // Verify default global hotkey is Shift-Command-C (or custom), and NOT Control-Space
        assert(hotkeyManager.summonModifierFlags.contains(.command) || hotkeyManager.summonModifierFlags.contains(.shift),
               "Global hotkey must be command/shift based")
        assert(hotkeyManager.summonKeyCode != 49, "Global hotkey must NOT be Space (keyCode 49)")

        let tempDb = "/tmp/mimra_prev_shortcut_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tempDb) }

        do {
            let client = try CoreClient(databasePath: tempDb)
            let panelCoord = PanelCoordinator(coreClient: client)
            let panel = panelCoord.getOrCreatePanel()

            // When panel is key window, Control-Space is intercepted locally
            let spaceEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .control,
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49 // Space
            )!

            assert(!panelCoord.previewCoordinator.isPreviewVisible, "Preview initially closed")

            let handled = panelCoord.handlePanelKeyDown(event: spaceEvent)
            assert(handled, "Control-Space must be intercepted locally inside panel")
            assert(panelCoord.previewCoordinator.isPreviewVisible, "Preview must be toggled visible")

            // Second toggle closes
            let handled2 = panelCoord.handlePanelKeyDown(event: spaceEvent)
            assert(handled2, "Second Control-Space must be handled")
            assert(!panelCoord.previewCoordinator.isPreviewVisible, "Preview must be toggled closed")
        } catch {
            fatalError("Failed initializing CoreClient: \(error)")
        }

        print("  -> Passed local shortcut isolation check.")
    }

    // MARK: - Test 2: Auto-Open Disabled by Default

    static func testAutoOpenDisabledByDefault() {
        print("  [Test 2] Auto-open disabled by default: selection does not trigger preview...")

        // Clear userdefaults key for clean test
        UserDefaults.standard.removeObject(forKey: "previewAutoOpenEnabled")

        let coordinator = PreviewCoordinator()
        assert(!coordinator.isAutoOpenEnabled, "Auto-open must be disabled by default")

        let parent = FloatingPanel(contentRect: NSRect(x: 400, y: 300, width: 440, height: 540))
        let item = makeDummyItem(id: "default-test")

        coordinator.handleSelectionChanged(item: item, parent: parent)
        assert(!coordinator.isPreviewVisible, "Preview must remain closed when auto-open is disabled")

        print("  -> Passed auto-open disabled check.")
    }

    // MARK: - Test 3: Auto-Open Timer Fires After Delay

    static func testAutoOpenTimerFiresAfterDelay() async {
        print("  [Test 3] Auto-open debounce timer fires after configured delay...")

        let coordinator = PreviewCoordinator()
        coordinator.isAutoOpenEnabled = true
        coordinator.autoOpenDelayMs = 80 // 80ms test delay

        let parent = FloatingPanel(contentRect: NSRect(x: 400, y: 300, width: 440, height: 540))
        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }

        let item = makeDummyItem(id: "auto-open-1")

        coordinator.handleSelectionChanged(item: item, parent: parent)

        // Immediately after, preview should still be closed
        assert(!coordinator.isPreviewVisible, "Preview must not open instantaneously")

        // Wait for delay + safety margin (120ms > 80ms)
        try? await Task.sleep(nanoseconds: 120_000_000)

        assert(coordinator.isPreviewVisible, "Preview must open after delay has elapsed")
        assert(coordinator.currentItem?.id == "auto-open-1", "Preview must display selected item")

        coordinator.hide()
        coordinator.isAutoOpenEnabled = false
        print("  -> Passed auto-open timer firing check.")
    }

    // MARK: - Test 4: Rapid Navigation Cancels Debounce Timer

    static func testRapidNavigationCancelsDebounceTimer() async {
        print("  [Test 4] Rapid navigation resets debounce timer; intermediate items never open...")

        let coordinator = PreviewCoordinator()
        coordinator.isAutoOpenEnabled = true
        coordinator.autoOpenDelayMs = 120 // 120ms delay

        let parent = FloatingPanel(contentRect: NSRect(x: 400, y: 300, width: 440, height: 540))
        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }

        let itemA = makeDummyItem(id: "item-A")
        let itemB = makeDummyItem(id: "item-B")
        let itemC = makeDummyItem(id: "item-C")

        // Select item A
        coordinator.handleSelectionChanged(item: itemA, parent: parent)

        // After 40ms, quickly move to item B (before 120ms elapsed)
        try? await Task.sleep(nanoseconds: 40_000_000)
        assert(!coordinator.isPreviewVisible, "Preview must not be visible yet")
        coordinator.handleSelectionChanged(item: itemB, parent: parent)

        // After another 40ms, quickly move to item C
        try? await Task.sleep(nanoseconds: 40_000_000)
        assert(!coordinator.isPreviewVisible, "Preview must not be visible yet")
        coordinator.handleSelectionChanged(item: itemC, parent: parent)

        // Wait 70ms: 40 + 40 + 70 = 150ms from start, but only 70ms since item C was selected!
        try? await Task.sleep(nanoseconds: 70_000_000)
        assert(!coordinator.isPreviewVisible, "Preview must not open prematurely for intermediate items")

        // Wait another 70ms (140ms elapsed since item C was selected > 120ms delay)
        try? await Task.sleep(nanoseconds: 70_000_000)
        assert(coordinator.isPreviewVisible, "Preview must open for final resting item")
        assert(coordinator.currentItem?.id == "item-C", "Preview must show final item C, got \(String(describing: coordinator.currentItem?.id))")

        coordinator.hide()
        coordinator.isAutoOpenEnabled = false
        print("  -> Passed rapid navigation debounce cancellation check.")
    }

    // MARK: - Test 5: Panel Dismissal Cancels Auto-Open Timer

    static func testPanelDismissalCancelsAutoOpenTimer() async {
        print("  [Test 5] Panel dismissal cancels pending auto-open timer (no orphan popups)...")

        let coordinator = PreviewCoordinator()
        coordinator.isAutoOpenEnabled = true
        coordinator.autoOpenDelayMs = 100 // 100ms delay

        let parent = FloatingPanel(contentRect: NSRect(x: 400, y: 300, width: 440, height: 540))
        parent.makeKeyAndOrderFront(nil)

        let item = makeDummyItem(id: "dismissal-test")
        coordinator.handleSelectionChanged(item: item, parent: parent)

        // Dismiss panel before delay elapses
        try? await Task.sleep(nanoseconds: 30_000_000)
        coordinator.hide()
        parent.orderOut(nil)

        // Wait past delay
        try? await Task.sleep(nanoseconds: 120_000_000)

        assert(!coordinator.isPreviewVisible, "Preview must NEVER pop open after parent was dismissed")

        coordinator.isAutoOpenEnabled = false
        print("  -> Passed dismissal cancellation check.")
    }

    // MARK: - Test 6: Immediate Update When Already Visible

    static func testImmediateUpdateWhenAlreadyVisible() {
        print("  [Test 6] Immediate content update without delay when preview is already open...")

        let coordinator = PreviewCoordinator()
        coordinator.isAutoOpenEnabled = true
        coordinator.autoOpenDelayMs = 500 // Long 500ms delay

        let parent = FloatingPanel(contentRect: NSRect(x: 400, y: 300, width: 440, height: 540))
        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }

        let item1 = makeDummyItem(id: "open-item-1")
        let item2 = makeDummyItem(id: "open-item-2")

        // Manually show preview for item 1
        coordinator.show(for: item1, parent: parent)
        assert(coordinator.isPreviewVisible, "Preview is open")
        assert(coordinator.currentItem?.id == "open-item-1", "Item 1 active")

        // Now change selection: must update immediately without waiting 500ms
        coordinator.handleSelectionChanged(item: item2, parent: parent)
        assert(coordinator.currentItem?.id == "open-item-2", "Item 2 must be updated immediately")
        assert(coordinator.isPreviewVisible, "Preview remains open")

        coordinator.hide()
        coordinator.isAutoOpenEnabled = false
        print("  -> Passed immediate update when visible check.")
    }

    // MARK: - Test 7: UserDefaults Persistence

    static func testUserDefaultsPersistence() {
        print("  [Test 7] UserDefaults persistence for preview auto-open and delay...")

        let coordinator = PreviewCoordinator()

        coordinator.isAutoOpenEnabled = true
        assert(UserDefaults.standard.bool(forKey: "previewAutoOpenEnabled") == true, "Must persist true")

        coordinator.autoOpenDelayMs = 600
        assert(UserDefaults.standard.integer(forKey: "previewDelayMs") == 600, "Must persist 600")

        coordinator.isAutoOpenEnabled = false
        assert(UserDefaults.standard.bool(forKey: "previewAutoOpenEnabled") == false, "Must persist false")

        print("  -> Passed UserDefaults persistence check.")
    }

    // MARK: - Helpers

    static func makeDummyItem(id: String) -> HistoryItemSummaryDto {
        HistoryItemSummaryDto(
            id: id,
            contentKind: "text",
            title: "Item \(id)",
            snippet: "Snippet for \(id)",
            isPinned: false,
            pinOrder: nil,
            pinKey: nil,
            sourceBundleId: "com.apple.Notes",
            firstCopiedAtMs: 1000,
            lastCopiedAtMs: 2000,
            copyCount: 1,
            byteSize: 64,
            availableUtis: ["public.utf8-plain-text"],
            titleHighlights: [],
            snippetHighlights: []
        )
    }
}
