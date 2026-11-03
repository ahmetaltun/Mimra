// ==============================================================================
// Mimra — Clipboard Type Settings & Format Enablement Automated Tests (T-TYPE-05)
// Linked Features: F-013 (Enable/disable formats), F-015 (Drop unselected/unsupported types)
// ==============================================================================

import AppKit
import Foundation

@main
struct TypeSettingsTests {
    static func main() async {
        print("----------------------------------------------------------------------")
        print("Starting Clipboard Type Settings Tests (T-TYPE-05, F-013, F-015)")
        print("----------------------------------------------------------------------")

        let tempDbPath = "/tmp/mimra_type_settings_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDbPath)
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-shm")
        }

        do {
            let client = try CoreClient(databasePath: tempDbPath)

            // =========================================================================
            // 1. Plain Text Toggle (F-013)
            // =========================================================================
            print("1. Testing Plain Text Format Enablement / Disablement...")

            let mockPb1 = NSPasteboard.withUniqueName()
            var config1 = ClipboardTypeConfiguration(
                storePlainText: false, // Disabled!
                storeRichText: true,
                storeImages: true,
                storeFiles: true
            )

            let monitor1 = ClipboardMonitor(
                pasteboard: mockPb1,
                privacyFilter: PrivacyFilter(typeConfiguration: config1),
                provenanceGuard: ClipboardProvenance(),
                typeConfiguration: config1,
                coreClient: client
            )

            var ingestCount1 = 0
            monitor1.onIngest = { _ in ingestCount1 += 1 }

            // Copy plain text
            mockPb1.declareTypes([.string], owner: nil)
            mockPb1.setString("Plain text snippet that should be dropped", forType: .string)
            monitor1.checkForChanges()
            try await Task.sleep(nanoseconds: 50_000_000)

            assert(ingestCount1 == 0, "Plain text copy must be DROPPED when storePlainText is disabled")
            let page1 = try await client.listPage(limit: 10, offset: 0)
            assert(page1.isEmpty, "Database must remain empty when plain text is disabled")

            // Re-enable plain text
            config1.storePlainText = true
            monitor1.typeConfiguration = config1

            mockPb1.declareTypes([.string], owner: nil)
            mockPb1.setString("Plain text snippet that should now be captured", forType: .string)
            monitor1.checkForChanges()
            for _ in 0..<10 {
                if ingestCount1 > 0 { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            assert(ingestCount1 == 1, "Plain text copy must be CAPTURED when storePlainText is re-enabled")
            print("  ✓ Plain text disable and re-enable verified (F-013)")

            // =========================================================================
            // 2. Rich Text Toggle & Stripping (F-013, F-015)
            // =========================================================================
            print("2. Testing Rich Text Format Enablement & Representation Stripping...")

            let mockPb2 = NSPasteboard.withUniqueName()
            let config2 = ClipboardTypeConfiguration(
                storePlainText: true,
                storeRichText: false, // Rich text disabled!
                storeImages: true,
                storeFiles: true
            )

            let monitor2 = ClipboardMonitor(
                pasteboard: mockPb2,
                privacyFilter: PrivacyFilter(typeConfiguration: config2),
                provenanceGuard: ClipboardProvenance(),
                typeConfiguration: config2,
                coreClient: client
            )

            var lastIngest2: IngestResultDto?
            monitor2.onIngest = { outcome in lastIngest2 = outcome }

            // 2a. Copy multi-representation text (Plain Text + HTML + RTF)
            let samplePlain = "Heading Text\nBody content."
            let sampleHtml = "<h1>Heading Text</h1><p>Body content.</p>"
            let sampleRtf = "{\\rtf1 Heading Text\\par Body content.}"

            mockPb2.declareTypes([.string, .rtf, .html], owner: nil)
            mockPb2.setString(samplePlain, forType: .string)
            mockPb2.setString(sampleHtml, forType: .html)
            mockPb2.setData(sampleRtf.data(using: .utf8)!, forType: .rtf)

            monitor2.checkForChanges()
            for _ in 0..<10 {
                if lastIngest2 != nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }

            guard let outcome2 = lastIngest2 else {
                fatalError("FAIL: Expected multi-rep copy to be ingested as plain text")
            }
            assert(outcome2.contentKind == "text", "When rich text is disabled, content kind must be 'text' instead of 'rich_text'")

            // Verify stored representations contain ONLY plain text (HTML and RTF stripped per F-013)
            let storedReps2 = try await client.getItemRepresentations(itemId: outcome2.itemId)
            assert(storedReps2.count == 1, "Expected exactly 1 representation (plain text), got \(storedReps2.count)")
            assert(storedReps2[0].uti == "public.utf8-plain-text", "Stored representation must be plain text")
            assert(!storedReps2.contains { $0.uti == "public.html" }, "HTML representation must be stripped when rich text is disabled")
            assert(!storedReps2.contains { $0.uti == "public.rtf" }, "RTF representation must be stripped when rich text is disabled")
            print("  ✓ Rich text stripped down to pure plain text when rich text is disabled")

            // 2b. Copy RTF when both plain text and rich text are disabled (only images/files enabled)
            let mockPb2Pure = NSPasteboard.withUniqueName()
            let config2Pure = ClipboardTypeConfiguration(
                storePlainText: false, // Text disabled!
                storeRichText: false,  // Rich text disabled!
                storeImages: true,
                storeFiles: true
            )
            let monitor2Pure = ClipboardMonitor(
                pasteboard: mockPb2Pure,
                privacyFilter: PrivacyFilter(typeConfiguration: config2Pure),
                provenanceGuard: ClipboardProvenance(),
                typeConfiguration: config2Pure,
                coreClient: client
            )
            var ingestCountPure = 0
            monitor2Pure.onIngest = { _ in ingestCountPure += 1 }

            mockPb2Pure.declareTypes([.rtf], owner: nil)
            mockPb2Pure.setData(sampleRtf.data(using: .utf8)!, forType: .rtf)
            monitor2Pure.checkForChanges()
            try await Task.sleep(nanoseconds: 50_000_000)
            assert(ingestCountPure == 0, "Rich text / text copy must be DROPPED when text and rich text formats are disabled")
            print("  ✓ Rich text copy dropped when text and rich text formats are disabled")

            // =========================================================================
            // 3. Images Toggle (F-013, F-015)
            // =========================================================================
            print("3. Testing Images Format Enablement / Disablement...")

            let mockPb3 = NSPasteboard.withUniqueName()
            var config3 = ClipboardTypeConfiguration(
                storePlainText: true,
                storeRichText: true,
                storeImages: false, // Images disabled!
                storeFiles: true
            )

            let monitor3 = ClipboardMonitor(
                pasteboard: mockPb3,
                privacyFilter: PrivacyFilter(typeConfiguration: config3),
                provenanceGuard: ClipboardProvenance(),
                typeConfiguration: config3,
                coreClient: client
            )

            var ingestCount3 = 0
            monitor3.onIngest = { _ in ingestCount3 += 1 }

            // Create 1x1 PNG data
            let pngRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 4,
                bitsPerPixel: 32
            )!
            let pngData = pngRep.representation(using: .png, properties: [:])!

            mockPb3.declareTypes([.png], owner: nil)
            mockPb3.setData(pngData, forType: .png)
            monitor3.checkForChanges()
            try await Task.sleep(nanoseconds: 50_000_000)

            assert(ingestCount3 == 0, "Image copy must be DROPPED when storeImages is disabled")

            // Re-enable images
            config3.storeImages = true
            monitor3.typeConfiguration = config3

            mockPb3.declareTypes([.png], owner: nil)
            mockPb3.setData(pngData, forType: .png)
            monitor3.checkForChanges()
            for _ in 0..<10 {
                if ingestCount3 > 0 { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            assert(ingestCount3 == 1, "Image copy must be CAPTURED when storeImages is re-enabled")
            print("  ✓ Image disable and re-enable verified (F-013)")

            // =========================================================================
            // 4. File References Toggle (F-013, F-015)
            // =========================================================================
            print("4. Testing File References Format Enablement / Disablement...")

            let mockPb4 = NSPasteboard.withUniqueName()
            var config4 = ClipboardTypeConfiguration(
                storePlainText: true,
                storeRichText: true,
                storeImages: true,
                storeFiles: false // Files disabled!
            )

            let monitor4 = ClipboardMonitor(
                pasteboard: mockPb4,
                privacyFilter: PrivacyFilter(typeConfiguration: config4),
                provenanceGuard: ClipboardProvenance(),
                typeConfiguration: config4,
                coreClient: client
            )

            var ingestCount4 = 0
            monitor4.onIngest = { _ in ingestCount4 += 1 }

            let fileUrl = URL(fileURLWithPath: "/tmp/sample_doc.pdf")
            mockPb4.declareTypes([.fileURL], owner: nil)
            mockPb4.writeObjects([fileUrl as NSURL])

            monitor4.checkForChanges()
            try await Task.sleep(nanoseconds: 50_000_000)

            assert(ingestCount4 == 0, "File URL copy must be DROPPED when storeFiles is disabled")

            // Re-enable files
            config4.storeFiles = true
            monitor4.typeConfiguration = config4

            mockPb4.declareTypes([.fileURL], owner: nil)
            mockPb4.writeObjects([fileUrl as NSURL])
            monitor4.checkForChanges()
            for _ in 0..<10 {
                if ingestCount4 > 0 { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            assert(ingestCount4 == 1, "File URL copy must be CAPTURED when storeFiles is re-enabled")
            print("  ✓ File reference disable and re-enable verified (F-013)")

            // =========================================================================
            // 5. Unknown / Unsupported Payload Types Dropped (F-015)
            // =========================================================================
            print("5. Testing Unknown / Unsupported Types Dropped (F-015)...")

            let mockPb5 = NSPasteboard.withUniqueName()
            let config5 = ClipboardTypeConfiguration(
                storePlainText: true,
                storeRichText: true,
                storeImages: true,
                storeFiles: true
            )

            let monitor5 = ClipboardMonitor(
                pasteboard: mockPb5,
                privacyFilter: PrivacyFilter(typeConfiguration: config5),
                provenanceGuard: ClipboardProvenance(),
                typeConfiguration: config5,
                coreClient: client
            )

            var ingestCount5 = 0
            monitor5.onIngest = { _ in ingestCount5 += 1 }

            // Write arbitrary unsupported type (WebArchive, proprietary application format)
            let webArchiveType = NSPasteboard.PasteboardType("com.apple.webarchive")
            let randomBlob = "bplist00...arbitrary webarchive binary...".data(using: .utf8)!
            mockPb5.declareTypes([webArchiveType], owner: nil)
            mockPb5.setData(randomBlob, forType: webArchiveType)

            monitor5.checkForChanges()
            try await Task.sleep(nanoseconds: 50_000_000)

            assert(ingestCount5 == 0, "Unsupported WebArchive payload must be DROPPED without persisting to disk (F-015)")
            print("  ✓ Unsupported private payload strictly dropped per F-015")

            print("\n----------------------------------------------------------------------")
            print("ALL TYPE SETTINGS & FORMAT ENABLEMENT TESTS (T-TYPE-05) PASSED!")
            print("----------------------------------------------------------------------")

        } catch {
            fatalError("FAIL: Unexpected error during type settings tests: \(error.localizedDescription)")
        }
    }
}
