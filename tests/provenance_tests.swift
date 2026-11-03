// ==============================================================================
// Mimra Tests — Clipboard Provenance & Self-Recapture Protection Verification
// Linked Features: F-012, F-020
// Test IDs: T-CAP-05
// ==============================================================================

import AppKit
import Foundation

@main
struct ProvenanceTests {
    static func main() {
        print("=== Running ClipboardProvenance Tests ===")

        let provenance = ClipboardProvenance()
        let pbName = NSPasteboard.Name("com.mimra.test.provenance.\(UUID().uuidString)")
        let testPb = NSPasteboard(name: pbName)

        // 1. Unrelated external copy should not be self-generated
        testPb.clearContents()
        testPb.setString("External App Copied String", forType: .string)
        let isSelf = provenance.isSelfGenerated(changeCount: testPb.changeCount, pasteboard: testPb)
        assert(!isSelf, "External write must not be detected as self-generated")
        print("✓ T-CAP-05: External write correctly identified as non-self")

        // 2. Self-write recorded via changeCount
        testPb.clearContents()
        testPb.setString("Mimra Replayed Item", forType: .string)
        provenance.recordSelfWrite(on: testPb)

        let isSelfAfterRecord = provenance.isSelfGenerated(changeCount: testPb.changeCount, pasteboard: testPb)
        assert(isSelfAfterRecord, "Write with matching recorded changeCount must be self-generated")
        print("✓ T-CAP-05: ChangeCount-matched write correctly identified as self-generated")

        // 3. Subsequent external write with different changeCount
        testPb.clearContents()
        testPb.setString("Next User Copy", forType: .string)
        let isNextSelf = provenance.isSelfGenerated(changeCount: testPb.changeCount, pasteboard: testPb)
        assert(!isNextSelf, "Subsequent change with different changeCount must not be self-generated")
        print("✓ T-CAP-05: Subsequent write correctly identified as new capture")

        // 4. Provenance UTI detection
        testPb.clearContents()
        let item = NSPasteboardItem()
        item.setString("Text with provenance marker", forType: .string)
        item.setData(Data([0x01]), forType: ClipboardProvenance.provenanceType)
        testPb.writeObjects([item])

        let isUtiSelf = provenance.isSelfGenerated(changeCount: testPb.changeCount, pasteboard: testPb)
        assert(isUtiSelf, "Pasteboard containing provenance UTI must be self-generated")
        print("✓ T-CAP-05: Provenance UTI marker correctly prevents recapture")

        // 5. Source app attribution detection (com.mimra.app)
        testPb.clearContents()
        let mimraSourceItem = NSPasteboardItem()
        mimraSourceItem.setString("Attributed to Mimra", forType: .string)
        mimraSourceItem.setString(ClipboardProvenance.mimraBundleIdentifier, forType: ClipboardProvenance.sourceAppType)
        testPb.writeObjects([mimraSourceItem])

        let isSourceSelf = provenance.isSelfGenerated(changeCount: testPb.changeCount, pasteboard: testPb)
        assert(isSourceSelf, "Pasteboard item attributed to com.mimra.app must be self-generated")
        print("✓ T-CAP-05: Source application attribution correctly prevents self-recapture")

        print("✓ ALL ClipboardProvenance Tests PASSED!")
    }
}
