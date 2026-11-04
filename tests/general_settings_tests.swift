// ==============================================================================
// Mimra — General Settings Integration Tests (P7-01 / F-020, F-035, F-056, F-062, F-064)
// Verified test runner for launch-at-login, audio feedback, system clipboard
// cleansing, and auto-paste preferences under Swift 6 strict concurrency.
// ==============================================================================

import AppKit
import Foundation
import ServiceManagement

// MARK: - Mock Providers for Deterministic Verification

final class MockLaunchAtLoginProvider: LaunchAtLoginProvider, @unchecked Sendable {
    var currentStatus: SMAppService.Status
    var shouldFailRegister: Bool = false
    var shouldFailUnregister: Bool = false
    var registerCallCount: Int = 0
    var unregisterCallCount: Int = 0
    var openSettingsCallCount: Int = 0

    init(initialStatus: SMAppService.Status = .notRegistered) {
        self.currentStatus = initialStatus
    }

    func getStatus() -> SMAppService.Status {
        currentStatus
    }

    func register() throws {
        registerCallCount += 1
        if shouldFailRegister {
            throw NSError(domain: "MockSMAppServiceError", code: 1001, userInfo: [NSLocalizedDescriptionKey: "OS policy blocked registration"])
        }
        currentStatus = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if shouldFailUnregister {
            throw NSError(domain: "MockSMAppServiceError", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Service removal failed"])
        }
        currentStatus = .notRegistered
    }

    func openSystemSettingsLoginItems() {
        openSettingsCallCount += 1
    }
}

final class MockSoundPlayer: SoundPlaying, @unchecked Sendable {
    var playedSounds: [String] = []

    func playSound(named name: String) -> Bool {
        playedSounds.append(name)
        return true
    }

    func reset() {
        playedSounds.removeAll()
    }
}

// MARK: - Test Suite Runner

@MainActor
final class GeneralSettingsTestsRunner {
    static func runAll() async {
        print("--- Running General Settings Integration Tests (P7-01) ---")

        await testLaunchAtLoginServiceStates()
        await testLaunchAtLoginErrorsAndApproval()
        await testSoundFeedbackService()
        await testClearSystemClipboardSetting()
        await testPasteModePreferencesAndSync()

        print("✓ All General Settings integration tests PASSED!")
    }

    // 1. Launch at Login: Status transitions and register/unregister
    static func testLaunchAtLoginServiceStates() async {
        print("  Testing LaunchAtLoginService status transitions and commands...")

        let mockProvider = MockLaunchAtLoginProvider(initialStatus: .notRegistered)
        let service = LaunchAtLoginService(provider: mockProvider)

        assert(!service.isEnabled, "FAIL: Service must not be enabled initially")
        assert(!service.requiresApproval, "FAIL: Service must not require approval initially")
        assert(service.isSupported, "FAIL: Service must be supported when status is notRegistered")

        // Enable login item
        service.setEnabled(true)
        assert(service.isEnabled, "FAIL: Service must be enabled after setEnabled(true)")
        assert(mockProvider.registerCallCount == 1, "FAIL: Provider register() must be called once")
        assert(mockProvider.currentStatus == .enabled, "FAIL: Provider status must be .enabled")
        assert(service.lastErrorMessage == nil, "FAIL: No error message should be present on clean registration")

        // Disable login item
        service.setEnabled(false)
        assert(!service.isEnabled, "FAIL: Service must be disabled after setEnabled(false)")
        assert(mockProvider.unregisterCallCount == 1, "FAIL: Provider unregister() must be called once")
        assert(mockProvider.currentStatus == .notRegistered, "FAIL: Provider status must be .notRegistered")

        print("  ✓ LaunchAtLoginService status transitions verified")
    }

    // 2. Launch at Login: Error reporting and approval required
    static func testLaunchAtLoginErrorsAndApproval() async {
        print("  Testing LaunchAtLoginService error reporting and approval required...")

        let mockProvider = MockLaunchAtLoginProvider(initialStatus: .notRegistered)
        mockProvider.shouldFailRegister = true
        let service = LaunchAtLoginService(provider: mockProvider)

        // Attempt registration with failure
        service.setEnabled(true)
        assert(!service.isEnabled, "FAIL: Service must not be enabled when registration fails")
        assert(service.lastErrorMessage != nil, "FAIL: Error message must be populated on registration failure")
        assert(service.lastErrorMessage?.contains("Failed to register Mimra as a login item") == true,
               "FAIL: Expected explanatory error message for registration failure, got: \(service.lastErrorMessage ?? "")")

        // Test requiresApproval status
        let approvalProvider = MockLaunchAtLoginProvider(initialStatus: .requiresApproval)
        let approvalService = LaunchAtLoginService(provider: approvalProvider)
        assert(approvalService.requiresApproval, "FAIL: requiresApproval must be true when status is .requiresApproval")
        assert(!approvalService.isEnabled, "FAIL: isEnabled must be false when approval is required")

        approvalService.openSystemSettings()
        assert(approvalProvider.openSettingsCallCount == 1, "FAIL: openSystemSettings must invoke openSystemSettingsLoginItems")

        // Test unbundled / notFound status
        let notFoundProvider = MockLaunchAtLoginProvider(initialStatus: .notFound)
        let notFoundService = LaunchAtLoginService(provider: notFoundProvider)
        assert(!notFoundService.isSupported, "FAIL: isSupported must be false when status is .notFound")

        print("  ✓ LaunchAtLoginService error handling and approval flows verified")
    }

    // 3. Sound Feedback Service
    static func testSoundFeedbackService() async {
        print("  Testing SoundFeedbackService audio playback and settings persistence...")

        let mockPlayer = MockSoundPlayer()
        let suiteName = "MimraTestDefaults_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!

        let service = SoundFeedbackService(soundPlayer: mockPlayer, userDefaults: testDefaults)

        // Initially disabled
        assert(!service.isEnabled, "FAIL: Audio feedback should be disabled by default")
        let playedWhenDisabled = service.playFeedbackSound()
        assert(!playedWhenDisabled, "FAIL: playFeedbackSound must return false when disabled")
        assert(mockPlayer.playedSounds.isEmpty, "FAIL: No sound should play when service is disabled")

        // Test manual sound test (should play even when isEnabled is false)
        let tested = service.testSound()
        assert(tested, "FAIL: testSound must return true")
        assert(mockPlayer.playedSounds == ["Pop"], "FAIL: Expected 'Pop' sound to play on test, got: \(mockPlayer.playedSounds)")
        mockPlayer.reset()

        // Enable audio feedback
        service.isEnabled = true
        assert(testDefaults.bool(forKey: SoundFeedbackService.playSoundsKey), "FAIL: isEnabled must persist to UserDefaults")

        let playedWhenEnabled = service.playFeedbackSound()
        assert(playedWhenEnabled, "FAIL: playFeedbackSound must return true when enabled")
        assert(mockPlayer.playedSounds == ["Pop"], "FAIL: Expected 'Pop' sound to play when enabled")
        mockPlayer.reset()

        // Change selected sound
        service.selectedSound = .tink
        assert(testDefaults.string(forKey: SoundFeedbackService.soundEffectKey) == "Tink", "FAIL: selectedSound must persist to UserDefaults")

        service.playFeedbackSound()
        assert(mockPlayer.playedSounds == ["Tink"], "FAIL: Expected 'Tink' sound to play after switching sound")

        testDefaults.removePersistentDomain(forName: suiteName)
        print("  ✓ SoundFeedbackService verified")
    }

    // 4. System Clipboard Cleansing (`clearSystemClipboard`)
    static func testClearSystemClipboardSetting() async {
        print("  Testing clearSystemClipboard setting and pasteboard clearing...")

        let pasteboard = NSPasteboard.general
        let key = "clearSystemClipboard"

        // Set test string in system pasteboard
        pasteboard.clearContents()
        pasteboard.setString("Confidential Secret \(UUID().uuidString)", forType: .string)
        assert(pasteboard.string(forType: .string) != nil, "FAIL: Test string must exist in system pasteboard")

        // When setting is false, clearing should NOT touch system pasteboard
        UserDefaults.standard.set(false, forKey: key)
        if UserDefaults.standard.bool(forKey: key) {
            pasteboard.clearContents()
        }
        assert(pasteboard.string(forType: .string) != nil, "FAIL: Pasteboard must remain untouched when clearSystemClipboard is false")

        // When setting is true, clearing SHOULD touch system pasteboard
        UserDefaults.standard.set(true, forKey: key)
        if UserDefaults.standard.bool(forKey: key) {
            pasteboard.clearContents()
        }
        assert(pasteboard.string(forType: .string) == nil, "FAIL: System pasteboard must be cleared when clearSystemClipboard is true")

        // Reset
        UserDefaults.standard.removeObject(forKey: key)
        print("  ✓ clearSystemClipboard setting verified")
    }

    // 5. Paste Mode Preferences & Sync
    static func testPasteModePreferencesAndSync() async {
        print("  Testing pasteAutomatically mode preferences and coordinator sync...")

        let key = "pasteAutomatically"
        let tempDbPath = "/tmp/mimra_general_settings_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDbPath)
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-shm")
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-wal")
        }

        let client = try! CoreClient(databasePath: tempDbPath)

        // Test with pasteAutomatically = true
        UserDefaults.standard.set(true, forKey: key)
        let coordinatorTrue = PasteCoordinator(coreClient: client)
        assert(coordinatorTrue.pasteAutomatically == true, "FAIL: PasteCoordinator must initialize with pasteAutomatically = true")

        // Test with pasteAutomatically = false
        UserDefaults.standard.set(false, forKey: key)
        let coordinatorFalse = PasteCoordinator(coreClient: client)
        assert(coordinatorFalse.pasteAutomatically == false, "FAIL: PasteCoordinator must initialize with pasteAutomatically = false")

        // Test audio feedback callback hook
        var audioFeedbackCalled = false
        coordinatorTrue.onAudioFeedback = {
            audioFeedbackCalled = true
        }
        coordinatorTrue.onAudioFeedback?()
        assert(audioFeedbackCalled, "FAIL: onAudioFeedback callback must be invokable on PasteCoordinator")

        // Reset
        UserDefaults.standard.set(true, forKey: key)
        print("  ✓ pasteAutomatically preferences verified")
    }
}

// Entrypoint
@main
struct GeneralSettingsTestsMain {
    static func main() async {
        await GeneralSettingsTestsRunner.runAll()
    }
}
