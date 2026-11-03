// ==============================================================================
// Mimra Tests — FTS5 Search Index, Triggers & Pagination Verification
// Linked Features: F-019, F-048
// Test IDs: T-SRCH-01, T-UI-03
// ==============================================================================

import AppKit
import Foundation

@main
struct SearchIndexTests {
    @MainActor
    static func main() async {
        print("=== Running FTS5 Search Index & Pagination Tests (P4-01 / T-SRCH-01) ===")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_search_index_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("search_test.db").path

        do {
            let core = try CoreClient(databasePath: dbPath)

            // 1. Initial Index Integrity
            let initialIntegrity = try await core.checkSearchIndexIntegrity()
            assert(initialIntegrity, "FAIL: Initial FTS5 integrity check must pass")
            print("✓ Step 1: Initial FTS5 index integrity verified")

            // 2. Ingest Test Corpus
            // Item 1: Plain text snippet match for "compiler"
            let cap1 = RawCapture(
                timestampMs: 1000,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Building swift project with native compiler flags".utf8)
                    )
                ]
            )
            let res1 = try await core.ingest(capture: cap1)

            // Item 2: Title match for "Compiler" (should rank higher due to BM25 weight)
            let cap2 = RawCapture(
                timestampMs: 2000,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Compiler Optimization Techniques in Modern Systems".utf8)
                    )
                ]
            )
            let res2 = try await core.ingest(capture: cap2)

            // Item 3: Unicode / German / CJK
            let cap3 = RawCapture(
                timestampMs: 3000,
                sourceBundleId: "com.google.Chrome",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("München Reiseführer und 検索エンジン".utf8)
                    )
                ]
            )
            _ = try await core.ingest(capture: cap3)

            // 3. Prefix & Full-Text Search
            let prefixResults = try await core.searchPage(query: "compil", limit: 10, offset: 0)
            assert(prefixResults.count == 2, "FAIL: Prefix 'compil' should match both items (got \(prefixResults.count))")
            assert(prefixResults[0].id == res2.itemId, "FAIL: Title match (Item 2) must rank first via BM25 weights")
            print("✓ Step 2: Prefix search and BM25 ranking verified (Title > Body)")

            // 4. Safe Query Sanitization (No syntax errors on special FTS characters)
            let messyQueries = [
                "compil*",
                "\"compiler\"",
                "compiler:optimization",
                "compiler (techniques)",
                "AND NOT OR NEAR",
                "***???:::",
                "",
                "   "
            ]
            for query in messyQueries {
                let results = try await core.searchPage(query: query, limit: 10, offset: 0)
                // Messy query should never crash or throw an unhandled SQLite error
                _ = results
            }
            print("✓ Step 3: FTS5 special character sanitization and resilience verified")

            // 5. Unicode / International Search
            let germanResults = try await core.searchPage(query: "München", limit: 10, offset: 0)
            assert(germanResults.count == 1, "FAIL: Unicode search for 'München' must match 1 item")

            let cjkResults = try await core.searchPage(query: "検索", limit: 10, offset: 0)
            assert(cjkResults.count == 1, "FAIL: CJK search for '検索' must match 1 item")
            print("✓ Step 4: Unicode, diacritics, and CJK token search verified")

            // 6. Pinned Precedence in Search Results
            // Pin Item 1 (which had lower BM25 rank)
            try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: nil, pinOrder: 1)
            let pinnedSearchResults = try await core.searchPage(query: "compiler", limit: 10, offset: 0)
            assert(pinnedSearchResults.count == 2, "FAIL: Expected 2 search matches")
            assert(pinnedSearchResults[0].id == res1.itemId, "FAIL: Pinned item must rank first regardless of BM25 score")
            assert(pinnedSearchResults[0].isPinned, "FAIL: First item must have isPinned == true")
            print("✓ Step 5: Pinned precedence over relevance ranking verified")

            // 7. Pagination Stability
            // Ingest 5 items with common keyword "AlphaPagination"
            var paginationIds: [String] = []
            for i in 1...5 {
                let cap = RawCapture(
                    timestampMs: 4000 + Int64(i),
                    sourceBundleId: "com.apple.Finder",
                    representations: [
                        RawRepresentation(
                            groupIndex: 0,
                            uti: "public.utf8-plain-text",
                            payload: Data("AlphaPagination Item Number \(i)".utf8)
                        )
                    ]
                )
                let res = try await core.ingest(capture: cap)
                paginationIds.append(res.itemId)
            }

            let page0 = try await core.searchPage(query: "AlphaPagination", limit: 2, offset: 0)
            let page1 = try await core.searchPage(query: "AlphaPagination", limit: 2, offset: 2)
            let page2 = try await core.searchPage(query: "AlphaPagination", limit: 2, offset: 4)

            assert(page0.count == 2, "FAIL: Page 0 count must be 2")
            assert(page1.count == 2, "FAIL: Page 1 count must be 2")
            assert(page2.count == 1, "FAIL: Page 2 count must be 1")

            let page0Ids = Set(page0.map { $0.id })
            let page1Ids = Set(page1.map { $0.id })
            let page2Ids = Set(page2.map { $0.id })

            assert(page0Ids.isDisjoint(with: page1Ids), "FAIL: Page 0 and Page 1 must be disjoint")
            assert(page1Ids.isDisjoint(with: page2Ids), "FAIL: Page 1 and Page 2 must be disjoint")
            print("✓ Step 6: Paginated search offset and limit stability verified")

            // 8. Dynamic Trigger Deletion & Rebuild
            let beforeDelete = try await core.searchPage(query: "Optimization", limit: 10, offset: 0)
            assert(beforeDelete.count == 1, "FAIL: Expected 1 match before delete")

            let deleted = try await core.deleteItem(itemId: res2.itemId)
            assert(deleted, "FAIL: deleteItem must succeed")

            let afterDelete = try await core.searchPage(query: "Optimization", limit: 10, offset: 0)
            assert(afterDelete.isEmpty, "FAIL: Item must not appear in search results after delete (trigger sync)")

            let integrityAfterDelete = try await core.checkSearchIndexIntegrity()
            assert(integrityAfterDelete, "FAIL: Index integrity check must pass after deletion")

            try await core.rebuildSearchIndex()
            let integrityAfterRebuild = try await core.checkSearchIndexIntegrity()
            assert(integrityAfterRebuild, "FAIL: Index integrity check must pass after rebuild")
            print("✓ Step 7: FTS5 deletion triggers, index integrity, and rebuild verified")

            // 9. PanelViewModel Integration
            let vm = PanelViewModel(coreClient: core)
            await vm.performSearch(query: "AlphaPagination")
            assert(vm.items.count == 5, "FAIL: PanelViewModel.performSearch must populate 5 items")
            assert(vm.selectedIndex == 0, "FAIL: Selection index should reset to 0 after search")
            print("✓ Step 8: PanelViewModel performSearch integration verified")

            try? FileManager.default.removeItem(at: tempDir)
            print("✓ ALL FTS5 Search Index Tests PASSED!")
        } catch {
            print("TEST FAILED WITH ERROR: \(error)")
            exit(1)
        }
    }
}
