// ==============================================================================
// Mimra Tests — Fuzzy Search, Deterministic Ranking, Recency Boost & Highlights
// Linked Features: F-019, F-048
// Test IDs: T-SRCH-01, T-UI-03
// ==============================================================================

import AppKit
import Foundation

@main
struct FuzzySearchTests {
    @MainActor
    static func main() async {
        print("=== Running Fuzzy Search, Ranking & Highlights Tests (P4-02 / T-SRCH-01) ===")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_fuzzy_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("fuzzy_test.db").path

        do {
            let core = try CoreClient(databasePath: dbPath)

            // -----------------------------------------------------------------
            // 1. Ingest Test Corpus
            // -----------------------------------------------------------------
            let now = Date().timeIntervalSince1970
            let nowMs = Int64(now * 1000)

            // Item 1: Acronym candidate "Visual Studio Code" (copied 1 min ago)
            let cap1 = RawCapture(
                timestampMs: nowMs - 60_000,
                sourceBundleId: "com.microsoft.VSCode",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Visual Studio Code modern IDE".utf8)
                    )
                ]
            )
            let res1 = try await core.ingest(capture: cap1)

            // Item 2: Older candidate with exact word "vsc" (copied 10 days ago)
            let cap2 = RawCapture(
                timestampMs: nowMs - (10 * 24 * 3600 * 1000),
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("vsc utility script for deployment".utf8)
                    )
                ]
            )
            let res2 = try await core.ingest(capture: cap2)

            // Item 3: Emoji content "Launch 🚀 mission"
            let cap3 = RawCapture(
                timestampMs: nowMs - 120_000,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Launch 🚀 mission to Mars orbital station".utf8)
                    )
                ]
            )
            let res3 = try await core.ingest(capture: cap3)

            // Item 4: Greek script
            let cap4 = RawCapture(
                timestampMs: nowMs - 180_000,
                sourceBundleId: "com.google.Chrome",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Ελληνικά αβγ κείμενο με σημειώσεις".utf8)
                    )
                ]
            )
            let res4 = try await core.ingest(capture: cap4)

            // Item 5: Cyrillic script
            let cap5 = RawCapture(
                timestampMs: nowMs - 240_000,
                sourceBundleId: "com.apple.Notes",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Привет мир и программирование на Rust".utf8)
                    )
                ]
            )
            let res5 = try await core.ingest(capture: cap5)

            // Item 6: Japanese CJK
            let cap6 = RawCapture(
                timestampMs: nowMs - 300_000,
                sourceBundleId: "com.apple.TextEdit",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("日本語の検索テストクリップボード".utf8)
                    )
                ]
            )
            let res6 = try await core.ingest(capture: cap6)

            // -----------------------------------------------------------------
            // 2. Acronym & Fuzzy Subsequence Matching (vsc -> Visual Studio Code)
            // -----------------------------------------------------------------
            let vscResults = try await core.searchPage(query: "vsc", limit: 10, offset: 0)
            assert(!vscResults.isEmpty, "FAIL: Query 'vsc' should match items")
            // Item 2 has exact word 'vsc', Item 1 matches acronym 'V' 'S' 'C'
            let matchedIds = vscResults.map { $0.id }
            assert(matchedIds.contains(res1.itemId), "FAIL: 'vsc' must match 'Visual Studio Code'")
            assert(matchedIds.contains(res2.itemId), "FAIL: 'vsc' must match 'vsc utility script'")

            // Verify highlight ranges on the acronym match
            if let vscItem = vscResults.first(where: { $0.id == res1.itemId }) {
                assert(!vscItem.titleHighlights.isEmpty, "FAIL: Acronym match must produce title highlights")
                // V at index 0, S at index 7, C at index 14
                let starts = vscItem.titleHighlights.map { $0.start }
                assert(starts.contains(0), "FAIL: 'V' at index 0 should be highlighted")
                assert(starts.contains(7), "FAIL: 'S' at index 7 should be highlighted")
                assert(starts.contains(14), "FAIL: 'C' at index 14 should be highlighted")
            }
            print("✓ Step 1: Acronym & subsequence fuzzy matching with boundary highlights verified")

            // -----------------------------------------------------------------
            // 3. Recency Boost Tie-Breaking
            // -----------------------------------------------------------------
            // Ingest two items with the exact same title, one copied 1 min ago, one copied 3 days ago
            let recentCap = RawCapture(
                timestampMs: nowMs - 60_000,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Identical Query Title Content Recent Copy".utf8)
                    )
                ]
            )
            let recentRes = try await core.ingest(capture: recentCap)

            let oldCap = RawCapture(
                timestampMs: nowMs - (3 * 24 * 3600 * 1000),
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Identical Query Title Content Old Copy".utf8)
                    )
                ]
            )
            let oldRes = try await core.ingest(capture: oldCap)

            let recencyResults = try await core.searchPage(query: "Identical Query Title", limit: 10, offset: 0)
            assert(recencyResults.count >= 2, "FAIL: Expected at least 2 matches")
            assert(recencyResults[0].id == recentRes.itemId, "FAIL: Recently copied item must rank first via recency boost")
            assert(recencyResults[1].id == oldRes.itemId, "FAIL: Older copied item must rank second")
            print("✓ Step 2: Recency boost tie-breaking verified")

            // -----------------------------------------------------------------
            // 4. Emoji / Astral-Plane UTF-16 Highlight Ranges
            // -----------------------------------------------------------------
            let emojiResults = try await core.searchPage(query: "🚀", limit: 10, offset: 0)
            assert(emojiResults.count == 1, "FAIL: Emoji query '🚀' should match 1 item")
            assert(emojiResults[0].id == res3.itemId)
            assert(!emojiResults[0].titleHighlights.isEmpty, "FAIL: Emoji match should produce highlight range")
            let emojiRange = emojiResults[0].titleHighlights[0]
            // "Launch " is 7 UTF-16 code units, 🚀 is 2 code units
            assert(emojiRange.start == 7, "FAIL: Emoji offset should be 7 (got \(emojiRange.start))")
            assert(emojiRange.length == 2, "FAIL: Emoji UTF-16 length should be 2 (got \(emojiRange.length))")
            print("✓ Step 3: Emoji and astral-plane UTF-16 surrogate pair highlights verified")

            // -----------------------------------------------------------------
            // 5. Unicode Non-Latin Script Matching
            // -----------------------------------------------------------------
            // Greek
            let greekResults = try await core.searchPage(query: "αβγ", limit: 10, offset: 0)
            assert(greekResults.count == 1, "FAIL: Greek query 'αβγ' should match 1 item")
            assert(greekResults[0].id == res4.itemId)
            assert(!greekResults[0].titleHighlights.isEmpty)

            // Cyrillic
            let cyrillicResults = try await core.searchPage(query: "Привет", limit: 10, offset: 0)
            assert(cyrillicResults.count == 1, "FAIL: Cyrillic query 'Привет' should match 1 item")
            assert(cyrillicResults[0].id == res5.itemId)
            assert(!cyrillicResults[0].titleHighlights.isEmpty)

            // CJK
            let cjkResults = try await core.searchPage(query: "検索", limit: 10, offset: 0)
            assert(cjkResults.count == 1, "FAIL: Japanese query '検索' should match 1 item")
            assert(cjkResults[0].id == res6.itemId)
            assert(!cjkResults[0].titleHighlights.isEmpty)
            print("✓ Step 4: Non-Latin scripts (Greek, Cyrillic, CJK) search & highlights verified")

            // -----------------------------------------------------------------
            // 6. Pinned Precedence in Fuzzy Search
            // -----------------------------------------------------------------
            // Pin the older item
            try await core.setPin(itemId: oldRes.itemId, isPinned: true, pinKey: nil, pinOrder: 1)
            let pinnedFuzzyResults = try await core.searchPage(query: "Identical Query Title", limit: 10, offset: 0)
            assert(pinnedFuzzyResults[0].id == oldRes.itemId, "FAIL: Pinned item must rank first in fuzzy search")
            assert(pinnedFuzzyResults[0].isPinned, "FAIL: First item must have isPinned == true")
            print("✓ Step 5: Pinned priority over fuzzy recency verified")

            // -----------------------------------------------------------------
            // 7. PanelViewModel Real-Time Search & Highlights Integration
            // -----------------------------------------------------------------
            let vm = PanelViewModel(coreClient: core)
            await vm.performSearch(query: "Visual Studio Code")
            assert(vm.items.count >= 1, "FAIL: ViewModel performSearch should return results")
            assert(vm.items[0].id == res1.itemId)
            assert(!vm.items[0].titleHighlights.isEmpty, "FAIL: ViewModel items must contain title highlights")
            print("✓ Step 6: PanelViewModel real-time search and highlights integration verified")

            try? FileManager.default.removeItem(at: tempDir)
            print("✓ ALL Fuzzy Search, Ranking & Highlights Tests PASSED!")
        } catch {
            print("TEST FAILED WITH ERROR: \(error)")
            exit(1)
        }
    }
}
