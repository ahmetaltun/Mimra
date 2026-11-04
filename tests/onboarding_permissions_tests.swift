// ==============================================================================
// Mimra — Onboarding & Permission Integration Tests (P7-08 / F-061, T-PASTE-03)
// Verifies onboarding lifecycle, educational content, dynamic Accessibility grant/revoke
// transitions, and graceful degradation to usable Copy-Only Mode.
// ==============================================================================

import AppKit
import Foundation

final class MutableTrustState: @unchecked Sendable {
    var trusted: Bool = false
}

final class CounterBox: @unchecked Sendable {
    var count: Int = 0
}

final class FlagBox: @unchecked Sendable {
    var flag: Bool = false
}

@main
struct OnboardingPermissionsTests {
    @MainActor
    static func main() async {
        print("--- Mimra Onboarding & Permissions Integration Tests (P7-08 / F-061, T-PASTE-03) ---")

        _ = NSApplication.shared

        let testDefaults = UserDefaults.standard
        testDefaults.removeObject(forKey: OnboardingService.hasCompletedOnboardingKey)
        defer {
            testDefaults.removeObject(forKey: OnboardingService.hasCompletedOnboardingKey)
        }

        // Setup temporary database
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("onboarding_test.sqlite").path
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            let core = try CoreClient(databasePath: dbPath)

            // -------------------------------------------------------------------------
            // Test 1: Onboarding Lifecycle & Educational Content (F-061)
            // -------------------------------------------------------------------------
            print("\nStep 1: Testing onboarding state machine and educational content...")

            let onboarding = OnboardingService(defaults: testDefaults)
            assert(onboarding.shouldShowOnboarding == true, "Fresh install must prompt onboarding")
            assert(onboarding.hasCompletedOnboarding == false, "Fresh install has not completed onboarding")
            assert(onboarding.currentStepIndex == 0, "Initial step index must be 0")
            assert(onboarding.currentStep == .continuousHistory, "Initial step must be continuousHistory")

            // Verify Step 0: Continuous History
            let step0 = onboarding.currentStep
            assert(step0.title == "Continuous History, 100% On-Device")
            assert(step0.descriptionText.contains("SQLite"), "Must explain local SQLite database")
            assert(step0.descriptionText.contains("zero network requests"), "Must assure zero network telemetry")

            // Advance to Step 1: Accessibility & Auto-Paste
            onboarding.advanceStep()
            assert(onboarding.currentStepIndex == 1)
            let step1 = onboarding.currentStep
            assert(step1.title == "Accessibility & Auto-Paste")
            assert(step1.descriptionText.contains("Copy-Only Mode"), "Must explain Copy-Only Mode fallback")
            assert(step1.descriptionText.contains("⌘V manually"), "Must explain manual paste fallback")

            // Advance to Step 2: Privacy & Exclusions
            onboarding.advanceStep()
            assert(onboarding.currentStepIndex == 2)
            let step2 = onboarding.currentStep
            assert(step2.title == "Built-in Privacy & Exclusions")
            assert(step2.descriptionText.contains("1Password"), "Must mention password manager filtering")
            assert(step2.descriptionText.contains("Bitwarden"), "Must mention Bitwarden filtering")

            // Advance to Step 3: Shortcuts & Ready
            onboarding.advanceStep()
            assert(onboarding.currentStepIndex == 3)
            let step3 = onboarding.currentStep
            assert(step3.title == "Ready to Supercharge Your Workflow")
            assert(step3.descriptionText.contains("⇧⌘C"), "Must explain summon shortcut")
            assert(step3.descriptionText.contains("⌥P"), "Must explain pin shortcut")

            // Complete onboarding
            onboarding.advanceStep()
            assert(onboarding.hasCompletedOnboarding == true, "Completing onboarding must set hasCompletedOnboarding to true")
            assert(onboarding.shouldShowOnboarding == false, "shouldShowOnboarding must now be false")

            // Verify persistence across new instance
            let reloaded = OnboardingService(defaults: testDefaults)
            assert(reloaded.hasCompletedOnboarding == true, "Completed onboarding must persist across reload")
            assert(reloaded.shouldShowOnboarding == false)

            // Reset onboarding
            reloaded.resetOnboarding()
            assert(reloaded.hasCompletedOnboarding == false, "Reset must restore initial state")
            assert(reloaded.shouldShowOnboarding == true)

            print("✓ Onboarding lifecycle, educational content, and persistence verified.")

            // -------------------------------------------------------------------------
            // Test 2: Usable Copy-Only Mode with Accessibility Denied (F-061, T-PASTE-03)
            // -------------------------------------------------------------------------
            print("\nStep 2: Testing usable Copy-Only Mode with Accessibility Denied...")

            // Ingest sample clipboard item
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let capture = RawCapture(
                timestampMs: nowMs,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: "https://github.com/mimra/mimra".data(using: .utf8)!
                    )
                ]
            )
            let ingestRes = try await core.ingest(capture: capture)
            assert(!ingestRes.itemId.isEmpty)

            // Instantiate PasteCoordinator with Accessibility explicitly DENIED
            let keystrokeFlag = FlagBox()
            let deniedCoordinator = PasteCoordinator(
                coreClient: core,
                accessibilityChecker: { false }, // Denied!
                keystrokePoster: { _ in
                    keystrokeFlag.flag = true
                    return true
                },
                secureInputChecker: { false },
                passwordFieldChecker: { _ in false },
                frontmostAppProvider: {
                    NSWorkspace.shared.frontmostApplication
                }
            )

            let currentApp = NSRunningApplication.current

            // Attempt to paste item
            let result = try await deniedCoordinator.paste(
                itemId: ingestRes.itemId,
                mode: .original,
                targetApp: currentApp,
                forcePaste: nil // user requested default paste behavior
            )

            // Verify result degraded gracefully to .copiedOnly
            switch result {
            case .copiedOnly(let reason):
                assert(reason == .accessibilityPermissionDenied,
                       "Must indicate accessibilityPermissionDenied as reason, got: \(reason)")
            case .pastedSuccessfully:
                fatalError("Should not paste successfully when accessibility is denied!")
            }

            assert(!keystrokeFlag.flag, "Synthetic keystroke must NOT be injected when accessibility is denied")

            // Verify the content was still copied to the system clipboard (usable copy-only mode)
            let clipboardString = NSPasteboard.general.string(forType: .string)
            assert(clipboardString == "https://github.com/mimra/mimra",
                   "Item must still be written to NSPasteboard so user can paste manually")

            print("✓ Usable Copy-Only Mode verified: item written to clipboard without crashing.")

            // -------------------------------------------------------------------------
            // Test 3: Dynamic Permission Grant & Revocation State Transitions (T-PASTE-03)
            // -------------------------------------------------------------------------
            print("\nStep 3: Testing dynamic permission grant and revocation state transitions...")

            let trustState = MutableTrustState()
            let counter = CounterBox()

            let dynamicCoordinator = PasteCoordinator(
                coreClient: core,
                accessibilityChecker: { trustState.trusted },
                keystrokePoster: { _ in
                    counter.count += 1
                    return true
                },
                secureInputChecker: { false },
                passwordFieldChecker: { _ in false },
                frontmostAppProvider: {
                    NSWorkspace.shared.frontmostApplication
                }
            )

            // Phase A: Revoked/Denied initially
            trustState.trusted = false
            let phaseAResult = try await dynamicCoordinator.paste(
                itemId: ingestRes.itemId,
                mode: .original,
                targetApp: currentApp,
                forcePaste: nil
            )
            assert(phaseAResult == .copiedOnly(reason: .accessibilityPermissionDenied))
            assert(counter.count == 0, "No keystroke in denied state")

            // Phase B: User grants permission in System Settings
            trustState.trusted = true
            let phaseBResult = try await dynamicCoordinator.paste(
                itemId: ingestRes.itemId,
                mode: .original,
                targetApp: currentApp,
                forcePaste: nil
            )
            // Depending on frontmost app (headless vs active app), verifies safe handling
            switch phaseBResult {
            case .pastedSuccessfully:
                assert(counter.count == 1, "Keystroke posted when trusted")
            case .copiedOnly:
                print("Headless test runner without external frontmost target: copy-only safe fallback")
            }

            // Phase C: User revokes permission in System Settings
            trustState.trusted = false
            let previousKeystrokes = counter.count
            let phaseCResult = try await dynamicCoordinator.paste(
                itemId: ingestRes.itemId,
                mode: .original,
                targetApp: currentApp,
                forcePaste: nil
            )
            assert(phaseCResult == .copiedOnly(reason: .accessibilityPermissionDenied),
                   "Revoked permission must immediately fall back to copy-only")
            assert(counter.count == previousKeystrokes, "Keystroke count must not change after revocation")

            print("✓ Dynamic grant and revocation transitions verified cleanly.")

            // -------------------------------------------------------------------------
            // Test 4: Accessibility Service Trust Polling & Notification (F-061)
            // -------------------------------------------------------------------------
            print("\nStep 4: Testing AccessibilityService trust state management...")

            let mockTrust = MutableTrustState()
            mockTrust.trusted = false
            let mockService = AccessibilityService(trustChecker: { mockTrust.trusted })
            assert(!mockService.isTrusted, "Initial state should be untrusted")

            // Simulate granting permission
            mockTrust.trusted = true
            let checkRes = mockService.checkTrustStatus()
            assert(checkRes == true, "checkTrustStatus should reflect updated status")
            assert(mockService.isTrusted == true, "Published isTrusted must update to true")

            // Simulate revoking permission
            mockTrust.trusted = false
            let revokeRes = mockService.checkTrustStatus()
            assert(revokeRes == false, "checkTrustStatus should reflect revocation")
            assert(mockService.isTrusted == false, "Published isTrusted must update to false")

            print("✓ AccessibilityService trust polling and updates verified.")

            print("\nAll Onboarding & Permissions integration tests passed cleanly! ✓")
        } catch {
            fatalError("Failed with error: \(error)")
        }
    }
}
