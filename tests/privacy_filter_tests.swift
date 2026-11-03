// ==============================================================================
// Mimra Tests — Privacy Filter Verification
// Linked Features: F-008, F-009, F-010, F-014, F-026
// Test IDs: T-PRIV-01, T-PRIV-02, T-PRIV-03, T-PRIV-04, T-PRIV-06
// ==============================================================================

import AppKit
import Foundation

@main
struct PrivacyFilterTests {
    static func main() {
        print("=== Running PrivacyFilter Tests ===")

        let filter = PrivacyFilter()
        let pbName = NSPasteboard.Name("com.mimra.test.privacy.\(UUID().uuidString)")
        let testPb = NSPasteboard(name: pbName)

        // 1. Test Empty Pasteboard
        testPb.clearContents()
        let emptyDecision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.apple.Terminal")
        assert(emptyDecision == .drop(.emptyPasteboard), "Empty pasteboard must be dropped")
        print("✓ T-PRIV: Empty pasteboard correctly dropped")

        // 2. Test Normal Plain Text Allowed
        testPb.clearContents()
        testPb.setString("Safe clipboard text", forType: .string)
        let safeDecision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.apple.Terminal")
        assert(safeDecision == .capture, "Legitimate text must be accepted")
        print("✓ T-PRIV: Normal plain text correctly accepted")

        // 3. Test T-PRIV-01: Mandatory Concealed Markers Dropped
        for marker in PrivacyFilter.mandatoryConcealedMarkers {
            testPb.clearContents()
            testPb.setString("Secret Password", forType: .string)
            testPb.setData(Data([0x01]), forType: NSPasteboard.PasteboardType(marker))

            let decision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.apple.Safari")
            assert(decision == .drop(.concealedMarker(marker)), "Concealed marker \(marker) must be dropped")
        }
        print("✓ T-PRIV-01: All \(PrivacyFilter.mandatoryConcealedMarkers.count) mandatory concealed markers dropped without inspecting payload")

        // 4. Test T-PRIV-03: Ignored Source Application
        filter.ignoredAppBundleIds = ["com.agilebits.onepassword-osx", "com.bitwarden.desktop"]
        testPb.clearContents()
        testPb.setString("Some text", forType: .string)

        let ignoredAppDecision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.bitwarden.desktop")
        assert(ignoredAppDecision == .drop(.ignoredSourceApp("com.bitwarden.desktop")), "Ignored source app must be dropped")
        print("✓ T-PRIV-03: Ignored source application correctly dropped")

        // 5. Test T-PRIV-02: Custom Ignored UTIs
        filter.customIgnoredUtis = ["org.custom.secret-type"]
        testPb.clearContents()
        testPb.setString("Custom sensitive data", forType: .string)
        testPb.setData(Data([0x00]), forType: NSPasteboard.PasteboardType("org.custom.secret-type"))

        let ignoredUtiDecision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.apple.Safari")
        assert(ignoredUtiDecision == .drop(.ignoredType("org.custom.secret-type")), "Custom ignored UTI must be dropped")
        print("✓ T-PRIV-02: Custom ignored UTI correctly dropped")

        // 6. Test T-PRIV-04: Universal Clipboard
        testPb.clearContents()
        testPb.setString("Remote Mac clipboard", forType: .string)
        testPb.setData(Data([0x01]), forType: NSPasteboard.PasteboardType(PrivacyFilter.universalClipboardUti))

        // When ignoreUniversalClipboard is false: allowed
        filter.ignoreUniversalClipboard = false
        assert(filter.shouldCapture(pasteboard: testPb, sourceBundleId: nil) == .capture)

        // When ignoreUniversalClipboard is true: dropped
        filter.ignoreUniversalClipboard = true
        assert(filter.shouldCapture(pasteboard: testPb, sourceBundleId: nil) == .drop(.universalClipboard))
        print("✓ T-PRIV-04: Universal Clipboard filtering correctly honored")

        // 7. Test T-PRIV-06: Pause State Machine
        filter.ignoreUniversalClipboard = false
        filter.isPaused = true
        testPb.clearContents()
        testPb.setString("Should not capture when paused", forType: .string)
        assert(filter.shouldCapture(pasteboard: testPb, sourceBundleId: nil) == .drop(.paused))

        filter.isPaused = false
        assert(filter.shouldCapture(pasteboard: testPb, sourceBundleId: nil) == .capture)
        print("✓ T-PRIV-06: Pause state machine works as expected")

        // 8. Test T-PRIV-06: Ignore Next Copy State Machine (single-shot)
        filter.ignoreNextCopy = true
        testPb.clearContents()
        testPb.setString("Ignored once", forType: .string)

        let firstCheck = filter.shouldCapture(pasteboard: testPb, sourceBundleId: nil)
        assert(firstCheck == .drop(.ignoreNextCopy), "First capture must be dropped")
        assert(filter.ignoreNextCopy == false, "ignoreNextCopy must be automatically reset to false")

        // Next copy should now be captured
        let secondCheck = filter.shouldCapture(pasteboard: testPb, sourceBundleId: nil)
        assert(secondCheck == .capture, "Subsequent capture must be allowed after reset")
        print("✓ T-PRIV-06: IgnoreNextCopy single-shot behavior verified")

        print("✓ ALL PrivacyFilter Tests PASSED!")
    }
}
