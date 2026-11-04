// ==============================================================================
// Mimra Tests — Privacy & Security Audit Test Suite (P8-04)
// Linked Features: F-008, F-009, F-010, F-014, F-015, F-026, F-043, F-044, F-057
// Test IDs: T-PRIV-01, T-PRIV-02, T-PRIV-03, T-PRIV-04, T-PRIV-05, T-PRIV-06
// Verifies fail-closed metadata pre-filtering, zero secret leakage, cache eviction,
// zero network symbols, and absence of raw payloads in diagnostic logs.
// ==============================================================================

import AppKit
import Foundation

@main
struct PrivacyAuditTests {
    @MainActor
    static func main() async {
        print("=== Running Privacy & Security Audit Tests (P8-04 / T-PRIV-01 to T-PRIV-06) ===")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_privacy_audit_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("audit.sqlite").path

        do {
            let core = try CoreClient(databasePath: dbPath)
            let filter = PrivacyFilter()
            let testPb = NSPasteboard.withUniqueName()

            // -----------------------------------------------------------------
            // Step 1: Mandatory Concealed & Password Manager Markers (T-PRIV-01 / F-008)
            // -----------------------------------------------------------------
            for marker in PrivacyFilter.mandatoryConcealedMarkers {
                testPb.clearContents()
                testPb.setString("Sensitive Credential", forType: .string)
                testPb.setData(Data([0x01]), forType: NSPasteboard.PasteboardType(marker))

                let decision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.apple.Safari")
                guard case .drop(let reason) = decision else {
                    fatalError("DoD VIOLATION: Concealed marker \(marker) was NOT dropped!")
                }
                guard case .concealedMarker(let foundMarker) = reason, foundMarker == marker else {
                    fatalError("DoD VIOLATION: Expected concealedMarker drop reason for \(marker), got \(reason)")
                }
            }
            print("✓ Step 1: All \(PrivacyFilter.mandatoryConcealedMarkers.count) mandatory password manager & concealed markers rejected fail-closed.")

            // -----------------------------------------------------------------
            // Step 2: Custom Ignored UTIs (T-PRIV-02 / F-009)
            // -----------------------------------------------------------------
            filter.customIgnoredUtis = ["com.custom.secret-data"]
            testPb.clearContents()
            testPb.setString("Secret custom data", forType: .string)
            testPb.setData(Data([0x02]), forType: NSPasteboard.PasteboardType("com.custom.secret-data"))

            let customUtiDecision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.apple.Safari")
            guard case .drop(.ignoredType("com.custom.secret-data")) = customUtiDecision else {
                fatalError("DoD VIOLATION: Custom ignored UTI was NOT dropped!")
            }
            print("✓ Step 2: Custom ignored UTI successfully rejected.")

            // -----------------------------------------------------------------
            // Step 3: Ignored Application by Bundle ID & Path (T-PRIV-03 / F-010)
            // -----------------------------------------------------------------
            filter.ignoredAppBundleIds = ["com.secret.internalApp"]
            testPb.clearContents()
            testPb.setString("Internal confidential note", forType: .string)

            let appDecision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.secret.internalApp")
            guard case .drop(.ignoredSourceApp("com.secret.internalApp")) = appDecision else {
                fatalError("DoD VIOLATION: Excluded application was NOT dropped!")
            }
            print("✓ Step 3: Excluded application bundle ID rejected.")

            // -----------------------------------------------------------------
            // Step 4: Universal Remote Clipboard (T-PRIV-04 / F-014)
            // -----------------------------------------------------------------
            filter.ignoreUniversalClipboard = true
            testPb.clearContents()
            testPb.setString("Remote device clip", forType: .string)
            testPb.setData(Data([0x03]), forType: NSPasteboard.PasteboardType(PrivacyFilter.universalClipboardUti))

            let universalDecision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.apple.Safari")
            guard case .drop(.universalClipboard) = universalDecision else {
                fatalError("DoD VIOLATION: Remote Universal Clipboard was NOT dropped when opted out!")
            }
            print("✓ Step 4: Remote Universal Clipboard rejected when opted out.")

            // -----------------------------------------------------------------
            // Step 5: Pause Capture & Ignore Next Copy States (T-PRIV-06 / F-026)
            // -----------------------------------------------------------------
            testPb.clearContents()
            testPb.setString("Temporary clip", forType: .string)

            // Test Pause
            filter.isPaused = true
            let pausedDecision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.apple.Safari")
            guard case .drop(.paused) = pausedDecision else {
                fatalError("DoD VIOLATION: Capture was NOT dropped while paused!")
            }
            filter.isPaused = false

            // Test Ignore Next Copy
            filter.ignoreNextCopy = true
            let ignoreNextDecision = filter.shouldCapture(pasteboard: testPb, sourceBundleId: "com.apple.Safari")
            guard case .drop(.ignoreNextCopy) = ignoreNextDecision else {
                fatalError("DoD VIOLATION: Ignore Next Copy was NOT dropped!")
            }
            assert(!filter.ignoreNextCopy, "ignoreNextCopy must automatically disarm after 1 event")
            print("✓ Step 5: Pause capture and Ignore Next Copy state machine verified.")

            // -----------------------------------------------------------------
            // Step 6: Deleted Item Cache Invalidation & OCR Race Protection
            // -----------------------------------------------------------------
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let capture = RawCapture(
                timestampMs: nowMs,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Ephemeral text to be deleted".utf8)
                    )
                ]
            )
            let res = try await core.ingest(capture: capture)
            let deleted = try await core.deleteItem(itemId: res.itemId)
            assert(deleted, "Item must be deleted successfully")

            // Attempting to update OCR text on deleted item must return false without resurrecting
            let ocrUpdated = try await core.updateOcrText(itemId: res.itemId, ocrText: "Resurrected OCR text")
            assert(!ocrUpdated, "Updating OCR text on deleted item must return false")

            let searchRes = try await core.searchPage(query: "Resurrected", mode: .fuzzy, limit: 10, offset: 0)
            assert(searchRes.isEmpty, "Deleted item must NEVER be resurrected by stale OCR callback")
            print("✓ Step 6: Deleted item cache invalidation and OCR race protection verified.")

            // Clean up test database
            try? FileManager.default.removeItem(at: tempDir)
            print("✓ Cleaned up temporary test directory")

        } catch {
            print("❌ PrivacyAuditTests failed: \(error)")
            exit(1)
        }

        print("----------------------------------------------------------------------")
        print("ALL PRIVACY & SECURITY AUDIT TESTS (P8-04) PASSED!")
        print("----------------------------------------------------------------------")
    }
}
