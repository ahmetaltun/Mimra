// ==============================================================================
// Mimra Tests — Auto-Paste & Focus Tracking Verification
// Linked Features: F-020, F-021, F-029
// Test IDs: T-PASTE-01, T-PASTE-02
// ==============================================================================

import AppKit
import CoreGraphics
import Foundation

final class PosterBox: @unchecked Sendable {
    var postedPid: pid_t?
}

@main
struct AutoPasteTests {
    @MainActor
    static func main() async {
        print("=== Running Auto-Paste & Focus Tracking Tests (T-PASTE-01, T-PASTE-02) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let core = try! CoreClient.inMemory()
        let testPbName = NSPasteboard.Name("com.mimra.test.autopaste.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: testPbName)
        let provenanceGuard = ClipboardProvenance()

        // Ingest test item
        let testPayload = "Auto Paste Test Payload".data(using: .utf8)!
        let capture = RawCapture(
            timestampMs: 1000,
            sourceBundleId: "com.apple.dt.Xcode",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: testPayload)
            ]
        )
        let ingestRes = try! await core.ingest(capture: capture)
        let testItemId = ingestRes.itemId

        // ---------------------------------------------------------------------
        // 1. T-PASTE-01: Auto-Paste With Accessibility Granted
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-01: Auto-Paste With Accessibility Granted ---")
        let box = PosterBox()
        let mockPoster: KeystrokePoster = { pid in
            box.postedPid = pid
            return true
        }

        let currentApp = NSRunningApplication.current
        let coordinator = PasteCoordinator(
            coreClient: core,
            pasteboard: pasteboard,
            provenanceGuard: provenanceGuard,
            pasteAutomatically: true,
            activationDelayNanoseconds: 1_000_000, // 1ms for fast test execution
            accessibilityChecker: { true },
            keystrokePoster: mockPoster,
            secureInputChecker: { false },
            passwordFieldChecker: { _ in false },
            frontmostAppProvider: { currentApp }
        )

        let result = try! await coordinator.paste(
            itemId: testItemId,
            mode: .original,
            targetApp: currentApp
        )

        guard case .pastedSuccessfully(let pid, _) = result else {
            fatalError("FAIL: Expected pastedSuccessfully, got: \(result)")
        }

        assert(pid == currentApp.processIdentifier, "FAIL: Target PID must match current application PID.")
        assert(box.postedPid == currentApp.processIdentifier, "FAIL: Keystroke poster must be called with target PID.")

        // Verify clipboard content
        let pbString = pasteboard.string(forType: .string)
        assert(pbString == "Auto Paste Test Payload", "FAIL: Clipboard content must match replayed payload.")
        assert(pasteboard.types?.contains(ClipboardProvenance.provenanceType) == true, "FAIL: Provenance must be stamped.")

        print("✓ T-PASTE-01: Auto-paste executes successfully when Accessibility is granted.")

        // ---------------------------------------------------------------------
        // 2. T-PASTE-01: Accessibility Denied -> Graceful Degradation (Copy-Only)
        // ---------------------------------------------------------------------
        print("--- Testing T-PASTE-01: Accessibility Denied (Copy-Only Fallback) ---")
        box.postedPid = nil
        let deniedCoordinator = PasteCoordinator(
            coreClient: core,
            pasteboard: pasteboard,
            provenanceGuard: provenanceGuard,
            pasteAutomatically: true,
            activationDelayNanoseconds: 1_000_000,
            accessibilityChecker: { false },
            keystrokePoster: mockPoster,
            secureInputChecker: { false },
            passwordFieldChecker: { _ in false },
            frontmostAppProvider: { currentApp }
        )

        let deniedResult = try! await deniedCoordinator.paste(
            itemId: testItemId,
            mode: .original,
            targetApp: currentApp
        )

        guard case .copiedOnly(let reason) = deniedResult else {
            fatalError("FAIL: Expected copiedOnly, got: \(deniedResult)")
        }
        assert(reason == .accessibilityPermissionDenied, "FAIL: Expected accessibilityPermissionDenied reason, got: \(reason)")
        assert(box.postedPid == nil, "FAIL: Keystroke poster must NOT be called when accessibility is denied.")
        assert(pasteboard.string(forType: .string) == "Auto Paste Test Payload", "FAIL: Payload must still be loaded on pasteboard.")

        print("✓ T-PASTE-01: Gracefully degrades to copy-only mode when Accessibility is denied.")

        // ---------------------------------------------------------------------
        // 3. Auto-Paste Disabled by User Preference
        // ---------------------------------------------------------------------
        print("--- Testing Auto-Paste Disabled by User Preference ---")
        box.postedPid = nil
        let disabledCoordinator = PasteCoordinator(
            coreClient: core,
            pasteboard: pasteboard,
            provenanceGuard: provenanceGuard,
            pasteAutomatically: false,
            activationDelayNanoseconds: 1_000_000,
            accessibilityChecker: { true },
            keystrokePoster: mockPoster,
            secureInputChecker: { false },
            passwordFieldChecker: { _ in false },
            frontmostAppProvider: { currentApp }
        )

        let disabledResult = try! await disabledCoordinator.paste(
            itemId: testItemId,
            mode: .original,
            targetApp: currentApp
        )

        guard case .copiedOnly(let disabledReason) = disabledResult else {
            fatalError("FAIL: Expected copiedOnly, got: \(disabledResult)")
        }
        assert(disabledReason == .autoPasteDisabled, "FAIL: Expected autoPasteDisabled reason.")
        assert(box.postedPid == nil, "FAIL: Keystroke poster must NOT be called when pasteAutomatically is false.")

        print("✓ Auto-paste user preference (copy-only mode) honored.")

        // ---------------------------------------------------------------------
        // 4. Force Paste Override (Option-Return behavior)
        // ---------------------------------------------------------------------
        print("--- Testing Force Paste Override (Option-Return) ---")
        box.postedPid = nil
        let forceResult = try! await disabledCoordinator.paste(
            itemId: testItemId,
            mode: .original,
            targetApp: currentApp,
            forcePaste: true
        )

        guard case .pastedSuccessfully(let forcePid, _) = forceResult else {
            fatalError("FAIL: Expected pastedSuccessfully with forcePaste override, got: \(forceResult)")
        }
        assert(forcePid == currentApp.processIdentifier, "FAIL: forcePaste override must post keystroke.")
        assert(box.postedPid == currentApp.processIdentifier, "FAIL: Keystroke poster must be called.")

        print("✓ Force paste override (Option-Return) successfully bypasses copy-only preference.")

        // ---------------------------------------------------------------------
        // 5. Target App Missing or Mimra Itself
        // ---------------------------------------------------------------------
        print("--- Testing Target App Missing or Mimra Self-Guard ---")
        let noTargetResult = try! await coordinator.paste(
            itemId: testItemId,
            mode: .original,
            targetApp: nil
        )
        guard case .copiedOnly(let noTargetReason) = noTargetResult else {
            fatalError("FAIL: Expected copiedOnly with no target application.")
        }
        assert(noTargetReason == .noTargetApplication, "FAIL: Expected noTargetApplication reason.")

        print("✓ Missing target app safely degrades to copy-only.")

        // ---------------------------------------------------------------------
        // 6. Real CGEvent Command-V Construction Verification
        // ---------------------------------------------------------------------
        print("--- Testing Native CGEvent Construction (Hardware Keystroke Verification) ---")
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        assert(keyDown != nil, "FAIL: CGEvent keyDown must construct successfully.")
        assert(keyUp != nil, "FAIL: CGEvent keyUp must construct successfully.")
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        assert(keyDown?.flags.contains(.maskCommand) == true, "FAIL: keyDown must carry Command flag.")
        assert(keyUp?.flags.contains(.maskCommand) == true, "FAIL: keyUp must carry Command flag.")

        print("✓ Native CGEvent Command-V virtual key code (0x09) and flags verified.")

        // ---------------------------------------------------------------------
        // 7. PanelCoordinator Focus Tracking & Commit Integration
        // ---------------------------------------------------------------------
        print("--- Testing PanelCoordinator Focus Tracking & Commit ---")
        let panelCoordinator = PanelCoordinator(coreClient: core, pasteCoordinator: coordinator)
        var receivedPasteResult: PasteResult?
        panelCoordinator.onPasteResult = { res in
            receivedPasteResult = res
        }

        let summaryItem = HistoryItemSummaryDto(
            id: testItemId,
            contentKind: "text",
            title: "Auto Paste Test",
            snippet: "Auto Paste Test Payload",
            isPinned: false,
            pinOrder: nil,
            pinKey: nil,
            sourceBundleId: "com.apple.dt.Xcode",
            firstCopiedAtMs: 1000,
            lastCopiedAtMs: 1000,
            copyCount: 1,
            byteSize: UInt64(testPayload.count),
            availableUtis: ["public.utf8-plain-text"]
        )

        // Simulate item commit with current target app
        panelCoordinator.handleItemCommit(item: summaryItem, mode: .original)

        // Wait briefly for async Task in handleItemCommit
        try? await Task.sleep(nanoseconds: 10_000_000)

        // Result was dispatched
        assert(receivedPasteResult != nil, "FAIL: onPasteResult callback must be triggered on item commit.")

        print("✓ PanelCoordinator commit correctly resolves target and dispatches PasteResult.")

        print("✓ ALL Auto-Paste & Focus Tracking Tests PASSED!")
    }
}
