// ==============================================================================
// Mimra — File Reference & Multi-File URL Tests
// Validates file URL capture, legacy NSFilenamesPboardType mapping,
// multi-item group preservation, Finder pasteboard replay, and vanished-file UX.
// Linked Feature: F-005, F-021
// Test ID: T-TYPE-03, T-PASTE-01, T-PASTE-02
// ==============================================================================

import AppKit
import Foundation

@main
struct FileUrlTests {
    static func main() async {
        print("=== Running File Reference & Multi-File URL Tests (T-TYPE-03) ===")

        let tempDbPath = "/tmp/mimra_file_url_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDbPath)
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-shm")
        }

        do {
            let client = try CoreClient(databasePath: tempDbPath)

            // Create temporary test files on disk
            let tempDir = FileManager.default.temporaryDirectory
            let file1 = tempDir.appendingPathComponent("mimra_doc_\(UUID().uuidString).txt")
            let file2 = tempDir.appendingPathComponent("mimra_report with spaces_\(UUID().uuidString).pdf")
            let file3 = tempDir.appendingPathComponent("mimra_image_\(UUID().uuidString).png")
            let vanishedFile = tempDir.appendingPathComponent("mimra_will_vanish_\(UUID().uuidString).txt")

            try "Sample content 1".write(to: file1, atomically: true, encoding: .utf8)
            try "Sample content 2".write(to: file2, atomically: true, encoding: .utf8)
            try "Sample content 3".write(to: file3, atomically: true, encoding: .utf8)
            try "Vanishing content".write(to: vanishedFile, atomically: true, encoding: .utf8)

            defer {
                try? FileManager.default.removeItem(at: file1)
                try? FileManager.default.removeItem(at: file2)
                try? FileManager.default.removeItem(at: file3)
                try? FileManager.default.removeItem(at: vanishedFile)
            }

            // -----------------------------------------------------------------
            // Test 1: Single File URL Capture & Percent-Decoding
            // -----------------------------------------------------------------
            print("\n--- Test 1: Single File URL Capture & Title Normalization ---")
            let file2UrlString = file2.absoluteString // file:///.../mimra_report%20with%20spaces_...pdf
            let file2Data = file2UrlString.data(using: .utf8)!
            let repFile2 = RawRepresentation(groupIndex: 0, uti: "public.file-url", payload: file2Data)

            let captureSingle = RawCapture(
                timestampMs: 1700000000000,
                sourceBundleId: "com.apple.finder",
                representations: [repFile2]
            )

            let resultSingle = try await client.ingest(capture: captureSingle)
            assert(resultSingle.contentKind == "file_urls", "Item must be classified as file_urls kind")

            let pageSingle = try await client.listPage(limit: 5, offset: 0)
            let singleSummary = pageSingle.first { $0.id == resultSingle.itemId }!
            assert(singleSummary.title.contains("mimra_report with spaces"), "Percent-encoded filename must be decoded in title: '\(singleSummary.title)'")
            print("✓ T-TYPE-03: Single file URL captured with clean decoded title: '\(singleSummary.title)'")

            // -----------------------------------------------------------------
            // Test 2: Multi-Item File URL Capture (Group Order Preservation)
            // -----------------------------------------------------------------
            print("\n--- Test 2: Multi-Item Group Preservation (3 Files) ---")
            let repGroup0 = RawRepresentation(groupIndex: 0, uti: "public.file-url", payload: file1.absoluteString.data(using: .utf8)!)
            let repGroup1 = RawRepresentation(groupIndex: 1, uti: "public.file-url", payload: file2.absoluteString.data(using: .utf8)!)
            let repGroup2 = RawRepresentation(groupIndex: 2, uti: "public.file-url", payload: file3.absoluteString.data(using: .utf8)!)

            let captureMulti = RawCapture(
                timestampMs: 1700000001000,
                sourceBundleId: "com.apple.finder",
                representations: [repGroup0, repGroup1, repGroup2]
            )

            let resultMulti = try await client.ingest(capture: captureMulti)
            assert(resultMulti.contentKind == "file_urls", "Multi-file copy must be classified as file_urls")

            let pageMulti = try await client.listPage(limit: 5, offset: 0)
            let multiSummary = pageMulti.first { $0.id == resultMulti.itemId }!
            assert(multiSummary.title == "3 files", "Multi-file title must reflect item count: '\(multiSummary.title)'")

            let multiReps = try await client.getItemRepresentations(itemId: resultMulti.itemId)
            assert(multiReps.count == 3, "Expected 3 distinct group representations")
            assert(multiReps[0].groupIndex == 0, "Group 0 index preserved")
            assert(multiReps[1].groupIndex == 1, "Group 1 index preserved")
            assert(multiReps[2].groupIndex == 2, "Group 2 index preserved")
            print("✓ T-TYPE-03: Multi-file copy preserved distinct groups and 1..N order: '\(multiSummary.title)'")

            // -----------------------------------------------------------------
            // Test 3: Legacy NSFilenamesPboardType Ingestion
            // -----------------------------------------------------------------
            print("\n--- Test 3: Legacy NSFilenamesPboardType Capture Pipeline ---")
            let customPb = NSPasteboard(name: NSPasteboard.Name("com.mimra.test.files.\(UUID().uuidString)"))
            customPb.clearContents()

            let monitor = await MainActor.run {
                ClipboardMonitor(pasteboard: customPb, coreClient: client)
            }

            // Write real Finder-style file URLs via NSURL writeObjects
            customPb.clearContents()
            let writeOk = customPb.writeObjects([file1 as NSURL, file2 as NSURL])
            assert(writeOk, "Writing NSURLs to pasteboard must succeed")

            await MainActor.run {
                monitor.checkForChanges()
            }
            try await Task.sleep(nanoseconds: 50_000_000)

            let recentPage = try await client.listPage(limit: 5, offset: 0)
            let legacyCaptured = recentPage.first { $0.contentKind == "file_urls" && $0.title == "2 files" }
            assert(legacyCaptured != nil, "Multi-file copy via NSURL writeObjects must be captured and classified as file_urls")
            print("✓ T-TYPE-03 / F-005: Multi-file copy captured and classified as file_urls: '\(legacyCaptured!.title)'")

            // -----------------------------------------------------------------
            // Test 4: Paste Replay (Finder & Legacy Application Compatibility)
            // -----------------------------------------------------------------
            print("\n--- Test 4: Replay to NSPasteboard (Original Mode) ---")
            let replayPb = NSPasteboard(name: NSPasteboard.Name("com.mimra.test.file.replay.\(UUID().uuidString)"))
            replayPb.clearContents()

            let coordinator = await MainActor.run {
                PasteCoordinator(coreClient: client, pasteboard: replayPb)
            }

            // Replay multi-file item
            let writeCount = try await coordinator.writeToPasteboard(itemId: resultMulti.itemId, mode: .original)
            assert(writeCount > 0, "Pasteboard write must increment changeCount")

            // Check NSPasteboard contents: exactly 3 items
            let pastedItems = replayPb.pasteboardItems
            assert(pastedItems?.count == 3, "NSPasteboard must contain exactly 3 items for multi-file copy, got \(pastedItems?.count ?? 0)")

            for (index, pbItem) in pastedItems!.enumerated() {
                assert(pbItem.string(forType: .fileURL) != nil, "Item \(index) must have .fileURL string")
                assert(pbItem.data(forType: .fileURL) != nil, "Item \(index) must have .fileURL data")
                assert(pbItem.data(forType: ClipboardProvenance.provenanceType) != nil, "Item \(index) must have provenance marker")
            }
            print("✓ T-PASTE-01 / T-TYPE-03: Multi-file items faithfully replayed with .fileURL and provenance")

            // -----------------------------------------------------------------
            // Test 5: Plain Paste Mode (Clean POSIX Paths)
            // -----------------------------------------------------------------
            print("\n--- Test 5: Plain Paste Stripping (POSIX Paths) ---")
            replayPb.clearContents()
            _ = try await coordinator.writeToPasteboard(itemId: resultMulti.itemId, mode: .plainText)

            assert(replayPb.pasteboardItems?.count == 1, "Plain mode must write single item")
            let plainItem = replayPb.pasteboardItems![0]
            let plainText = plainItem.string(forType: .string)
            assert(plainText != nil, "Plain mode must set string")
            assert(plainText!.contains(file1.path), "Plain text must contain decoded POSIX path of file 1")
            assert(plainText!.contains(file2.path), "Plain text must contain decoded POSIX path of file 2")
            assert(plainText!.contains("\n"), "Multiple files must be newline-delimited in plain text")
            assert(!plainText!.contains("file://"), "Plain mode must strip file:// URL scheme down to clean POSIX path")
            print("✓ T-PASTE-02 / T-TYPE-03: Plain paste cleanly extracts newline-delimited POSIX paths without URL schemes")

            // -----------------------------------------------------------------
            // Test 6: Vanished-File UX & Resilience
            // -----------------------------------------------------------------
            print("\n--- Test 6: Vanished-File UX & Replay Resilience ---")
            let vanishedUrlString = vanishedFile.absoluteString
            let repVanished = RawRepresentation(groupIndex: 0, uti: "public.file-url", payload: vanishedUrlString.data(using: .utf8)!)
            let captureVanished = RawCapture(timestampMs: 1700000005000, sourceBundleId: "com.apple.finder", representations: [repVanished])
            let resultVanished = try await client.ingest(capture: captureVanished)

            // Now delete the file from disk (simulating user deletion or move)
            try FileManager.default.removeItem(at: vanishedFile)
            assert(!FileManager.default.fileExists(atPath: vanishedFile.path), "File must be deleted from disk")

            // Verify history still has the item and title
            let pageVanished = try await client.listPage(limit: 5, offset: 0)
            let vanishedSummary = pageVanished.first { $0.id == resultVanished.itemId }!
            assert(vanishedSummary.title.contains("mimra_will_vanish"), "Title must be preserved even if file is deleted")

            // Replay original mode must still succeed and write the URL
            replayPb.clearContents()
            let vanishedWriteCount = try await coordinator.writeToPasteboard(itemId: resultVanished.itemId, mode: .original)
            assert(vanishedWriteCount > 0)
            assert(replayPb.pasteboardItems?[0].string(forType: .fileURL) == vanishedUrlString)
            print("✓ T-TYPE-03: Vanished file URL faithfully preserved and replayed without crash")

            // Replay plain mode must still output the path
            replayPb.clearContents()
            _ = try await coordinator.writeToPasteboard(itemId: resultVanished.itemId, mode: .plainText)
            let vanishedPlainText = replayPb.pasteboardItems?[0].string(forType: .string)
            assert(vanishedPlainText == vanishedFile.path, "Plain paste of vanished file must preserve path string: '\(vanishedPlainText ?? "")'")
            print("✓ T-PASTE-02 / T-TYPE-03: No silent path degradation when referencing vanished files")

            print("\n=======================================================")
            print("✓ ALL FILE REFERENCE & MULTI-FILE URL TESTS PASSED!")
            print("=======================================================")

        } catch {
            print("❌ File URL tests failed: \(error)")
            exit(1)
        }
    }
}
