// ==============================================================================
// Mimra Tests — Persistence & Relaunch Verification (P1-08)
// Linked Features: F-052
// Test IDs: T-HIST-02
// ==============================================================================

import Foundation

@main
struct PersistenceRelaunchTests {
    static func main() async {
        print("=== Running Persistence & Relaunch Tests (1,000 items) ===")

        let testDbPath = "/tmp/mimra_relaunch_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: testDbPath)
            try? FileManager.default.removeItem(atPath: "\(testDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(testDbPath)-shm")
        }

        do {
            let totalItems = 1000

            // 1. First session: open database and insert 1,000 items
            print("Session 1: Ingesting \(totalItems) synthetic items...")
            var client: CoreClient? = try CoreClient(databasePath: testDbPath)

            // Allow up to 1500 items for this stress test
            await client?.setMaxUnpinned(limit: 1500)

            var pinnedIds: Set<String> = []

            for i in 1...totalItems {
                let payload = "Synthetic item #\(i) content line".data(using: .utf8)!
                let rep = RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: payload)
                let capture = RawCapture(
                    timestampMs: 1700000000000 + Int64(i * 10),
                    sourceBundleId: "com.mimra.test",
                    representations: [rep]
                )

                let result = try await client!.ingest(capture: capture)

                // Pin every 200th item (5 pinned items total)
                if i % 200 == 0 {
                    try await client!.setPin(
                        itemId: result.itemId,
                        isPinned: true,
                        pinKey: "\(i / 200)",
                        pinOrder: UInt32(i / 200)
                    )
                    pinnedIds.insert(result.itemId)
                }
            }

            let initialStats = try await client!.getStats()
            assert(initialStats.totalItems == UInt64(totalItems), "Must have ingested \(totalItems) items")
            assert(initialStats.pinnedItems == 5, "Must have 5 pinned items")
            print("✓ Session 1 completed: \(initialStats.totalItems) items written to SQLite")

            // 2. Simulate complete application termination / shutdown
            client = nil
            print("Session 1 terminated. Simulating cold restart...")

            // 3. Session 2: Reopen from disk (crash-safe reopen)
            let reopenedClient = try CoreClient(databasePath: testDbPath)
            let reopenedStats = try await reopenedClient.getStats()

            assert(
                reopenedStats.totalItems == UInt64(totalItems),
                "Total items on reopen (\(reopenedStats.totalItems)) must match original (\(totalItems))"
            )
            assert(
                reopenedStats.pinnedItems == 5,
                "Pinned items count on reopen must match original (5)"
            )

            // Read the first page (pinned items should be at the top)
            let firstPage = try await reopenedClient.listPage(limit: 10, offset: 0)
            assert(firstPage.count == 10, "Page must contain 10 items")

            for i in 0..<5 {
                assert(firstPage[i].isPinned, "Item at index \(i) must be pinned")
                assert(pinnedIds.contains(firstPage[i].id), "Pinned item ID must match")
            }

            // Verify order of unpinned items (recency order)
            // Note: item #1000 was pinned because 1000 % 200 == 0, so the most recent unpinned item is #999
            assert(!firstPage[5].isPinned, "Item at index 5 should be unpinned")
            assert(firstPage[5].title == "Synthetic item #999 content line", "Latest unpinned item must be #999")

            print("✓ Session 2 verified: All \(totalItems) items survived cold restart with stable ordering")
            print("✓ ALL Persistence & Relaunch Tests PASSED!")
        } catch {
            print("❌ Persistence relaunch test failed: \(error)")
            exit(1)
        }
    }
}
