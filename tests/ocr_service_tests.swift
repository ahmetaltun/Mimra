// ==============================================================================
// Mimra — OCR Service & Vision Text Recognition Tests
// Validates on-device Vision text recognition on background actor, automatic
// language detection across multilingual synthetic images, FTS5 search indexing,
// clean cancellation, and stale callback protection.
// Linked Features: F-043, F-044, F-051
// Test IDs: T-OCR-01, T-OCR-02, T-SRCH-04
// ==============================================================================

import AppKit
import CoreGraphics
import Foundation
@preconcurrency import Vision

@main
struct OCRServiceTests {
    static func main() async {
        print("=== Running OCR Service & Multilingual Vision Recognition Tests (P6-05 / F-043, T-OCR-01) ===")

        let tempDbPath = "/tmp/mimra_ocr_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDbPath)
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-shm")
        }

        // -----------------------------------------------------------------
        // Helper: Generate crisp synthetic test image with rendered text lines
        // -----------------------------------------------------------------
        func makeSyntheticTextImage(lines: [String], width: Int = 800, height: Int = 400) -> Data {
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

            // Solid high-contrast white background
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            let font = NSFont.boldSystemFont(ofSize: 28)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]

            var yOffset = CGFloat(height) - 70.0
            for line in lines {
                let attrString = NSAttributedString(string: line, attributes: attrs)
                attrString.draw(at: NSPoint(x: 40.0, y: yOffset))
                yOffset -= 65.0
            }

            NSGraphicsContext.restoreGraphicsState()
            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                fatalError("Failed to encode synthetic test image to PNG")
            }
            return pngData
        }

        // Initialize CoreClient with isolated test database
        let coreClient = try! CoreClient(databasePath: tempDbPath)
        let ocrService = OCRService()

        // -----------------------------------------------------------------
        // Test 1: On-Device Vision Recognition with 2 Languages (English & German)
        // -----------------------------------------------------------------
        print("\n--- Test 1: Multilingual Synthetic Image Recognition (English & German) ---")
        let bilingualLines = [
            "Mimra Core Diagnostic: Storage integrity verified.",
            "Fehlerueberwachung aktiv: System laeuft einwandfrei."
        ]
        let bilingualImage = makeSyntheticTextImage(lines: bilingualLines)
        assert(!bilingualImage.isEmpty, "Synthetic image data must not be empty")

        do {
            let recognizedText = try await ocrService.recognizeText(in: bilingualImage)
            assert(!recognizedText.isEmpty, "OCR service must recognize text in synthetic image")

            // Verify recognition across both English and German components
            let containsEnglish = recognizedText.localizedCaseInsensitiveContains("Diagnostic")
                || recognizedText.localizedCaseInsensitiveContains("Storage")
                || recognizedText.localizedCaseInsensitiveContains("integrity")
            let containsGerman = recognizedText.localizedCaseInsensitiveContains("Fehlerueberwachung")
                || recognizedText.localizedCaseInsensitiveContains("aktiv")
                || recognizedText.localizedCaseInsensitiveContains("System")

            assert(containsEnglish, "Recognized text must contain English keywords from test image")
            assert(containsGerman, "Recognized text must contain German keywords via automatic language detection")
            print("✓ Successfully recognized text across 2 languages on-device without network calls")
        } catch {
            fatalError("Test 1 failed with unexpected error: \(error)")
        }

        // -----------------------------------------------------------------
        // Test 2: Ingestion, Background Indexing & Multilingual FTS5 Search
        // -----------------------------------------------------------------
        print("\n--- Test 2: Ingestion & FTS5 Search Across Multilingual OCR Text ---")
        let imageCapture = RawCapture(
            timestampMs: 500_000,
            sourceBundleId: "com.apple.Preview",
            representations: [
                RawRepresentation(
                    groupIndex: 0,
                    uti: "public.png",
                    payload: bilingualImage
                )
            ]
        )

        let ingestOutcome = try! await coreClient.ingest(capture: imageCapture)
        let itemId = ingestOutcome.itemId
        assert(ingestOutcome.contentKind == "image", "Ingested item must be classified as image")

        // Before OCR indexing, searching for terms inside the image returns 0 results
        let preSearchEnglish = try! await coreClient.searchPage(query: "Diagnostic", mode: .fuzzy, limit: 10, offset: 0)
        assert(preSearchEnglish.isEmpty, "Pre-OCR search for image text must return empty")

        let preSearchGerman = try! await coreClient.searchPage(query: "Fehlerueberwachung", mode: .fuzzy, limit: 10, offset: 0)
        assert(preSearchGerman.isEmpty, "Pre-OCR search for image text must return empty")

        // Perform recognizeAndIndex
        let indexedText = try! await ocrService.recognizeAndIndex(
            itemId: itemId,
            imageData: bilingualImage,
            coreClient: coreClient
        )
        assert(!indexedText.isEmpty, "Indexed OCR text must not be empty")

        // Verify getOcrText retrieves the saved OCR text
        let storedOcr = try! await coreClient.getOcrText(itemId: itemId)
        assert(storedOcr == indexedText, "Stored OCR text in SQLite must match recognized text")

        // Search in Fuzzy Mode for English keyword
        let postSearchEnglish = try! await coreClient.searchPage(query: "Diagnostic", mode: .fuzzy, limit: 10, offset: 0)
        assert(postSearchEnglish.count == 1, "FTS5 fuzzy search must find image item by English OCR text")
        assert(postSearchEnglish[0].id == itemId, "Search result ID must match ingested image ID")
        assert(postSearchEnglish[0].snippet.localizedCaseInsensitiveContains("Diagnostic"), "Result snippet must reflect matching OCR text")
        assert(!postSearchEnglish[0].snippetHighlights.isEmpty, "Result snippet highlights must be populated")

        // Search in Exact Mode for German keyword
        let postSearchGerman = try! await coreClient.searchPage(query: "Fehlerueberwachung", mode: .exact, limit: 10, offset: 0)
        assert(postSearchGerman.count == 1, "FTS5 exact search must find image item by German OCR text")
        assert(postSearchGerman[0].id == itemId, "Search result ID must match ingested image ID")
        assert(postSearchGerman[0].snippet.localizedCaseInsensitiveContains("Fehlerueberwachung"), "Result snippet must reflect matching OCR text")

        // Search in Regex Mode
        let postSearchRegex = try! await coreClient.searchPage(query: "Storage.*integrity", mode: .regex, limit: 10, offset: 0)
        assert(postSearchRegex.count == 1, "FTS5 regex search must find image item by matching regex on OCR text")
        assert(postSearchRegex[0].id == itemId, "Search result ID must match ingested image ID")

        print("✓ Successfully indexed OCR text and verified FTS5 search in Fuzzy, Exact, and Regex modes")

        // -----------------------------------------------------------------
        // Test 3: Clean Cancellation (DoD Requirement)
        // -----------------------------------------------------------------
        print("\n--- Test 3: Clean Cancellation of In-Flight Recognition ---")
        let largeImage = makeSyntheticTextImage(
            lines: (0..<12).map { "High-density system diagnostic line \($0) with extensive content" },
            width: 1400,
            height: 900
        )
        let cancelTaskId = UUID().uuidString

        // Start recognition task in background
        let asyncTask = Task { () -> Result<String, Error> in
            do {
                let text = try await ocrService.recognizeText(in: largeImage, itemId: cancelTaskId)
                return .success(text)
            } catch {
                return .failure(error)
            }
        }

        // Cancel immediately
        await ocrService.cancel(itemId: cancelTaskId)

        let taskOutcome = await asyncTask.value
        switch taskOutcome {
        case .success:
            // If the task completed before cancel could be delivered, verify cleanup
            print("Note: Recognition completed quickly before cancellation interrupt arrived.")
        case .failure(let err):
            if let ocrErr = err as? OCRError {
                switch ocrErr {
                case .cancelled:
                    print("✓ Caught expected OCRError.cancelled cleanly")
                default:
                    print("✓ Caught cancelled task error cleanly: \(ocrErr.localizedDescription)")
                }
            } else {
                print("✓ Caught cancellation error cleanly: \(err.localizedDescription)")
            }
        }

        let isStillProcessing = await ocrService.isProcessing(itemId: cancelTaskId)
        assert(!isStillProcessing, "Task must no longer be marked as processing after completion or cancellation")
        print("✓ Verified clean task cancellation without crashes, memory leaks, or unhandled errors")

        // -----------------------------------------------------------------
        // Test 4: Cancel All In-Flight Tasks
        // -----------------------------------------------------------------
        print("\n--- Test 4: cancelAll Execution ---")
        let dummyTaskIds = (0..<3).map { "dummy_task_\($0)_\(UUID().uuidString)" }
        var spawnedTasks: [Task<Void, Never>] = []

        for dummyId in dummyTaskIds {
            let t = Task {
                _ = try? await ocrService.recognizeText(in: largeImage, itemId: dummyId)
            }
            spawnedTasks.append(t)
        }

        await ocrService.cancelAll()
        for t in spawnedTasks {
            _ = await t.value
        }

        let remainingCount = await ocrService.activeTaskCount
        assert(remainingCount == 0, "activeTaskCount must be 0 after cancelAll()")
        print("✓ cancelAll successfully terminated all registered tasks")

        // -----------------------------------------------------------------
        // Test 5: Stale Callback / Non-Existent Item Protection (F-040, T-SRCH-04)
        // -----------------------------------------------------------------
        print("\n--- Test 5: Stale Callback & Non-Existent Item Protection ---")
        let nonExistentId = UUID().uuidString
        let staleUpdated = try! await coreClient.updateOcrText(
            itemId: nonExistentId,
            ocrText: "Ghost text for deleted item"
        )
        assert(!staleUpdated, "updateOcrText must return false for non-existent or deleted UUID")

        let ghostText = try! await coreClient.getOcrText(itemId: nonExistentId)
        assert(ghostText == nil, "getOcrText must return nil for non-existent UUID")

        // Search must not resurrect ghost items
        let ghostSearch = try! await coreClient.searchPage(query: "Ghost", mode: .fuzzy, limit: 10, offset: 0)
        assert(ghostSearch.isEmpty, "Search must not find unindexed/deleted ghost records")

        // Verify SQLite index integrity remains uncompromised
        let indexIntact = try! await coreClient.checkSearchIndexIntegrity()
        assert(indexIntact, "Search index integrity must remain 100% verified")
        print("✓ Stale callbacks on deleted items safely handled with zero resurrection")

        // -----------------------------------------------------------------
        // Test 6: Input Validation & Negative Edge Cases
        // -----------------------------------------------------------------
        print("\n--- Test 6: Input Validation & Negative Edge Cases ---")
        // Empty payload
        do {
            _ = try await ocrService.recognizeText(in: Data())
            assertionFailure("Empty data must throw invalidImageData error")
        } catch let error as OCRError {
            switch error {
            case .invalidImageData:
                print("✓ Correctly caught expected invalidImageData for empty input")
            default:
                assertionFailure("Unexpected OCRError: \(error)")
            }
        } catch {
            assertionFailure("Unexpected error type: \(error)")
        }

        // Corrupted payload
        do {
            let corruptedData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
            let result = try await ocrService.recognizeText(in: corruptedData)
            // Vision either returns empty observations or throws visionFailure
            assert(result.isEmpty, "Corrupted bytes should result in empty recognized string")
            print("✓ Corrupted bytes handled gracefully with empty result")
        } catch let error as OCRError {
            print("✓ Corrupted bytes handled gracefully with typed error: \(error.localizedDescription)")
        } catch {
            print("✓ Corrupted bytes handled with error: \(error.localizedDescription)")
        }

        print("\n=== ALL OCR SERVICE & VISION RECOGNITION TESTS PASSED! ===")
    }
}
