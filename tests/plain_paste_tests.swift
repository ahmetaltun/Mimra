// ==============================================================================
// Mimra Tests — Plain Paste & Formatted Downgrade Verification
// Linked Features: F-020, F-021
// Test IDs: T-PASTE-03
// ==============================================================================

import AppKit
import Foundation

@main
struct PlainPasteTests {
    @MainActor
    static func main() async {
        print("=== Running Plain Paste & Formatted Downgrade Tests (T-PASTE-03) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let core = try! CoreClient.inMemory()
        let testPbName = NSPasteboard.Name("com.mimra.test.plainpaste.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: testPbName)
        let provenanceGuard = ClipboardProvenance()
        let coordinator = PasteCoordinator(
            coreClient: core,
            pasteboard: pasteboard,
            provenanceGuard: provenanceGuard
        )

        // ---------------------------------------------------------------------
        // 1. T-PASTE-03: Strip Rich Formats (RTF + HTML + Plain Text)
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-03: Strip Rich Formats to Plain Text ---")
        let plainSample = "Plain Text Content Here"
        let plainData = plainSample.data(using: .utf8)!
        let htmlSample = "<p><b>Bold HTML</b></p>"
        let htmlData = htmlSample.data(using: .utf8)!
        let rtfSample = "{\\rtf1\\ansi\\b Bold RTF\\b0}"
        let rtfData = rtfSample.data(using: .utf8)!

        let richCapture = RawCapture(
            timestampMs: 1000,
            sourceBundleId: "com.apple.Safari",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: plainData),
                RawRepresentation(groupIndex: 0, uti: "public.html", payload: htmlData),
                RawRepresentation(groupIndex: 0, uti: "public.rtf", payload: rtfData)
            ]
        )
        let richIngest = try! await core.ingest(capture: richCapture)
        let richItemId = richIngest.itemId

        try! await coordinator.writeToPasteboard(itemId: richItemId, mode: .plainText)

        guard let items = pasteboard.pasteboardItems, items.count == 1 else {
            fatalError("FAIL: Expected 1 stripped item on pasteboard, got \(pasteboard.pasteboardItems?.count ?? 0)")
        }
        let strippedItem = items[0]
        assert(strippedItem.string(forType: .string) == plainSample, "FAIL: Plain text string must match original.")
        assert(!strippedItem.types.contains(NSPasteboard.PasteboardType("public.html")), "FAIL: HTML UTI must be stripped in .plainText mode.")
        assert(!strippedItem.types.contains(NSPasteboard.PasteboardType("public.rtf")), "FAIL: RTF UTI must be stripped in .plainText mode.")
        assert(strippedItem.types.contains(ClipboardProvenance.provenanceType), "FAIL: Provenance marker must be stamped.")

        print("✓ T-PASTE-03: Multi-representation rich text stripped cleanly to plain text.")

        // ---------------------------------------------------------------------
        // 2. T-PASTE-03: RTF-Only Extraction (No Plain Text UTI)
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-03: RTF-Only Extraction ---")
        let rtfOnlyCapture = RawCapture(
            timestampMs: 2000,
            sourceBundleId: "com.apple.TextEdit",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.rtf", payload: rtfData)
            ]
        )
        let rtfOnlyIngest = try! await core.ingest(capture: rtfOnlyCapture)
        try! await coordinator.writeToPasteboard(itemId: rtfOnlyIngest.itemId, mode: .plainText)

        guard let rtfItems = pasteboard.pasteboardItems, rtfItems.count == 1 else {
            fatalError("FAIL: Expected 1 item for RTF-only plain paste.")
        }
        let extractedRtfText = rtfItems[0].string(forType: .string)
        assert(extractedRtfText == "Bold RTF", "FAIL: Plain text extracted from RTF must equal 'Bold RTF', got '\(extractedRtfText ?? "")'")
        assert(!rtfItems[0].types.contains(NSPasteboard.PasteboardType("public.rtf")), "FAIL: RTF UTI must be stripped.")

        print("✓ T-PASTE-03: Plain text successfully extracted from RTF-only capture.")

        // ---------------------------------------------------------------------
        // 3. T-PASTE-03: HTML-Only Extraction (No Plain Text UTI)
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-03: HTML-Only Extraction ---")
        let htmlOnlyCapture = RawCapture(
            timestampMs: 3000,
            sourceBundleId: "com.google.Chrome",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.html", payload: htmlData)
            ]
        )
        let htmlOnlyIngest = try! await core.ingest(capture: htmlOnlyCapture)
        try! await coordinator.writeToPasteboard(itemId: htmlOnlyIngest.itemId, mode: .plainText)

        guard let htmlItems = pasteboard.pasteboardItems, htmlItems.count == 1 else {
            fatalError("FAIL: Expected 1 item for HTML-only plain paste.")
        }
        let extractedHtmlText = htmlItems[0].string(forType: .string)
        assert(extractedHtmlText == "Bold HTML", "FAIL: Plain text extracted from HTML must equal 'Bold HTML', got '\(extractedHtmlText ?? "")'")
        assert(!htmlItems[0].types.contains(NSPasteboard.PasteboardType("public.html")), "FAIL: HTML UTI must be stripped.")

        print("✓ T-PASTE-03: Plain text successfully extracted from HTML-only capture.")

        // ---------------------------------------------------------------------
        // 4. T-PASTE-03: Single File URL Conversion (Percent-Encoded Path)
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-03: Single File URL Conversion ---")
        let fileUrlString = "file:///Users/testuser/My%20Documents/Report%202026.pdf"
        let fileUrlData = fileUrlString.data(using: .utf8)!
        let fileCapture = RawCapture(
            timestampMs: 4000,
            sourceBundleId: "com.apple.finder",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.file-url", payload: fileUrlData)
            ]
        )
        let fileIngest = try! await core.ingest(capture: fileCapture)
        try! await coordinator.writeToPasteboard(itemId: fileIngest.itemId, mode: .plainText)

        guard let fileItems = pasteboard.pasteboardItems, fileItems.count == 1 else {
            fatalError("FAIL: Expected 1 item for file URL plain paste.")
        }
        let extractedFilePath = fileItems[0].string(forType: .string)
        assert(
            extractedFilePath == "/Users/testuser/My Documents/Report 2026.pdf",
            "FAIL: Expected decoded POSIX path '/Users/testuser/My Documents/Report 2026.pdf', got '\(extractedFilePath ?? "")'"
        )

        print("✓ T-PASTE-03: Percent-encoded file URL converted to decoded plain POSIX path.")

        // ---------------------------------------------------------------------
        // 5. T-PASTE-03: Multi-File Reference Conversion (Multiple Groups)
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-03: Multi-File Reference Conversion ---")
        let file1Url = "file:///Users/testuser/file1.txt".data(using: .utf8)!
        let file2Url = "file:///Users/testuser/file2.txt".data(using: .utf8)!
        let multiFileCapture = RawCapture(
            timestampMs: 5000,
            sourceBundleId: "com.apple.finder",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.file-url", payload: file1Url),
                RawRepresentation(groupIndex: 1, uti: "public.file-url", payload: file2Url)
            ]
        )
        let multiFileIngest = try! await core.ingest(capture: multiFileCapture)
        try! await coordinator.writeToPasteboard(itemId: multiFileIngest.itemId, mode: .plainText)

        guard let multiFileItems = pasteboard.pasteboardItems, multiFileItems.count == 1 else {
            fatalError("FAIL: Expected 1 merged plain-text item for multi-file plain paste.")
        }
        let multiFilePathString = multiFileItems[0].string(forType: .string)
        let expectedMulti = "/Users/testuser/file1.txt\n/Users/testuser/file2.txt"
        assert(
            multiFilePathString == expectedMulti,
            "FAIL: Expected multi-file newline joined string '\(expectedMulti)', got '\(multiFilePathString ?? "")'"
        )

        print("✓ T-PASTE-03: Multi-file references joined by newlines into plain text list.")

        // ---------------------------------------------------------------------
        // 6. T-PASTE-03: NSFilenamesPboardType Property List Conversion
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-03: NSFilenamesPboardType Conversion ---")
        let plistPaths = ["/Applications/Mimra.app", "/Applications/Xcode.app"]
        let plistData = try! PropertyListSerialization.data(fromPropertyList: plistPaths, format: .xml, options: 0)
        let plistCapture = RawCapture(
            timestampMs: 6000,
            sourceBundleId: "com.apple.finder",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "NSFilenamesPboardType", payload: plistData)
            ]
        )
        let plistIngest = try! await core.ingest(capture: plistCapture)
        try! await coordinator.writeToPasteboard(itemId: plistIngest.itemId, mode: .plainText)

        guard let plistItems = pasteboard.pasteboardItems, plistItems.count == 1 else {
            fatalError("FAIL: Expected 1 item for NSFilenamesPboardType plain paste.")
        }
        let extractedPlistText = plistItems[0].string(forType: .string)
        let expectedPlist = "/Applications/Mimra.app\n/Applications/Xcode.app"
        assert(
            extractedPlistText == expectedPlist,
            "FAIL: Expected '\(expectedPlist)', got '\(extractedPlistText ?? "")'"
        )

        print("✓ T-PASTE-03: NSFilenamesPboardType property list converted to plain text.")

        // ---------------------------------------------------------------------
        // 7. T-PASTE-03: Binary / Image Fallback Preservation
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-03: Binary Image Fallback Preservation ---")
        let fakeImageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG magic bytes
        let imageCapture = RawCapture(
            timestampMs: 7000,
            sourceBundleId: "com.apple.Preview",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.png", payload: fakeImageData)
            ]
        )
        let imageIngest = try! await core.ingest(capture: imageCapture)
        try! await coordinator.writeToPasteboard(itemId: imageIngest.itemId, mode: .plainText)

        // When plain text cannot be extracted from a pure image, it falls back to original representation
        guard let fallbackItems = pasteboard.pasteboardItems, fallbackItems.count == 1 else {
            fatalError("FAIL: Image fallback should preserve 1 pasteboard item.")
        }
        assert(fallbackItems[0].data(forType: NSPasteboard.PasteboardType("public.png")) == fakeImageData, "FAIL: Image data must be preserved on plain-text fallback.")

        print("✓ T-PASTE-03: Binary image safely falls back to original representation without error.")

        // ---------------------------------------------------------------------
        // 8. T-PASTE-03: PanelCoordinator Keyboard Modifiers for Plain Paste
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-03: Keyboard Modifiers for Plain Paste & Inverted Auto-Paste ---")
        let panelCoordinator = PanelCoordinator(coreClient: core, pasteCoordinator: coordinator)
        var lastCommittedItem: HistoryItemSummaryDto?
        var lastCommittedMode: PasteMode?
        var lastCommittedForce: Bool?

        panelCoordinator.viewModel.onCommitItem = { item, mode, forcePaste in
            lastCommittedItem = item
            lastCommittedMode = mode
            lastCommittedForce = forcePaste
        }

        let summary = HistoryItemSummaryDto(
            id: richItemId,
            contentKind: "text",
            title: "Test Rich",
            snippet: "Plain Text Content Here",
            isPinned: false,
            pinOrder: nil,
            pinKey: nil,
            sourceBundleId: "com.apple.Safari",
            firstCopiedAtMs: 1000,
            lastCopiedAtMs: 1000,
            copyCount: 1,
            byteSize: 100,
            availableUtis: ["public.utf8-plain-text", "public.html", "public.rtf"]
        )
        panelCoordinator.viewModel.items = [summary]
        panelCoordinator.viewModel.selectedIndex = 0

        // A. Shift-Return (Plain Paste)
        let shiftReturnEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36 // Return
        )!
        assert(panelCoordinator.handlePanelKeyDown(event: shiftReturnEvent), "FAIL: Shift-Return should be handled.")
        assert(lastCommittedItem?.id == richItemId, "FAIL: Committed item ID must match.")
        assert(lastCommittedMode == .plainText, "FAIL: Shift-Return must commit in .plainText mode.")
        assert(lastCommittedForce == nil, "FAIL: Shift-Return without Option should not force paste.")

        // B. Option-Shift-Return (Plain Copy / Inverted Auto-Paste)
        let optShiftReturnEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!
        assert(panelCoordinator.handlePanelKeyDown(event: optShiftReturnEvent), "FAIL: Option-Shift-Return should be handled.")
        assert(lastCommittedMode == .plainText, "FAIL: Option-Shift-Return must commit in .plainText mode.")
        assert(lastCommittedForce == false, "FAIL: Option-Shift-Return must invert auto-paste (forcePaste: false).")

        // C. Shift-Command-1 (Quick-Pick Plain Paste)
        let shiftCmd1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18 // '1'
        )!
        assert(panelCoordinator.handlePanelKeyDown(event: shiftCmd1Event), "FAIL: Shift-Command-1 should be handled.")
        assert(lastCommittedMode == .plainText, "FAIL: Shift-Command-1 must commit in .plainText mode.")
        assert(lastCommittedForce == nil, "FAIL: Shift-Command-1 should not force paste.")

        // D. Option-Shift-Command-1 (Quick-Pick Plain Copy)
        let optShiftCmd1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        )!
        assert(panelCoordinator.handlePanelKeyDown(event: optShiftCmd1Event), "FAIL: Option-Shift-Command-1 should be handled.")
        assert(lastCommittedMode == .plainText, "FAIL: Option-Shift-Command-1 must commit in .plainText mode.")
        assert(lastCommittedForce == false, "FAIL: Option-Shift-Command-1 must invert auto-paste (forcePaste: false).")

        print("✓ T-PASTE-03: Mode-specific shortcuts (Shift-Return, Option-Shift-Return, ⇧⌘1, ⌥⇧⌘1) verified.")

        print("✓ ALL Plain Paste & Formatted Downgrade Tests PASSED!")
    }
}
