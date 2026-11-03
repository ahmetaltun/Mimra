// ==============================================================================
// Mimra — Quick Pick 1-9 & Modifier-Dependent Selection Tests
// Linked Features: F-022, F-020, F-021, F-024
// Test IDs: T-KEY-01, T-PASTE-01, T-PASTE-02
// Verification: Number quick picks 1–9 with modifier support (copy/paste/plain),
// capacity and boundary limits, layout/shift keycode resilience, and visible order matching.
// ==============================================================================

import AppKit
import Foundation

final class PosterBox: @unchecked Sendable {
    var postedPid: pid_t?
}

@main
struct QuickPickTests {
    @MainActor
    static func main() async {
        print("=== Running Quick Pick 1-9 & Modifier Tests (P5-05 / F-022, T-KEY-01) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("quick_pick_test.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // =====================================================================
        // Step 1: Unit Verification of KeyCode and Layout Resilience
        // =====================================================================
        print("\nStep 1: Testing KeyCode Mapping & Shift/AZERTY Layout Resilience...")

        // Top row numbers (keyCodes 18, 19, 20, 21, 23, 22, 26, 28, 25)
        let topRowKeyCodes: [(UInt16, Int)] = [
            (18, 1), (19, 2), (20, 3), (21, 4), (23, 5),
            (22, 6), (26, 7), (28, 8), (25, 9)
        ]
        for (kc, expectedNum) in topRowKeyCodes {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\(expectedNum)",
                charactersIgnoringModifiers: "\(expectedNum)",
                isARepeat: false,
                keyCode: kc
            )!
            let parsed = PanelCoordinator.quickPickNumber(for: event)
            assert(parsed == expectedNum, "FAIL: KeyCode \(kc) should parse to \(expectedNum), got \(String(describing: parsed))")
        }

        // Keypad numbers (keyCodes 83, 84, 85, 86, 87, 88, 89, 91, 92)
        let keypadKeyCodes: [(UInt16, Int)] = [
            (83, 1), (84, 2), (85, 3), (86, 4), (87, 5),
            (88, 6), (89, 7), (91, 8), (92, 9)
        ]
        for (kc, expectedNum) in keypadKeyCodes {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .numericPad],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\(expectedNum)",
                charactersIgnoringModifiers: "\(expectedNum)",
                isARepeat: false,
                keyCode: kc
            )!
            let parsed = PanelCoordinator.quickPickNumber(for: event)
            assert(parsed == expectedNum, "FAIL: Keypad keyCode \(kc) should parse to \(expectedNum), got \(String(describing: parsed))")
        }

        // Shift modifier effect: charactersIgnoringModifiers returns "!" for key 1 on US layout
        let shiftKey1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "!",
            charactersIgnoringModifiers: "!",
            isARepeat: false,
            keyCode: 18 // key 1
        )!
        let shiftNum = PanelCoordinator.quickPickNumber(for: shiftKey1Event)
        assert(shiftNum == 1, "FAIL: Shift-modified key 1 (charactersIgnoringModifiers='!') must still resolve to 1 via keyCode 18.")

        // AZERTY layout effect: key 1 without shift returns "&"
        let azertyKey1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "&",
            charactersIgnoringModifiers: "&",
            isARepeat: false,
            keyCode: 18
        )!
        let azertyNum = PanelCoordinator.quickPickNumber(for: azertyKey1Event)
        assert(azertyNum == 1, "FAIL: AZERTY key 1 must resolve to 1 via keyCode 18.")

        // Character fallback when keyCode is 0 / dummy
        let dummyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "7",
            charactersIgnoringModifiers: "7",
            isARepeat: false,
            keyCode: 0
        )!
        let fallbackNum = PanelCoordinator.quickPickNumber(for: dummyEvent)
        assert(fallbackNum == 7, "FAIL: Fallback character parse should extract 7.")

        // Non-number key returns nil
        let nonNumEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "e",
            charactersIgnoringModifiers: "e",
            isARepeat: false,
            keyCode: 14 // 'e'
        )!
        assert(PanelCoordinator.quickPickNumber(for: nonNumEvent) == nil, "FAIL: Key 'e' must not parse as a quick pick number.")

        print("✓ Step 1: KeyCode mapping, keypad numbers, shift resilience, and character fallback verified.")

        // =====================================================================
        // Step 2: Ingest Test Items into SQLite
        // =====================================================================
        print("\nStep 2: Ingesting Corpus of History Items...")
        let core = try! CoreClient(databasePath: dbPath)
        let testPbName = NSPasteboard.Name("com.mimra.test.quickpick.\(UUID().uuidString)")
        let testPasteboard = NSPasteboard(name: testPbName)
        let provenanceGuard = ClipboardProvenance()
        let posterBox = PosterBox()
        let mockPoster: KeystrokePoster = { pid in
            posterBox.postedPid = pid
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
        let vm = coordinator.viewModel

        // Initially empty
        await vm.loadData()
        assert(vm.items.isEmpty, "History should be initially empty.")

        // Ingest 12 items with known titles
        var ingestedIds: [String] = []
        for i in 1...12 {
            let text = i <= 3 ? "Safari Page \(i) text" : "Note Entry \(i) text"
            let textPayload = text.data(using: .utf8)!
            let htmlPayload = "<b>Formatted content \(i)</b>".data(using: .utf8)!
            let capture = RawCapture(
                timestampMs: Int64(1000 + i * 10),
                sourceBundleId: i <= 3 ? "com.apple.Safari" : "com.apple.Notes",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: textPayload),
                    RawRepresentation(groupIndex: 1, uti: "public.html", payload: htmlPayload)
                ]
            )
            let res = try! await core.ingest(capture: capture)
            ingestedIds.append(res.itemId)
        }

        await vm.loadData()
        assert(vm.items.count == 12, "FAIL: Expected 12 items in history, got \(vm.items.count)")
        print("✓ Step 2: 12 test items successfully ingested.")

        // =====================================================================
        // Step 3: Capacity & Boundary Limits
        // =====================================================================
        print("\nStep 3: Testing Capacity & Boundary Cases...")

        // Test with empty viewmodel
        let emptyCore = try! CoreClient.inMemory()
        let emptyVm = PanelViewModel(coreClient: emptyCore)
        var commitCalled = false
        emptyVm.onCommitItem = { _, _, _ in commitCalled = true }

        let emptyPick1 = emptyVm.quickPick(number: 1)
        assert(!emptyPick1, "FAIL: quickPick on empty list must return false.")
        assert(!commitCalled, "FAIL: commit must not be called on empty list.")

        // Test out of bounds numbers: 0, 10, -1
        assert(!vm.quickPick(number: 0), "FAIL: quickPick(0) must return false.")
        assert(!vm.quickPick(number: 10), "FAIL: quickPick(10) must return false.")
        assert(!vm.quickPick(number: -3), "FAIL: quickPick(-3) must return false.")

        // Test requesting index beyond count when count < 9
        vm.searchText = "Safari Page 1" // matches Safari Page 1 only
        assert(vm.filteredItems.count == 1, "FAIL: Expected 1 filtered item, got \(vm.filteredItems.count)")
        assert(vm.quickPick(number: 2) == false, "FAIL: quickPick(2) when only 1 item exists must return false.")
        assert(vm.quickPick(number: 5) == false, "FAIL: quickPick(5) when only 1 item exists must return false.")
        assert(vm.quickPick(number: 1) == true, "FAIL: quickPick(1) on 1-item filtered list should succeed.")
        vm.searchText = "" // Reset search

        print("✓ Step 3: Capacity and boundary limits verified.")

        // =====================================================================
        // Step 4: Verification of Visible Order Matching (DoD: P5-05)
        // =====================================================================
        print("\nStep 4: Testing Visible Order Matching (Recency, Pin Top/Bottom, Search)...")

        var lastCommittedItem: HistoryItemSummaryDto?
        var lastCommittedMode: PasteMode?
        var lastCommittedForce: Bool?

        coordinator.onItemCommitted = { item, mode, force in
            lastCommittedItem = item
            lastCommittedMode = mode
            lastCommittedForce = force
        }

        // In recency order: item 12 is top (row 1), item 11 is row 2, ..., item 4 is row 9.
        await vm.loadData()
        let topItem = vm.filteredItems[0]
        let ninthItem = vm.filteredItems[8]

        // ⌘1 selects visible row 1
        let cmd1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        )!
        assert(coordinator.handlePanelKeyDown(event: cmd1Event), "FAIL: ⌘1 should be handled.")
        assert(lastCommittedItem?.id == topItem.id, "FAIL: ⌘1 must pick visible row 1 ('\(topItem.title)'), got '\(lastCommittedItem?.title ?? "")'")
        assert(vm.selectedIndex == 0, "FAIL: selectedIndex must be 0")

        // ⌘9 selects visible row 9
        let cmd9Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "9",
            charactersIgnoringModifiers: "9",
            isARepeat: false,
            keyCode: 25
        )!
        assert(coordinator.handlePanelKeyDown(event: cmd9Event), "FAIL: ⌘9 should be handled.")
        assert(lastCommittedItem?.id == ninthItem.id, "FAIL: ⌘9 must pick visible row 9 ('\(ninthItem.title)'), got '\(lastCommittedItem?.title ?? "")'")
        assert(vm.selectedIndex == 8, "FAIL: selectedIndex must be 8")

        // Search Filter visible order matching:
        // Search for "Safari": matches items 3, 2, 1 (3 items total).
        vm.searchText = "Safari"
        assert(vm.filteredItems.count == 3, "Expected 3 Safari items.")
        let secondSafari = vm.filteredItems[1]

        // ⌘4 under search: only 3 results exist -> must not commit anything
        lastCommittedItem = nil
        let cmd4Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "4",
            charactersIgnoringModifiers: "4",
            isARepeat: false,
            keyCode: 21
        )!
        assert(coordinator.handlePanelKeyDown(event: cmd4Event), "FAIL: ⌘4 event should be consumed as hotkey.")
        assert(lastCommittedItem == nil, "FAIL: ⌘4 with only 3 visible items must not commit anything.")

        // ⌘2 under search: commits the 2nd search result
        let cmd2Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "2",
            charactersIgnoringModifiers: "2",
            isARepeat: false,
            keyCode: 19
        )!
        assert(coordinator.handlePanelKeyDown(event: cmd2Event), "FAIL: ⌘2 should be handled.")
        assert(lastCommittedItem?.id == secondSafari.id, "FAIL: ⌘2 under search must pick 2nd search result ('\(secondSafari.title)')")
        assert(vm.selectedItemId == secondSafari.id, "FAIL: selectedItemId must match 2nd search result")

        vm.searchText = "" // Reset search
        await vm.loadData()

        // Pinned arrangement visible order matching:
        // Pin Item 1 with key "z"
        try! await core.setPin(itemId: ingestedIds[0], isPinned: true, pinKey: "z", pinOrder: 0)

        // With pinArrangement = .top: pinned Item 1 appears at index 0
        vm.pinArrangement = .top
        await vm.loadData()
        assert(vm.filteredItems[0].id == ingestedIds[0], "FAIL: Pinned item should be at row 1 under .top")

        assert(coordinator.handlePanelKeyDown(event: cmd1Event), "FAIL: ⌘1 should be handled.")
        assert(lastCommittedItem?.id == ingestedIds[0], "FAIL: ⌘1 under pinArrangement=.top must pick pinned Item 1 at row 1.")

        // With pinArrangement = .bottom: unpinned items appear first, pinned item is at the bottom
        vm.pinArrangement = .bottom
        await vm.loadData()
        let bottomItem = vm.filteredItems[0]
        assert(bottomItem.id != ingestedIds[0], "FAIL: Item 1 should not be at row 1 under .bottom")

        assert(coordinator.handlePanelKeyDown(event: cmd1Event), "FAIL: ⌘1 should be handled.")
        assert(lastCommittedItem?.id == bottomItem.id, "FAIL: ⌘1 under pinArrangement=.bottom must pick unpinned item at row 1.")

        // Reset pin arrangement
        vm.pinArrangement = .top
        _ = try! await core.togglePin(itemId: ingestedIds[0]) // unpin
        await vm.loadData()

        print("✓ Step 4: DoD verified: quick pick 1-9 strictly matches visible row order under all sort, pin, and search modes.")

        // =====================================================================
        // Step 5: Modifier Combinations (Copy / Paste / Plain Text) (F-022)
        // =====================================================================
        print("\nStep 5: Testing Modifier Combinations (Copy, Paste, Plain Text)...")

        // A. Standard ⌘1: mode = .original, forcePaste = nil
        lastCommittedMode = nil
        lastCommittedForce = nil
        assert(coordinator.handlePanelKeyDown(event: cmd1Event))
        assert(lastCommittedMode == .original, "FAIL: ⌘1 must commit with .original mode")
        assert(lastCommittedForce == nil, "FAIL: ⌘1 must use default paste behavior (forcePaste: nil)")

        // B. ⌥⌘1 (Option-Command-1): Invert auto-paste (forcePaste: false when pasteAutomatically is true)
        pasteCoordinator.pasteAutomatically = true
        let optCmd1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        )!
        assert(coordinator.handlePanelKeyDown(event: optCmd1Event))
        assert(lastCommittedMode == .original, "FAIL: ⌥⌘1 must commit with .original mode")
        assert(lastCommittedForce == false, "FAIL: ⌥⌘1 must invert auto-paste to copy-only (forcePaste: false)")

        // Invert auto-paste when pasteAutomatically is false
        pasteCoordinator.pasteAutomatically = false
        assert(coordinator.handlePanelKeyDown(event: optCmd1Event))
        assert(lastCommittedForce == true, "FAIL: ⌥⌘1 when pasteAutomatically=false must invert to force paste (forcePaste: true)")
        pasteCoordinator.pasteAutomatically = true // Reset

        // C. ⇧⌘1 (Shift-Command-1): Plain text mode
        let shiftCmd1 = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "!",
            charactersIgnoringModifiers: "!",
            isARepeat: false,
            keyCode: 18 // KeyCode 18 ('1') with Shift
        )!
        assert(coordinator.handlePanelKeyDown(event: shiftCmd1))
        assert(lastCommittedMode == .plainText, "FAIL: ⇧⌘1 must commit in .plainText mode")
        assert(lastCommittedForce == nil, "FAIL: ⇧⌘1 must preserve default auto-paste preference")

        // D. ⌥⇧⌘1 (Option-Shift-Command-1): Plain text + Inverted auto-paste
        let optShiftCmd1 = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "!",
            charactersIgnoringModifiers: "!",
            isARepeat: false,
            keyCode: 18
        )!
        assert(coordinator.handlePanelKeyDown(event: optShiftCmd1))
        assert(lastCommittedMode == .plainText, "FAIL: ⌥⇧⌘1 must commit in .plainText mode")
        assert(lastCommittedForce == false, "FAIL: ⌥⇧⌘1 must invert auto-paste (forcePaste: false)")

        // E. Control variants (⌃1, ⌥⌃1, ⇧⌃1, ⌥⇧⌃1)
        let ctrl1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        )!
        assert(coordinator.handlePanelKeyDown(event: ctrl1Event))
        assert(lastCommittedMode == .original, "FAIL: ⌃1 must commit with .original mode")

        let optCtrl1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        )!
        assert(coordinator.handlePanelKeyDown(event: optCtrl1Event))
        assert(lastCommittedForce == false, "FAIL: ⌥⌃1 must invert auto-paste")

        print("✓ Step 5: All modifier combinations (Default, Option, Shift, Option-Shift, Control) verified.")

        // =====================================================================
        // Step 6: End-to-End Replay Fidelity Under Quick Pick
        // =====================================================================
        print("\nStep 6: Testing End-to-End Pasteboard Replay via Quick Pick...")

        // Allow any lingering in-flight paste task from Step 5 hotkey testing to complete
        try? await Task.sleep(nanoseconds: 60_000_000)

        posterBox.postedPid = nil
        let targetRowItem = vm.filteredItems[0]
        coordinator.targetApp = currentApp

        var recordedResult: PasteResult?
        coordinator.onPasteResult = { res in
            recordedResult = res
        }

        // Trigger quick pick 1 via FloatingPanel
        let panel = coordinator.getOrCreatePanel()
        _ = panel // Ensure panel hosting view is initialized
        coordinator.handleItemCommit(item: targetRowItem, mode: .original, forcePaste: nil)

        // Give async paste task a moment to write to pasteboard
        for _ in 0..<20 {
            if recordedResult != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let res1 = recordedResult else {
            fatalError("FAIL: Paste task timed out without producing result")
        }
        guard case .pastedSuccessfully = res1 else {
            fatalError("FAIL: Expected pastedSuccessfully, got: \(res1)")
        }

        assert(testPasteboard.string(forType: .string)?.contains("text") == true, "FAIL: Pasteboard should have plain text")
        assert(testPasteboard.data(forType: .html) != nil, "FAIL: Original mode should replay HTML representation")
        assert(posterBox.postedPid == currentApp.processIdentifier, "FAIL: Keystroke poster must be called for target app")

        // Trigger quick pick plain text mode
        posterBox.postedPid = nil
        recordedResult = nil
        coordinator.handleItemCommit(item: targetRowItem, mode: .plainText, forcePaste: nil)
        for _ in 0..<20 {
            if recordedResult != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        assert(testPasteboard.string(forType: .string)?.contains("text") == true, "FAIL: Pasteboard should have plain text")
        assert(testPasteboard.data(forType: .html) == nil, "FAIL: PlainText mode must strip HTML representation")

        print("✓ Step 6: Replay fidelity and representation stripping confirmed.")

        // =====================================================================
        // Step 7: Active Pin Editing Protection
        // =====================================================================
        print("\nStep 7: Testing Active Pin Editing Immunity...")

        // When pin editing is active, number keys and shortcuts must not trigger quick pick
        let targetId = vm.filteredItems[0].id
        _ = try! await core.togglePin(itemId: targetId)
        await vm.loadData()
        let editablePin = vm.filteredItems.first(where: { $0.id == targetId })!
        assert(editablePin.isPinned, "Item must be pinned.")

        await vm.startEditing(item: editablePin)
        assert(vm.editingPinItem != nil, "Pin editing must be active.")

        lastCommittedItem = nil
        let interceptedDuringEdit = coordinator.handlePanelKeyDown(event: cmd1Event)
        assert(!interceptedDuringEdit, "FAIL: ⌘1 must not be intercepted during pin editing.")
        assert(lastCommittedItem == nil, "FAIL: No item should be committed during active pin editing.")

        vm.cancelEditing()
        assert(vm.editingPinItem == nil, "Pin editing canceled.")

        print("✓ Step 7: Active pin editing is fully protected from quick pick interception.")

        print("\n=== ALL QUICK PICK & MODIFIER TESTS (P5-05 / F-022, T-KEY-01) PASSED! ===")
    }
}
