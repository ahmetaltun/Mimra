// ==============================================================================
// Mimra — Deduplication Hardening Automated Tests (T-CAP-05, F-012)
// Linked Features: F-012 (Dedupe consecutive/repeated copies reliably)
// ==============================================================================

import AppKit
import Foundation

@main
struct DedupeHardeningTests {
    static func main() async {
        print("----------------------------------------------------------------------")
        print("Starting Deduplication Hardening Tests (T-CAP-05, F-012)")
        print("----------------------------------------------------------------------")

        let tempDbPath = "/tmp/mimra_dedupe_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDbPath)
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-shm")
        }

        do {
            let client = try CoreClient(databasePath: tempDbPath)

            // =========================================================================
            // 1. Google Sheets: Session Churn Deduplication (T-CAP-05, F-012)
            // =========================================================================
            print("1. Testing Google Sheets / Excel HTML Session Churn Deduplication...")

            let sheetsPlainText = "Revenue\t$10,000\nProfit\t$2,500\n"
            let sheetsHtmlV1 = "<google-sheets-html-origin data-session=\"session-1234\"><table><tr><td>Revenue</td><td>$10,000</td></tr></table></google-sheets-html-origin>"
            let sheetsHtmlV2 = "<google-sheets-html-origin data-session=\"session-9876\"><table><tr><td>Revenue</td><td>$10,000</td></tr></table></google-sheets-html-origin>"

            let repPlain1 = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: sheetsPlainText.data(using: .utf8)!
            )
            let repHtml1 = RawRepresentation(
                groupIndex: 0,
                uti: "public.html",
                payload: sheetsHtmlV1.data(using: .utf8)!
            )

            let captureSheets1 = RawCapture(
                timestampMs: 1000,
                sourceBundleId: "com.google.Chrome",
                representations: [repPlain1, repHtml1]
            )

            let outcomeSheets1 = try await client.ingest(capture: captureSheets1)
            assert(!outcomeSheets1.isDuplicate, "First Google Sheets copy must be a new item")
            assert(outcomeSheets1.copyCount == 1, "First copy count must be 1")
            let sheetsItemId = outcomeSheets1.itemId

            // Copy 2: same cell data 5 seconds later with dynamic session ID in HTML
            let repPlain2 = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: sheetsPlainText.data(using: .utf8)!
            )
            let repHtml2 = RawRepresentation(
                groupIndex: 0,
                uti: "public.html",
                payload: sheetsHtmlV2.data(using: .utf8)!
            )

            let captureSheets2 = RawCapture(
                timestampMs: 6000,
                sourceBundleId: "com.google.Chrome",
                representations: [repPlain2, repHtml2]
            )

            let outcomeSheets2 = try await client.ingest(capture: captureSheets2)
            assert(outcomeSheets2.isDuplicate, "Repeated Google Sheets copy must be deduplicated")
            assert(outcomeSheets2.itemId == sheetsItemId, "Deduplicated item ID must match original")
            assert(outcomeSheets2.copyCount == 2, "Copy count must increment to 2")

            // Verify HTML representation payload was updated to session 2
            let sheetsReps = try await client.getItemRepresentations(itemId: sheetsItemId)
            let storedHtmlRep = sheetsReps.first { $0.uti == "public.html" }
            assert(storedHtmlRep != nil, "HTML representation must exist")
            let storedHtmlStr = String(data: storedHtmlRep!.payload, encoding: .utf8)
            assert(storedHtmlStr?.contains("session-9876") == true, "Stored HTML representation must be updated to newest session")
            print("  ✓ Google Sheets HTML churn deduplicated with refreshed HTML payload")

            // =========================================================================
            // 2. Safari URL Variants Deduplication (T-CAP-05, F-006, F-012)
            // =========================================================================
            print("2. Testing Safari URL Variants & Title Upgrade...")

            // 2a. User copies URL with trailing slash from Safari address bar
            let urlTrailingSlash = "https://github.com/rust-lang/rust/"
            let repUrl1 = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: urlTrailingSlash.data(using: .utf8)!
            )
            let captureUrl1 = RawCapture(
                timestampMs: 10000,
                sourceBundleId: "com.apple.Safari",
                representations: [repUrl1]
            )
            let outcomeUrl1 = try await client.ingest(capture: captureUrl1)
            assert(!outcomeUrl1.isDuplicate, "First URL copy must be new item")
            let urlItemId = outcomeUrl1.itemId

            // 2b. User copies via 'Copy Link' with public.url, public.url-name (web page title), and plain text
            let cleanUrl = "https://github.com/rust-lang/rust"
            let pageTitle = "GitHub - rust-lang/rust: Empowering everyone to build reliable software."
            let repPublicUrl = RawRepresentation(
                groupIndex: 0,
                uti: "public.url",
                payload: cleanUrl.data(using: .utf8)!
            )
            let repUrlName = RawRepresentation(
                groupIndex: 0,
                uti: "public.url-name",
                payload: pageTitle.data(using: .utf8)!
            )
            let repUrlPlain2 = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: cleanUrl.data(using: .utf8)!
            )
            let captureUrl2 = RawCapture(
                timestampMs: 15000,
                sourceBundleId: "com.apple.Safari",
                representations: [repPublicUrl, repUrlName, repUrlPlain2]
            )
            let outcomeUrl2 = try await client.ingest(capture: captureUrl2)
            assert(outcomeUrl2.isDuplicate, "Safari link copy must deduplicate with address bar URL")
            assert(outcomeUrl2.itemId == urlItemId, "Item ID must match")
            assert(outcomeUrl2.copyCount == 2, "Copy count must increment to 2")
            assert(outcomeUrl2.title == pageTitle, "Item title must upgrade to rich page title from public.url-name")

            // 2c. User copies with port 443 and upper case host: "HTTPS://GITHUB.COM:443/rust-lang/rust"
            let repUrl3 = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: "HTTPS://GITHUB.COM:443/rust-lang/rust/".data(using: .utf8)!
            )
            let captureUrl3 = RawCapture(
                timestampMs: 20000,
                sourceBundleId: "com.apple.Safari",
                representations: [repUrl3]
            )
            let outcomeUrl3 = try await client.ingest(capture: captureUrl3)
            assert(outcomeUrl3.isDuplicate, "URL with port 443 and case difference must deduplicate")
            assert(outcomeUrl3.itemId == urlItemId, "Item ID must match")
            assert(outcomeUrl3.copyCount == 3, "Copy count must increment to 3")
            print("  ✓ Safari URL variations deduplicated and title upgraded to page title")

            // =========================================================================
            // 3. VS Code: Trailing Whitespace & Newline Deduplication (T-CAP-05, F-012)
            // =========================================================================
            print("3. Testing VS Code Trailing Whitespace & Newline Deduplication...")

            // 3a. Copy full line (Cmd+C with cursor on line -> includes trailing \n)
            let codeWithNewline = "fn calculate_total(items: &[Item]) -> u64 {\n    items.iter().sum()\n}\n"
            let repCode1 = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: codeWithNewline.data(using: .utf8)!
            )
            let captureCode1 = RawCapture(
                timestampMs: 30000,
                sourceBundleId: "com.microsoft.VSCode",
                representations: [repCode1]
            )
            let outcomeCode1 = try await client.ingest(capture: captureCode1)
            assert(!outcomeCode1.isDuplicate, "First code copy must be new item")
            let codeItemId = outcomeCode1.itemId

            // 3b. Copy exact selection without trailing newline
            let codeWithoutNewline = "fn calculate_total(items: &[Item]) -> u64 {\n    items.iter().sum()\n}"
            let repCode2 = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: codeWithoutNewline.data(using: .utf8)!
            )
            let captureCode2 = RawCapture(
                timestampMs: 35000,
                sourceBundleId: "com.microsoft.VSCode",
                representations: [repCode2]
            )
            let outcomeCode2 = try await client.ingest(capture: captureCode2)
            assert(outcomeCode2.isDuplicate, "Code copy without trailing newline must deduplicate")
            assert(outcomeCode2.itemId == codeItemId, "Item ID must match")
            assert(outcomeCode2.copyCount == 2, "Copy count must increment to 2")

            // 3c. Copy selection with trailing line spaces
            let codeWithTrailingSpaces = "fn calculate_total(items: &[Item]) -> u64 {   \n    items.iter().sum()  \n}\n"
            let repCode3 = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: codeWithTrailingSpaces.data(using: .utf8)!
            )
            let captureCode3 = RawCapture(
                timestampMs: 40000,
                sourceBundleId: "com.microsoft.VSCode",
                representations: [repCode3]
            )
            let outcomeCode3 = try await client.ingest(capture: captureCode3)
            assert(outcomeCode3.isDuplicate, "Code copy with trailing spaces must deduplicate")
            assert(outcomeCode3.itemId == codeItemId, "Item ID must match")
            assert(outcomeCode3.copyCount == 3, "Copy count must increment to 3")
            print("  ✓ VS Code line vs selection vs trailing spaces deduplicated")

            // =========================================================================
            // 4. Apple Notes & Multi-Representation Merging (T-CAP-05, F-003, F-012)
            // =========================================================================
            print("4. Testing Multi-Representation Merging & Rich Preservation...")

            let noteText = "Sprint Planning Notes"
            let noteRtf1 = "{\\rtf1\\ansi{\\fonttbl\\f0 Helvetica;}\\pard Sprint Planning Notes}"
            let noteRtf2 = "{\\rtf1\\ansi{\\fonttbl\\f0 Arial;\\f1 Helvetica;}\\pard Sprint Planning Notes}"

            let repNoteText1 = RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: noteText.data(using: .utf8)!)
            let repNoteRtf1 = RawRepresentation(groupIndex: 0, uti: "public.rtf", payload: noteRtf1.data(using: .utf8)!)
            let captureNote1 = RawCapture(
                timestampMs: 50000,
                sourceBundleId: "com.apple.Notes",
                representations: [repNoteText1, repNoteRtf1]
            )
            let outcomeNote1 = try await client.ingest(capture: captureNote1)
            assert(!outcomeNote1.isDuplicate, "First note copy must be new item")
            let noteItemId = outcomeNote1.itemId
            assert(outcomeNote1.contentKind == "rich_text", "Item kind must be rich_text")

            // Copy 2: same note text copied again with different RTF font tables
            let repNoteText2 = RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: noteText.data(using: .utf8)!)
            let repNoteRtf2 = RawRepresentation(groupIndex: 0, uti: "public.rtf", payload: noteRtf2.data(using: .utf8)!)
            let captureNote2 = RawCapture(
                timestampMs: 55000,
                sourceBundleId: "com.apple.Notes",
                representations: [repNoteText2, repNoteRtf2]
            )
            let outcomeNote2 = try await client.ingest(capture: captureNote2)
            assert(outcomeNote2.isDuplicate, "Note copy with different RTF fonttbl must deduplicate")
            assert(outcomeNote2.itemId == noteItemId, "Item ID must match")
            assert(outcomeNote2.copyCount == 2, "Copy count must increment to 2")

            // Copy 3: user recopies exact same text from Terminal (plain text only)
            let repNoteText3 = RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: noteText.data(using: .utf8)!)
            let captureNote3 = RawCapture(
                timestampMs: 60000,
                sourceBundleId: "com.apple.Terminal",
                representations: [repNoteText3]
            )
            let outcomeNote3 = try await client.ingest(capture: captureNote3)
            assert(outcomeNote3.isDuplicate, "Plain recopy of note text must deduplicate")
            assert(outcomeNote3.itemId == noteItemId, "Item ID must match")
            assert(outcomeNote3.copyCount == 3, "Copy count must increment to 3")
            assert(outcomeNote3.contentKind == "rich_text", "Kind must remain rich_text")

            // Verify stored representations still have public.rtf from earlier copy
            let noteReps = try await client.getItemRepresentations(itemId: noteItemId)
            assert(noteReps.contains { $0.uti == "public.rtf" }, "Rich RTF representation must NOT be lost when recopying from plain source")
            print("  ✓ Apple Notes RTF variations deduplicated and rich representations preserved")

            // =========================================================================
            // 5. Finder Multi-File Selection Order Permutations (T-CAP-05, F-005, F-012)
            // =========================================================================
            print("5. Testing Finder Multi-File Order Permutations...")

            // Selection A: doc_b then doc_a
            let repFileA1 = RawRepresentation(groupIndex: 0, uti: "public.file-url", payload: "file:///tmp/doc_b.pdf".data(using: .utf8)!)
            let repFileA2 = RawRepresentation(groupIndex: 1, uti: "public.file-url", payload: "file:///tmp/doc_a.pdf/".data(using: .utf8)!)
            let captureFilesA = RawCapture(
                timestampMs: 70000,
                sourceBundleId: "com.apple.finder",
                representations: [repFileA1, repFileA2]
            )
            let outcomeFilesA = try await client.ingest(capture: captureFilesA)
            assert(!outcomeFilesA.isDuplicate, "First file selection must be new item")
            let fileItemId = outcomeFilesA.itemId

            // Selection B: doc_a then doc_b, localhost prefix and no trailing slash
            let repFileB1 = RawRepresentation(groupIndex: 0, uti: "public.file-url", payload: "file://localhost/tmp/doc_a.pdf".data(using: .utf8)!)
            let repFileB2 = RawRepresentation(groupIndex: 1, uti: "public.file-url", payload: "file:///tmp/doc_b.pdf".data(using: .utf8)!)
            let captureFilesB = RawCapture(
                timestampMs: 75000,
                sourceBundleId: "com.apple.finder",
                representations: [repFileB1, repFileB2]
            )
            let outcomeFilesB = try await client.ingest(capture: captureFilesB)
            assert(outcomeFilesB.isDuplicate, "File selection order permutation must deduplicate")
            assert(outcomeFilesB.itemId == fileItemId, "Item ID must match")
            assert(outcomeFilesB.copyCount == 2, "Copy count must increment to 2")
            print("  ✓ Finder file selection order permutation deduplicated")

            // =========================================================================
            // 6. Distinct Content Safety (Must NOT Deduplicate)
            // =========================================================================
            print("6. Testing Distinct Content Safety...")

            let distinctCode = "fn calculate_total(items: &[Item]) -> u64 {\n    items.iter().product()\n}\n"
            let repDistinct = RawRepresentation(
                groupIndex: 0,
                uti: "public.utf8-plain-text",
                payload: distinctCode.data(using: .utf8)!
            )
            let captureDistinct = RawCapture(
                timestampMs: 80000,
                sourceBundleId: "com.microsoft.VSCode",
                representations: [repDistinct]
            )
            let outcomeDistinct = try await client.ingest(capture: captureDistinct)
            assert(!outcomeDistinct.isDuplicate, "Different content must NOT deduplicate")
            assert(outcomeDistinct.itemId != codeItemId, "Different content must receive new unique item ID")
            print("  ✓ Distinct content verified to produce independent items")

            // =========================================================================
            // 7. ClipboardMonitor Rapid Burst Debouncing (T-CAP-05, F-012)
            // =========================================================================
            print("7. Testing ClipboardMonitor Rapid Burst Debouncing...")

            let mockPasteboard = NSPasteboard.withUniqueName()
            let monitor = ClipboardMonitor(
                pasteboard: mockPasteboard,
                privacyFilter: PrivacyFilter(),
                provenanceGuard: ClipboardProvenance(),
                coreClient: client
            )

            // Track ingestion count via callback
            var ingestCallCount = 0
            monitor.onIngest = { _ in
                ingestCallCount += 1
            }

            // Perform first copy on pasteboard (increments changeCount)
            mockPasteboard.declareTypes([.string], owner: nil)
            mockPasteboard.setString("Burst Test Snippet", forType: .string)

            // Process first change
            monitor.checkForChanges()
            // Wait brief moment for async Task in monitor to ingest
            for _ in 0..<10 {
                if ingestCallCount > 0 { break }
                try await Task.sleep(nanoseconds: 20_000_000) // 20ms
            }
            assert(ingestCallCount == 1, "First copy must be ingested, got \(ingestCallCount)")

            // Simulate rapid burst write from complex app (< 20ms later)
            // App clears and re-sets same string, incrementing changeCount rapidly
            mockPasteboard.declareTypes([.string], owner: nil)
            mockPasteboard.setString("Burst Test Snippet", forType: .string)

            monitor.checkForChanges()
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms

            // Ingest count should still be 1 because burst was debounced!
            assert(ingestCallCount == 1, "Rapid burst (< 100ms) with identical content must be debounced without duplicate ingest call")
            print("  ✓ Rapid clipboard burst (< 100ms) debounced successfully")

            print("\n----------------------------------------------------------------------")
            print("ALL DEDUPLICATION HARDENING TESTS (T-CAP-05, F-012) PASSED SUCCESSFULLY!")
            print("----------------------------------------------------------------------")

        } catch {
            fatalError("FAIL: Unexpected error during deduplication hardening tests: \(error.localizedDescription)")
        }
    }
}
