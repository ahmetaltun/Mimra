// ==============================================================================
// Mimra Tests — Retention Limit 2000 & Multi-Tab Synchronization
// Linked Features: F-025, F-052, F-055
// Test IDs: T-HIST-06
// ==============================================================================

import AppKit
import Foundation

@main
struct RetentionLimit2000Tests {
    @MainActor
    static func main() async {
        print("=== Running Retention Limit 2000 & Persistence Tests (T-HIST-06) ===")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_retention_2000_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("retention_2000.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
            UserDefaults.standard.removeObject(forKey: "retentionMaxCount")
            UserDefaults.standard.removeObject(forKey: "retentionMaxAgeDays")
            UserDefaults.standard.removeObject(forKey: "retentionMaxSizeBytes")
        }

        do {
            // -----------------------------------------------------------------
            // 1. Configure 2,000 items in UserDefaults
            // -----------------------------------------------------------------
            UserDefaults.standard.set(2000, forKey: "retentionMaxCount")
            UserDefaults.standard.set(30, forKey: "retentionMaxAgeDays")
            UserDefaults.standard.set(Int64(100 * 1024 * 1024), forKey: "retentionMaxSizeBytes")

            let core = try CoreClient(databasePath: dbPath)
            core.loadPersistedRetentionPolicy()

            let activePolicy = core.getRetentionPolicy()
            assert(activePolicy.maxCount == 2000, "Active policy maxCount must be 2000, got \(String(describing: activePolicy.maxCount))")
            print("✓ Step 1: Active retention policy synchronized to 2,000 items")

            // -----------------------------------------------------------------
            // 2. Ingest 250 distinct items (surpassing the previous 200 cap)
            // -----------------------------------------------------------------
            print("Step 2: Ingesting 250 distinct items...")
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            for i in 1...250 {
                let payload = "Clipboard item #\(i) payload content with unique text \(UUID().uuidString)".data(using: .utf8)!
                let capture = RawCapture(
                    timestampMs: nowMs + Int64(i * 100),
                    sourceBundleId: "com.apple.Safari",
                    representations: [
                        RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: payload)
                    ]
                )
                _ = try await core.ingest(capture: capture)
            }

            let stats = try await core.getStats()
            assert(stats.totalItems == 250, "Total items must be 250, got \(stats.totalItems)")
            assert(stats.unpinnedItems == 250, "Unpinned items must be 250, got \(stats.unpinnedItems)")

            let fetched = try await core.listPageWithSort(
                sortMode: .recency,
                pinArrangement: .top,
                limit: 2000,
                offset: 0
            )
            assert(fetched.count == 250, "listPageWithSort must return all 250 items, got \(fetched.count)")
            print("✓ Step 2: Successfully ingested 250 items without truncation at 200")

            // -----------------------------------------------------------------
            // 3. Cold restart persistence verification
            // -----------------------------------------------------------------
            print("Step 3: Simulating cold restart and ingesting beyond 250...")
            let reopenedCore = try CoreClient(databasePath: dbPath)
            reopenedCore.loadPersistedRetentionPolicy()

            let reopenedPolicy = reopenedCore.getRetentionPolicy()
            assert(reopenedPolicy.maxCount == 2000, "Reopened engine must maintain 2,000 maxCount")

            // Ingest item #251
            let item251 = RawCapture(
                timestampMs: nowMs + 30000,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Item #251 after cold restart".data(using: .utf8)!)
                ]
            )
            _ = try await reopenedCore.ingest(capture: item251)

            let reopenedStats = try await reopenedCore.getStats()
            assert(reopenedStats.totalItems == 251, "Total items after cold restart ingest must be 251, got \(reopenedStats.totalItems)")
            print("✓ Step 3: Cold restart maintained 2,000 item capacity; total is 251")

            // -----------------------------------------------------------------
            // 4. StorageSettingsViewModel multi-tab synchronization
            // -----------------------------------------------------------------
            print("Step 4: Testing StorageSettingsViewModel and external sync...")
            let storageVm = StorageSettingsViewModel(coreClient: reopenedCore)
            assert(storageVm.maxCount == 2000, "StorageSettingsViewModel must initialize with 2000, got \(storageVm.maxCount)")

            // Update to 1000 via view model
            storageVm.maxCount = 1000
            assert(UserDefaults.standard.integer(forKey: "retentionMaxCount") == 1000, "UserDefaults must be 1000")
            assert(reopenedCore.getRetentionPolicy().maxCount == 1000, "Engine must be updated to 1000")

            // External change to 2000 (e.g. from GeneralSettingsTab)
            UserDefaults.standard.set(2000, forKey: "retentionMaxCount")
            storageVm.reloadFromUserDefaults()
            assert(storageVm.maxCount == 2000, "StorageSettingsViewModel must reload 2000 from UserDefaults")
            assert(reopenedCore.getRetentionPolicy().maxCount == 2000, "Engine must be updated to 2000")
            print("✓ Step 4: StorageSettingsViewModel bi-directional synchronization verified")

            // -----------------------------------------------------------------
            // 5. Explicit downscale retention enforcement
            // -----------------------------------------------------------------
            print("Step 5: Testing downscale eviction when limit is reduced to 50...")
            let cleanupReport = try await reopenedCore.enforceRetention(
                policy: RetentionPolicyDto(maxCount: 50, maxAgeDays: nil, maxSizeBytes: nil)
            )
            assert(cleanupReport.evictedByCount == 201, "Must evict 201 unpinned items (251 - 50)")
            assert(cleanupReport.remainingUnpinned == 50, "Remaining unpinned items must be exactly 50")

            let finalStats = try await reopenedCore.getStats()
            assert(finalStats.totalItems == 50, "Final total items must be 50")
            print("✓ Step 5: Downscale eviction correctly reduced 251 items to 50")

        } catch {
            print("❌ Test failed with error: \(error)")
            exit(1)
        }

        print("=== ALL RETENTION LIMIT 2000 & MULTI-TAB TESTS PASSED! ===")
    }
}
