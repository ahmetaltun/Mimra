// ==============================================================================
// Mimra — OCR Race Protection & High-Concurrency Dismissal Stress Tests
// Validates that delete and clear operations while OCR is pending never resurrect
// deleted items, and runs a comprehensive 1,000 rapid changes + dismissals stress test.
// Linked Features: F-040, F-043, F-051, F-052
// Test IDs: T-PREV-02, T-SRCH-04, T-OCR-03
// ==============================================================================

import AppKit
import CoreGraphics
import Foundation
@preconcurrency import Vision

@main
@MainActor
struct OCRRaceProtectionTests {
    static func main() async {
        print("=== Running OCR Race Protection & 1,000 Rapid Changes Stress Tests (P6-07 / T-PREV-02, T-SRCH-04) ===")

        let tempDbPath = "/tmp/mimra_ocr_race_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDbPath)
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-shm")
        }

        // Helper: Generate synthetic test image with crisp rendered text
        func makeTestImage(text: String, width: Int = 400, height: Int = 200) -> Data {
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

            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            let font = NSFont.boldSystemFont(ofSize: 22)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let attrString = NSAttributedString(string: text, attributes: attrs)
            attrString.draw(at: NSPoint(x: 20, y: 80))

            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!
        }

        let coreClient = try! CoreClient(databasePath: tempDbPath)
        let ocrService = OCRService.shared

        // -----------------------------------------------------------------
        // Test 1: Immediate Deletion while OCR in-flight (Zero Resurrection)
        // -----------------------------------------------------------------
        print("\n--- Test 1: Immediate Deletion while Vision OCR in-flight ---")
        let test1Text = "Ephemeral Confidential Token ABC987"
        let img1 = makeTestImage(text: test1Text)

        let cap1 = RawCapture(
            timestampMs: 1_000_000,
            sourceBundleId: "com.apple.Preview",
            representations: [RawRepresentation(groupIndex: 0, uti: "public.png", payload: img1)]
        )
        let ingest1 = try! await coreClient.ingest(capture: cap1)
        let id1 = ingest1.itemId

        // Launch OCR task
        let ocrTask1 = Task { () -> String? in
            try? await ocrService.recognizeAndIndex(
                itemId: id1,
                imageData: img1,
                coreClient: coreClient
            )
        }

        // Immediately delete item while OCR is executing
        await ocrService.cancel(itemId: id1)
        let deleted1 = try! await coreClient.deleteItem(itemId: id1)
        assert(deleted1, "Item must be deleted successfully")

        _ = await ocrTask1.value

        // Assert item was NOT resurrected in SQLite or FTS5
        let storedOcr1 = try! await coreClient.getOcrText(itemId: id1)
        assert(storedOcr1 == nil, "Deleted item must not have OCR text or exist in history")

        let search1 = try! await coreClient.searchPage(query: "Ephemeral", mode: .fuzzy, limit: 10, offset: 0)
        assert(search1.isEmpty, "FTS5 search must not find text from deleted item")

        let integrity1 = try! await coreClient.checkSearchIndexIntegrity()
        assert(integrity1, "FTS5 index integrity must remain 100% verified")
        print("✓ Immediate deletion while OCR in-flight safely completed with zero item resurrection")

        // -----------------------------------------------------------------
        // Test 2: Clear Unpinned while multiple OCR tasks in-flight
        // -----------------------------------------------------------------
        print("\n--- Test 2: Clear Unpinned while multiple OCR tasks in-flight ---")
        var batchIds: [String] = []
        var batchTasks: [Task<String?, Never>] = []

        for i in 0..<5 {
            let txt = "Batch OCR Content Index \(i) Alpha"
            let img = makeTestImage(text: txt)
            let cap = RawCapture(
                timestampMs: Int64(2_000_000 + i),
                sourceBundleId: "com.apple.Preview",
                representations: [RawRepresentation(groupIndex: 0, uti: "public.png", payload: img)]
            )
            let ing = try! await coreClient.ingest(capture: cap)
            batchIds.append(ing.itemId)

            let t = Task { () -> String? in
                try? await ocrService.recognizeAndIndex(
                    itemId: ing.itemId,
                    imageData: img,
                    coreClient: coreClient
                )
            }
            batchTasks.append(t)
        }

        // Immediately clear unpinned and cancel all
        await ocrService.cancelAll()
        let clearedCount = try! await coreClient.clearUnpinned()
        assert(clearedCount == 5, "Must clear all 5 unpinned items")

        for t in batchTasks {
            _ = await t.value
        }

        let statsAfterClear = try! await coreClient.getStats()
        assert(statsAfterClear.totalItems == 0, "Total items must remain 0 after clear_unpinned")

        let searchBatch = try! await coreClient.searchPage(query: "Alpha", mode: .fuzzy, limit: 10, offset: 0)
        assert(searchBatch.isEmpty, "Search must return 0 results after clear_unpinned")
        print("✓ Clear unpinned during concurrent OCR safely cleared history with zero resurrecting items")

        // -----------------------------------------------------------------
        // Test 3: Clear All with Pinned Items during in-flight OCR
        // -----------------------------------------------------------------
        print("\n--- Test 3: Clear All with Pinned Items during in-flight OCR ---")
        let pinnedImg = makeTestImage(text: "Pinned Secret Diagnostic")
        let capPinned = RawCapture(
            timestampMs: 3_000_000,
            sourceBundleId: "com.apple.Preview",
            representations: [RawRepresentation(groupIndex: 0, uti: "public.png", payload: pinnedImg)]
        )
        let ingPinned = try! await coreClient.ingest(capture: capPinned)
        try! await coreClient.setPin(itemId: ingPinned.itemId, isPinned: true, pinKey: "1")

        let pinnedTask = Task { () -> String? in
            try? await ocrService.recognizeAndIndex(
                itemId: ingPinned.itemId,
                imageData: pinnedImg,
                coreClient: coreClient
            )
        }

        await ocrService.cancelAll()
        let clearedAllCount = try! await coreClient.clearAll()
        assert(clearedAllCount >= 1, "Must clear pinned item")

        _ = await pinnedTask.value

        let statsAfterAll = try! await coreClient.getStats()
        assert(statsAfterAll.totalItems == 0, "Total items must be 0 after clearAll")

        let searchPinned = try! await coreClient.searchPage(query: "Diagnostic", mode: .fuzzy, limit: 10, offset: 0)
        assert(searchPinned.isEmpty, "Search must find 0 items after clearAll")
        print("✓ Clear all during concurrent OCR safely wiped all items with zero resurrection")

        // -----------------------------------------------------------------
        // Test 4: Stress Test: 1,000 Rapid Changes + Dismissals (DoD Requirement)
        // -----------------------------------------------------------------
        print("\n--- Test 4: High-Concurrency Stress Test (1,000 Rapid Changes + Dismissals) ---")
        let previewCoordinator = PreviewCoordinator(coreClient: coreClient)
        previewCoordinator.isAutoOpenEnabled = true
        previewCoordinator.autoOpenDelayMs = 50

        // Pre-generate synthetic images to eliminate repetitive PNG encoding overhead
        let testImagePalette = (0..<5).map { makeTestImage(text: "StressItem \($0)", width: 160, height: 80) }

        var liveItemIds: [String] = []
        var backgroundTasks: [Task<Void, Never>] = []

        let startTime = DispatchTime.now().uptimeNanoseconds

        for iteration in 0..<1000 {
            let actionType = iteration % 10

            switch actionType {
            case 0, 1:
                // Rapid Image Ingestion with concurrent OCR dispatch
                let imgData = testImagePalette[iteration % testImagePalette.count]
                let cap = RawCapture(
                    timestampMs: Int64(4_000_000 + iteration),
                    sourceBundleId: "com.apple.Preview",
                    representations: [RawRepresentation(groupIndex: 0, uti: "public.png", payload: imgData)]
                )
                if let ing = try? await coreClient.ingest(capture: cap) {
                    liveItemIds.append(ing.itemId)

                    let t = Task {
                        _ = try? await ocrService.recognizeAndIndex(
                            itemId: ing.itemId,
                            imageData: imgData,
                            coreClient: coreClient
                        )
                    }
                    backgroundTasks.append(t)
                }

            case 2:
                // Rapid Plain Text Ingestion
                let textPayload = "Rapid Text Clip \(iteration)".data(using: .utf8)!
                let cap = RawCapture(
                    timestampMs: Int64(4_000_000 + iteration),
                    sourceBundleId: "com.apple.Terminal",
                    representations: [RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: textPayload)]
                )
                if let ing = try? await coreClient.ingest(capture: cap) {
                    liveItemIds.append(ing.itemId)
                }

            case 3, 4:
                // Rapid Preview Placement & Dismissal Geometry Cycle
                let placement = PreviewBoundsCalculator.calculatePlacement(
                    parentFrame: CGRect(x: 200, y: 200, width: 340, height: 480),
                    previewSize: CGSize(width: 360, height: 460),
                    screenVisibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    gap: 6.0,
                    preferredSide: (iteration % 2 == 0) ? .right : .left
                )
                assert(placement.frame.width == 360)
                previewCoordinator.cancelAutoOpenTimer()

            case 5:
                // Rapid Preview Dismissal
                previewCoordinator.hide()
                previewCoordinator.cancelAutoOpenTimer()

            case 6:
                // Rapid Item Deletion with immediate OCR cancellation
                if !liveItemIds.isEmpty {
                    let targetIndex = iteration % liveItemIds.count
                    let targetId = liveItemIds.remove(at: targetIndex)
                    await ocrService.cancel(itemId: targetId)
                    _ = try? await coreClient.deleteItem(itemId: targetId)
                }

            case 7:
                // Rapid Search Query
                _ = try? await coreClient.searchPage(query: "StressItem", mode: .fuzzy, limit: 5, offset: 0)

            case 8:
                // Toggle Pin Status on random active item
                if let randomId = liveItemIds.last {
                    _ = try? await coreClient.setPin(itemId: randomId, isPinned: (iteration % 2 == 0))
                }

            case 9:
                // Periodic Sweep: cancel all in-flight OCR and clear unpinned history
                if iteration % 100 == 9 {
                    await ocrService.cancelAll()
                    _ = try? await coreClient.clearUnpinned()
                    liveItemIds.removeAll()
                    previewCoordinator.hide()
                }

            default:
                break
            }
        }

        // Cleanly cancel and drain any remaining in-flight background OCR tasks
        await ocrService.cancelAll()
        for task in backgroundTasks {
            _ = await task.value
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000.0
        print("✓ Completed 1,000 rapid changes + dismissals in \(String(format: "%.1f", elapsedMs))ms")

        // -----------------------------------------------------------------
        // Verification & Post-Stress Invariants
        // -----------------------------------------------------------------
        print("\n--- Verifying Post-Stress System Integrity & Invariants ---")

        // 1. Verify all active OCR tasks drained cleanly (zero leaks)
        let activeOcrCount = await ocrService.activeTaskCount
        assert(activeOcrCount == 0, "activeTaskCount must be 0 after test completion")

        // 2. Verify FTS5 virtual table integrity
        let indexIntact = try! await coreClient.checkSearchIndexIntegrity()
        assert(indexIntact, "SQLite search index integrity must be 100% intact after 1,000 operations")

        // 3. Verify PreviewCoordinator is clean and dismissed
        assert(!previewCoordinator.isPreviewVisible, "Preview coordinator must be dismissed")

        print("✓ All invariants verified: zero leaks, 100% index integrity, clean dismissal")
        print("\n=== ALL OCR RACE PROTECTION & DISMISSAL STRESS TESTS PASSED! ===")
    }
}
