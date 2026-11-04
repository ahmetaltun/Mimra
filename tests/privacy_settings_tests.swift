// ==============================================================================
// Mimra — Privacy & Exclusions Settings Integration Tests (P7-04 / F-009, F-010, F-057)
// Verifies custom ignored UTIs (exact & wildcards), application exclusions outside
// /Applications by binary path, persistence, duplicate validation, pause, and
// single-shot ignore-next capture under Swift 6 strict concurrency.
// Linked Tests: T-PRIV-02, T-PRIV-03, T-SET-02
// ==============================================================================

import AppKit
import Foundation

@main
struct PrivacySettingsTests {
    @MainActor
    static func main() async {
        print("--- Mimra Privacy & Exclusions Settings Tests (P7-04 / F-009, F-010, F-057) ---")

        _ = NSApplication.shared

        // Clean test UserDefaults domain
        let testDefaults = UserDefaults.standard
        let testKeys = [
            PrivacyConfiguration.isPausedKey,
            PrivacyConfiguration.ignoreUniversalClipboardKey,
            PrivacyConfiguration.ignoredApplicationsKey,
            PrivacyConfiguration.customIgnoredUtisKey
        ]
        for key in testKeys {
            testDefaults.removeObject(forKey: key)
        }

        defer {
            for key in testKeys {
                testDefaults.removeObject(forKey: key)
            }
        }

        let privacyConfig = PrivacyConfiguration(defaults: testDefaults)
        let filter = PrivacyFilter()

        // -------------------------------------------------------------------------
        // Test 1: Custom Ignored UTIs Validation & Synchronization (F-009, T-SET-02)
        // -------------------------------------------------------------------------
        print("\nStep 1: Testing UTI validation and addition...")

        // Valid UTIs
        do {
            try privacyConfig.addCustomUti("com.company.secret")
            try privacyConfig.addCustomUti("org.custom.*")
        } catch {
            fatalError("Failed to add valid UTIs: \(error.localizedDescription)")
        }
        assert(privacyConfig.customIgnoredUtis.count == 2, "Expected 2 custom UTIs")

        // Duplicate rejection
        do {
            try privacyConfig.addCustomUti("com.company.SECRET")
            fatalError("Adding duplicate UTI should have thrown error")
        } catch let PrivacyConfigurationError.duplicateUti(uti) {
            assert(uti == "com.company.SECRET", "Expected duplicateUti error for \(uti)")
        } catch {
            fatalError("Unexpected error for duplicate UTI: \(error)")
        }

        // Empty UTI rejection
        do {
            try privacyConfig.addCustomUti("   ")
            fatalError("Adding empty UTI should have thrown error")
        } catch PrivacyConfigurationError.emptyUti {
            // expected
        } catch {
            fatalError("Unexpected error for empty UTI: \(error)")
        }

        // Invalid characters rejection
        do {
            try privacyConfig.addCustomUti("invalid;uti!@#")
            fatalError("Adding invalid UTI should have thrown error")
        } catch let PrivacyConfigurationError.invalidUtiCharacters(uti) {
            assert(uti == "invalid;uti!@#", "Expected invalidUtiCharacters error for \(uti)")
        } catch {
            fatalError("Unexpected error for invalid UTI: \(error)")
        }
        print("✓ Custom UTI validation and rejection rules verified.")

        // -------------------------------------------------------------------------
        // Test 2: Custom Ignored UTIs Filtering (Exact & Wildcards) (F-009, T-PRIV-02)
        // -------------------------------------------------------------------------
        print("\nStep 2: Testing pre-read UTI rejection in PrivacyFilter...")
        privacyConfig.sync(to: filter)

        let mockPb = NSPasteboard.withUniqueName()

        // Test normal allowed text
        mockPb.declareTypes([.string], owner: nil)
        mockPb.setString("Normal safe content", forType: .string)
        let safeDecision = filter.shouldCapture(pasteboard: mockPb, sourceBundleId: "com.apple.Safari")
        assert(safeDecision == .capture, "Safe content should be captured")

        // Test exact custom ignored UTI (case-insensitive)
        let exactSecretPb = NSPasteboard.withUniqueName()
        exactSecretPb.declareTypes([NSPasteboard.PasteboardType("com.company.secret"), .string], owner: nil)
        exactSecretPb.setString("Private corporate payload", forType: .string)
        let exactDecision = filter.shouldCapture(pasteboard: exactSecretPb, sourceBundleId: "com.apple.Safari")
        assert(exactDecision == .drop(.ignoredType("com.company.secret")),
               "Exact custom UTI must be dropped before reading payload")

        // Test wildcard prefix ignored UTI
        let wildcardSecretPb = NSPasteboard.withUniqueName()
        wildcardSecretPb.declareTypes([NSPasteboard.PasteboardType("org.custom.auth-token"), .string], owner: nil)
        wildcardSecretPb.setString("Bearer xyz", forType: .string)
        let wildcardDecision = filter.shouldCapture(pasteboard: wildcardSecretPb, sourceBundleId: "com.apple.Safari")
        assert(wildcardDecision == .drop(.ignoredType("org.custom.auth-token")),
               "Wildcard custom UTI 'org.custom.*' must drop 'org.custom.auth-token'")

        // Test removing custom UTI restores capture
        privacyConfig.removeCustomUti("com.company.secret")
        privacyConfig.sync(to: filter)
        let restoredDecision = filter.shouldCapture(pasteboard: exactSecretPb, sourceBundleId: "com.apple.Safari")
        assert(restoredDecision == .capture, "Removed custom UTI should restore capture")

        print("✓ Custom UTI exact and wildcard filtering verified.")

        // -------------------------------------------------------------------------
        // Test 3: Application Exclusions (Inside & Outside /Applications) (F-010, T-PRIV-03)
        // -------------------------------------------------------------------------
        print("\nStep 3: Testing Application Exclusions including non-/Applications paths...")

        // Exclude standard bundle ID app
        do {
            try privacyConfig.addApplication(bundleId: "com.apple.keychainaccess", name: "Keychain Access")
        } catch {
            fatalError("Failed to add Keychain Access: \(error)")
        }

        // Exclude application outside /Applications by path
        let nonStandardPath = "/Users/developer/Downloads/CustomCLIApp.app"
        do {
            try privacyConfig.addApplication(
                bundleId: "path:\(nonStandardPath)",
                name: "CustomCLIApp",
                path: nonStandardPath
            )
        } catch {
            fatalError("Failed to add non-standard path app: \(error)")
        }

        // Duplicate app rejection
        do {
            try privacyConfig.addApplication(bundleId: "com.apple.keychainaccess", name: "Keychain Duplicate")
            fatalError("Adding duplicate application should throw error")
        } catch let PrivacyConfigurationError.duplicateApplication(name) {
            assert(name == "Keychain Access" || name == "Keychain Duplicate")
        } catch {
            fatalError("Unexpected error for duplicate application: \(error)")
        }

        privacyConfig.sync(to: filter)

        // Capture from Safari -> allowed
        let safariDecision = filter.shouldCapture(pasteboard: mockPb, sourceBundleId: "com.apple.Safari")
        assert(safariDecision == .capture, "Safari should be captured")

        // Capture from Keychain Access -> dropped
        let keychainDecision = filter.shouldCapture(pasteboard: mockPb, sourceBundleId: "com.apple.keychainaccess")
        assert(keychainDecision == .drop(.ignoredSourceApp("com.apple.keychainaccess")),
               "Keychain Access must be dropped before payload inspection")

        // Capture from app outside /Applications by path -> dropped
        let pathAppDecision = filter.shouldCapture(
            pasteboard: mockPb,
            sourceBundleId: nil,
            sourcePath: nonStandardPath
        )
        assert(pathAppDecision == .drop(.ignoredSourceApp(nonStandardPath)),
               "App outside /Applications must be dropped via sourcePath before payload read")

        // Remove application exclusion restores capture
        privacyConfig.removeApplication(bundleId: "com.apple.keychainaccess")
        privacyConfig.sync(to: filter)
        let restoredAppDecision = filter.shouldCapture(pasteboard: mockPb, sourceBundleId: "com.apple.keychainaccess")
        assert(restoredAppDecision == .capture, "Removed app should be captured again")

        print("✓ Application exclusions by bundle ID and filesystem path verified.")

        // -------------------------------------------------------------------------
        // Test 4: Capture Pause & Ignore Next Copy Controls (F-026, F-057, T-PRIV-06)
        // -------------------------------------------------------------------------
        print("\nStep 4: Testing Pause and Single-Shot Ignore-Next Copy...")

        // Test Pause
        privacyConfig.isPaused = true
        privacyConfig.sync(to: filter)
        let pausedDecision = filter.shouldCapture(pasteboard: mockPb, sourceBundleId: "com.apple.Safari")
        assert(pausedDecision == .drop(.paused), "Paused filter must drop captures")

        privacyConfig.isPaused = false
        privacyConfig.sync(to: filter)
        let unpausedDecision = filter.shouldCapture(pasteboard: mockPb, sourceBundleId: "com.apple.Safari")
        assert(unpausedDecision == .capture, "Unpaused filter must capture")

        // Test Ignore Next Copy (single-shot)
        privacyConfig.ignoreNextCopy = true
        privacyConfig.sync(to: filter)

        // First copy must be dropped
        let firstCopyDecision = filter.shouldCapture(pasteboard: mockPb, sourceBundleId: "com.apple.Safari")
        assert(firstCopyDecision == .drop(.ignoreNextCopy), "Armed ignore-next must drop the first copy")

        // Subsequent copy must be captured (disarmed automatically)
        let secondCopyDecision = filter.shouldCapture(pasteboard: mockPb, sourceBundleId: "com.apple.Safari")
        assert(secondCopyDecision == .capture, "Subsequent copy after ignore-next must be captured")

        // Test Ignore Universal Clipboard
        privacyConfig.ignoreUniversalClipboard = true
        privacyConfig.sync(to: filter)

        let remotePb = NSPasteboard.withUniqueName()
        remotePb.declareTypes([NSPasteboard.PasteboardType(PrivacyFilter.universalClipboardUti), .string], owner: nil)
        remotePb.setString("Remote continuity text", forType: .string)

        let remoteDecision = filter.shouldCapture(pasteboard: remotePb, sourceBundleId: "com.apple.Safari")
        assert(remoteDecision == .drop(.universalClipboard), "Universal Clipboard must be dropped when enabled")

        privacyConfig.ignoreUniversalClipboard = false
        privacyConfig.sync(to: filter)
        let remoteAllowedDecision = filter.shouldCapture(pasteboard: remotePb, sourceBundleId: "com.apple.Safari")
        assert(remoteAllowedDecision == .capture, "Universal Clipboard must be captured when toggle is disabled")

        print("✓ Pause, Ignore-Next-Copy single shot, and Universal Clipboard verified.")

        // -------------------------------------------------------------------------
        // Test 5: Persistence Across Model Re-instantiation (T-SET-02)
        // -------------------------------------------------------------------------
        print("\nStep 5: Testing persistence across PrivacyConfiguration reloads...")
        privacyConfig.isPaused = true
        privacyConfig.ignoreUniversalClipboard = true
        try? privacyConfig.addApplication(bundleId: "com.apple.Notes", name: "Apple Notes", path: "/Applications/Notes.app")
        try? privacyConfig.addCustomUti("net.custom.token")

        // Create new instance loading from same UserDefaults
        let reloadedConfig = PrivacyConfiguration(defaults: testDefaults)
        assert(reloadedConfig.isPaused == true, "Persisted isPaused mismatch")
        assert(reloadedConfig.ignoreUniversalClipboard == true, "Persisted ignoreUniversalClipboard mismatch")
        assert(reloadedConfig.ignoredApplications.contains(where: { $0.bundleId == "com.apple.Notes" }),
               "Persisted ignoredApplications missing com.apple.Notes")
        assert(reloadedConfig.customIgnoredUtis.contains("net.custom.token"),
               "Persisted customIgnoredUtis missing net.custom.token")

        print("✓ PrivacyConfiguration persistence verified.")

        print("\nAll Privacy & Exclusions Settings integration tests passed cleanly! ✓")
    }
}
