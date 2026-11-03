// ==============================================================================
// Mimra Tests — Paste Replay Codec Verification
// Linked Features: F-012, F-020, F-021
// Test IDs: T-PASTE-01, T-PASTE-02, T-CAP-05
// ==============================================================================

import AppKit
import Foundation

@main
struct PasteReplayTests {
    @MainActor
    static func main() async {
        print("=== Running Paste Replay Codec Tests (T-PASTE-01, T-PASTE-02, T-CAP-05) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Initialize ephemeral in-memory CoreClient
        let core = try! CoreClient.inMemory()

        // Create a unique named pasteboard for testing isolation
        let testPbName = NSPasteboard.Name("com.mimra.test.pasteboard.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: testPbName)
        let provenanceGuard = ClipboardProvenance()
        let coordinator = PasteCoordinator(
            coreClient: core,
            pasteboard: pasteboard,
            provenanceGuard: provenanceGuard
        )

        // ---------------------------------------------------------------------
        // 1. T-PASTE-01: Plain text round-trip and provenance stamping
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-01: Plain Text Round-Trip & Provenance ---")
        let textPayload = "Hello Mimra Replay Codec! 🚀"
        let textData = textPayload.data(using: .utf8)!

        let plainCapture = RawCapture(
            timestampMs: 1000,
            sourceBundleId: "com.apple.Terminal",
            representations: [
                RawRepresentation(
                    groupIndex: 0,
                    uti: "public.utf8-plain-text",
                    payload: textData
                )
            ]
        )

        let ingestResult = try! await core.ingest(capture: plainCapture)
        let itemId = ingestResult.itemId

        // Replay to pasteboard
        let changeCountAfterReplay = try! await coordinator.writeToPasteboard(
            itemId: itemId,
            mode: .original
        )

        assert(changeCountAfterReplay > 0, "Pasteboard changeCount must advance after write.")
        assert(pasteboard.changeCount == changeCountAfterReplay, "Returned changeCount must match pasteboard.")

        // Verify pasteboard content byte-exact match
        guard let items = pasteboard.pasteboardItems, items.count == 1 else {
            fatalError("Assertion failed: Expected 1 pasteboard item, found \(pasteboard.pasteboardItems?.count ?? 0)")
        }

        let replayedString = items[0].string(forType: .string)
        assert(replayedString == textPayload, "Replayed text must match original string byte-for-byte.")

        let replayedData = items[0].data(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
        assert(replayedData == textData, "Replayed raw bytes must match original UTF-8 bytes exactly.")

        // Verify provenance markers
        assert(items[0].types.contains(ClipboardProvenance.provenanceType), "Provenance UTI marker must be present on replayed item.")
        let sourceVal = items[0].string(forType: ClipboardProvenance.sourceAppType)
        assert(sourceVal == ClipboardProvenance.mimraBundleIdentifier, "Source app marker must match Mimra bundle identifier.")

        // Verify that provenanceGuard recognizes this write as self-generated (preventing recapture)
        let isSelf = provenanceGuard.isSelfGenerated(changeCount: pasteboard.changeCount, pasteboard: pasteboard)
        assert(isSelf, "Provenance guard must recognize replayed item as self-generated.")

        print("✓ T-PASTE-01: Plain text round-trip matches byte-for-byte and stamps provenance.")

        // ---------------------------------------------------------------------
        // 2. T-PASTE-02: Multi-representation round-trip (.original mode)
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-02: Multi-Representation Original Replay ---")
        let plainText = "Bold Formatting Test"
        let plainBytes = plainText.data(using: .utf8)!
        let htmlText = "<b>Bold Formatting Test</b>"
        let htmlBytes = htmlText.data(using: .utf8)!
        let rtfText = "{\\rtf1\\ansi\\b Bold Formatting Test\\b0}"
        let rtfBytes = rtfText.data(using: .utf8)!

        let richCapture = RawCapture(
            timestampMs: 2000,
            sourceBundleId: "com.apple.Safari",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: plainBytes),
                RawRepresentation(groupIndex: 0, uti: "public.html", payload: htmlBytes),
                RawRepresentation(groupIndex: 0, uti: "public.rtf", payload: rtfBytes),
            ]
        )

        let richIngest = try! await core.ingest(capture: richCapture)
        let richItemId = richIngest.itemId

        try! await coordinator.writeToPasteboard(itemId: richItemId, mode: .original)

        guard let richItems = pasteboard.pasteboardItems, richItems.count == 1 else {
            fatalError("Assertion failed: Expected 1 rich pasteboard item.")
        }

        let pbItem = richItems[0]
        assert(pbItem.data(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")) == plainBytes, "Plain text representation must match.")
        assert(pbItem.data(forType: NSPasteboard.PasteboardType("public.html")) == htmlBytes, "HTML representation must match.")
        assert(pbItem.data(forType: NSPasteboard.PasteboardType("public.rtf")) == rtfBytes, "RTF representation must match.")
        assert(pbItem.types.contains(ClipboardProvenance.provenanceType), "Provenance type must be stamped on rich item.")

        print("✓ T-PASTE-02: Multi-representation item replayed faithfully with all original UTIs.")

        // ---------------------------------------------------------------------
        // 3. T-PASTE-02: Plain-text mode (.plainText) strips rich representations
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-02: Plain-Text Stripping Mode ---")
        try! await coordinator.writeToPasteboard(itemId: richItemId, mode: .plainText)

        guard let strippedItems = pasteboard.pasteboardItems, strippedItems.count == 1 else {
            fatalError("Assertion failed: Expected 1 stripped pasteboard item.")
        }

        let strippedItem = strippedItems[0]
        assert(strippedItem.string(forType: .string) == plainText, "Plain text string must be preserved.")
        assert(!strippedItem.types.contains(NSPasteboard.PasteboardType("public.html")), "HTML representation must be stripped.")
        assert(!strippedItem.types.contains(NSPasteboard.PasteboardType("public.rtf")), "RTF representation must be stripped.")
        assert(strippedItem.types.contains(ClipboardProvenance.provenanceType), "Provenance type must still be stamped.")

        print("✓ T-PASTE-02: Plain-text mode successfully strips HTML and RTF while preserving plain text.")

        // ---------------------------------------------------------------------
        // 4. Multi-item group replay (groupIndex 0 and 1)
        // ---------------------------------------------------------------------
        print("--- Testing Multi-Item Replay (Multiple Groups) ---")
        let item1Text = "Multi-Item Group 0".data(using: .utf8)!
        let item2Text = "Multi-Item Group 1".data(using: .utf8)!

        let multiItemCapture = RawCapture(
            timestampMs: 3000,
            sourceBundleId: "com.apple.finder",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: item1Text),
                RawRepresentation(groupIndex: 1, uti: "public.utf8-plain-text", payload: item2Text),
            ]
        )

        let multiIngest = try! await core.ingest(capture: multiItemCapture)
        try! await coordinator.writeToPasteboard(itemId: multiIngest.itemId, mode: .original)

        guard let multiItems = pasteboard.pasteboardItems, multiItems.count == 2 else {
            fatalError("Assertion failed: Expected 2 pasteboard items for multi-item capture, found \(pasteboard.pasteboardItems?.count ?? 0)")
        }

        assert(multiItems[0].string(forType: .string) == "Multi-Item Group 0", "Group 0 text must match.")
        assert(multiItems[1].string(forType: .string) == "Multi-Item Group 1", "Group 1 text must match.")
        assert(multiItems[0].types.contains(ClipboardProvenance.provenanceType), "Group 0 must have provenance marker.")
        assert(multiItems[1].types.contains(ClipboardProvenance.provenanceType), "Group 1 must have provenance marker.")

        print("✓ Multi-item capture successfully replayed with multiple NSPasteboardItems.")

        // ---------------------------------------------------------------------
        // 5. Error handling: Non-existent item throws itemNotFound
        // ---------------------------------------------------------------------
        print("--- Testing Error Handling: Item Not Found ---")
        let missingId = UUID().uuidString
        var caughtExpectedError = false
        do {
            try await coordinator.writeToPasteboard(itemId: missingId)
        } catch let PasteError.itemNotFound(id) {
            assert(id == missingId, "Error ID must match requested missing ID.")
            caughtExpectedError = true
        } catch {
            fatalError("Unexpected error thrown: \(error)")
        }
        assert(caughtExpectedError, "Non-existent item must throw PasteError.itemNotFound.")

        print("✓ Error handling verified: non-existent item throws typed PasteError.itemNotFound.")

        // ---------------------------------------------------------------------
        // 6. Callback notification
        // ---------------------------------------------------------------------
        print("--- Testing Callback Notification ---")
        var callbackReceived = false
        coordinator.onItemWritten = { writtenId, mode in
            if writtenId == itemId && mode == .original {
                callbackReceived = true
            }
        }
        try! await coordinator.writeToPasteboard(itemId: itemId, mode: .original)
        assert(callbackReceived, "onItemWritten callback must be invoked upon successful replay.")

        print("✓ Callback notification verified.")

        print("✓ ALL Paste Replay Codec Tests PASSED!")
    }
}
