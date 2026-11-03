// ==============================================================================
// Mimra Tests — Sorting, Pinned Arrangement, Highlight Styles, and Selection Stability
// Linked Features: F-019, F-024, F-048, F-050, F-054
// Test IDs: T-UI-03, T-KEY-03, T-SRCH-01, T-SRCH-02
// ==============================================================================

import AppKit
import Foundation

@main
struct SortingHighlightTests {
    @MainActor
    static func main() async {
        print("=== Running Sorting, Pinned Arrangement & Selection Stability Tests (P4-04 / T-UI-03, T-KEY-03) ===")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_sort_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("sort_test.db").path

        do {
            let core = try CoreClient(databasePath: dbPath)

            // -----------------------------------------------------------------
            // 1. Ingest Test Items
            // -----------------------------------------------------------------
            let baseTime = Int64(1_700_000_000_000)

            // Item 1: Oldest capture (t = baseTime + 1000)
            let cap1 = RawCapture(
                timestampMs: baseTime + 1000,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Alpha Command Terminal Syntax".utf8)
                    )
                ]
            )
            let res1 = try await core.ingest(capture: cap1)

            // Item 2: Mid-age capture, multiple recopies (t = baseTime + 2000, copyCount will increase)
            let cap2 = RawCapture(
                timestampMs: baseTime + 2000,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Beta Browser Website URL".utf8)
                    )
                ]
            )
            let res2 = try await core.ingest(capture: cap2)
            // Re-copy Item 2 three times to increase its copy count
            _ = try await core.ingest(capture: cap2)
            _ = try await core.ingest(capture: cap2)
            _ = try await core.ingest(capture: cap2)

            // Item 3: Newest unpinned capture (t = baseTime + 3000)
            let cap3 = RawCapture(
                timestampMs: baseTime + 3000,
                sourceBundleId: "com.apple.Notes",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Gamma Meeting Notes and Action Items".utf8)
                    )
                ]
            )
            let res3 = try await core.ingest(capture: cap3)

            // Item 4: Pinned capture (t = baseTime + 1500)
            let cap4 = RawCapture(
                timestampMs: baseTime + 1500,
                sourceBundleId: "com.apple.TextEdit",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Delta Pinned Secret Token 42".utf8)
                    )
                ]
            )
            let res4 = try await core.ingest(capture: cap4)
            try await core.setPin(itemId: res4.itemId, isPinned: true, pinKey: "1", pinOrder: 1)

            print("✓ Step 1: Ingested test corpus with timestamps, recopies, and pinned status")

            // -----------------------------------------------------------------
            // 2. Test listPageWithSort: PinArrangement (Top, Bottom, Inline)
            // -----------------------------------------------------------------
            // Top: Pinned first (Delta), then Gamma (3000), Beta (2000), Alpha (1000)
            let topList = try await core.listPageWithSort(
                sortMode: .recency,
                pinArrangement: .top,
                limit: 10,
                offset: 0
            )
            assert(topList.count == 4, "Must have 4 items")
            assert(topList[0].id == res4.itemId, "Top arrangement: Pinned item must be first")
            assert(topList[1].id == res3.itemId, "Top arrangement: Newest unpinned must be second")
            assert(topList[2].id == res2.itemId, "Top arrangement: Mid-age unpinned must be third")
            assert(topList[3].id == res1.itemId, "Top arrangement: Oldest unpinned must be fourth")

            // Bottom: Gamma (3000), Beta (2000), Alpha (1000), Pinned last (Delta)
            let bottomList = try await core.listPageWithSort(
                sortMode: .recency,
                pinArrangement: .bottom,
                limit: 10,
                offset: 0
            )
            assert(bottomList.count == 4, "Must have 4 items")
            assert(bottomList[0].id == res3.itemId, "Bottom arrangement: Newest unpinned must be first")
            assert(bottomList[1].id == res2.itemId, "Bottom arrangement: Mid-age unpinned must be second")
            assert(bottomList[2].id == res1.itemId, "Bottom arrangement: Oldest unpinned must be third")
            assert(bottomList[3].id == res4.itemId, "Bottom arrangement: Pinned item must be last")

            // Inline: Gamma (3000), Beta (2000), Delta (1500), Alpha (1000)
            let inlineList = try await core.listPageWithSort(
                sortMode: .recency,
                pinArrangement: .inline,
                limit: 10,
                offset: 0
            )
            assert(inlineList.count == 4, "Must have 4 items")
            assert(inlineList[0].id == res3.itemId, "Inline arrangement: Gamma (3000) first")
            assert(inlineList[1].id == res2.itemId, "Inline arrangement: Beta (2000) second")
            assert(inlineList[2].id == res4.itemId, "Inline arrangement: Delta (1500) third")
            assert(inlineList[3].id == res1.itemId, "Inline arrangement: Alpha (1000) fourth")

            print("✓ Step 2: PinArrangement (Top, Bottom, Inline) verified")

            // -----------------------------------------------------------------
            // 3. Test listPageWithSort: HistorySortMode (Recency, CopyCount, FirstCopied)
            // -----------------------------------------------------------------
            // CopyCount with Top arrangement:
            // Pinned first (Delta), then Beta (copy_count = 4), then Gamma / Alpha
            let countList = try await core.listPageWithSort(
                sortMode: .copyCount,
                pinArrangement: .top,
                limit: 10,
                offset: 0
            )
            assert(countList[0].id == res4.itemId, "Pinned item first")
            assert(countList[1].id == res2.itemId, "Beta item with 4 copies must be first unpinned")

            // FirstCopied with Top arrangement:
            // Pinned first, then newest first-capture Gamma (3000), then Beta (2000), then Alpha (1000)
            let firstCopiedList = try await core.listPageWithSort(
                sortMode: .firstCopied,
                pinArrangement: .top,
                limit: 10,
                offset: 0
            )
            assert(firstCopiedList[0].id == res4.itemId, "Pinned item first")
            assert(firstCopiedList[1].id == res3.itemId, "Gamma first copied at 3000 must be first unpinned")
            assert(firstCopiedList[2].id == res2.itemId, "Beta first copied at 2000 must be second unpinned")
            assert(firstCopiedList[3].id == res1.itemId, "Alpha first copied at 1000 must be third unpinned")

            print("✓ Step 3: HistorySortMode (Recency, CopyCount, FirstCopied) verified")

            // -----------------------------------------------------------------
            // 4. Test searchPageWithOptions: Relevance vs Recency & Pinned Placement
            // -----------------------------------------------------------------
            // Search query "Token" matches Delta (Secret Token)
            let tokenMatches = try await core.searchPageWithOptions(
                query: "Token",
                mode: .fuzzy,
                sortByRelevance: true,
                pinArrangement: .top,
                limit: 10,
                offset: 0
            )
            assert(tokenMatches.count == 1, "Must find 1 token match")
            assert(tokenMatches[0].id == res4.itemId)

            // Search query matching multiple items:
            // Query "Terminal" matches Alpha (title starts with Alpha Command Terminal Syntax)
            // and we can search "Syntax" or single letter
            let searchResults = try await core.searchPageWithOptions(
                query: "Syntax",
                mode: .fuzzy,
                sortByRelevance: true,
                pinArrangement: .top,
                limit: 10,
                offset: 0
            )
            assert(searchResults.count >= 1, "Must find match")
            assert(searchResults[0].id == res1.itemId)

            print("✓ Step 4: searchPageWithOptions verified")

            // -----------------------------------------------------------------
            // 5. Test SearchHighlightStyle Enum Fidelity
            // -----------------------------------------------------------------
            assert(SearchHighlightStyle.bold.rawValue == "bold")
            assert(SearchHighlightStyle.underline.rawValue == "underline")
            assert(SearchHighlightStyle.italic.rawValue == "italic")
            assert(SearchHighlightStyle.boldUnderline.rawValue == "boldUnderline")
            assert(SearchHighlightStyle.accent.rawValue == "accent")
            assert(SearchHighlightStyle.none.rawValue == "none")

            for style in SearchHighlightStyle.allCases {
                assert(!style.displayName.isEmpty, "Display name for \(style) must not be empty")
                let roundtripped = SearchHighlightStyle(rawValue: style.rawValue)
                assert(roundtripped == style, "Raw value roundtrip must equal original")
            }

            print("✓ Step 5: SearchHighlightStyle enum cases and display names verified")

            // -----------------------------------------------------------------
            // 6. Test PanelViewModel DoD: Selection Remains on Same ID on Updates
            // -----------------------------------------------------------------
            let viewModel = PanelViewModel(coreClient: core)
            await viewModel.loadData()

            assert(viewModel.items.count == 4, "Must have 4 loaded items")
            assert(viewModel.selectedIndex == 0, "Default selection is index 0")

            // Select index 2 (item res2 - Beta Browser Website URL)
            viewModel.selectIndex(2)
            let selectedBefore = viewModel.selectedItem
            assert(selectedBefore?.id == res2.itemId, "Must have selected res2 at index 2")
            assert(viewModel.selectedItemId == res2.itemId, "selectedItemId must be res2.itemId")

            // Simulate incoming new capture in the background (P4-04 DoD test)
            let capNew = RawCapture(
                timestampMs: baseTime + 5000,
                sourceBundleId: "com.apple.Finder",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Zeta Incoming Copy Event".utf8)
                    )
                ]
            )
            _ = try await core.ingest(capture: capNew)

            // Reload data in viewModel (as triggered by mimraClipboardDidIngest notification)
            await viewModel.loadData()

            // VERIFY DoD: The item ID remained EXACTLY res2.itemId!
            assert(viewModel.items.count == 5, "Must now have 5 items")
            assert(viewModel.selectedItem?.id == res2.itemId, "DoD VIOLATION: selectedItem ID must remain res2.itemId on updates!")
            // Its index shifted from 2 to 3 because Zeta was inserted
            assert(viewModel.selectedIndex == 3, "Index must shift to 3 to follow the item ID")
            assert(viewModel.selectedItemId == res2.itemId, "selectedItemId must remain res2.itemId")

            print("✓ Step 6: Definition of Done VERIFIED: selection remains on same ID on incoming updates")

            // -----------------------------------------------------------------
            // 7. Test Deletion Stability (T-KEY-03): Deleting Other Item
            // -----------------------------------------------------------------
            // Currently selecting res2 (index 3). Now delete res3 (Gamma, which is index 2 above res2)
            let deletedAbove = await viewModel.deleteItem(itemId: res3.itemId)
            assert(deletedAbove, "Delete must succeed")
            assert(viewModel.items.count == 4, "Item count decreased to 4")

            // VERIFY DoD: Selection MUST STILL be on res2.itemId!
            assert(viewModel.selectedItem?.id == res2.itemId, "DoD: selectedItem ID must remain res2.itemId after deleting other item")
            assert(viewModel.selectedIndex == 2, "Index must adapt to 2 to follow res2.itemId")

            print("✓ Step 7: Selection remains on same ID when another item is deleted")

            // -----------------------------------------------------------------
            // 8. Test Deleting Selected Item: Stays at Same Visual Position (T-KEY-03)
            // -----------------------------------------------------------------
            // Currently selecting res2 at index 2.
            // Items are: [Delta (pin), Zeta, Beta (res2), Alpha].
            // If we delete res2, the selection should remain at index 2 (which will now be Alpha),
            // NOT jump wildly to 0 or crash!
            let deletedSelected = await viewModel.deleteSelectedItem()
            assert(deletedSelected, "Delete must succeed")
            assert(viewModel.items.count == 3, "Count is now 3")
            assert(viewModel.selectedIndex == 2, "Index must stay at 2 (visual position stability)")
            assert(viewModel.selectedItem?.id == res1.itemId, "Item at index 2 is now Alpha (res1)")

            print("✓ Step 8: Deleting selected item preserves visual row position without jumping to 0")

            // -----------------------------------------------------------------
            // 9. Test Deleting Bottom-Most Item: Steps Up Smoothly
            // -----------------------------------------------------------------
            // Currently selecting index 2 (Alpha, bottom item in 3-item list).
            // Deleting it should clamp selection to index 1 (new bottom).
            let deletedBottom = await viewModel.deleteSelectedItem()
            assert(deletedBottom, "Delete must succeed")
            assert(viewModel.items.count == 2, "Count is now 2")
            assert(viewModel.selectedIndex == 1, "Index must clamp to new bottom (1)")
            assert(viewModel.selectedItem != nil, "Selected item must exist")

            print("✓ Step 9: Deleting bottom-most item steps up smoothly to new bottom")

            // -----------------------------------------------------------------
            // 10. Test Page Up, Page Down, Home, End Navigation (T-KEY-03)
            // -----------------------------------------------------------------
            // Add 10 dummy items to test paging
            for i in 1...10 {
                let dCap = RawCapture(
                    timestampMs: baseTime + 10_000 + Int64(i * 100),
                    sourceBundleId: "com.apple.Terminal",
                    representations: [
                        RawRepresentation(
                            groupIndex: 0,
                            uti: "public.utf8-plain-text",
                            payload: Data("Paging Dummy Item #\(i)".utf8)
                        )
                    ]
                )
                _ = try await core.ingest(capture: dCap)
            }
            await viewModel.loadData()
            assert(viewModel.items.count >= 12, "Must have at least 12 items")

            // Select first (Home)
            viewModel.selectFirst()
            assert(viewModel.selectedIndex == 0, "selectFirst must select index 0")

            // Select last (End)
            viewModel.selectLast()
            let lastIndex = viewModel.items.count - 1
            assert(viewModel.selectedIndex == lastIndex, "selectLast must select last index")

            // Page Up by 5
            viewModel.selectPageUp(pageSize: 5)
            assert(viewModel.selectedIndex == lastIndex - 5, "selectPageUp must decrease index by pageSize")

            // Page Up clamped to 0
            viewModel.selectPageUp(pageSize: 50)
            assert(viewModel.selectedIndex == 0, "selectPageUp must clamp to 0")

            // Page Down by 4
            viewModel.selectPageDown(pageSize: 4)
            assert(viewModel.selectedIndex == 4, "selectPageDown must increase index by pageSize")

            // Page Down clamped to lastIndex
            viewModel.selectPageDown(pageSize: 50)
            assert(viewModel.selectedIndex == lastIndex, "selectPageDown must clamp to lastIndex")

            print("✓ Step 10: Page Up / Page Down / Home / End navigation verified")

            // -----------------------------------------------------------------
            // Clean up
            // -----------------------------------------------------------------
            try? FileManager.default.removeItem(at: tempDir)
            print("✓ Cleaned up temporary test directory")

        } catch {
            print("❌ Unexpected error during SortingHighlightTests: \(error)")
            exit(1)
        }

        print("----------------------------------------------------------------------")
        print("ALL SORTING, PIN ARRANGEMENT & SELECTION STABILITY TESTS (P4-04) PASSED!")
        print("----------------------------------------------------------------------")
    }
}
