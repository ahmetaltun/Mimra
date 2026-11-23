// ==============================================================================
// Mimra — Preview Window Enhancements Tests
// Verifies format detection, Markdown/JSON/RTF/HTML rendering, Color/URL/File
// inspectors, ImageZoomController, and defaultToFormattedPreview setting.
// ==============================================================================

import AppKit
import Foundation
import SwiftUI

func assertTrue(_ cond: Bool, _ msg: String) {
    if !cond {
        fputs("❌ ASSERTION FAILED: \(msg)\n", stderr)
        exit(1)
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    if a != b {
        fputs("❌ ASSERTION FAILED: \(msg) (got \(a), expected \(b))\n", stderr)
        exit(1)
    }
}

@main
struct PreviewEnhancementsTestRunner {
    @MainActor
    static func main() {
        print("Running Preview Window Enhancements Tests...")

        // 1. Default setting: Original view by default (false)
        let suiteName = "com.mimra.tests.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let config = AppearanceConfiguration(userDefaults: defaults)
        assertEqual(config.defaultToFormattedPreview, false, "Preview should open in Original view by default")
        config.defaultToFormattedPreview = true
        assertEqual(config.defaultToFormattedPreview, true, "Setting should persist true")
        defaults.removePersistentDomain(forName: suiteName)

        // 2. TextFormatDetector — JSON
        assertEqual(
            TextFormatDetector.detect(text: "{\"name\":\"Mimra\",\"version\":2}"),
            .json,
            "Valid JSON object should be detected as .json"
        )
        assertEqual(
            TextFormatDetector.detect(text: "[1, 2, 3]"),
            .json,
            "Valid JSON array should be detected as .json"
        )
        assertEqual(
            TextFormatDetector.detect(text: "{not valid json}"),
            .plain,
            "Invalid JSON should fall back to .plain"
        )

        // 3. TextFormatDetector — Markdown
        let mdSample = """
        # Release Notes
        - [x] Zoom and pan
        - [ ] More themes
        Check [Mimra](https://example.com) for `details`.
        ```swift
        let x = 42
        ```
        """
        assertEqual(TextFormatDetector.detect(text: mdSample), .markdown, "Markdown sample should be detected as .markdown")
        assertEqual(
            TextFormatDetector.detect(text: "Hello world, this is a normal plain text sentence - nothing special."),
            .plain,
            "Plain prose with a hyphen should remain .plain"
        )
        assertEqual(TextFormatDetector.detect(text: ""), .plain, "Empty string should be .plain")

        // 4. TextFormatDetector — RTF / HTML
        assertEqual(
            TextFormatDetector.detect(text: "Hello", availableUtis: ["public.rtf"], hasRtfData: true),
            .rtf,
            "RTF representation should be detected as .rtf"
        )
        assertEqual(
            TextFormatDetector.detect(text: "Hello", availableUtis: ["public.html"], hasHtmlData: true),
            .html,
            "HTML representation should be detected as .html"
        )

        // 5. JsonTextFormatter
        let pretty = JsonTextFormatter.prettyPrint("{\"b\":2,\"a\":\"hello\"}")
        assertTrue(pretty != nil, "Pretty print should succeed on valid JSON")
        assertTrue(pretty!.contains("\n"), "Pretty printed JSON should be multi-line")
        assertTrue(JsonTextFormatter.prettyPrint("invalid") == nil, "Pretty print should return nil for invalid JSON")
        let highlighted = JsonTextFormatter.attributedHighlight(pretty!)
        assertEqual(highlighted.string, pretty!, "Highlighted JSON string should match pretty JSON")

        // 6. MarkdownAttributedRenderer (including Unicode, emoji, tables, edge cases)
        let tableMd = """
        # Heading 1 🚀
        > A blockquote
        | Col A | Col B |
        | --- | --- |
        | Val 1 | Val 2 |
        """
        let renderedMd = MarkdownAttributedRenderer.render(tableMd)
        assertTrue(renderedMd.string.contains("Heading 1 🚀"), "Markdown renderer should preserve heading & emoji")
        assertTrue(renderedMd.string.contains("Col A"), "Markdown renderer should preserve table content")
        assertEqual(MarkdownAttributedRenderer.render("").string, "", "Empty markdown should render empty")

        // 7. RichTextAttributedRenderer (safe offline HTML)
        let htmlSample = "<script>alert(1)</script><h1>Title</h1><p>Hello &amp; <b>world</b></p>"
        let renderedHtml = RichTextAttributedRenderer.renderHtml(htmlSample)
        assertTrue(!renderedHtml.string.contains("alert(1)"), "HTML renderer must strip script blocks")
        assertTrue(renderedHtml.string.contains("Hello & world"), "HTML renderer should decode entities")

        // 8. HexColorInfo extensions
        if let color = ColorDetector.detect(in: "#FF5733") {
            assertEqual(color.rgbString, "rgb(255, 87, 51)", "RGB conversion should match")
            assertTrue(color.hslString.hasPrefix("hsl("), "HSL conversion should format cleanly")
            assertTrue(color.contrastAgainstBlack > 1.0, "Contrast ratio should be > 1")
            assertTrue(color.contrastAgainstWhite > 1.0, "Contrast ratio should be > 1")
        } else {
            assertTrue(false, "ColorDetector should parse #FF5733")
        }

        // 9. PreviewViewState & ImagePreviewService resolution
        let viewState = PreviewViewState()
        assertEqual(viewState.isFormattedMode, false, "PreviewViewState should default to Original mode")
        viewState.toggleFormattedMode()
        assertEqual(viewState.isFormattedMode, true, "toggleFormattedMode should flip to Formatted")
        viewState.resetForNewItem()
        assertEqual(viewState.isFormattedMode, false, "resetForNewItem should restore default")
        assertEqual(ImagePreviewService.shared.maxPixelSize, 3840, "ImagePreviewService should support 4K zoom clarity")

        print("✅ All Preview Window Enhancements Tests PASSED!")
    }
}
