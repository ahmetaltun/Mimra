// ==============================================================================
// Mimra — Rich Text & HTML Multi-Representation Tests
// Validates full round-trip fidelity for HTML, RTF, and RTFD alongside plain text.
// Linked Features: F-003, F-007, F-021
// Test IDs: T-TYPE-01, T-CAP-03, T-PASTE-02
// ==============================================================================

import AppKit
import Foundation

@main
struct RichTextTests {
    static func main() async {
        print("=== Running Rich Text & HTML Multi-Representation Tests (T-TYPE-01) ===")

        let tempDbPath = "/tmp/mimra_rich_text_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDbPath)
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-shm")
        }

        do {
            let client = try CoreClient(databasePath: tempDbPath)

            // -----------------------------------------------------------------
            // Test 1: Full multi-representation item (Plain + HTML + RTF)
            // -----------------------------------------------------------------
            print("\n--- Test 1: Full Multi-Representation Item (HTML + RTF + Plain Text) ---")
            let samplePlainText = "Mimra Rich Text Heading\nSecond line with formatted content."
            let sampleHtml = "<h1>Mimra Rich Text Heading</h1><p>Second line with <b>formatted</b> content.</p>"
            let sampleRtf = "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2821{\\fonttbl\\f0\\fswiss Helvetica;}\\pard\\f0\\fs28 Mimra Rich Text Heading\\par Second line with \\b formatted\\b0 content.}"

            let plainData = samplePlainText.data(using: .utf8)!
            let htmlData = sampleHtml.data(using: .utf8)!
            let rtfData = sampleRtf.data(using: .utf8)!

            let repPlain = RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: plainData)
            let repHtml = RawRepresentation(groupIndex: 0, uti: "public.html", payload: htmlData)
            let repRtf = RawRepresentation(groupIndex: 0, uti: "public.rtf", payload: rtfData)

            let capture1 = RawCapture(
                timestampMs: 1700000000000,
                sourceBundleId: "com.apple.Safari",
                representations: [repPlain, repHtml, repRtf]
            )

            let result1 = try await client.ingest(capture: capture1)
            assert(!result1.isDuplicate, "First ingestion must not be duplicate")
            assert(result1.contentKind == "rich_text", "Multi-rep item with HTML/RTF must be rich_text")
            print("✓ T-TYPE-01: Multi-representation item ingested with ID: \(result1.itemId)")

            // Fetch representations back from SQLite and verify fidelity
            let fetchedReps = try await client.getItemRepresentations(itemId: result1.itemId)
            assert(fetchedReps.count == 3, "Expected 3 stored representations, got \(fetchedReps.count)")

            let fetchedPlain = fetchedReps.first { $0.uti == "public.utf8-plain-text" }
            let fetchedHtml = fetchedReps.first { $0.uti == "public.html" }
            let fetchedRtf = fetchedReps.first { $0.uti == "public.rtf" }

            assert(fetchedPlain?.payload == plainData, "Plain text payload corrupted across storage boundary")
            assert(fetchedHtml?.payload == htmlData, "HTML payload corrupted across storage boundary")
            assert(fetchedRtf?.payload == rtfData, "RTF payload corrupted across storage boundary")
            print("✓ T-TYPE-01: Stored representations preserved byte-for-byte in SQLite")

            // Test Replay in Original Mode
            let originalItems = PasteCoordinator.encodePasteboardItems(representations: fetchedReps, mode: .original)
            assert(originalItems.count == 1, "Expected 1 pasteboard item for group 0")
            let pbItemOriginal = originalItems[0]

            assert(pbItemOriginal.data(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")) == plainData, "Original replay missing plain text")
            assert(pbItemOriginal.data(forType: NSPasteboard.PasteboardType("public.html")) == htmlData, "Original replay missing HTML")
            assert(pbItemOriginal.data(forType: NSPasteboard.PasteboardType("public.rtf")) == rtfData, "Original replay missing RTF")
            assert(pbItemOriginal.string(forType: .string) == samplePlainText, "Original replay missing string(forType: .string)")
            print("✓ T-PASTE-01 / T-TYPE-01: Original replay preserves all flavors and types")

            // Test Replay in Plain Text Mode
            let plainItems = PasteCoordinator.encodePasteboardItems(representations: fetchedReps, mode: .plainText)
            assert(plainItems.count == 1, "Expected 1 pasteboard item for plain mode")
            let pbItemPlain = plainItems[0]

            assert(pbItemPlain.data(forType: .string) == plainData, "Plain mode must set plain text payload")
            assert(pbItemPlain.data(forType: NSPasteboard.PasteboardType("public.html")) == nil, "Plain mode must not contain HTML")
            assert(pbItemPlain.data(forType: NSPasteboard.PasteboardType("public.rtf")) == nil, "Plain mode must not contain RTF")
            assert(pbItemPlain.string(forType: .string) == samplePlainText, "Plain mode string content must match")
            print("✓ T-PASTE-02 / T-TYPE-01: Plain-text replay strips all formatting and rich flavors")

            // -----------------------------------------------------------------
            // Test 2: Ingest item with ONLY HTML (no plain text supplied by app)
            // -----------------------------------------------------------------
            print("\n--- Test 2: HTML-Only Copy (Deriving Search Text & Title) ---")
            let htmlOnlyString = "<div class='article'><h2>Breaking Tech News</h2><p>Apple announces new macOS hardware with high efficiency.</p></div>"
            let htmlOnlyData = htmlOnlyString.data(using: .utf8)!
            let repHtmlOnly = RawRepresentation(groupIndex: 0, uti: "public.html", payload: htmlOnlyData)

            let captureHtmlOnly = RawCapture(
                timestampMs: 1700000005000,
                sourceBundleId: "com.google.Chrome",
                representations: [repHtmlOnly]
            )

            let resultHtmlOnly = try await client.ingest(capture: captureHtmlOnly)
            assert(resultHtmlOnly.contentKind == "rich_text", "HTML-only item must be classified as rich_text")

            let page = try await client.listPage(limit: 10, offset: 0)
            let htmlItemSummary = page.first { $0.id == resultHtmlOnly.itemId }
            assert(htmlItemSummary != nil, "Ingested HTML-only item must be listed in history")
            assert(htmlItemSummary?.title.contains("Breaking Tech News") == true, "Title must be derived from HTML content, got: \(htmlItemSummary?.title ?? "")")
            print("✓ T-TYPE-01: HTML-only copy derived descriptive title: '\(htmlItemSummary!.title)'")

            // Test plain-text extraction from HTML-only item
            let htmlOnlyReps = try await client.getItemRepresentations(itemId: resultHtmlOnly.itemId)
            let extractedPlainFromHtml = PasteCoordinator.extractPlainText(from: htmlOnlyReps)
            assert(extractedPlainFromHtml != nil, "Plain text must be extractable from HTML")
            assert(extractedPlainFromHtml!.contains("Breaking Tech News"), "Extracted text missing heading")
            assert(extractedPlainFromHtml!.contains("Apple announces new macOS hardware"), "Extracted text missing body")
            print("✓ T-TYPE-01: Clean plain text extracted from HTML without tags: '\(extractedPlainFromHtml!)'")

            // -----------------------------------------------------------------
            // Test 3: Ingest item with ONLY RTF (no plain text supplied by app)
            // -----------------------------------------------------------------
            print("\n--- Test 3: RTF-Only Copy ---")
            let rtfOnlyString = "{\\rtf1\\ansi{\\fonttbl\\f0\\fswiss Helvetica;}\\pard\\f0\\fs24 Important Notes Document\\par Bullet 1: Security\\par Bullet 2: Privacy}"
            let rtfOnlyData = rtfOnlyString.data(using: .utf8)!
            let repRtfOnly = RawRepresentation(groupIndex: 0, uti: "public.rtf", payload: rtfOnlyData)

            let captureRtfOnly = RawCapture(
                timestampMs: 1700000010000,
                sourceBundleId: "com.apple.Notes",
                representations: [repRtfOnly]
            )

            let resultRtfOnly = try await client.ingest(capture: captureRtfOnly)
            let pageRtf = try await client.listPage(limit: 10, offset: 0)
            let rtfSummary = pageRtf.first { $0.id == resultRtfOnly.itemId }
            assert(rtfSummary != nil, "Ingested RTF-only item must be listed in history")
            assert(rtfSummary?.title.contains("Important Notes Document") == true, "Title must be derived from RTF text, got: \(rtfSummary?.title ?? "")")
            print("✓ T-TYPE-01: RTF-only copy derived descriptive title: '\(rtfSummary!.title)'")

            let rtfOnlyReps = try await client.getItemRepresentations(itemId: resultRtfOnly.itemId)
            let extractedPlainFromRtf = PasteCoordinator.extractPlainText(from: rtfOnlyReps)
            assert(extractedPlainFromRtf != nil, "Plain text must be extractable from RTF")
            assert(extractedPlainFromRtf!.contains("Important Notes Document"), "Extracted text missing header")
            assert(extractedPlainFromRtf!.contains("Bullet 1: Security"), "Extracted text missing body")
            print("✓ T-TYPE-01: Clean plain text extracted from RTF: '\(extractedPlainFromRtf!)'")

            // -----------------------------------------------------------------
            // Test 4: ClipboardMonitor UTI standardizer & synthesis
            // -----------------------------------------------------------------
            print("\n--- Test 4: ClipboardMonitor Extraction Pipeline & Legacy Mappings ---")
            let customPb = NSPasteboard(name: NSPasteboard.Name("com.mimra.test.p301.\(UUID().uuidString)"))
            customPb.clearContents()

            let monitor = await MainActor.run {
                ClipboardMonitor(pasteboard: customPb, coreClient: client)
            }

            // Write legacy Apple HTML pasteboard type and NSRTFPboardType via pasteboard declareTypes
            let legacyHtmlType = NSPasteboard.PasteboardType("Apple HTML pasteboard type")
            let legacyRtfType = NSPasteboard.PasteboardType("NSRTFPboardType")
            customPb.declareTypes([legacyHtmlType, legacyRtfType], owner: nil)
            customPb.setData("<b>Legacy WebKit HTML</b>".data(using: .utf8)!, forType: legacyHtmlType)
            customPb.setData("{\\rtf1\\ansi Legacy RTF Content}".data(using: .utf8)!, forType: legacyRtfType)

            await MainActor.run {
                monitor.checkForChanges()
            }

            // Allow async task to complete
            try await Task.sleep(nanoseconds: 50_000_000)

            let recentPage = try await client.listPage(limit: 5, offset: 0)
            let legacyItem = recentPage.first { $0.title.contains("Legacy WebKit HTML") || $0.title.contains("Legacy RTF Content") }
            assert(legacyItem != nil, "Item copied under legacy UTIs must be captured and indexed with synthesized plain text")

            let legacyReps = try await client.getItemRepresentations(itemId: legacyItem!.id)
            let legacyUtis = Set(legacyReps.map { $0.uti })
            assert(legacyUtis.contains("public.html"), "Apple HTML pasteboard type must map to canonical public.html")
            assert(legacyUtis.contains("public.rtf"), "NSRTFPboardType must map to canonical public.rtf")
            assert(legacyUtis.contains("public.utf8-plain-text"), "Synthesized public.utf8-plain-text must be attached")
            print("✓ T-TYPE-01 / F-003: Legacy UTIs standardized and plain-text synthesized successfully")

            // -----------------------------------------------------------------
            // Test 5: Real NSPasteboard Round-Trip Fidelity
            // -----------------------------------------------------------------
            print("\n--- Test 5: NSPasteboard Replay & Provenance Verification ---")
            let replayPb = NSPasteboard(name: NSPasteboard.Name("com.mimra.test.replay.\(UUID().uuidString)"))
            replayPb.clearContents()

            let coordinator = await MainActor.run {
                PasteCoordinator(coreClient: client, pasteboard: replayPb)
            }

            let writeCount = try await coordinator.writeToPasteboard(itemId: result1.itemId, mode: .original)
            assert(writeCount > 0, "Writing original representations to pasteboard must succeed")

            // Verify what is on the pasteboard
            assert(replayPb.pasteboardItems?.count == 1, "Pasteboard should have 1 item")
            let pastedItem = replayPb.pasteboardItems![0]

            assert(pastedItem.data(forType: NSPasteboard.PasteboardType("public.html")) == htmlData, "HTML data on pasteboard must match original")
            assert(pastedItem.data(forType: NSPasteboard.PasteboardType("public.rtf")) == rtfData, "RTF data on pasteboard must match original")
            assert(pastedItem.string(forType: .string) == samplePlainText, "Plain text on pasteboard must match original")

            // Verify provenance marker stamped on pasteboard
            let provData = pastedItem.data(forType: ClipboardProvenance.provenanceType)
            assert(provData != nil, "Provenance marker must be present on replayed item")
            print("✓ T-PASTE-01 / T-TYPE-01: Full round-trip onto NSPasteboard verified with provenance marker")

            // -----------------------------------------------------------------
            // Test 6: Malformed / Edge Case HTML & RTF Handling
            // -----------------------------------------------------------------
            print("\n--- Test 6: Malformed HTML and RTF Robustness ---")
            let malformedHtml = "<div>Unclosed <b>HTML tags &amp; &lt;entities&gt; with broken <<brackets>>".data(using: .utf8)!
            let repMalformedHtml = RawRepresentation(groupIndex: 0, uti: "public.html", payload: malformedHtml)
            let captureMalformed = RawCapture(
                timestampMs: 1700000015000,
                sourceBundleId: "com.mimra.test",
                representations: [repMalformedHtml]
            )
            let resultMalformed = try await client.ingest(capture: captureMalformed)
            assert(resultMalformed.contentKind == "rich_text")

            let malformedPlain = PasteCoordinator.extractPlainText(from: [repMalformedHtml])
            assert(malformedPlain != nil && !malformedPlain!.isEmpty, "Malformed HTML must not crash and extract text")
            print("✓ Negative/Edge Test: Malformed HTML handled cleanly without failure")

            let malformedRtf = "{\\rtf1\\ansi Truncated RTF without closing brace".data(using: .utf8)!
            let repMalformedRtf = RawRepresentation(groupIndex: 0, uti: "public.rtf", payload: malformedRtf)
            let malformedRtfPlain = PasteCoordinator.extractPlainText(from: [repMalformedRtf])
            assert(malformedRtfPlain != nil && !malformedRtfPlain!.isEmpty, "Truncated RTF must not crash and extract text")
            print("✓ Negative/Edge Test: Truncated RTF handled cleanly without failure")

            print("\n=======================================================")
            print("✓ ALL RICH TEXT & HTML MULTI-REPRESENTATION TESTS PASSED!")
            print("=======================================================")

        } catch {
            print("❌ Rich text tests failed: \(error)")
            exit(1)
        }
    }
}
