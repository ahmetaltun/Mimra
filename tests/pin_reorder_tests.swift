// ==============================================================================
// Mimra — Pin Reordering & Keyboard Accessibility Integration Tests
// Linked Features: F-046, F-024
// Test IDs: T-PIN-03
// Verification: Drag-and-drop reorder persistence, keyboard accessibility alternative
// (Option-Command-Up / Option-Command-Down), selection stability, and deterministic
// sequence across database relaunch.
// ==============================================================================

import AppKit
import Foundation

@main
struct PinReorderTests {
    @MainActor
    static func main() async {
        print("=== Running Pin Reordering & Accessibility Tests (P5-03 / F-046, T-PIN-03) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_pin_reorder_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("pin_reorder.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        do {
            print("\nStep 1: Ingest Initial Dataset (3 Pinned, 1 Unpinned)...")
            let core = try CoreClient(databasePath: dbPath)
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            // Item A: "Pin Item Alpha", shortcut: "["
            let capA = RawCapture(
                timestampMs: nowMs,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Alpha Payload".data(using: .utf8)!)
                ]
            )
            let resA = try await core.ingest(capture: capA)

            // Item B: "Pin Item Beta", shortcut: "k"
            let capB = RawCapture(
                timestampMs: nowMs + 10,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Beta Payload".data(using: .utf8)!)
                ]
            )
            let resB = try await core.ingest(capture: capB)

            // Item C: "Pin Item Gamma", shortcut: "="
            let capC = RawCapture(
                timestampMs: nowMs + 20,
                sourceBundleId: "com.apple.Notes",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Gamma Payload".data(using: .utf8)!)
                ]
            )
            let resC = try await core.ingest(capture: capC)

            // Item D: "Unpinned Delta"
            let capD = RawCapture(
                timestampMs: nowMs + 30,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Delta Unpinned".data(using: .utf8)!)
                ]
            )
            let resD = try await core.ingest(capture: capD)

            // Pin items A, B, C with initial pin_orders 0, 1, 2 and unique shortcuts
            try await core.setPin(itemId: resA.itemId, isPinned: true, pinKey: "[", pinOrder: 0)
            try await core.setPin(itemId: resB.itemId, isPinned: true, pinKey: "k", pinOrder: 1)
            try await core.setPin(itemId: resC.itemId, isPinned: true, pinKey: "=", pinOrder: 2)

            let initialList = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            assert(initialList.count == 4, "Expected 4 items in total")
            assert(initialList[0].id == resA.itemId && initialList[0].pinOrder == 0 && initialList[0].pinKey == "[", "Item A must be at index 0")
            assert(initialList[1].id == resB.itemId && initialList[1].pinOrder == 1 && initialList[1].pinKey == "k", "Item B must be at index 1")
            assert(initialList[2].id == resC.itemId && initialList[2].pinOrder == 2 && initialList[2].pinKey == "=", "Item C must be at index 2")
            assert(initialList[3].id == resD.itemId && !initialList[3].isPinned, "Item D must remain unpinned")
            print("✓ Initial dataset and pin shortcuts verified.")

            print("\nStep 2: Core reorderPins API Execution & Shortcut Preservation (F-046)...")
            // Reorder pinned items to: [C, A, B]
            try await core.reorderPins(orderedIds: [resC.itemId, resA.itemId, resB.itemId])

            let reorderedList = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            assert(reorderedList[0].id == resC.itemId, "Item C must now be at index 0")
            assert(reorderedList[0].pinOrder == 0, "Item C pinOrder must be 0")
            assert(reorderedList[0].pinKey == "=", "Item C must retain its shortcut '='")

            assert(reorderedList[1].id == resA.itemId, "Item A must now be at index 1")
            assert(reorderedList[1].pinOrder == 1, "Item A pinOrder must be 1")
            assert(reorderedList[1].pinKey == "[", "Item A must retain its shortcut '['")

            assert(reorderedList[2].id == resB.itemId, "Item B must now be at index 2")
            assert(reorderedList[2].pinOrder == 2, "Item B pinOrder must be 2")
            assert(reorderedList[2].pinKey == "k", "Item B must retain its shortcut 'k'")

            assert(reorderedList[3].id == resD.itemId, "Item D must remain at index 3 in history")
            print("✓ reorderPins updated sequential pin_order and preserved all custom pin shortcuts.")

            print("\nStep 3: Edge Cases & Error Guards (T-PIN-03)...")
            // Attempt to reorder containing unpinned item (resD) -> must fail
            var caughtUnpinned = false
            do {
                try await core.reorderPins(orderedIds: [resC.itemId, resD.itemId, resA.itemId])
            } catch CoreError.InvalidInput(let details) {
                caughtUnpinned = true
                assert(details.contains("not pinned"), "Expected error message to mention item is not pinned: \(details)")
            }
            assert(caughtUnpinned, "FAIL: reorderPins did not reject unpinned item ID")

            // Attempt to reorder with a non-existent UUID -> must fail
            var caughtNonExistent = false
            do {
                let fakeId = UUID().uuidString
                try await core.reorderPins(orderedIds: [fakeId, resA.itemId])
            } catch CoreError.ItemNotFound(let id) {
                caughtNonExistent = true
                assert(!id.isEmpty, "Expected item not found error to report the missing id")
            }
            assert(caughtNonExistent, "FAIL: reorderPins did not reject non-existent UUID")

            // Attempt to reorder with duplicate UUIDs -> must fail
            var caughtDuplicate = false
            do {
                try await core.reorderPins(orderedIds: [resA.itemId, resA.itemId])
            } catch CoreError.InvalidInput(let details) {
                caughtDuplicate = true
                assert(details.contains("duplicate"), "Expected error to indicate duplicate ID: \(details)")
            }
            assert(caughtDuplicate, "FAIL: reorderPins did not reject duplicate UUIDs")
            print("✓ Invalid reorder requests rejected with explicit error types.")

            print("\nStep 4: ViewModel Drag & Drop Reordering and Selection Stability...")
            let coordinator = PanelCoordinator(coreClient: core)
            let vm = coordinator.viewModel
            await vm.loadData()

            assert(vm.items.count == 4, "ViewModel should have loaded 4 items")
            // Currently order is [C, A, B, D]. Select Item A (index 1).
            vm.selectIndex(1, fromHover: false)
            assert(vm.selectedItem?.id == resA.itemId, "Item A should be selected")

            // Drag Item B onto Item C position (simulates dragging index 2 to index 0)
            let dropSuccess = await vm.movePin(sourceId: resB.itemId, targetId: resC.itemId)
            assert(dropSuccess, "movePin should succeed")

            // Expected new order: [B, C, A, D]
            assert(vm.items[0].id == resB.itemId, "Item B should be at index 0 after drag")
            assert(vm.items[1].id == resC.itemId, "Item C should be at index 1")
            assert(vm.items[2].id == resA.itemId, "Item A should be at index 2")

            // Verify selection stability: Item A should still be the selected item!
            assert(vm.selectedItem?.id == resA.itemId, "Selection stability failed: expected Item A to stay selected")
            assert(vm.selectedIndex == 2, "Selected index should have tracked to index 2")
            print("✓ Drag & Drop movePin succeeded with active selection stability.")

            print("\nStep 5: Keyboard Reordering Navigation (⌥⌘↑ and ⌥⌘↓)...")
            // Active selection is Item A at index 2.
            // Move Item A UP: ⌥⌘↑
            let moveUpSuccess = await vm.moveSelectedPinUp()
            assert(moveUpSuccess, "moveSelectedPinUp should succeed")

            // Expected order: [B, A, C, D]
            assert(vm.items[0].id == resB.itemId, "Item B should be at index 0")
            assert(vm.items[1].id == resA.itemId, "Item A should be at index 1")
            assert(vm.items[2].id == resC.itemId, "Item C should be at index 2")
            assert(vm.selectedItem?.id == resA.itemId, "Item A should remain selected after moving up")

            // Move Item A DOWN: ⌥⌘↓
            let moveDownSuccess = await vm.moveSelectedPinDown()
            assert(moveDownSuccess, "moveSelectedPinDown should succeed")

            // Expected order: [B, C, A, D]
            assert(vm.items[0].id == resB.itemId, "Item B should be at index 0")
            assert(vm.items[1].id == resC.itemId, "Item C should be at index 1")
            assert(vm.items[2].id == resA.itemId, "Item A should be at index 2")
            assert(vm.selectedItem?.id == resA.itemId, "Item A should remain selected after moving down")
            print("✓ ViewModel moveSelectedPinUp / moveSelectedPinDown successfully moved items with selection stability.")

            print("\nStep 6: PanelCoordinator Event Interception (⌥⌘↑ / ⌥⌘↓)...")
            // Synthesize Option-Command-Up key event (keyCode 126)
            let optCmdUpEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 126
            )!

            let upEventHandled = coordinator.handlePanelKeyDown(event: optCmdUpEvent)
            assert(upEventHandled, "FAIL: Option-Command-Up key event was not intercepted")

            // Allow background async Task in coordinator to complete
            try await Task.sleep(nanoseconds: 100_000_000)

            // Order should now be [B, A, C, D]
            assert(vm.items[1].id == resA.itemId, "Option-Command-Up should have moved Item A to index 1")

            // Synthesize Option-Command-Down key event (keyCode 125)
            let optCmdDownEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 125
            )!

            let downEventHandled = coordinator.handlePanelKeyDown(event: optCmdDownEvent)
            assert(downEventHandled, "FAIL: Option-Command-Down key event was not intercepted")

            try await Task.sleep(nanoseconds: 100_000_000)

            // Order should now be [B, C, A, D]
            assert(vm.items[2].id == resA.itemId, "Option-Command-Down should have moved Item A to index 2")
            print("✓ PanelCoordinator successfully intercepted and dispatched ⌥⌘↑ and ⌥⌘↓.")

            print("\nStep 7: Verify Database Relaunch Determinism (DoD)...")
            // Final order before closing: [B, C, A, D]
            // Drop core and coordinator references
            // Reopen database from disk with a fresh CoreClient
            let freshCore = try CoreClient(databasePath: dbPath)
            let relaunchedList = try await freshCore.listPageWithSort(
                sortMode: .recency,
                pinArrangement: .top,
                limit: 10,
                offset: 0
            )

            assert(relaunchedList.count == 4, "Expected 4 items after relaunch")
            assert(relaunchedList[0].id == resB.itemId, "FAIL: After relaunch, Item B must be at index 0")
            assert(relaunchedList[0].pinOrder == 0, "Item B pinOrder must persist as 0")
            assert(relaunchedList[0].pinKey == "k", "Item B shortcut 'k' must persist")

            assert(relaunchedList[1].id == resC.itemId, "FAIL: After relaunch, Item C must be at index 1")
            assert(relaunchedList[1].pinOrder == 1, "Item C pinOrder must persist as 1")
            assert(relaunchedList[1].pinKey == "=", "Item C shortcut '=' must persist")

            assert(relaunchedList[2].id == resA.itemId, "FAIL: After relaunch, Item A must be at index 2")
            assert(relaunchedList[2].pinOrder == 2, "Item A pinOrder must persist as 2")
            assert(relaunchedList[2].pinKey == "[", "Item A shortcut '[' must persist")

            assert(relaunchedList[3].id == resD.itemId, "FAIL: After relaunch, Item D must be at index 3")
            assert(!relaunchedList[3].isPinned, "Item D must remain unpinned")
            print("✓ Relaunch determinism verified: Pinned order [B, C, A] and shortcuts intact after database reload.")

            print("\n🎉 ALL PIN REORDERING & ACCESSIBILITY TESTS PASSED (P5-03 / F-046, T-PIN-03)!")
        } catch {
            fatalError("Pin reordering tests failed with error: \(error)")
        }
    }
}
