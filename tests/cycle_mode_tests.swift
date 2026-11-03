// ==============================================================================
// Mimra Tests — Summon-Key Cycle Mode Verification
// Linked Features: F-023, F-031, F-020, F-024
// Test IDs: T-KEY-02, T-KEY-04, T-PASTE-01
// Verification: Repeat summon key while holding modifiers, release commits;
// cancel on Escape/focus loss; circular wrap-around; reverse cycling;
// arrow navigation during cycle; disarming on text input; zero conflict with pins.
// ==============================================================================

import AppKit
import Carbon
import Foundation

final class CyclePosterBox: @unchecked Sendable {
    var postedPid: pid_t?
    var postCount: Int = 0
}

@main
struct CycleModeTests {
    @MainActor
    static func main() async {
        print("=== Running Summon-Key Cycle Mode Tests (P5-06 / F-023, F-031, T-KEY-02, T-KEY-04) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mimra_cycle_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("cycle_test.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // =====================================================================
        // Step 1: Unit Verification of Primary Modifier Resolution & Conversion
        // =====================================================================
        print("\nStep 1: Testing Primary Modifier Resolution & Carbon Conversion...")

        // Carbon modifiers conversion
        let carbonCmdShift = UInt32(cmdKey | shiftKey)
        let appKitCmdShift = HotkeyManager.carbonModifiersToNSEventModifierFlags(carbonCmdShift)
        assert(appKitCmdShift.contains([.command, .shift]), "FAIL: Carbon cmdKey | shiftKey should contain command and shift")

        let carbonOpt = UInt32(optionKey)
        let appKitOpt = HotkeyManager.carbonModifiersToNSEventModifierFlags(carbonOpt)
        assert(appKitOpt.contains(.option), "FAIL: Carbon optionKey should convert to NSEvent .option")

        let carbonCtrl = UInt32(controlKey)
        let appKitCtrl = HotkeyManager.carbonModifiersToNSEventModifierFlags(carbonCtrl)
        assert(appKitCtrl.contains(.control), "FAIL: Carbon controlKey should convert to NSEvent .control")

        let core = try! CoreClient(databasePath: dbPath)
        let testPbName = NSPasteboard.Name("com.mimra.test.cycle.\(UUID().uuidString)")
        let testPasteboard = NSPasteboard(name: testPbName)
        let provenanceGuard = ClipboardProvenance()
        let posterBox = CyclePosterBox()
        let mockPoster: KeystrokePoster = { pid in
            posterBox.postedPid = pid
            posterBox.postCount += 1
            return true
        }

        let currentApp = NSRunningApplication.current
        let pasteCoordinator = PasteCoordinator(
            coreClient: core,
            pasteboard: testPasteboard,
            provenanceGuard: provenanceGuard,
            pasteAutomatically: true,
            activationDelayNanoseconds: 1_000_000,
            accessibilityChecker: { true },
            keystrokePoster: mockPoster,
            secureInputChecker: { false },
            passwordFieldChecker: { _ in false },
            frontmostAppProvider: { currentApp }
        )

        let coordinator = PanelCoordinator(coreClient: core, pasteCoordinator: pasteCoordinator)
        assert(coordinator.primarySummonModifier == .command, "FAIL: Default summon modifiers [.command, .shift] must resolve primary modifier to .command")

        coordinator.summonModifiers = [.option]
        assert(coordinator.primarySummonModifier == .option, "FAIL: Option-only summon must resolve primary to .option")

        coordinator.summonModifiers = [.control]
        assert(coordinator.primarySummonModifier == .control, "FAIL: Control-only summon must resolve primary to .control")

        coordinator.summonModifiers = [.shift]
        assert(coordinator.primarySummonModifier == .shift, "FAIL: Shift-only summon must resolve primary to .shift")

        coordinator.summonModifiers = [.command, .shift]
        print("✓ Step 1: Primary modifier resolution and Carbon flags conversion verified.")

        // =====================================================================
        // Step 2: Seed Corpus of Test Items
        // =====================================================================
        print("\nStep 2: Ingesting History Corpus...")
        let testItems = [
            "Alpha item 1",
            "Beta item 2",
            "Gamma item 3",
            "Delta item 4",
            "Epsilon item 5"
        ]

        var itemIds: [String] = []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var offsetMs: Int64 = 0
        for text in testItems {
            let capture = RawCapture(
                timestampMs: nowMs + offsetMs,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: text.data(using: .utf8)!)
                ]
            )
            let res = try! await core.ingest(capture: capture)
            itemIds.append(res.itemId)
            offsetMs += 100
        }

        await coordinator.viewModel.loadData()
        assert(coordinator.viewModel.items.count == 5, "FAIL: Should have 5 items in history")
        print("✓ Step 2: Ingested \(coordinator.viewModel.items.count) items into SQLite.")

        // =====================================================================
        // Step 3: Initial Summon Without Repeat (Normal Summon)
        // =====================================================================
        print("\nStep 3: Initial Summon Without Repeat (No Cycling)...")
        coordinator.show()
        let panel = coordinator.getOrCreatePanel()
        assert(panel.isVisible, "FAIL: Panel must be visible after show()")
        assert(!coordinator.isCycleActive, "FAIL: Initial summon must NOT activate cycle mode")
        assert(coordinator.viewModel.selectedIndex == 0, "FAIL: Initial selection should be at index 0")

        // User releases modifier keys without repeating summon
        var committedItem: HistoryItemSummaryDto? = nil
        coordinator.onCycleCommitted = { item in
            committedItem = item
        }

        let releaseEvent = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0
        )!
        coordinator.handlePanelFlagsChanged(event: releaseEvent)

        assert(!coordinator.isCycleActive, "FAIL: Cycle mode should remain false")
        assert(committedItem == nil, "FAIL: Releasing modifier without repeating summon must NOT commit")
        assert(panel.isVisible, "FAIL: Panel must remain open for normal browsing")
        print("✓ Step 3: Initial summon without repeat leaves panel open and does not commit.")

        // =====================================================================
        // Step 4: Repeat Summon Key While Holding Modifiers & Release Commit
        // =====================================================================
        print("\nStep 4: Repeat Summon Key Forward Cycling (0 -> 1 -> 2 -> 3) & Release Commit...")

        var cycleChangeLog: [(Int, String)] = []
        coordinator.onCycleChanged = { idx, item in
            cycleChangeLog.append((idx, item?.title ?? ""))
        }

        // Tap summon key second time (repeat summon)
        coordinator.handleSummonHotkey()
        assert(coordinator.isCycleActive, "FAIL: Repeating summon key must activate cycle mode")
        assert(coordinator.viewModel.selectedIndex == 1, "FAIL: Selection should advance to index 1 (got \(coordinator.viewModel.selectedIndex))")

        // Tap summon key third time
        coordinator.handleSummonHotkey()
        assert(coordinator.viewModel.selectedIndex == 2, "FAIL: Selection should advance to index 2 (got \(coordinator.viewModel.selectedIndex))")

        // Tap summon key fourth time
        coordinator.handleSummonHotkey()
        assert(coordinator.viewModel.selectedIndex == 3, "FAIL: Selection should advance to index 3 (got \(coordinator.viewModel.selectedIndex))")

        assert(cycleChangeLog.count == 3, "FAIL: Expected 3 cycle change notifications")
        assert(cycleChangeLog.map { $0.0 } == [1, 2, 3], "FAIL: Expected indices [1, 2, 3]")

        // Releasing modifiers commits item at index 3
        var finalCommittedItem: HistoryItemSummaryDto? = nil
        var finalCommitMode: PasteMode? = nil
        coordinator.onItemCommitted = { item, mode, _ in
            finalCommittedItem = item
            finalCommitMode = mode
        }

        coordinator.handlePanelFlagsChanged(event: releaseEvent)

        assert(!coordinator.isCycleActive, "FAIL: Cycle mode must reset to false after commit")
        assert(!panel.isVisible, "FAIL: Panel should hide after commit")
        assert(finalCommittedItem != nil, "FAIL: An item must be committed on modifier release")
        assert(finalCommittedItem?.id == coordinator.viewModel.items[3].id, "FAIL: Committed item must match item at index 3")
        assert(finalCommitMode == .original, "FAIL: Default commit mode should be original")
        print("✓ Step 4: Forward cycling across multiple taps and commit on modifier release verified.")

        // =====================================================================
        // Step 5: Circular Wrap-Around at Boundary
        // =====================================================================
        print("\nStep 5: Testing Circular Wrap-Around at List Boundary...")
        coordinator.show()
        assert(coordinator.viewModel.selectedIndex == 0, "FAIL: Selection reset to 0 on show")

        // Advance 5 times (0 -> 1 -> 2 -> 3 -> 4 -> wrap to 0)
        for _ in 1...5 {
            coordinator.cycleNext()
        }
        assert(coordinator.viewModel.selectedIndex == 0, "FAIL: 5 advances on 5 items must wrap back to index 0 (got \(coordinator.viewModel.selectedIndex))")

        // Advance 1 more time -> index 1
        coordinator.cycleNext()
        assert(coordinator.viewModel.selectedIndex == 1, "FAIL: Subsequent advance must reach index 1")

        coordinator.handlePanelFlagsChanged(event: releaseEvent)
        assert(!panel.isVisible, "FAIL: Panel should hide after commit")
        assert(finalCommittedItem?.id == coordinator.viewModel.items[1].id, "FAIL: Committed item must be index 1 after wrap-around")
        print("✓ Step 5: Circular boundary wrap-around verified.")

        // =====================================================================
        // Step 6: Reverse Cycling (Shift or Previous)
        // =====================================================================
        print("\nStep 6: Testing Reverse Cycling...")
        coordinator.show()
        assert(coordinator.viewModel.selectedIndex == 0)

        // cyclePrevious from 0 wraps to 4
        coordinator.cyclePrevious()
        assert(coordinator.isCycleActive, "FAIL: cyclePrevious must activate cycle mode")
        assert(coordinator.viewModel.selectedIndex == 4, "FAIL: cyclePrevious from 0 must wrap to 4 (got \(coordinator.viewModel.selectedIndex))")

        // cyclePrevious from 4 moves to 3
        coordinator.cyclePrevious()
        assert(coordinator.viewModel.selectedIndex == 3, "FAIL: cyclePrevious from 4 must move to 3")

        coordinator.handlePanelFlagsChanged(event: releaseEvent)
        assert(finalCommittedItem?.id == coordinator.viewModel.items[3].id, "FAIL: Committed item must be index 3")
        print("✓ Step 6: Reverse cycling and boundary wrap-around verified.")

        // =====================================================================
        // Step 7: Cancellation on Escape Key
        // =====================================================================
        print("\nStep 7: Testing Cancellation on Escape Key...")
        coordinator.show()
        coordinator.cycleNext()
        coordinator.cycleNext()
        assert(coordinator.isCycleActive, "FAIL: Cycle mode should be active")
        assert(coordinator.viewModel.selectedIndex == 2, "FAIL: Selection should be at index 2")

        var cancelledCalled = false
        coordinator.onCycleCancelled = {
            cancelledCalled = true
        }

        // Send Escape key event (keyCode 53)
        let escapeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!

        finalCommittedItem = nil
        let handledEscape = coordinator.handlePanelKeyDown(event: escapeEvent)
        assert(handledEscape, "FAIL: Escape key must be handled")
        assert(!coordinator.isCycleActive, "FAIL: Cycle mode must be cancelled by Escape")
        assert(!panel.isVisible, "FAIL: Panel must be hidden on Escape")
        assert(cancelledCalled, "FAIL: onCycleCancelled callback should have fired")

        // Releasing modifiers after Escape must NOT commit anything
        coordinator.handlePanelFlagsChanged(event: releaseEvent)
        assert(finalCommittedItem == nil, "FAIL: Releasing modifiers after Escape must NOT commit any item")
        print("✓ Step 7: Cancellation on Escape key verified (zero spurious commit).")

        // =====================================================================
        // Step 8: Cancellation on Focus Loss (Resign Key)
        // =====================================================================
        print("\nStep 8: Testing Cancellation on Focus Loss (resignKey)...")
        coordinator.show()
        coordinator.cycleNext()
        assert(coordinator.isCycleActive, "FAIL: Cycle mode should be active")

        cancelledCalled = false
        finalCommittedItem = nil

        // Simulate resignKey (user clicks outside or switches applications)
        panel.resignKey()

        assert(!coordinator.isCycleActive, "FAIL: Focus loss must cancel cycle mode")
        assert(!panel.isVisible, "FAIL: Panel must hide on resignKey")
        assert(cancelledCalled, "FAIL: onCycleCancelled callback should fire on focus loss")

        // Modifiers released in another app
        coordinator.handlePanelFlagsChanged(event: releaseEvent)
        assert(finalCommittedItem == nil, "FAIL: Releasing modifiers after resignKey must NOT commit")
        print("✓ Step 8: Cancellation on focus loss verified.")

        // =====================================================================
        // Step 9: Disarming on Regular Text Input (Typing into Search)
        // =====================================================================
        print("\nStep 9: Testing Disarming on Regular Text Input...")
        coordinator.show()
        coordinator.cycleNext()
        assert(coordinator.isCycleActive, "FAIL: Cycle mode should be active")

        cancelledCalled = false
        finalCommittedItem = nil

        // User types 'b' into search
        let charEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11 // 'b'
        )!

        let handledChar = coordinator.handlePanelKeyDown(event: charEvent)
        assert(!handledChar, "FAIL: Regular character key should return false to let NSTextField receive input")
        assert(!coordinator.isCycleActive, "FAIL: Regular key press must disarm cycle mode")
        assert(cancelledCalled, "FAIL: onCycleCancelled should fire when typing text")

        // Releasing modifiers now does NOT commit
        coordinator.handlePanelFlagsChanged(event: releaseEvent)
        assert(finalCommittedItem == nil, "FAIL: Releasing modifiers after typing text must NOT commit")
        print("✓ Step 9: Disarming cycle mode on regular text input verified.")

        // =====================================================================
        // Step 10: Manual Arrow Key Navigation During Cycle Mode
        // =====================================================================
        print("\nStep 10: Testing Manual Arrow Key Navigation During Cycle Mode...")
        coordinator.show()
        coordinator.cycleNext() // index 1
        assert(coordinator.isCycleActive)

        // Down Arrow (keyCode 125) advances to index 2
        let downArrow = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 125
        )!
        _ = coordinator.handlePanelKeyDown(event: downArrow)
        assert(coordinator.viewModel.selectedIndex == 2, "FAIL: Down arrow should move selection to index 2")
        assert(coordinator.isCycleActive, "FAIL: Cycle mode must remain active during arrow navigation")

        // Up Arrow (keyCode 126) retreats to index 1
        let upArrow = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 126
        )!
        _ = coordinator.handlePanelKeyDown(event: upArrow)
        assert(coordinator.viewModel.selectedIndex == 1, "FAIL: Up arrow should move selection back to index 1")
        assert(coordinator.isCycleActive, "FAIL: Cycle mode must remain active during arrow navigation")

        // Release commits index 1
        finalCommittedItem = nil
        coordinator.handlePanelFlagsChanged(event: releaseEvent)
        assert(finalCommittedItem?.id == coordinator.viewModel.items[1].id, "FAIL: Releasing modifiers after arrow navigation must commit selected item")
        print("✓ Step 10: Arrow key navigation during cycle mode verified.")

        // =====================================================================
        // Step 11: In-Panel Summon Key Handling via handlePanelKeyDown
        // =====================================================================
        print("\nStep 11: Testing In-Panel Summon Key via handlePanelKeyDown...")
        coordinator.show()
        assert(coordinator.viewModel.selectedIndex == 0)

        // KeyCode 8 (kVK_ANSI_C) with command + shift
        let inPanelSummonEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        )!

        let handledSummon = coordinator.handlePanelKeyDown(event: inPanelSummonEvent)
        assert(handledSummon, "FAIL: In-panel summon key must be handled")
        assert(coordinator.isCycleActive, "FAIL: In-panel summon key must activate cycle mode")
        assert(coordinator.viewModel.selectedIndex == 1, "FAIL: In-panel summon key must advance selection to index 1")

        coordinator.handlePanelFlagsChanged(event: releaseEvent)
        print("✓ Step 11: In-panel summon key handling via handlePanelKeyDown verified.")

        // =====================================================================
        // Step 12: Cycle Mode Disabled Preference
        // =====================================================================
        print("\nStep 12: Testing cycleModeEnabled = false Preference...")
        coordinator.cycleModeEnabled = false
        coordinator.show()
        assert(panel.isVisible)

        // Calling summon when cycle mode is disabled should toggle (hide) panel
        coordinator.handleSummonHotkey()
        assert(!panel.isVisible, "FAIL: When cycleModeEnabled is false, summon key must hide panel")
        assert(!coordinator.isCycleActive, "FAIL: Cycle mode must not be active")

        coordinator.cycleModeEnabled = true // Restore
        print("✓ Step 12: Cycle mode disabled preference verified.")

        // =====================================================================
        // Step 13: Pin Operations & Conflict Prevention
        // =====================================================================
        print("\nStep 13: Testing Pin Operations & Conflict Prevention...")
        // Explicitly pin an item in core and reload
        _ = try! await core.togglePin(itemId: itemIds[0])
        await coordinator.viewModel.loadData()
        assert(coordinator.viewModel.items.first(where: { $0.id == itemIds[0] })?.isPinned == true, "FAIL: Item 0 should be pinned")

        coordinator.show()
        coordinator.cycleNext()
        assert(coordinator.isCycleActive, "FAIL: Cycle mode should be active")

        // Option-P pressed while in cycle mode must disarm cycle mode
        let optionPEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .option,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35 // 'p'
        )!

        let handledPin = coordinator.handlePanelKeyDown(event: optionPEvent)
        assert(handledPin, "FAIL: Option-P must be handled")
        assert(!coordinator.isCycleActive, "FAIL: Pin shortcut must disarm cycle mode")

        // Now test cycle smoothly across pinned and unpinned items
        coordinator.cycleNext()
        assert(coordinator.isCycleActive, "FAIL: Cycle mode active")
        assert(coordinator.viewModel.selectedIndex >= 0)

        coordinator.handlePanelFlagsChanged(event: releaseEvent)
        assert(!panel.isVisible, "FAIL: Panel must hide on modifier release")
        print("✓ Step 13: Pin operations and conflict prevention verified.")

        // =====================================================================
        // Step 14: Empty History Boundary Case
        // =====================================================================
        print("\nStep 14: Testing Empty History Edge Case...")
        let emptyTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("empty_cycle_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: emptyTempDir, withIntermediateDirectories: true)
        let emptyDbPath = emptyTempDir.appendingPathComponent("empty.sqlite").path
        defer {
            try? FileManager.default.removeItem(at: emptyTempDir)
        }

        let emptyCore = try! CoreClient(databasePath: emptyDbPath)
        let emptyCoordinator = PanelCoordinator(coreClient: emptyCore)
        await emptyCoordinator.viewModel.loadData()
        assert(emptyCoordinator.viewModel.items.isEmpty)

        emptyCoordinator.show()
        emptyCoordinator.handleSummonHotkey()
        // Should not crash, index stays 0
        assert(emptyCoordinator.viewModel.selectedIndex == 0)

        // Release modifier
        emptyCoordinator.handlePanelFlagsChanged(event: releaseEvent)
        assert(!emptyCoordinator.getOrCreatePanel().isVisible)
        print("✓ Step 14: Empty history edge case verified without error.")

        print("\n✓ ALL 14 SUMMON-KEY CYCLE MODE TEST SUITES PASSED CLEANLY!")
    }
}
