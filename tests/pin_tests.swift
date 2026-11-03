// ==============================================================================
// Mimra — Pinning & Advanced Keyboard Operations Integration Tests
// Linked Features: F-020, F-024, F-036, F-053
// Test IDs: T-PIN-01, T-HIST-03, T-KEY-01
// Verification: Pin/unpin state transitions, stable pinned section, shortcuts,
// restart survival, retention eviction immunity, and clear-unpinned protection.
// ==============================================================================

import Foundation
import AppKit

@main
struct PinTests {
    @MainActor
    static func main() async {
        print("--- Mimra Pinning & Keyboard Integration Tests (P5-01 / F-020, F-024, F-053) ---")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("pin_test.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        do {
            print("\nStep 1: Verify Initial Ingestion & Atomic Pin Toggling...")
            var core = try CoreClient(databasePath: dbPath)

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            // Ingest Item 1 (unpinned)
            let capture1 = RawCapture(
                timestampMs: nowMs,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Item 1 Text".data(using: .utf8)!)
                ]
            )
            let res1 = try await core.ingest(capture: capture1)

            // Ingest Item 2 (unpinned)
            let capture2 = RawCapture(
                timestampMs: nowMs + 100,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Item 2 Text".data(using: .utf8)!)
                ]
            )
            let res2 = try await core.ingest(capture: capture2)

            // Initially both are unpinned
            var page = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            assert(page.count == 2, "Expected 2 items in history")
            assert(!page[0].isPinned, "Item should start unpinned")
            assert(!page[1].isPinned, "Item should start unpinned")

            // Toggle pin on Item 1 -> becomes pinned
            let pinned1 = try await core.togglePin(itemId: res1.itemId)
            assert(pinned1 == true, "togglePin should return true when item becomes pinned")

            page = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            assert(page[0].id == res1.itemId, "Pinned item 1 must appear at top of list")
            assert(page[0].isPinned, "Item 1 must be marked pinned")
            assert(page[0].pinOrder == 0, "Item 1 should have pinOrder = 0")
            print("✓ Atomic pin toggling successfully set Item 1 as pinned at the top.")

            print("\nStep 2: Verify Pin Order, Pin Key Assignment & Collision Guard...")
            // Assign custom pinKey "k" to Item 1
            try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: "k", pinOrder: 0)
            page = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            assert(page[0].pinKey == "k", "Item 1 must have pinKey 'k'")

            // Pin Item 2 with a duplicate pinKey "k" -> must fail due to unique constraint
            var collisionCaught = false
            do {
                try await core.setPin(itemId: res2.itemId, isPinned: true, pinKey: "k", pinOrder: 1)
            } catch {
                collisionCaught = true
            }
            assert(collisionCaught, "Assigning duplicate pinKey must trigger a unique constraint error")

            // Pin Item 2 with distinct pinKey "x" -> succeeds
            try await core.setPin(itemId: res2.itemId, isPinned: true, pinKey: "x", pinOrder: 1)
            page = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            assert(page.count == 2, "Both items should exist")
            assert(page[0].pinOrder == 0 && page[0].pinKey == "k", "Item 1 has order 0 and key 'k'")
            assert(page[1].pinOrder == 1 && page[1].pinKey == "x", "Item 2 has order 1 and key 'x'")
            print("✓ Pin order and unique shortcut assignment verified.")

            print("\nStep 3: Verify Unpinning Clears Pin Order & Shortcut Constraint...")
            // Unpin Item 1
            let unpinned1 = try await core.togglePin(itemId: res1.itemId)
            assert(unpinned1 == false, "togglePin should return false when item is unpinned")

            page = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            let unpinnedItem1 = page.first(where: { $0.id == res1.itemId })!
            assert(!unpinnedItem1.isPinned, "Item 1 must not be pinned")
            assert(unpinnedItem1.pinOrder == nil, "Unpinned item must have nil pinOrder")
            assert(unpinnedItem1.pinKey == nil, "Unpinned item must have nil pinKey")

            // Now reassigning "k" to Item 2 succeeds because Item 1 was unpinned and released the key
            try await core.setPin(itemId: res2.itemId, isPinned: true, pinKey: "k", pinOrder: 0)
            page = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            let updatedItem2 = page.first(where: { $0.id == res2.itemId })!
            assert(updatedItem2.pinKey == "k", "Item 2 now holds pinKey 'k'")
            print("✓ Unpinning cleanly releases pinKey constraint and clears pinOrder.")

            print("\nStep 4: Verify Retention Eviction Protection (DoD Requirement)...")
            // Configure capacity to max 3 unpinned items
            await core.setMaxUnpinned(limit: 3)

            // Ingest 6 unpinned items while Item 2 is pinned
            var unpinnedIds: [String] = []
            for i in 1...6 {
                let capture = RawCapture(
                    timestampMs: nowMs + 1000 + Int64(i * 100),
                    sourceBundleId: "com.apple.Safari",
                    representations: [
                        RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Churn Item \(i)".data(using: .utf8)!)
                    ]
                )
                let res = try await core.ingest(capture: capture)
                unpinnedIds.append(res.itemId)
            }

            // Ingestion with maxUnpinned = 3 should have immediately evicted older unpinned items
            var stats = try await core.getStats()
            assert(stats.pinnedItems == 1, "Expected exactly 1 pinned item retained during ingestion churn")
            assert(stats.unpinnedItems <= 3, "Unpinned items must be capped at 3 during ingestion churn")

            // Now lower policy to max 1 and manually enforce retention
            let report = try await core.enforceRetention(policy: RetentionPolicyDto(maxCount: 1, maxAgeDays: nil, maxSizeBytes: nil))
            assert(report.evictedByCount > 0, "Excess unpinned items must be evicted when policy tightened")

            stats = try await core.getStats()
            assert(stats.pinnedItems == 1, "Pinned item 2 must NEVER be evicted under tighter retention")
            assert(stats.unpinnedItems == 1, "Unpinned items strictly capped at 1")

            page = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 20, offset: 0)
            assert(page.contains(where: { $0.id == res2.itemId && $0.isPinned }), "Pinned item 2 must survive retention eviction")
            print("✓ Pinned item 2 survived heavy capacity churn and policy tightening without eviction.")

            print("\nStep 5: Verify Clear-Unpinned Protection (DoD Requirement)...")
            let clearedCount = try await core.clearUnpinned()
            assert(clearedCount > 0, "clearUnpinned should clear unpinned items")

            let statsAfterClear = try await core.getStats()
            assert(statsAfterClear.unpinnedItems == 0, "All unpinned items must be cleared")
            assert(statsAfterClear.pinnedItems == 1, "Pinned item must remain intact")

            page = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            assert(page.count == 1, "Only pinned item should remain")
            assert(page[0].id == res2.itemId, "Retained item must be Item 2")
            assert(page[0].pinKey == "k", "Retained item pinKey 'k' must be preserved")
            print("✓ Pinned item survived clearUnpinned completely intact.")

            print("\nStep 6: Verify Persistence Across Relaunch / Restart (DoD Requirement)...")
            // Release existing core instance and create new instance pointing to same file
            core = try CoreClient(databasePath: dbPath)

            let statsReopened = try await core.getStats()
            assert(statsReopened.pinnedItems == 1, "Pinned item count must survive relaunch")
            assert(statsReopened.unpinnedItems == 0, "Unpinned count must survive relaunch")

            let reopenedPage = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            assert(reopenedPage.count == 1, "Only pinned item should exist upon reopen")
            assert(reopenedPage[0].id == res2.itemId, "Item 2 identity preserved across restart")
            assert(reopenedPage[0].isPinned, "Pinned state preserved across restart")
            assert(reopenedPage[0].pinKey == "k", "Pin shortcut 'k' preserved across restart")
            assert(reopenedPage[0].pinOrder == 0, "Pin order 0 preserved across restart")
            print("✓ Pinned item and its shortcut/ordering survived full application relaunch.")

            print("\nStep 7: Verify Recopy Duplicate Preserves Pin State...")
            // Recopy the content of Item 2
            let recopyCapture = RawCapture(
                timestampMs: nowMs + 50000,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Item 2 Text".data(using: .utf8)!)
                ]
            )
            let recopyRes = try await core.ingest(capture: recopyCapture)
            assert(recopyRes.isDuplicate == true, "Recopy should be detected as duplicate")
            assert(recopyRes.itemId == res2.itemId, "Duplicate ID must match Item 2")

            let recopyPage = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            assert(recopyPage[0].id == res2.itemId, "Item 2 should remain at the top")
            assert(recopyPage[0].isPinned, "Item 2 must remain pinned after recopy")
            assert(recopyPage[0].pinKey == "k", "Item 2 pinKey must remain 'k'")
            assert(recopyPage[0].copyCount == 2, "Item 2 copyCount incremented to 2")
            print("✓ Duplicate ingestion preserved pinned status, pinKey, and updated copyCount.")

            print("\nStep 8: Verify PanelViewModel Pin Integration & Selection Stability...")
            let viewModel = PanelViewModel(coreClient: core)
            await viewModel.loadData()
            assert(viewModel.items.count == 1, "ViewModel loaded 1 item")
            assert(viewModel.selectedIndex == 0, "First item selected")

            // Ingest an unpinned item
            let captureNew = RawCapture(
                timestampMs: nowMs + 60000,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Brand New Item".data(using: .utf8)!)
                ]
            )
            let resNew = try await core.ingest(capture: captureNew)
            await viewModel.loadData()
            assert(viewModel.items.count == 2, "ViewModel loaded 2 items")

            // Select the unpinned item (index 1)
            viewModel.selectIndex(1)
            assert(viewModel.selectedItem?.id == resNew.itemId, "Unpinned item selected")

            // Toggle pin on the selected item
            let toggledOk = await viewModel.togglePinSelectedItem()
            assert(toggledOk == true, "togglePinSelectedItem succeeded")

            // Selection must be PRESERVED on the newly pinned item even though it moved to pinned position
            assert(viewModel.selectedItem?.id == resNew.itemId, "Selection must stay on the toggled item")
            assert(viewModel.selectedItem?.isPinned == true, "Selected item is now pinned")
            print("✓ PanelViewModel pin toggling preserved active selection and updated view state.")

            print("\nStep 9: Verify Clear-All Clears Both Pinned and Unpinned...")
            let clearedAll = try await core.clearAll()
            assert(clearedAll == 2, "clearAll should clear both pinned items")

            let finalStats = try await core.getStats()
            assert(finalStats.totalItems == 0, "All items cleared")
            assert(finalStats.pinnedItems == 0, "Pinned items cleared on explicit clearAll")
            print("✓ Explicit clearAll successfully cleared both pinned and unpinned items.")

            print("\n✓ ALL PINNING & ADVANCED KEYBOARD INTEGRATION TESTS PASSED (P5-01 / DoD Satisfied)!")
        } catch {
            fatalError("Pin integration test failed: \(error)")
        }
    }
}
