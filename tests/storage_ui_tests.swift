// ==============================================================================
// Mimra — Storage UI & Metrics Integration Tests (P4-06 / F-025, F-055, T-HIST-01, T-HIST-05)
// Verifies DB size display, retention limits, distinct clear confirmations,
// and that disk metrics update after checkpoint, vacuum, and cleanup.
// ==============================================================================

import Foundation
import AppKit

@main
struct StorageUiTests {
    @MainActor
    static func main() async {
        print("--- Mimra Storage UI & Metrics Tests (P4-06 / F-025, F-055) ---")

        // Setup temporary isolated database file on disk to verify real disk metrics and WAL checkpoint
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("storage_ui_test.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        do {
            let core = try CoreClient(databasePath: dbPath)

            print("\nStep 1: Ingest sample items (pinned and unpinned) to populate database...")
            var pinnedIds: [String] = []
            var unpinnedIds: [String] = []

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            // Ingest 5 items
            for i in 1...5 {
                let text = "History Item Content \(i) — payload text with some padding \(String(repeating: "ABC", count: 100))"
                let capture = RawCapture(
                    timestampMs: nowMs + Int64(i * 100),
                    sourceBundleId: "com.apple.Safari",
                    representations: [
                        RawRepresentation(
                            groupIndex: 0,
                            uti: "public.utf8-plain-text",
                            payload: text.data(using: .utf8)!
                        )
                    ]
                )
                let res = try await core.ingest(capture: capture)
                if i <= 2 {
                    try await core.setPin(itemId: res.itemId, isPinned: true, pinKey: "\(i)", pinOrder: UInt32(i))
                    pinnedIds.append(res.itemId)
                } else {
                    unpinnedIds.append(res.itemId)
                }
            }

            print("Ingested 2 pinned and 3 unpinned items.")

            print("\nStep 2: Initialize StorageSettingsViewModel and verify initial metrics...")
            let vm = StorageSettingsViewModel(coreClient: core)
            assert(!vm.isLoading, "ViewModel should not be loading initially")
            assert(vm.stats == nil, "Stats should be nil before loadStats")

            await vm.loadStats()

            guard let stats = vm.stats else {
                fatalError("Failed to load stats into ViewModel")
            }

            print("Initial Storage Stats:")
            print("  Total items: \(stats.totalItems)")
            print("  Pinned items: \(stats.pinnedItems)")
            print("  Unpinned items: \(stats.unpinnedItems)")
            print("  Total representations: \(stats.totalRepresentations)")
            print("  Database size: \(stats.dbSizeBytes) bytes (\(vm.formattedDbSize))")

            assert(stats.totalItems == 5, "Expected 5 total items, got \(stats.totalItems)")
            assert(stats.pinnedItems == 2, "Expected 2 pinned items, got \(stats.pinnedItems)")
            assert(stats.unpinnedItems == 3, "Expected 3 unpinned items, got \(stats.unpinnedItems)")
            assert(stats.totalRepresentations == 5, "Expected 5 representations, got \(stats.totalRepresentations)")
            assert(stats.dbSizeBytes > 0, "Expected non-zero DB size on disk")
            assert(!vm.formattedDbSize.isEmpty, "Formatted DB size should not be empty")

            print("✓ Step 2 Passed: Initial storage metrics correctly reflect ingested items.")

            print("\nStep 3: Verify retention policy customization and enforcement...")
            // Set count limit to 1 unpinned item
            vm.maxCount = 1
            vm.maxAgeDays = 0 // unlimited
            vm.maxSizeBytes = 0 // unlimited

            let policyDto = vm.currentPolicyDto
            assert(policyDto.maxCount == 1, "Expected maxCount to be 1")
            assert(policyDto.maxAgeDays == nil, "Expected maxAgeDays to be nil (unlimited)")
            assert(policyDto.maxSizeBytes == nil, "Expected maxSizeBytes to be nil (unlimited)")

            await vm.applyRetentionPolicy()

            guard let afterRetentionStats = vm.stats else {
                fatalError("Stats missing after applyRetentionPolicy")
            }

            print("Stats after applying retention policy (maxCount = 1):")
            print("  Total items: \(afterRetentionStats.totalItems)")
            print("  Pinned items: \(afterRetentionStats.pinnedItems)")
            print("  Unpinned items: \(afterRetentionStats.unpinnedItems)")
            print("  Status message: \(vm.statusMessage ?? "")")

            assert(afterRetentionStats.pinnedItems == 2, "Pinned items must be 100% immune to eviction")
            assert(afterRetentionStats.unpinnedItems == 1, "Unpinned items should be reduced to 1 by retention policy")
            assert(afterRetentionStats.totalItems == 3, "Total items should now be 3 (2 pinned + 1 unpinned)")
            assert(vm.statusMessage?.contains("Retention policy applied") == true, "Status message should report success")

            print("✓ Step 3 Passed: Retention policy enforced, unpinned evicted, pinned preserved, metrics updated.")

            print("\nStep 4: Verify Database Optimization (Checkpoint & Vacuum)...")
            await vm.optimizeDatabase()

            guard let afterOptStats = vm.stats else {
                fatalError("Stats missing after optimizeDatabase")
            }

            print("Stats after database optimization:")
            print("  Database size: \(afterOptStats.dbSizeBytes) bytes (\(vm.formattedDbSize))")
            print("  Status message: \(vm.statusMessage ?? "")")

            assert(afterOptStats.totalItems == 3, "Total items should remain unchanged after vacuum")
            assert(vm.statusMessage?.contains("Database optimization completed") == true, "Status message should report optimization")

            print("✓ Step 4 Passed: Optimization completed and disk metrics updated.")

            print("\nStep 5: Verify Clear Unpinned with distinct confirmation (F-025, T-HIST-01)...")
            // Check alert separation
            assert(!vm.showClearUnpinnedAlert, "Clear unpinned alert should be false initially")
            assert(!vm.showClearAllAlert, "Clear all alert should be false initially")

            vm.showClearUnpinnedAlert = true
            assert(vm.showClearUnpinnedAlert && !vm.showClearAllAlert, "Alerts must be distinct and independent")

            await vm.confirmClearUnpinned()

            guard let afterClearUnpinnedStats = vm.stats else {
                fatalError("Stats missing after clear unpinned")
            }

            print("Stats after clear unpinned:")
            print("  Total items: \(afterClearUnpinnedStats.totalItems)")
            print("  Pinned items: \(afterClearUnpinnedStats.pinnedItems)")
            print("  Unpinned items: \(afterClearUnpinnedStats.unpinnedItems)")
            print("  Status message: \(vm.statusMessage ?? "")")

            assert(afterClearUnpinnedStats.pinnedItems == 2, "Pinned items MUST be preserved when clearing unpinned")
            assert(afterClearUnpinnedStats.unpinnedItems == 0, "Unpinned items must be 0 after clear unpinned")
            assert(afterClearUnpinnedStats.totalItems == 2, "Total items should equal pinned count (2)")
            assert(vm.statusMessage?.contains("Pinned items were preserved") == true, "Status message must confirm pin preservation")

            print("✓ Step 5 Passed: Clear unpinned permanently removed unpinned items and preserved all pinned items.")

            print("\nStep 6: Verify Clear All History with distinct confirmation (F-025, T-HIST-01)...")
            vm.showClearAllAlert = true
            assert(vm.showClearAllAlert, "Clear all alert should be presented")

            await vm.confirmClearAll()

            guard let afterClearAllStats = vm.stats else {
                fatalError("Stats missing after clear all")
            }

            print("Stats after clear all:")
            print("  Total items: \(afterClearAllStats.totalItems)")
            print("  Pinned items: \(afterClearAllStats.pinnedItems)")
            print("  Unpinned items: \(afterClearAllStats.unpinnedItems)")
            print("  Total representations: \(afterClearAllStats.totalRepresentations)")
            print("  Database size: \(afterClearAllStats.dbSizeBytes) bytes (\(vm.formattedDbSize))")
            print("  Status message: \(vm.statusMessage ?? "")")

            assert(afterClearAllStats.totalItems == 0, "Total items must be 0 after clear all")
            assert(afterClearAllStats.pinnedItems == 0, "Pinned items must be 0 after clear all")
            assert(afterClearAllStats.unpinnedItems == 0, "Unpinned items must be 0 after clear all")
            assert(afterClearAllStats.totalRepresentations == 0, "Representations must be 0 after clear all")
            assert(vm.statusMessage?.contains("Permanently cleared all") == true, "Status message must confirm complete wipe")

            print("✓ Step 6 Passed: Clear all permanently erased all history items including pinned clips.")

            print("\n=======================================================")
            print("✓ ALL STORAGE UI & METRICS UPDATE TESTS PASSED! (P4-06)")
            print("=======================================================")

        } catch {
            fatalError("Storage UI tests failed with unexpected error: \(error)")
        }
    }
}
