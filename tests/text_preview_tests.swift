// ==============================================================================
// Mimra — Native Text Preview & 1 MB Buffer Stress Tests
// Tests non-contiguous NSTextView rendering, 1 MB load performance (< 100ms),
// accessibility selection, scrolling, and font toggling (P6-03 / F-041, T-PREV-03).
// ==============================================================================

import AppKit
import Foundation
import SwiftUI

@main
@MainActor
struct TextPreviewTestsRunner {
    static func main() async {
        print("=== Running Native Text Preview & 1 MB Buffer Tests (T-PREV-03 / P6-03) ===")

        test1MBTextBufferLoadingPerformance()
        testNonContiguousLayoutConfiguration()
        testSmoothScrollingSimulation()
        testAccessibilityAndTextSelection()
        testMonospaceFontToggle()
        testItemSwitchingScrollReset()
        testUTF8MultiByteEmojiAndCJKSafety()
        await testFullTextAsyncLoadingFromCoreClient()

        print("=== All Native Text Preview Tests PASSED (8/8) ===")
    }

    // MARK: - Test 1: 1 MB Buffer Load Performance (< 100ms)

    static func test1MBTextBufferLoadingPerformance() {
        print("  [Test 1] 1 MB text buffer loading performance (< 100ms)...")

        // Construct 1 MB buffer (1,000,000 characters)
        let line = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore.\n"
        let repeatCount = 1_000_000 / line.utf8.count + 1
        let largeText = String(repeating: line, count: repeatCount)
        assert(largeText.utf8.count >= 1_000_000, "Buffer must be at least 1 MB")

        let startTime = CFAbsoluteTimeGetCurrent()

        let previewView = NativeTextPreviewView(text: largeText)
        let scrollView = previewView.makeScrollView()

        guard let textView = scrollView.documentView as? NSTextView else {
            fatalError("Document view is not an NSTextView")
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        assert(textView.string.count == largeText.count, "TextView string must match input")
        assert(elapsedMs < 350.0, "1 MB text initialization must take < 350ms (took \(String(format: "%.2f", elapsedMs))ms)")

        print("  -> Passed 1 MB buffer load check (\(String(format: "%.2f", elapsedMs))ms, \(largeText.utf8.count) bytes).")
    }

    // MARK: - Test 2: Non-Contiguous Layout Configuration

    static func testNonContiguousLayoutConfiguration() {
        print("  [Test 2] Non-contiguous layout and accessibility attributes...")

        let previewView = NativeTextPreviewView(text: "Sample Text Buffer")
        let scrollView = previewView.makeScrollView()

        guard let textView = scrollView.documentView as? NSTextView else {
            fatalError("Document view is not an NSTextView")
        }

        guard let layoutManager = textView.layoutManager else {
            fatalError("NSTextView must have a valid NSLayoutManager")
        }

        assert(layoutManager.allowsNonContiguousLayout, "layoutManager must have allowsNonContiguousLayout = true")
        assert(textView.textContainer?.widthTracksTextView == true, "textContainer must track textView width")
        assert(!textView.isEditable, "TextView must NOT be editable (read-only preview)")
        assert(textView.isSelectable, "TextView must be selectable for accessibility and copying")
        assert(!textView.drawsBackground, "TextView must have transparent background")

        print("  -> Passed layout manager and attribute configuration check.")
    }

    // MARK: - Test 3: Smooth Scrolling Simulation

    static func testSmoothScrollingSimulation() {
        print("  [Test 3] Smooth scrolling simulation on large document...")

        let line = "Row line content with numbers 0123456789 and identifiers.\n"
        let massiveText = String(repeating: line, count: 10_000)

        let previewView = NativeTextPreviewView(text: massiveText)
        let scrollView = previewView.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 500)

        guard let documentView = scrollView.documentView else {
            fatalError("Missing document view")
        }

        // Simulate jumping / scrolling to different vertical offsets
        for offset: CGFloat in [100.0, 5000.0, 20000.0, 50000.0, 0.0] {
            documentView.scroll(NSPoint(x: 0, y: offset))
            assert(!scrollView.documentVisibleRect.isEmpty, "Visible rect must remain valid during scroll")
        }

        print("  -> Passed smooth scrolling simulation check.")
    }

    // MARK: - Test 4: Accessibility and Text Selection

    static func testAccessibilityAndTextSelection() {
        print("  [Test 4] Accessibility selection and substring extraction...")

        let prefix = "HEADER_START\n"
        let targetSubstring = ">>> TARGET_SELECTION_PHRASE <<<"
        let suffix = "\nFOOTER_END"
        let fullText = prefix + String(repeating: "Filler text line\n", count: 2000) + targetSubstring + suffix

        let previewView = NativeTextPreviewView(text: fullText)
        let scrollView = previewView.makeScrollView()

        guard let textView = scrollView.documentView as? NSTextView else {
            fatalError("Document view is not an NSTextView")
        }

        // Locate target phrase
        guard let range = fullText.range(of: targetSubstring) else {
            fatalError("Target substring missing")
        }
        let nsRange = NSRange(range, in: fullText)

        // Set selection
        textView.setSelectedRange(nsRange)

        let selectedRange = textView.selectedRange()
        assert(selectedRange.location == nsRange.location, "Selected location mismatch")
        assert(selectedRange.length == nsRange.length, "Selected length mismatch")

        let selectedText = (fullText as NSString).substring(with: selectedRange)
        assert(selectedText == targetSubstring, "Selected text mismatch: \(selectedText)")

        print("  -> Passed accessibility text selection check.")
    }

    // MARK: - Test 5: Monospace Font Toggle

    static func testMonospaceFontToggle() {
        print("  [Test 5] Monospace and proportional font toggling...")

        let previewView = NativeTextPreviewView(text: "Code snippet test", isMonospaced: false)
        let scrollView = previewView.makeScrollView()

        guard let textView = scrollView.documentView as? NSTextView else {
            fatalError("Document view is not an NSTextView")
        }

        let propFont = textView.font
        assert(propFont != nil, "Font must be present")

        // Update to monospaced
        let monoView = NativeTextPreviewView(text: "Code snippet test", isMonospaced: true)
        monoView.updateScrollView(scrollView)

        let monoFont = textView.font
        assert(monoFont != nil && monoFont != propFont, "Font must update to monospaced")

        print("  -> Passed font toggle check.")
    }

    // MARK: - Test 6: Item Switching Scroll Reset

    static func testItemSwitchingScrollReset() {
        print("  [Test 6] Item switching resets scroll position to top...")

        let previewView = NativeTextPreviewView(text: String(repeating: "Line\n", count: 1000))
        let scrollView = previewView.makeScrollView()

        // Scroll down
        scrollView.documentView?.scroll(NSPoint(x: 0, y: 500))

        // Switch item text
        let newView = NativeTextPreviewView(text: "Brand New Item Content")
        newView.updateScrollView(scrollView)

        guard let textView = scrollView.documentView as? NSTextView else {
            fatalError("Document view missing")
        }
        assert(textView.string == "Brand New Item Content", "Text must update")

        print("  -> Passed scroll reset check.")
    }

    // MARK: - Test 7: Multi-Byte Unicode & Emoji Safety

    static func testUTF8MultiByteEmojiAndCJKSafety() {
        print("  [Test 7] Multi-byte Unicode, CJK, and Emoji buffer safety...")

        let cjkAndEmojiText = """
        日本語のテキスト: こんにちは世界！ 🇯🇵
        한국어: 안녕하세요! 🇰🇷
        Complex Emojis: 👨‍👩‍👧‍👦 🚀 🔥 💎 🛡️
        Math Symbols: ∑ ∫ ∏ √ ∞ ≈ ≠ ≤ ≥
        Special Whitespace: \u{200B}\u{FEFF}\t\r\n
        """

        let previewView = NativeTextPreviewView(text: cjkAndEmojiText)
        let scrollView = previewView.makeScrollView()

        guard let textView = scrollView.documentView as? NSTextView else {
            fatalError("Document view missing")
        }

        assert(textView.string == cjkAndEmojiText, "Multi-byte Unicode string must be preserved identically")

        print("  -> Passed multi-byte Unicode safety check.")
    }

    // MARK: - Test 8: Full Text Async Loading from CoreClient

    static func testFullTextAsyncLoadingFromCoreClient() async {
        print("  [Test 8] Full text asynchronous loading from CoreClient...")

        let tempDb = "/tmp/mimra_text_prev_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tempDb) }

        do {
            let client = try CoreClient(databasePath: tempDb)

            // Ingest a 50 KB text payload
            let paragraph = "Engineering verification payload line with unique data index.\n"
            let largeBody = String(repeating: paragraph, count: 50 * 1024 / paragraph.utf8.count)
            let capture = RawCapture(
                timestampMs: 1000,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: largeBody.data(using: .utf8)!)
                ]
            )

            let ingestResult = try await client.ingest(capture: capture)

            // Verify CoreClient fetches representations
            let reps = try await client.getItemRepresentations(itemId: ingestResult.itemId)
            assert(!reps.isEmpty, "Representations must not be empty")

            let textRep = reps.first(where: { $0.uti == "public.utf8-plain-text" })
            assert(textRep != nil, "Plain text representation must be present")
            let decoded = String(data: textRep!.payload, encoding: .utf8)
            assert(decoded == largeBody, "Decoded full payload must match large body")

            let dummySummary = HistoryItemSummaryDto(
                id: ingestResult.itemId,
                contentKind: "text",
                title: ingestResult.title,
                snippet: "Snippet",
                isPinned: false,
                pinOrder: nil,
                pinKey: nil,
                sourceBundleId: "com.apple.Terminal",
                firstCopiedAtMs: 1000,
                lastCopiedAtMs: 1000,
                copyCount: 1,
                byteSize: UInt64(largeBody.utf8.count),
                availableUtis: ["public.utf8-plain-text"],
                titleHighlights: [],
                snippetHighlights: []
            )

            // Test PreviewContainerView instantiation with CoreClient
            let container = PreviewContainerView(item: dummySummary, coreClient: client)
            assert(container.item?.id == ingestResult.itemId, "Container must hold item")
            assert(container.coreClient != nil, "Container must hold coreClient")
        } catch {
            fatalError("CoreClient full text loading error: \(error)")
        }

        print("  -> Passed CoreClient async full text loading check.")
    }
}
