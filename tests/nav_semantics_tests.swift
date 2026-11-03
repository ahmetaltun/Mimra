// ==============================================================================
// Mimra Tests — Navigation Semantics, Delete Stability & Section Consistency
// Linked Features: F-030, F-036, F-020, F-024
// Test IDs: T-KEY-03, T-UI-10, T-HIST-01
// Verification: Page Up/Down bounds clamping, Home/End, selection preservation
// after deleting items (specifically first unpinned, middle, last, and rapid deletes),
// pinned-only lists, mixed section headers, zero results vs empty clipboard state.
// ==============================================================================

import AppKit
import Carbon
import Foundation

@main
struct NavSemanticsTests {
    @MainActor
    static func main() async {
        print("=== Running Navigation Semantics & Delete Stability Tests (P5-07 / F-030, F-036, T-KEY-03, T-UI-10) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mimra_nav_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("nav_test.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let core = try! CoreClient(databasePath: dbPath)
        let coordinator = PanelCoordinator(coreClient: core)
        let vm = coordinator.viewModel

        // =====================================================================
        // Step 1: Page Down, Page Up, Home, End Bounds & Clamping (T-KEY-03, F-030)
        // =====================================================================
        print("\nStep 1: Testing Page Down / Page Up / Home / End Navigation & Clamping...")

        // Seed 25 items
        var itemIds: [String] = []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for i in 1...25 {
            let capture = RawCapture(
                timestampMs: nowMs + Int64(i * 10),
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Item \(i) content".data(using: .utf8)!)
                ]
            )
            let res = try! await core.ingest(capture: capture)
            itemIds.append(res.itemId)
        }

        await vm.loadData()
        assert(vm.items.count == 25, "FAIL: Expected 25 items, got \(vm.items.count)")
        assert(vm.selectedIndex == 0, "FAIL: Initial selection must be at index 0")

        // 1. Page Down 10 items (0 -> 10)
        vm.selectPageDown(pageSize: 10)
        assert(vm.selectedIndex == 10, "FAIL: selectPageDown(10) from 0 should reach index 10, got \(vm.selectedIndex)")
        assert(vm.selectedItemId == vm.filteredItems[10].id, "FAIL: selectedItemId must match index 10")

        // 2. Page Down 10 items (10 -> 20)
        vm.selectPageDown(pageSize: 10)
        assert(vm.selectedIndex == 20, "FAIL: selectPageDown(10) from 10 should reach index 20, got \(vm.selectedIndex)")

        // 3. Page Down 10 items (20 -> clamped to 24)
        vm.selectPageDown(pageSize: 10)
        assert(vm.selectedIndex == 24, "FAIL: selectPageDown(10) from 20 must clamp to 24 (count - 1), got \(vm.selectedIndex)")

        // 4. Page Down at boundary stays at 24
        vm.selectPageDown(pageSize: 10)
        assert(vm.selectedIndex == 24, "FAIL: selectPageDown at bottom boundary must remain at 24")

        // 5. Page Up 10 items (24 -> 14)
        vm.selectPageUp(pageSize: 10)
        assert(vm.selectedIndex == 14, "FAIL: selectPageUp(10) from 24 should reach index 14, got \(vm.selectedIndex)")

        // 6. Page Up 10 items (14 -> 4)
        vm.selectPageUp(pageSize: 10)
        assert(vm.selectedIndex == 4, "FAIL: selectPageUp(10) from 14 should reach index 4, got \(vm.selectedIndex)")

        // 7. Page Up 10 items (4 -> clamped to 0)
        vm.selectPageUp(pageSize: 10)
        assert(vm.selectedIndex == 0, "FAIL: selectPageUp(10) from 4 must clamp to 0, got \(vm.selectedIndex)")

        // 8. Page Up at top boundary stays at 0
        vm.selectPageUp(pageSize: 10)
        assert(vm.selectedIndex == 0, "FAIL: selectPageUp at top boundary must remain at 0")

        // 9. Home & End keys
        vm.selectLast()
        assert(vm.selectedIndex == 24, "FAIL: selectLast() must select 24")
        vm.selectFirst()
        assert(vm.selectedIndex == 0, "FAIL: selectFirst() must select 0")

        print("✓ Step 1: Page Down, Page Up, Home, and End clamping verified.")

        // =====================================================================
        // Step 2: KeyDown Interception for Page Up / Page Down (T-KEY-03)
        // =====================================================================
        print("\nStep 2: Testing PanelCoordinator KeyDown Interception for Page Up/Down...")
        coordinator.show()

        // Simulated Page Down (keyCode 121)
        let pageDownEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 121
        )!
        let handledPgDown = coordinator.handlePanelKeyDown(event: pageDownEvent)
        assert(handledPgDown, "FAIL: Page Down (keyCode 121) must be handled")
        assert(vm.selectedIndex == 10, "FAIL: Page Down key event should advance selection to index 10, got \(vm.selectedIndex)")

        // Simulated Page Up (keyCode 116)
        let pageUpEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 116
        )!
        let handledPgUp = coordinator.handlePanelKeyDown(event: pageUpEvent)
        assert(handledPgUp, "FAIL: Page Up (keyCode 116) must be handled")
        assert(vm.selectedIndex == 0, "FAIL: Page Up key event should retreat selection to index 0, got \(vm.selectedIndex)")

        // Simulated End (keyCode 119) & Home (keyCode 115)
        let endEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 119
        )!
        let handledEnd = coordinator.handlePanelKeyDown(event: endEvent)
        assert(handledEnd, "FAIL: End (keyCode 119) must be handled")
        assert(vm.selectedIndex == 24, "FAIL: End key must select 24")

        let homeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 115
        )!
        let handledHome = coordinator.handlePanelKeyDown(event: homeEvent)
        assert(handledHome, "FAIL: Home (keyCode 115) must be handled")
        assert(vm.selectedIndex == 0, "FAIL: Home key must select 0")

        coordinator.hide()
        print("✓ Step 2: KeyDown interception for Page Up/Down and Home/End verified.")

        // =====================================================================
        // Step 3: Selection Stability Following Deletions (T-KEY-03, F-030)
        // =====================================================================
        print("\nStep 3: Testing Selection Stability Following Deletions...")

        // Clear and setup controlled fixture with 2 pinned items and 3 unpinned items
        _ = try! await core.clearAll()
        await vm.loadData()

        var fixtureIds: [String] = []
        for i in 1...5 {
            let cap = RawCapture(
                timestampMs: nowMs + Int64(i * 100),
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Clip \(i)".data(using: .utf8)!)
                ]
            )
            let r = try! await core.ingest(capture: cap)
            fixtureIds.append(r.itemId)
        }

        // Pin items 1 and 2
        _ = try! await core.togglePin(itemId: fixtureIds[0])
        _ = try! await core.togglePin(itemId: fixtureIds[1])
        vm.pinArrangement = .top
        await vm.loadData()

        assert(vm.items.count == 5)
        assert(vm.items[0].isPinned && vm.items[1].isPinned, "Top two items must be pinned")
        assert(!vm.items[2].isPinned && !vm.items[3].isPinned && !vm.items[4].isPinned, "Bottom three items must be unpinned")

        // -----------------------------------------------------------------
        // Subtest 3A: Deleting first unpinned item (first-unpinned deletion regression scenario)
        // -----------------------------------------------------------------
        // Select index 2 (the first unpinned item)
        vm.selectIndex(2, fromHover: false)
        let firstUnpinned = vm.selectedItem!
        assert(!firstUnpinned.isPinned, "Selected item at index 2 must be unpinned")

        let nextUnpinnedId = vm.filteredItems[3].id
        let deletedFirstUnpinned = await vm.deleteItem(itemId: firstUnpinned.id)
        assert(deletedFirstUnpinned, "FAIL: deleteItem should succeed")

        // Selection MUST remain at index 2, now pointing to nextUnpinned
        assert(vm.selectedIndex == 2, "FAIL: Selection after deleting first unpinned item must remain at index 2 (got \(vm.selectedIndex))")
        assert(vm.selectedItem?.id == nextUnpinnedId, "FAIL: Selected item must now be the successor unpinned item (nextUnpinnedId)")
        assert(vm.selectedItem?.isPinned == false, "FAIL: Selection must remain on an unpinned item, NOT jump to pinned items")
        print("✓ Subtest 3A: Deleting first unpinned item preserved stable selection on successor unpinned item.")

        // -----------------------------------------------------------------
        // Subtest 3B: Deleting middle item
        // -----------------------------------------------------------------
        // Current list has 4 items (2 pinned, 2 unpinned). Index 2 selected.
        let middleItem = vm.selectedItem!
        let lastItemId = vm.filteredItems[3].id
        let deletedMiddle = await vm.deleteItem(itemId: middleItem.id)
        assert(deletedMiddle)

        assert(vm.selectedIndex == 2, "FAIL: Selection should remain at index 2")
        assert(vm.selectedItem?.id == lastItemId, "FAIL: Selection should advance to the remaining unpinned item")
        print("✓ Subtest 3B: Deleting middle item preserved index stability.")

        // -----------------------------------------------------------------
        // Subtest 3C: Deleting last item in list
        // -----------------------------------------------------------------
        // Current list has 3 items (2 pinned at [0,1], 1 unpinned at [2]). Index 2 selected.
        let lastItem = vm.selectedItem!
        let expectedFallbackId = vm.filteredItems[1].id // the second pinned item
        let deletedLast = await vm.deleteItem(itemId: lastItem.id)
        assert(deletedLast)

        assert(vm.selectedIndex == 1, "FAIL: Deleting last item must clamp selection to index 1 (got \(vm.selectedIndex))")
        assert(vm.selectedItem?.id == expectedFallbackId, "FAIL: Selection should fall back to previous item at index 1")
        print("✓ Subtest 3C: Deleting last item clamped selection to previous item.")

        // -----------------------------------------------------------------
        // Subtest 3D: Rapid successive deletion stress test
        // -----------------------------------------------------------------
        print("Subtest 3D: Running rapid successive deletion stress test (15 items)...")
        for i in 1...15 {
            let cap = RawCapture(
                timestampMs: nowMs + Int64(i * 10),
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Rapid item \(i)".data(using: .utf8)!)
                ]
            )
            _ = try! await core.ingest(capture: cap)
        }
        await vm.loadData()
        let initialCount = vm.items.count
        assert(initialCount >= 15)

        // Rapidly delete 10 items from currently selected index
        for _ in 1...10 {
            let toDelete = vm.selectedItem!
            let ok = await vm.deleteItem(itemId: toDelete.id)
            assert(ok, "FAIL: Rapid delete failed")
            assert(vm.selectedIndex >= 0 && vm.selectedIndex < vm.items.count, "FAIL: Selection out of bounds during rapid delete")
            assert(vm.selectedItemId == vm.selectedItem?.id, "FAIL: selectedItemId must match selectedItem")
        }
        assert(vm.items.count == initialCount - 10, "FAIL: Exactly 10 items should have been deleted")
        print("✓ Subtest 3D: Rapid successive deletions completed without crash or selection corruption.")

        // -----------------------------------------------------------------
        // Subtest 3E: Deleting all items until 0 remains
        // -----------------------------------------------------------------
        while !vm.items.isEmpty {
            let item = vm.selectedItem!
            _ = await vm.deleteItem(itemId: item.id)
        }
        assert(vm.items.isEmpty, "Items list should now be completely empty")
        assert(vm.selectedIndex == 0, "Selected index must be 0 on empty list")
        assert(vm.selectedItemId == nil, "selectedItemId must be nil on empty list")
        assert(vm.selectedItem == nil, "selectedItem must be nil on empty list")
        print("✓ Subtest 3E: Deleting all items safely transitions to empty state.")

        // =====================================================================
        // Step 4: Pinned-Only, History-Only & Mixed Sectioning (T-UI-10, F-036)
        // =====================================================================
        print("\nStep 4: Testing Pinned-Only, History-Only & Mixed Section Semantics...")

        // Subtest 4A: History-Only List (0 pinned, 3 unpinned)
        for i in 1...3 {
            let cap = RawCapture(
                timestampMs: nowMs + Int64(i * 10),
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Unpinned \(i)".data(using: .utf8)!)
                ]
            )
            _ = try! await core.ingest(capture: cap)
        }
        await vm.loadData()

        assert(vm.hasPinnedItems == false, "FAIL: hasPinnedItems must be false")
        assert(vm.hasUnpinnedItems == true, "FAIL: hasUnpinnedItems must be true")
        assert(vm.hasMixedPinnedAndUnpinned == false, "FAIL: hasMixedPinnedAndUnpinned must be false for history-only list")
        print("✓ Subtest 4A: History-only list state verified (no spurious PINNED/HISTORY headers).")

        // Subtest 4B: Pinned-Only List (3 pinned, 0 unpinned)
        for item in vm.items {
            _ = try! await core.togglePin(itemId: item.id)
        }
        await vm.loadData()

        assert(vm.hasPinnedItems == true, "FAIL: hasPinnedItems must be true")
        assert(vm.hasUnpinnedItems == false, "FAIL: hasUnpinnedItems must be false")
        assert(vm.hasMixedPinnedAndUnpinned == false, "FAIL: hasMixedPinnedAndUnpinned must be false for pinned-only list")
        print("✓ Subtest 4B: Pinned-only list state verified (no spurious separators).")

        // Subtest 4C: Mixed List (3 pinned, 2 unpinned)
        for i in 4...5 {
            let cap = RawCapture(
                timestampMs: nowMs + Int64(i * 100),
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Unpinned \(i)".data(using: .utf8)!)
                ]
            )
            _ = try! await core.ingest(capture: cap)
        }
        await vm.loadData()

        assert(vm.hasPinnedItems == true, "FAIL: hasPinnedItems must be true")
        assert(vm.hasUnpinnedItems == true, "FAIL: hasUnpinnedItems must be true")
        assert(vm.hasMixedPinnedAndUnpinned == true, "FAIL: hasMixedPinnedAndUnpinned must be true for mixed list")
        print("✓ Subtest 4C: Mixed list state verified (clean section headers and single divider).")

        // Subtest 4D: Zero Results Empty State vs Total Empty State
        vm.searchText = "nonexistent_query_xyz"
        assert(vm.items.count == 5, "Total items must be 5")
        assert(vm.filteredItems.isEmpty, "Filtered items must be 0 for nonexistent query")
        assert(vm.selectedItem == nil, "selectedItem must be nil during 0 results")

        vm.searchText = ""
        assert(!vm.filteredItems.isEmpty, "Filtered items restored when search cleared")
        assert(vm.selectedItem != nil, "selectedItem restored")
        print("✓ Subtest 4D: Zero results search state vs total empty state verified.")

        print("\n✓ ALL NAVIGATION SEMANTICS, DELETE STABILITY & SECTION TESTS PASSED CLEANLY!")
    }
}
