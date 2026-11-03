// ==============================================================================
// Mimra Tests — History Limits, Retention Policy, and Pin Protection
// Linked Features: F-025, F-052, F-053
// Test IDs: T-HIST-01, T-HIST-03, T-HIST-05
// ==============================================================================

import AppKit
import Foundation

@main
struct HistoryLimitTests {
    @MainActor
    static func main() async {
        print("=== Running History Limit & Retention Policy Tests (P4-05 / T-HIST-01, T-HIST-03, T-HIST-05) ===")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_retention_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("retention_test.db").path

        do {
            let core = try CoreClient(databasePath: dbPath)

            // -----------------------------------------------------------------
            // 1. Initial State & Default Policy Verification
            // -----------------------------------------------------------------
            let defaultPolicy = await core.getRetentionPolicy()
            assert(defaultPolicy.maxCount == 200, "Default max count should be 200")
            assert(defaultPolicy.maxAgeDays == nil, "Default max age days should be nil")
            assert(defaultPolicy.maxSizeBytes == nil, "Default max size bytes should be nil")
            print("✓ Step 1: Default retention policy verified")

            // -----------------------------------------------------------------
            // 2. Ingest Corpus with Distinct Ages, Sizes, and Pinned Items
            // -----------------------------------------------------------------
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let oneDayMs: Int64 = 86_400_000

            // Pinned Item 1 (Anchor): created 50 days ago, 12 KB payload
            let pinCap1 = RawCapture(
                timestampMs: nowMs - (50 * oneDayMs),
                sourceBundleId: "com.apple.Notes",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data(repeating: 0x41, count: 12_000) // 12 KB
                    )
                ]
            )
            let pinRes1 = try await core.ingest(capture: pinCap1)
            try await core.setPin(itemId: pinRes1.itemId, isPinned: true, pinKey: "1", pinOrder: 1)

            // Pinned Item 2: created 20 days ago, 8 KB payload
            let pinCap2 = RawCapture(
                timestampMs: nowMs - (20 * oneDayMs),
                sourceBundleId: "com.apple.Notes",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data(repeating: 0x42, count: 8_000) // 8 KB
                    )
                ]
            )
            let pinRes2 = try await core.ingest(capture: pinCap2)
            try await core.setPin(itemId: pinRes2.itemId, isPinned: true, pinKey: "2", pinOrder: 2)

            // Unpinned Item A: 45 days old, 2 KB payload (will be evicted by maxAgeDays = 30)
            let capA = RawCapture(
                timestampMs: nowMs - (45 * oneDayMs),
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Old unpinned item A (45 days old)".utf8)
                    )
                ]
            )
            let resA = try await core.ingest(capture: capA)

            // Unpinned Item B: 15 days old, 6 KB payload
            let capB = RawCapture(
                timestampMs: nowMs - (15 * oneDayMs),
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data(repeating: 0x43, count: 6_000)
                    )
                ]
            )
            let resB = try await core.ingest(capture: capB)

            // Unpinned Item C: 10 days old, 6 KB payload
            let capC = RawCapture(
                timestampMs: nowMs - (10 * oneDayMs),
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data(repeating: 0x44, count: 6_000)
                    )
                ]
            )
            let resC = try await core.ingest(capture: capC)

            // Unpinned Item D: 2 days old, 6 KB payload
            let capD = RawCapture(
                timestampMs: nowMs - (2 * oneDayMs),
                sourceBundleId: "com.apple.TextEdit",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data(repeating: 0x45, count: 6_000)
                    )
                ]
            )
            let resD = try await core.ingest(capture: capD)

            let statsInitial = try await core.getStats()
            assert(statsInitial.pinnedItems == 2, "Must have 2 pinned items")
            assert(statsInitial.unpinnedItems == 4, "Must have 4 unpinned items")
            print("✓ Step 2: Ingested corpus (2 pinned, 4 unpinned)")

            // -----------------------------------------------------------------
            // 3. Test Age Eviction (maxAgeDays = 30)
            // -----------------------------------------------------------------
            // Expected: Item A (45 days old) evicted. Pinned Item 1 (50 days old) PRESERVED!
            let ageReport = try await core.enforceRetention(
                policy: RetentionPolicyDto(maxCount: nil, maxAgeDays: 30, maxSizeBytes: nil)
            )
            assert(ageReport.evictedByAge == 1, "Must evict 1 item by age")
            assert(ageReport.totalEvicted == 1, "Total evicted must be 1")
            assert(ageReport.remainingPinned == 2, "Pinned items must be preserved (2)")
            assert(ageReport.remainingUnpinned == 3, "Unpinned items must be 3 (B, C, D)")

            let itemsAfterAge = try await core.listPage(limit: 10, offset: 0)
            assert(!itemsAfterAge.contains { $0.id == resA.itemId }, "Item A must be evicted")
            assert(itemsAfterAge.contains { $0.id == pinRes1.itemId }, "Pinned item 1 (50 days old) must survive")
            assert(itemsAfterAge.contains { $0.id == pinRes2.itemId }, "Pinned item 2 must survive")
            print("✓ Step 3: Age-based retention verified (pinned items immune to age eviction)")

            // -----------------------------------------------------------------
            // 4. Test Count Eviction (maxCount = 2)
            // -----------------------------------------------------------------
            // Remaining unpinned: B (15 days), C (10 days), D (2 days) -> count 3.
            // Expected: Oldest unpinned Item B evicted; C and D remain. Pinned items PRESERVED!
            let countReport = try await core.enforceRetention(
                policy: RetentionPolicyDto(maxCount: 2, maxAgeDays: nil, maxSizeBytes: nil)
            )
            assert(countReport.evictedByCount == 1, "Must evict 1 item by count")
            assert(countReport.remainingPinned == 2, "Both pinned items preserved")
            assert(countReport.remainingUnpinned == 2, "Unpinned items capped at 2")

            let itemsAfterCount = try await core.listPage(limit: 10, offset: 0)
            assert(!itemsAfterCount.contains { $0.id == resB.itemId }, "Item B must be evicted")
            assert(itemsAfterCount.contains { $0.id == resC.itemId }, "Item C must remain")
            assert(itemsAfterCount.contains { $0.id == resD.itemId }, "Item D must remain")
            assert(itemsAfterCount.contains { $0.id == pinRes1.itemId }, "Pinned item 1 preserved")
            print("✓ Step 4: Count-based retention verified (oldest unpinned evicted, pinned immune)")

            // -----------------------------------------------------------------
            // 5. Test Size Budget Eviction (maxSizeBytes = 7_000)
            // -----------------------------------------------------------------
            // Remaining unpinned: C (6 KB) and D (6 KB) -> total unpinned size = 12 KB.
            // Expected: Oldest unpinned Item C evicted to get under 7 KB; D remains. Pinned items PRESERVED!
            let sizeReport = try await core.enforceRetention(
                policy: RetentionPolicyDto(maxCount: nil, maxAgeDays: nil, maxSizeBytes: 7_000)
            )
            assert(sizeReport.evictedBySize == 1, "Must evict 1 item by size")
            assert(sizeReport.remainingPinned == 2, "Both pinned items preserved")
            assert(sizeReport.remainingUnpinned == 1, "Only Item D remains unpinned")

            let itemsAfterSize = try await core.listPage(limit: 10, offset: 0)
            assert(!itemsAfterSize.contains { $0.id == resC.itemId }, "Item C must be evicted by size budget")
            assert(itemsAfterSize.contains { $0.id == resD.itemId }, "Item D must remain")
            assert(itemsAfterSize.contains { $0.id == pinRes1.itemId }, "Pinned item 1 preserved")
            assert(itemsAfterSize.contains { $0.id == pinRes2.itemId }, "Pinned item 2 preserved")
            print("✓ Step 5: Payload size budget retention verified")

            // -----------------------------------------------------------------
            // 6. Test WAL Checkpoint & Vacuum
            // -----------------------------------------------------------------
            let pages = try await core.checkpointWal()
            try await core.vacuumDatabase()
            let integrityCheck = try await core.checkSearchIndexIntegrity()
            assert(integrityCheck, "Search index integrity must pass after vacuum")
            print("✓ Step 6: WAL checkpoint (pages: \(pages)) and VACUUM passed cleanly")

            // -----------------------------------------------------------------
            // 7. Test clearUnpinned (T-HIST-01 / F-025)
            // -----------------------------------------------------------------
            // Expected: Item D cleared. Both pinned items (pinRes1, pinRes2) PRESERVED!
            let clearedCount = try await core.clearUnpinned()
            assert(clearedCount == 1, "Must clear 1 unpinned item")

            let statsAfterClearUnpinned = try await core.getStats()
            assert(statsAfterClearUnpinned.unpinnedItems == 0, "Unpinned items must be 0")
            assert(statsAfterClearUnpinned.pinnedItems == 2, "Pinned items must STILL be 2")

            let itemsAfterClearUnpinned = try await core.listPage(limit: 10, offset: 0)
            assert(itemsAfterClearUnpinned.count == 2, "List must contain exactly the 2 pinned items")
            assert(itemsAfterClearUnpinned.contains { $0.id == pinRes1.itemId })
            assert(itemsAfterClearUnpinned.contains { $0.id == pinRes2.itemId })
            print("✓ Step 7: clearUnpinned verified: all unpinned cleared, 100% pinned preserved")

            // -----------------------------------------------------------------
            // 8. Test clearAll (T-HIST-01 / F-025)
            // -----------------------------------------------------------------
            // Expected: Full reset. All items (including pinned) cleared!
            let clearedAll = try await core.clearAll()
            assert(clearedAll == 2, "Must clear the remaining 2 pinned items")

            let statsAfterClearAll = try await core.getStats()
            assert(statsAfterClearAll.totalItems == 0, "Total items must be 0")
            assert(statsAfterClearAll.pinnedItems == 0, "Pinned items must be 0")
            assert(statsAfterClearAll.totalRepresentations == 0, "Representations must be 0")

            let itemsEmpty = try await core.listPage(limit: 10, offset: 0)
            assert(itemsEmpty.isEmpty, "History list must be completely empty")
            print("✓ Step 8: clearAll verified: complete reset including pinned items")

            // -----------------------------------------------------------------
            // 9. Post-Clear Integrity Verification
            // -----------------------------------------------------------------
            let finalIntegrity = try await core.checkSearchIndexIntegrity()
            assert(finalIntegrity, "Search index integrity must pass when empty")
            print("✓ Step 9: Post-clear index integrity check passed")

            // Clean up test database directory
            try? FileManager.default.removeItem(at: tempDir)
            print("✓ Cleaned up temporary test directory")

        } catch {
            print("❌ Unexpected error during HistoryLimitTests: \(error)")
            exit(1)
        }

        print("----------------------------------------------------------------------")
        print("ALL HISTORY LIMIT, RETENTION & CLEAR TESTS (P4-05) PASSED!")
        print("----------------------------------------------------------------------")
    }
}
