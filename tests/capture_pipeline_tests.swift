// ==============================================================================
// Mimra Tests — Capture Pipeline & CoreClient Integration Verification
// Linked Features: F-001, F-002, F-003, F-007, F-012, F-015, F-053
// Test IDs: T-CAP-01, T-CAP-02, T-CAP-03, T-CAP-05, T-PRIV-05, T-HIST-03
// ==============================================================================

import AppKit
import Foundation

@main
struct CapturePipelineTests {
    static func main() async {
        print("=== Running Capture Pipeline & CoreClient Tests ===")

        do {
            // 1. Initialize in-memory CoreClient
            let client = try CoreClient.inMemory()
            print("✓ Initialized in-memory CoreClient")

            // 2. Ingest first plain text item
            let textData = "Line 1: Hello Mimra\nLine 2: Secondary snippet line".data(using: .utf8)!
            let rep1 = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: textData
            )
            let capture1 = RawCapture(
                timestampMs: 1700000000000,
                sourceBundleId: "com.apple.Terminal",
                representations: [rep1]
            )

            let result1 = try await client.ingest(capture: capture1)
            assert(!result1.isDuplicate, "First ingestion must not be a duplicate")
            assert(result1.title == "Line 1: Hello Mimra", "Title must match first line")
            assert(result1.copyCount == 1, "Copy count must start at 1")
            assert(result1.contentKind == "text", "Content kind must be text")
            print("✓ T-CAP-02: Plain text item ingested successfully: \(result1.itemId)")

            // 3. Ingest identical item -> verify deduplication (F-012, T-CAP-05)
            let rep1Dup = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: textData
            )
            let capture1Dup = RawCapture(
                timestampMs: 1700000005000,
                sourceBundleId: "com.google.Chrome",
                representations: [rep1Dup]
            )

            let result1Dup = try await client.ingest(capture: capture1Dup)
            assert(result1Dup.isDuplicate, "Repeated copy must be detected as duplicate")
            assert(result1Dup.itemId == result1.itemId, "Duplicate item ID must match original")
            assert(result1Dup.copyCount == 2, "Copy count must increment to 2")
            print("✓ T-CAP-05: Deduplication and copy count increment verified")

            // 4. Ingest multi-representation item (F-003, F-007, T-CAP-03)
            let htmlData = "<b>Rich formatted content</b>".data(using: .utf8)!
            let plainData = "Rich formatted content".data(using: .utf8)!
            let repPlain = RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: plainData)
            let repHtml = RawRepresentation(groupIndex: 0, uti: "public.html", payload: htmlData)
            let captureMulti = RawCapture(
                timestampMs: 1700000010000,
                sourceBundleId: "com.apple.Safari",
                representations: [repPlain, repHtml]
            )

            let resultMulti = try await client.ingest(capture: captureMulti)
            assert(!resultMulti.isDuplicate, "Multi-rep item must be inserted")
            assert(resultMulti.contentKind == "rich_text", "HTML representation must produce rich_text kind")
            print("✓ T-CAP-03 / T-TYPE-01: Multi-representation rich text captured: \(resultMulti.itemId)")

            // 5. Query history page
            let page = try await client.listPage(limit: 10, offset: 0)
            assert(page.count == 2, "Page must contain exactly 2 distinct items")
            assert(page[0].id == resultMulti.itemId, "Most recent item must be first")
            assert(page[1].id == result1.itemId, "Earlier item must be second")
            print("✓ T-HIST: History pagination and recency ordering verified")

            // 6. Fetch raw payload by UTI
            let fetchedHtml = try await client.fetchPayload(itemId: resultMulti.itemId, uti: "public.html")
            assert(fetchedHtml == htmlData, "Fetched HTML payload must match original bytes")
            print("✓ Payload round-trip verified across FFI boundary")

            // 7. Pin item and test protection against clear-unpinned (F-053, T-HIST-03)
            try await client.setPin(itemId: result1.itemId, isPinned: true, pinKey: "1", pinOrder: 1)
            let pageAfterPin = try await client.listPage(limit: 10, offset: 0)
            assert(pageAfterPin[0].id == result1.itemId, "Pinned item must jump to front of list")
            assert(pageAfterPin[0].isPinned, "Item must be marked as pinned")

            // Clear unpinned
            let clearedCount = try await client.clearUnpinned()
            assert(clearedCount == 1, "Exactly 1 unpinned item must be cleared")

            let pageAfterClear = try await client.listPage(limit: 10, offset: 0)
            assert(pageAfterClear.count == 1, "Only pinned item should remain")
            assert(pageAfterClear[0].id == result1.itemId, "Pinned item was preserved")
            print("✓ T-HIST-03: Pinned item eviction protection verified")

            // 8. Test ClipboardMonitor with mock pasteboard
            let pbName = NSPasteboard.Name("com.mimra.test.monitor.\(UUID().uuidString)")
            let testPb = NSPasteboard(name: pbName)
            let monitor = await MainActor.run {
                ClipboardMonitor(
                    pasteboard: testPb,
                    privacyFilter: PrivacyFilter(),
                    provenanceGuard: ClipboardProvenance(),
                    coreClient: client
                )
            }

            // Write new content to test pasteboard
            testPb.clearContents()
            testPb.setString("Monitored Text via Pasteboard", forType: .string)

            // Let monitor process change
            await MainActor.run {
                monitor.checkForChanges()
            }

            // Wait brief moment for background Task to finish ingestion
            try await Task.sleep(nanoseconds: 100_000_000)

            let finalPage = try await client.listPage(limit: 10, offset: 0)
            let foundMonitored = finalPage.contains { $0.title == "Monitored Text via Pasteboard" }
            assert(foundMonitored, "ClipboardMonitor must ingest text from pasteboard")
            print("✓ T-CAP-01: ClipboardMonitor end-to-end ingestion verified")

            // 9. Storage stats
            let stats = try await client.getStats()
            assert(stats.totalItems == 2, "Expected 2 items in database")
            assert(stats.pinnedItems == 1, "Expected 1 pinned item")
            assert(stats.unpinnedItems == 1, "Expected 1 unpinned item")
            print("✓ Storage stats verified: \(stats.totalItems) total items")

            print("✓ ALL Capture Pipeline & CoreClient Tests PASSED!")
        } catch {
            print("❌ Pipeline test failed with error: \(error)")
            exit(1)
        }
    }
}
