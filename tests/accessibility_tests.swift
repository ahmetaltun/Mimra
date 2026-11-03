// ==============================================================================
// Mimra Tests — Accessibility Service & Copy-Only Fallback Verification
// Linked Features: F-020, F-027, F-028
// Test IDs: T-PASTE-01, T-UI-04
// ==============================================================================

import AppKit
import Foundation

final class MutableTrustState: @unchecked Sendable {
    var trusted: Bool = false
}

final class CounterBox: @unchecked Sendable {
    var count: Int = 0
}

@main
struct AccessibilityTests {
    @MainActor
    static func main() async {
        print("=== Running Accessibility & Copy-Only Fallback Tests (T-PASTE-01, T-UI-04) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // ---------------------------------------------------------------------
        // 1. Accessibility Trust Checker & State Changes
        // ---------------------------------------------------------------------
        print("--- Testing Accessibility Trust State Machine ---")
        let state = MutableTrustState()
        let service = AccessibilityService(trustChecker: { state.trusted })

        assert(!service.isTrusted, "FAIL: Initial state must be untrusted when checker returns false.")

        state.trusted = true
        service.checkTrustStatus()
        assert(service.isTrusted, "FAIL: isTrusted must transition to true after checker returns true.")

        state.trusted = false
        service.checkTrustStatus()
        assert(!service.isTrusted, "FAIL: isTrusted must transition to false when revoked.")

        print("✓ Accessibility trust state machine correctly reflects system status transitions.")

        // ---------------------------------------------------------------------
        // 2. System Settings URL Resolution
        // ---------------------------------------------------------------------
        print("--- Testing System Settings URL ---")
        assert(
            service.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "FAIL: System Settings URL must target Privacy_Accessibility pane."
        )
        print("✓ System Settings URL target verified.")

        // ---------------------------------------------------------------------
        // 3. Periodic Polling Observation Lifecycle
        // ---------------------------------------------------------------------
        print("--- Testing Observation Lifecycle ---")
        service.startObserving(interval: 0.05)
        state.trusted = true

        // Allow run loop timer to fire
        try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
        assert(service.isTrusted, "FAIL: Periodic observation timer must detect trust change to true.")

        service.stopObserving()
        state.trusted = false
        try? await Task.sleep(nanoseconds: 120_000_000)
        assert(service.isTrusted, "FAIL: Stopped observation must not poll or overwrite state.")

        print("✓ Periodic observation lifecycle and timer cleanup verified.")

        // ---------------------------------------------------------------------
        // 4. End-to-End Copy-Only Degradation and Auto-Paste Recovery
        // ---------------------------------------------------------------------
        print("--- Testing End-to-End Copy-Only Degradation and Recovery ---")
        let core = try! CoreClient.inMemory()
        let testPbName = NSPasteboard.Name("com.mimra.test.fallback.\(UUID().uuidString)")
        let testPasteboard = NSPasteboard(name: testPbName)
        let provenance = ClipboardProvenance()

        let payloadData = "Fallback Test String".data(using: .utf8)!
        let capture = RawCapture(
            timestampMs: 1000,
            sourceBundleId: "com.apple.Safari",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: payloadData)
            ]
        )
        let ingestRes = try! await core.ingest(capture: capture)
        let itemId = ingestRes.itemId

        state.trusted = false
        let counterBox = CounterBox()
        let mockPoster: KeystrokePoster = { _ in
            counterBox.count += 1
            return true
        }

        let targetApp = NSRunningApplication.current

        let coordinator = PasteCoordinator(
            coreClient: core,
            pasteboard: testPasteboard,
            provenanceGuard: provenance,
            pasteAutomatically: true,
            activationDelayNanoseconds: 1_000_000,
            accessibilityChecker: { service.isProcessTrusted() },
            keystrokePoster: mockPoster,
            secureInputChecker: { false },
            passwordFieldChecker: { _ in false },
            frontmostAppProvider: { targetApp }
        )

        // Attempt paste while untrusted -> must degrade to copy-only
        let fallbackResult = try! await coordinator.paste(
            itemId: itemId,
            mode: .original,
            targetApp: targetApp
        )

        guard case .copiedOnly(let reason) = fallbackResult else {
            fatalError("FAIL: Expected copiedOnly when untrusted, got: \(fallbackResult)")
        }
        assert(reason == .accessibilityPermissionDenied, "FAIL: Reason must be .accessibilityPermissionDenied.")
        assert(counterBox.count == 0, "FAIL: No keystrokes must be posted in copy-only mode.")
        assert(testPasteboard.string(forType: .string) == "Fallback Test String", "FAIL: Payload must be preserved on pasteboard.")

        print("✓ Copy-only degradation: item safely copied to pasteboard without keystroke injection.")

        // Grant permission -> recovery to auto-paste
        state.trusted = true
        let recoveredResult = try! await coordinator.paste(
            itemId: itemId,
            mode: .original,
            targetApp: targetApp
        )

        guard case .pastedSuccessfully = recoveredResult else {
            fatalError("FAIL: Expected pastedSuccessfully after permission granted, got: \(recoveredResult)")
        }
        assert(counterBox.count == 1, "FAIL: Keystroke must be posted after recovery.")

        print("✓ Recovery: auto-paste immediately resumes once Accessibility is granted.")

        print("✓ ALL Accessibility & Copy-Only Fallback Tests PASSED!")
    }
}
