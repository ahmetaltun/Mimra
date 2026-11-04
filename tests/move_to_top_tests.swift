// ==============================================================================
// Mimra Tests — Move History Item to Top on Selection / Paste
// Verification: Touch timestamp updates, PasteCoordinator integration,
// PanelViewModel in-memory reordering, pinned stability, and user preference toggle.
// ==============================================================================

import AppKit
import Foundation

@main
struct MoveToTopTests {
    @MainActor
    static func main() async {
        print("=== Running Move History Item to Top Tests ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let core = try! CoreClient.inMemory()
        let testPbName = NSPasteboard.Name("com.mimra.test.movetotop.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: testPbName)
        let provenanceGuard = ClipboardProvenance()

        // ---------------------------------------------------------------------
        // Step 1: Ingest Test Corpus with Distinct Timestamps
        // ---------------------------------------------------------------------
        print("\n--- Step 1: Ingesting Initial Test Corpus ---")
        let cap1 = RawCapture(
            timestampMs: 1000,
            sourceBundleId: "com.apple.Terminal",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Item 1 (Oldest)".data(using: .utf8)!)
            ]
        )
        let res1 = try! await core.ingest(capture: cap1)

        let cap2 = RawCapture(
            timestampMs: 2000,
            sourceBundleId: "com.apple.Safari",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Item 2 (Middle)".data(using: .utf8)!)
            ]
        )
        let res2 = try! await core.ingest(capture: cap2)

        let cap3 = RawCapture(
            timestampMs: 3000,
            sourceBundleId: "com.apple.Notes",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Item 3 (Newest)".data(using: .utf8)!)
            ]
        )
        let res3 = try! await core.ingest(capture: cap3)

        // Verify initial recency order: [Item 3, Item 2, Item 1]
        let initialList = try! await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
        assert(initialList.count == 3, "Expected 3 items")
        assert(initialList[0].id == res3.itemId, "FAIL: Expected Item 3 first, got \(initialList[0].title)")
        assert(initialList[1].id == res2.itemId, "FAIL: Expected Item 2 second, got \(initialList[1].title)")
        assert(initialList[2].id == res1.itemId, "FAIL: Expected Item 1 third, got \(initialList[2].title)")
        assert(initialList[2].copyCount == 1, "Expected copyCount == 1")
        print("✓ Initial chronological order verified: [Item 3, Item 2, Item 1]")

        // ---------------------------------------------------------------------
        // Step 2: Test CoreClient touchItem Promotes to Top in Storage
        // ---------------------------------------------------------------------
        print("\n--- Step 2: CoreClient.touchItem Promotion in Storage ---")
        let touched = try! await core.touchItem(itemId: res1.itemId, timestampMs: 4000)
        assert(touched, "FAIL: touchItem should return true for existing item")

        let touchedList = try! await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
        assert(touchedList[0].id == res1.itemId, "FAIL: Item 1 should now be at the top of history")
        assert(touchedList[1].id == res3.itemId, "FAIL: Item 3 should now be second")
        assert(touchedList[2].id == res2.itemId, "FAIL: Item 2 should now be third")
        assert(touchedList[0].copyCount == 2, "FAIL: copyCount should have incremented to 2")
        print("✓ touchItem elevated Item 1 to top in SQLite: [Item 1, Item 3, Item 2]")

        // ---------------------------------------------------------------------
        // Step 3: Test PasteCoordinator.paste Automatically Promotes Item
        // ---------------------------------------------------------------------
        print("\n--- Step 3: PasteCoordinator.paste Promotes Item ---")
        UserDefaults.standard.set(true, forKey: "moveToTopOnPaste")

        let coordinator = PasteCoordinator(
            coreClient: core,
            pasteboard: pasteboard,
            provenanceGuard: provenanceGuard,
            pasteAutomatically: false, // Copy-only mode to avoid synthetic keystrokes in test
            accessibilityChecker: { true },
            keystrokePoster: { _ in true },
            secureInputChecker: { false },
            passwordFieldChecker: { _ in false },
            frontmostAppProvider: { nil }
        )

        // Paste Item 2 (currently at index 2)
        let pasteResult = try! await coordinator.paste(itemId: res2.itemId, mode: PasteMode.original)
        assert(pasteResult == .copiedOnly(reason: .autoPasteDisabled), "Expected paste result to be copiedOnly")

        let afterPasteList = try! await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
        assert(afterPasteList[0].id == res2.itemId, "FAIL: Item 2 should be at the top after paste, got \(afterPasteList[0].title)")
        assert(afterPasteList[1].id == res1.itemId, "FAIL: Item 1 should be second")
        assert(afterPasteList[2].id == res3.itemId, "FAIL: Item 3 should be third")
        print("✓ PasteCoordinator.paste elevated Item 2 to top: [Item 2, Item 1, Item 3]")

        // ---------------------------------------------------------------------
        // Step 4: Test PanelViewModel.moveItemToTop Optimistic UI Reordering
        // ---------------------------------------------------------------------
        print("\n--- Step 4: PanelViewModel In-Memory Reordering ---")
        let viewModel = PanelViewModel(coreClient: core)
        await viewModel.loadData()
        assert(viewModel.items.count == 3, "Expected 3 items in viewModel")
        assert(viewModel.items[0].id == res2.itemId, "Expected Item 2 first")

        // Select Item 3 (index 2) and commit selection
        viewModel.selectIndex(2, fromHover: false)
        assert(viewModel.selectedItem?.id == res3.itemId, "Expected Item 3 to be selected")
        viewModel.commitSelection()

        // Verify optimistic in-memory reordering moved Item 3 to index 0
        assert(viewModel.items[0].id == res3.itemId, "FAIL: Item 3 should move to top in viewModel.items")
        assert(viewModel.items[1].id == res2.itemId, "FAIL: Item 2 should move to second")
        assert(viewModel.items[2].id == res1.itemId, "FAIL: Item 1 should move to third")
        print("✓ PanelViewModel committed selection immediately reordered items to [Item 3, Item 2, Item 1]")

        // ---------------------------------------------------------------------
        // Step 5: Test Disabled Preference (moveToTopOnPaste = false)
        // ---------------------------------------------------------------------
        print("\n--- Step 5: Disabled Preference (moveToTopOnPaste = false) ---")
        UserDefaults.standard.set(false, forKey: "moveToTopOnPaste")

        // Select Item 1 (at index 2) and commit with preference disabled
        viewModel.selectIndex(2, fromHover: false)
        assert(viewModel.selectedItem?.id == res1.itemId)
        viewModel.commitSelection()

        // Verify Item 1 did NOT move to top
        assert(viewModel.items[0].id == res3.itemId, "FAIL: Top item should still be Item 3 when preference is false")
        assert(viewModel.items[2].id == res1.itemId, "FAIL: Item 1 should remain at index 2")

        // PasteCoordinator should also honor false preference
        _ = try! await coordinator.paste(itemId: res1.itemId, mode: PasteMode.original)
        let listNoMove = try! await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
        assert(listNoMove[0].id != res1.itemId, "FAIL: Storage should not promote Item 1 when moveToTopOnPaste is false")
        print("✓ Disabled preference preserved item positions in both UI and storage")

        // Restore default preference
        UserDefaults.standard.removeObject(forKey: "moveToTopOnPaste")

        // ---------------------------------------------------------------------
        // Step 6: Pinned Items Order Stability
        // ---------------------------------------------------------------------
        print("\n--- Step 6: Pinned Items Order Stability ---")
        // Pin Item 1 as Pin #1
        try! await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: "1", pinOrder: 1)
        await viewModel.loadData()

        assert(viewModel.items[0].isPinned && viewModel.items[0].id == res1.itemId, "Pinned Item 1 must be at index 0")

        // Find Item 3 (which is unpinned and currently at index 2)
        let item3Index = viewModel.items.firstIndex(where: { $0.id == res3.itemId })!
        assert(item3Index > 0, "Item 3 should be below pinned items")

        // Choose Item 3
        viewModel.selectIndex(item3Index, fromHover: false)
        viewModel.commitSelection()

        // Item 1 (pinned) must remain at index 0; Item 3 should be top of unpinned items (index 1)
        assert(viewModel.items[0].isPinned && viewModel.items[0].id == res1.itemId, "Pinned item 1 must remain at top")
        assert(viewModel.items[1].id == res3.itemId, "Item 3 must be first unpinned item")
        print("✓ Pinned items order preserved while unpinned items reorder to top")

        print("\n=== ALL MOVE TO TOP TESTS PASSED SUCCESSFULLY! ===")
    }
}
