// ==============================================================================
// Mimra Tests — Leak & Retention Stress Test Suite (P8-01)
// Linked Features: F-025, F-052, F-053
// Test IDs: T-HIST-05, T-DB-01
// Verifies stable bounded memory growth, synthetic multi-thousand copy churn,
// guaranteed pin preservation, zero orphan representations, and 100% FK & FTS integrity.
// ==============================================================================

import AppKit
import Foundation
import Darwin

/// Returns the current resident memory size in bytes for the active process.
func getResidentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    if kerr == KERN_SUCCESS {
        return info.resident_size
    }
    return 0
}

@main
struct LeakRetentionStressTests {
    @MainActor
    static func main() async {
        print("=== Running Leak & Retention Stress Tests (P8-01 / T-HIST-05) ===")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_stress_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("stress.sqlite").path

        do {
            let core = try CoreClient(databasePath: dbPath)

            // -----------------------------------------------------------------
            // Step 1: Memory Baseline Measurement
            // -----------------------------------------------------------------
            let initialMemory = getResidentMemoryBytes()
            print("Initial Resident Memory: \(initialMemory / (1024 * 1024)) MB")

            // -----------------------------------------------------------------
            // Step 2: Establish Guaranteed Pinned Items (Anchor Set)
            // -----------------------------------------------------------------
            let baseTime = Int64(Date().timeIntervalSince1970 * 1000) - 100_000_000
            var pinnedIds: [String] = []

            for i in 1...10 {
                let capture = RawCapture(
                    timestampMs: baseTime + Int64(i * 1000),
                    sourceBundleId: "com.apple.Notes",
                    representations: [
                        RawRepresentation(
                            groupIndex: 0,
                            uti: "public.utf8-plain-text",
                            payload: Data("Guaranteed Permanent Pinned Document #\(i)".utf8)
                        )
                    ]
                )
                let res = try await core.ingest(capture: capture)
                try await core.setPin(itemId: res.itemId, isPinned: true, pinKey: "\(i % 10)", pinOrder: UInt32(i))
                pinnedIds.push(res.itemId)
            }
            print("✓ Step 1: Created 10 guaranteed pinned items")

            // -----------------------------------------------------------------
            // Step 3: Configure Strict Retention Policy
            // -----------------------------------------------------------------
            let retentionPolicy = RetentionPolicyDto(
                maxCount: 50,
                maxAgeDays: 14,
                maxSizeBytes: 200_000 // 200 KB cap for unpinned items
            )
            await core.setRetentionPolicy(policy: retentionPolicy)

            // -----------------------------------------------------------------
            // Step 4: Synthetic High-Volume Churn (3,000 Ingestion Cycles)
            // -----------------------------------------------------------------
            let churnCycles = 3000
            let duplicatePool = [
                "Common Repetitive Snippet 1: func test() { return true }",
                "Common Repetitive Snippet 2: https://github.com/mimra/mimra",
                "Common Repetitive Snippet 3: SELECT * FROM items WHERE is_pinned = 1;"
            ]

            print("Executing \(churnCycles) synthetic copy events with 25% duplicate recopies...")
            var midMemory: UInt64 = 0

            for cycle in 1...churnCycles {
                let capture: RawCapture = autoreleasepool {
                    let isDuplicate = (cycle % 4 == 0)
                    let text = isDuplicate
                        ? duplicatePool[cycle % duplicatePool.count]
                        : "Synthetic unique item payload #\(cycle) generated for memory stress verification."

                    return RawCapture(
                        timestampMs: baseTime + Int64(cycle * 100),
                        sourceBundleId: isDuplicate ? "com.apple.Terminal" : "com.apple.Safari",
                        representations: [
                            RawRepresentation(
                                groupIndex: 0,
                                uti: "public.utf8-plain-text",
                                payload: Data(text.utf8)
                            ),
                            RawRepresentation(
                                groupIndex: 0,
                                uti: "public.html",
                                payload: Data("<span>\(text)</span>".utf8)
                            )
                        ]
                    )
                }

                _ = try await core.ingest(capture: capture)

                // Enforce retention every 100 cycles
                if cycle % 100 == 0 {
                    _ = try await core.enforceRetention()
                    _ = try await core.listPage(limit: 50, offset: 0)
                    _ = try await core.searchPage(query: "Synthetic", mode: .fuzzy, limit: 10, offset: 0)
                }

                if cycle == 1500 {
                    midMemory = getResidentMemoryBytes()
                    print("Mid-cycle Resident Memory (1,500 events): \(midMemory / (1024 * 1024)) MB")
                }
            }

            // Final retention enforcement
            let report = try await core.enforceRetention()
            print("✓ Step 4: Churn completed. Evicted by count: \(report.evictedByCount), by size: \(report.evictedBySize)")

            // -----------------------------------------------------------------
            // Step 5: Verification of Pinned Item Preservation
            // -----------------------------------------------------------------
            let finalStats = try await core.getStats()
            assert(finalStats.pinnedItems == 10, "All 10 pinned items must survive 3,000 churn cycles! Found: \(finalStats.pinnedItems)")
            assert(finalStats.unpinnedItems <= 50, "Unpinned items must be capped at <= 50! Found: \(finalStats.unpinnedItems)")

            let allItems = try await core.listPage(limit: 100, offset: 0)
            for pinId in pinnedIds {
                assert(allItems.contains { $0.id == pinId }, "Pinned item \(pinId) was lost during churn!")
            }
            print("✓ Step 5: 100% of pinned items survived churn. Unpinned bounded <= 50.")

            // -----------------------------------------------------------------
            // Step 6: Database Integrity & Orphan Verification
            // -----------------------------------------------------------------
            try await core.verifyIntegrity()
            let ftsIntact = try await core.checkSearchIndexIntegrity()
            assert(ftsIntact, "FTS5 search index integrity must pass cleanly!")
            print("✓ Step 6: PRAGMA foreign_key_check, integrity_check, and FTS5 verification passed (0 orphans).")

            // -----------------------------------------------------------------
            // Step 7: Bounded Memory Growth Check
            // -----------------------------------------------------------------
            let finalMemory = getResidentMemoryBytes()
            print("Final Resident Memory: \(finalMemory / (1024 * 1024)) MB")
            let growthBytes = finalMemory > initialMemory ? (finalMemory - initialMemory) : 0
            let growthMB = growthBytes / (1024 * 1024)
            print("Net Resident Memory Delta: \(growthMB) MB")

            // Stable bounded growth: under 30 MB for 3,000 full ingest/search/retention cycles
            assert(growthMB < 30, "Memory growth (\(growthMB) MB) exceeded acceptable bound of 30 MB!")
            print("✓ Step 7: Memory growth is strictly bounded and stable (\(growthMB) MB < 30 MB threshold).")

            // Clean up test database
            try? FileManager.default.removeItem(at: tempDir)
            print("✓ Cleaned up temporary test directory")

        } catch {
            print("❌ LeakRetentionStressTests failed: \(error)")
            exit(1)
        }

        print("----------------------------------------------------------------------")
        print("ALL LEAK & RETENTION STRESS TESTS (P8-01) PASSED!")
        print("----------------------------------------------------------------------")
    }
}

private extension Array {
    mutating func push(_ element: Element) {
        self.append(element)
    }
}
