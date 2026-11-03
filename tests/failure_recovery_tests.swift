// ==============================================================================
// Mimra — Database Failure Recovery & Backup Tests (P4-07 / T-DB-01, F-052, F-055)
// Verifies:
// 1. Resilient recovery from corrupted database file (safe quarantine, no history wipe).
// 2. Data salvaging and fresh DB initialization upon corruption.
// 3. Atomic database backup snapshot generation.
// 4. Safe database restoration from backup.
// 5. Transaction atomicity and zero orphaned records.
// ==============================================================================

import Foundation
import AppKit

@main
struct FailureRecoveryTests {
    @MainActor
    static func main() async {
        print("--- Mimra Database Failure Recovery & Backup Tests (P4-07 / T-DB-01) ---")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("recovery_test.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        do {
            print("\nStep 1: Create initial database and ingest test clips...")
            let core = try CoreClient(databasePath: dbPath)

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let capture1 = RawCapture(
                timestampMs: nowMs,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: "Initial Clip One — Safari notes".data(using: .utf8)!
                    )
                ]
            )
            let res1 = try await core.ingest(capture: capture1)
            try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: "1", pinOrder: 1)

            let capture2 = RawCapture(
                timestampMs: nowMs + 100,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: "Initial Clip Two — Terminal command".data(using: .utf8)!
                    )
                ]
            )
            _ = try await core.ingest(capture: capture2)

            let itemsBefore = try await core.listPage(limit: 10, offset: 0)
            assert(itemsBefore.count == 2, "Expected 2 items before corruption")
            print("✓ Ingested 2 items successfully into initial database")

            print("\nStep 2: Test atomic backup generation...")
            let backupPath = tempDir.appendingPathComponent("backup.sqlite").path
            try await core.backupDatabase(to: backupPath)

            assert(FileManager.default.fileExists(atPath: backupPath), "Backup file must exist on disk")
            let backupAttributes = try FileManager.default.attributesOfItem(atPath: backupPath)
            let backupSize = backupAttributes[.size] as? UInt64 ?? 0
            assert(backupSize > 0, "Backup file size must be non-zero")
            print("✓ Database backup snapshot created successfully (\(backupSize) bytes)")

            print("\nStep 3: Test database integrity verification on healthy database...")
            try await core.verifyIntegrity()
            print("✓ Integrity verification passed on healthy database")

            print("\nStep 4: Intentionally corrupt the primary SQLite database file...")
            // Flush and release current handle by dropping core reference
            _ = try await core.checkpointWal()

            // Overwrite first 64 bytes of the database with garbage to simulate disk corruption
            let corruptBytes = "CORRUPTED_SQLITE_HEADER_GARBAGE_BYTES_1234567890_DAMAGE".data(using: .utf8)!
            let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: dbPath))
            fileHandle.seek(toFileOffset: 0)
            fileHandle.write(corruptBytes)
            fileHandle.closeFile()
            print("✓ Corrupted database file header on disk")

            print("\nStep 5: Relaunch CoreClient on corrupted database (Resilient Recovery)...")
            // Opening resiliently must not crash with fatalError, and must not unconditionally wipe
            let recoveredCore = try CoreClient(databasePath: dbPath)

            let report = recoveredCore.recoveryReport
            assert(report != nil, "Recovery report must be present")
            assert(report!.wasRecovered, "Database must be marked as recovered")
            assert(report!.quarantinedBackupPath != nil, "Quarantined backup path must be set")

            let quarantinePath = report!.quarantinedBackupPath!
            assert(FileManager.default.fileExists(atPath: quarantinePath), "Quarantined file must exist on disk")
            assert(quarantinePath.contains(".corrupt."), "Quarantined path must contain '.corrupt.'")

            // Verify quarantined file still contains our corruption marker (no unconditional wipe)
            let quarantinedData = try Data(contentsOf: URL(fileURLWithPath: quarantinePath))
            let marker = String(data: quarantinedData.prefix(corruptBytes.count), encoding: .utf8)
            assert(marker?.contains("CORRUPTED_SQLITE_HEADER") == true, "Quarantine file must retain original corrupted bytes")
            print("✓ Corrupted database was safely quarantined to: \(quarantinePath)")

            // Verify newly initialized database is 100% operational
            try await recoveredCore.verifyIntegrity()
            print("✓ Recovered database passed integrity verification")

            // Ingest new item into recovered database
            let capture3 = RawCapture(
                timestampMs: nowMs + 200,
                sourceBundleId: "com.apple.Notes",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: "Post-recovery clip — fresh database functioning".data(using: .utf8)!
                    )
                ]
            )
            _ = try await recoveredCore.ingest(capture: capture3)
            let itemsAfterRecovery = try await recoveredCore.listPage(limit: 10, offset: 0)
            assert(!itemsAfterRecovery.isEmpty, "Recovered database must be queryable and contain new clips")
            print("✓ Successfully ingested new clips into recovered database")

            print("\nStep 6: Test database restore from earlier backup (in-place and offline)...")
            // 6a. In-place restore on active handle using SQLite Online Backup API
            try await recoveredCore.restoreFromBackup(backupPath: backupPath)
            try await recoveredCore.verifyIntegrity()

            let inPlaceRestoredItems = try await recoveredCore.listPage(limit: 10, offset: 0)
            assert(inPlaceRestoredItems.count == 2, "In-place restored database must contain exactly the 2 items from backup")
            assert(inPlaceRestoredItems.contains(where: { $0.title.contains("Initial Clip One") }), "Restored database must contain Clip One")
            assert(inPlaceRestoredItems.contains(where: { $0.title.contains("Initial Clip Two") }), "Restored database must contain Clip Two")
            print("✓ In-place live database restore succeeded and matches original snapshot")

            // 6b. Offline database file restoration into a new target path
            let offlineDbPath = tempDir.appendingPathComponent("offline_target.sqlite").path
            try CoreClient.restoreDatabase(from: backupPath, to: offlineDbPath)
            let offlineCore = try CoreClient(databasePath: offlineDbPath)
            try await offlineCore.verifyIntegrity()
            let offlineItems = try await offlineCore.listPage(limit: 10, offset: 0)
            assert(offlineItems.count == 2, "Offline restored database must contain exactly the 2 items from backup")
            print("✓ Offline database restoration succeeded and verified")

            print("\nStep 7: Test transaction rollback atomicity on error...")
            // Empty payload should trigger CoreError.EmptyPayload
            let emptyCapture = RawCapture(
                timestampMs: nowMs + 300,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data()
                    )
                ]
            )
            do {
                _ = try await recoveredCore.ingest(capture: emptyCapture)
                assert(false, "Empty payload ingest must throw CoreError.EmptyPayload")
            } catch {
                print("✓ Empty payload safely rejected with error: \(error)")
            }

            // Verify database remains consistent with no partial writes
            try await recoveredCore.verifyIntegrity()
            let finalItems = try await recoveredCore.listPage(limit: 10, offset: 0)
            assert(finalItems.count == 2, "Database item count must remain unchanged after rejected transaction")
            print("✓ Transaction atomicity verified — zero orphan records")

            print("\n✓ ALL FAILURE RECOVERY, QUARANTINE, BACKUP & RESTORE TESTS PASSED!")
        } catch {
            print("❌ Test failed with error: \(error)")
            exit(1)
        }
    }
}
