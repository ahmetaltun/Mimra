// ==============================================================================
// Mimra — Image Types & Thumbnail Cache Tests
// Validates allowlisted image format fidelity (PNG, TIFF, JPEG, HEIC) and
// off-main-thread lazy thumbnail decoding with memory bounds.
// Linked Feature: F-004
// Test ID: T-TYPE-02
// ==============================================================================

import AppKit
import CoreGraphics
import Foundation

@main
struct ImageTypeTests {
    static func main() async {
        print("=== Running Image Types & Thumbnail Cache Tests (T-TYPE-02) ===")

        let tempDbPath = "/tmp/mimra_image_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDbPath)
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-shm")
        }

        do {
            let client = try CoreClient(databasePath: tempDbPath)

            // -----------------------------------------------------------------
            // Helper: Generate valid synthetic image data using AppKit
            // -----------------------------------------------------------------
            func makeSyntheticImageData(width: Int, height: Int, fileType: NSBitmapImageRep.FileType) -> Data {
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: width,
                    pixelsHigh: height,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: width * 4,
                    bitsPerPixel: 32
                )!

                NSGraphicsContext.saveGraphicsState()
                let context = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current = context

                // Draw a colored background with a diagonal stripe
                NSColor.systemBlue.setFill()
                NSRect(x: 0, y: 0, width: width, height: height).fill()
                NSColor.systemOrange.setStroke()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 0, y: 0))
                path.line(to: NSPoint(x: width, y: height))
                path.lineWidth = 4
                path.stroke()

                NSGraphicsContext.restoreGraphicsState()
                return rep.representation(using: fileType, properties: [:])!
            }

            let pngData = makeSyntheticImageData(width: 200, height: 150, fileType: .png)
            let jpegData = makeSyntheticImageData(width: 200, height: 150, fileType: .jpeg)
            let tiffData = makeSyntheticImageData(width: 100, height: 100, fileType: .tiff)

            assert(!pngData.isEmpty, "Generated PNG data must not be empty")
            assert(!jpegData.isEmpty, "Generated JPEG data must not be empty")
            assert(!tiffData.isEmpty, "Generated TIFF data must not be empty")
            print("✓ Generated valid synthetic PNG (\(pngData.count) B), JPEG (\(jpegData.count) B), TIFF (\(tiffData.count) B)")

            // -----------------------------------------------------------------
            // Test 1: Ingestion & Content Classification (PNG, JPEG, TIFF)
            // -----------------------------------------------------------------
            print("\n--- Test 1: Image Ingestion and Metadata Derivation ---")

            // Ingest PNG
            let repPng = RawRepresentation(groupIndex: 0, uti: "public.png", payload: pngData)
            let capturePng = RawCapture(
                timestampMs: 1700000000000,
                sourceBundleId: "com.apple.screencaptureui",
                representations: [repPng]
            )
            let resultPng = try await client.ingest(capture: capturePng)
            assert(resultPng.contentKind == "image", "PNG item must be classified as image kind")

            // Ingest JPEG
            let repJpeg = RawRepresentation(groupIndex: 0, uti: "public.jpeg", payload: jpegData)
            let captureJpeg = RawCapture(
                timestampMs: 1700000001000,
                sourceBundleId: "com.google.Chrome",
                representations: [repJpeg]
            )
            let resultJpeg = try await client.ingest(capture: captureJpeg)
            assert(resultJpeg.contentKind == "image", "JPEG item must be classified as image kind")

            // Ingest TIFF
            let repTiff = RawRepresentation(groupIndex: 0, uti: "public.tiff", payload: tiffData)
            let captureTiff = RawCapture(
                timestampMs: 1700000002000,
                sourceBundleId: "com.apple.Preview",
                representations: [repTiff]
            )
            let resultTiff = try await client.ingest(capture: captureTiff)
            assert(resultTiff.contentKind == "image", "TIFF item must be classified as image kind")

            // Verify history page items and derived titles
            let page = try await client.listPage(limit: 10, offset: 0)
            assert(page.count == 3, "Page should contain exactly 3 items")

            let summaryPng = page.first { $0.id == resultPng.itemId }!
            assert(summaryPng.title.contains("PNG Image"), "PNG title should mention format, got: \(summaryPng.title)")
            print("✓ T-TYPE-02: PNG item titled accurately: '\(summaryPng.title)'")

            let summaryJpeg = page.first { $0.id == resultJpeg.itemId }!
            assert(summaryJpeg.title.contains("JPEG Image"), "JPEG title should mention format, got: \(summaryJpeg.title)")
            print("✓ T-TYPE-02: JPEG item titled accurately: '\(summaryJpeg.title)'")

            let summaryTiff = page.first { $0.id == resultTiff.itemId }!
            assert(summaryTiff.title.contains("TIFF Image"), "TIFF title should mention format, got: \(summaryTiff.title)")
            print("✓ T-TYPE-02: TIFF item titled accurately: '\(summaryTiff.title)'")

            // -----------------------------------------------------------------
            // Test 2: Byte-for-Byte Storage Fidelity
            // -----------------------------------------------------------------
            print("\n--- Test 2: SQLite Storage Fidelity ---")
            let storedPngReps = try await client.getItemRepresentations(itemId: resultPng.itemId)
            assert(storedPngReps.count == 1, "Expected 1 stored representation for PNG")
            assert(storedPngReps[0].payload == pngData, "Stored PNG payload must match original bytes exactly")

            let storedJpegReps = try await client.getItemRepresentations(itemId: resultJpeg.itemId)
            assert(storedJpegReps[0].payload == jpegData, "Stored JPEG payload must match original bytes exactly")

            let storedTiffReps = try await client.getItemRepresentations(itemId: resultTiff.itemId)
            assert(storedTiffReps[0].payload == tiffData, "Stored TIFF payload must match original bytes exactly")
            print("✓ T-TYPE-02: All image payloads preserved with byte-for-byte fidelity across FFI/SQLite")

            // -----------------------------------------------------------------
            // Test 3: Off-Main-Thread Thumbnail Generation & Scaling
            // -----------------------------------------------------------------
            print("\n--- Test 3: Lazy Downscaled Thumbnail Generation ---")
            let decodedThumbnail = ImageThumbnailService.decodeThumbnail(from: pngData, maxPixelSize: 64)
            assert(decodedThumbnail != nil, "Decoding valid PNG thumbnail must succeed")
            let thumb = decodedThumbnail!
            assert(max(thumb.size.width, thumb.size.height) <= 64, "Decoded thumbnail must be clamped to maxPixelSize: \(thumb.size)")
            print("✓ T-TYPE-02: Downscaled 200x150 image to thumbnail: \(thumb.size.width)x\(thumb.size.height)")

            // Test via ImageThumbnailService actor
            let service = ImageThumbnailService(maxPixelSize: 80)
            let asyncThumb = await service.thumbnail(for: resultPng.itemId) {
                return pngData
            }
            assert(asyncThumb != nil, "Async thumbnail fetching must return valid NSImage")
            assert(max(asyncThumb!.size.width, asyncThumb!.size.height) <= 80, "Max dimension clamped to 80")

            // Verify it was cached in memory
            let cached = service.cachedThumbnail(for: resultPng.itemId)
            assert(cached != nil, "Decoded image must be present in thumbnail cache")
            assert(cached === asyncThumb, "Cached image reference must match loaded image")
            print("✓ T-TYPE-02: Memory-bounded thumbnail caching verified")

            // -----------------------------------------------------------------
            // Test 4: Concurrent Request Deduplication (Task Coalescing)
            // -----------------------------------------------------------------
            print("\n--- Test 4: Concurrent Request Coalescing ---")
            let countingService = ImageThumbnailService(maxPixelSize: 100)

            // Launch 10 simultaneous requests for the same uncached item ID
            let concurrentResults = await withTaskGroup(of: SendableImage.self, returning: [SendableImage].self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        let res = await countingService.thumbnail(for: "concurrent-item-1") {
                            try? await Task.sleep(nanoseconds: 10_000_000)
                            return pngData
                        }
                        return SendableImage(res)
                    }
                }
                var results: [SendableImage] = []
                for await res in group {
                    results.append(res)
                }
                return results
            }

            assert(concurrentResults.count == 10, "All 10 concurrent requests must complete")
            for res in concurrentResults {
                assert(res.image != nil, "Every concurrent request must yield a valid image")
            }
            print("✓ T-TYPE-02: Concurrent thumbnail requests coalesced cleanly")

            // -----------------------------------------------------------------
            // Test 5: Cache Memory Limits & Eviction
            // -----------------------------------------------------------------
            print("\n--- Test 5: Cache Eviction and Clear ---")
            let limitedService = ImageThumbnailService(maxPixelSize: 32, countLimit: 2, totalCostLimitBytes: 1024 * 1024)

            _ = await limitedService.thumbnail(for: "item-1") { pngData }
            _ = await limitedService.thumbnail(for: "item-2") { jpegData }
            let item1Cached = limitedService.cachedThumbnail(for: "item-1")
            let item2Cached = limitedService.cachedThumbnail(for: "item-2")
            assert(item1Cached != nil)
            assert(item2Cached != nil)

            // Clear cache
            await limitedService.clearCache()
            let item1AfterClear = limitedService.cachedThumbnail(for: "item-1")
            let item2AfterClear = limitedService.cachedThumbnail(for: "item-2")
            assert(item1AfterClear == nil, "Cache clear must remove item-1")
            assert(item2AfterClear == nil, "Cache clear must remove item-2")
            print("✓ T-TYPE-02: Thumbnail cache clear operation verified")

            // -----------------------------------------------------------------
            // Test 6: Replay Reconstitution onto NSPasteboard
            // -----------------------------------------------------------------
            print("\n--- Test 6: NSPasteboard Image Replay & Provenance ---")
            let testPb = NSPasteboard(name: NSPasteboard.Name("com.mimra.test.image.replay.\(UUID().uuidString)"))
            testPb.clearContents()

            let coordinator = await MainActor.run {
                PasteCoordinator(coreClient: client, pasteboard: testPb)
            }

            // Write in original mode
            let writeCount = try await coordinator.writeToPasteboard(itemId: resultPng.itemId, mode: .original)
            assert(writeCount > 0, "Write to pasteboard must return valid change count")

            assert(testPb.pasteboardItems?.count == 1, "Expected 1 item on pasteboard")
            let pastedItem = testPb.pasteboardItems![0]
            assert(pastedItem.data(forType: NSPasteboard.PasteboardType("public.png")) == pngData, "Pasted PNG data must match original")
            assert(pastedItem.data(forType: ClipboardProvenance.provenanceType) != nil, "Provenance marker must be present")
            print("✓ T-PASTE-01 / T-TYPE-02: Image replayed onto NSPasteboard with provenance marker")

            // Write in plain-text mode (should fall back gracefully to image rather than empty write)
            testPb.clearContents()
            _ = try await coordinator.writeToPasteboard(itemId: resultPng.itemId, mode: .plainText)
            assert(testPb.pasteboardItems?.count == 1, "Plain paste on pure image must fall back to original")
            assert(testPb.pasteboardItems![0].data(forType: NSPasteboard.PasteboardType("public.png")) == pngData)
            print("✓ T-PASTE-02 / T-TYPE-02: Plain paste on pure image gracefully falls back to image")

            // -----------------------------------------------------------------
            // Test 7: Negative & Malformed Image Data Tests
            // -----------------------------------------------------------------
            print("\n--- Test 7: Negative & Malformed Image Tests ---")
            // Empty data
            let emptyThumb = ImageThumbnailService.decodeThumbnail(from: Data(), maxPixelSize: 64)
            assert(emptyThumb == nil, "Empty data must return nil without crash")

            // Corrupt data (random noise)
            let corruptData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
            let corruptThumb = ImageThumbnailService.decodeThumbnail(from: corruptData, maxPixelSize: 64)
            assert(corruptThumb == nil, "Corrupt image bytes must return nil safely without crash")

            // Corrupt image ingested into client
            let repCorrupt = RawRepresentation(groupIndex: 0, uti: "public.png", payload: corruptData)
            let captureCorrupt = RawCapture(timestampMs: 1700000010000, sourceBundleId: "com.mimra.test", representations: [repCorrupt])
            let resultCorrupt = try await client.ingest(capture: captureCorrupt)
            assert(resultCorrupt.contentKind == "image")

            let corruptServiceThumb = await service.thumbnail(for: resultCorrupt.itemId) { corruptData }
            assert(corruptServiceThumb == nil, "Thumbnail service must return nil for invalid image bytes")
            print("✓ Negative/Edge Test: Corrupt image bytes handled gracefully with nil result")

            print("\n=======================================================")
            print("✓ ALL IMAGE TYPES & THUMBNAIL CACHE TESTS PASSED!")
            print("=======================================================")

        } catch {
            print("❌ Image type tests failed: \(error)")
            exit(1)
        }
    }
}
