// ==============================================================================
// Mimra — Accessibility Service & Permission Manager
// Manages macOS Accessibility trust status, permissions prompt, System Settings
// navigation, and live observation for graceful copy-only degradation.
// Linked Features: F-020, F-027, F-028
// Test IDs: T-PASTE-01, T-UI-04
// ==============================================================================

import ApplicationServices
import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "AccessibilityService")

/// Nonisolated state wrapper for timer lifecycle under Swift 6 strict concurrency.
final class AccessibilityTimerState: @unchecked Sendable {
    var timer: Timer?

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        invalidate()
    }
}

/// Service managing Accessibility permissions and graceful fallback to Copy-Only Mode.
@MainActor
public final class AccessibilityService: ObservableObject {
    /// Shared singleton instance.
    public static let shared = AccessibilityService()

    /// URL string directing macOS to the Accessibility section in Privacy & Security settings.
    public static let systemSettingsAccessibilityPath = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    /// Published trust status reflecting whether the application has Accessibility permissions.
    @Published public private(set) var isTrusted: Bool = false

    /// URL directing the user to the Accessibility settings pane in macOS System Settings.
    public var settingsURL: URL? {
        URL(string: Self.systemSettingsAccessibilityPath)
    }

    private let trustChecker: @Sendable () -> Bool
    private let timerState = AccessibilityTimerState()

    public init(trustChecker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.trustChecker = trustChecker
        self.isTrusted = trustChecker()
    }

    /// Synchronous, thread-safe query for current accessibility trust status.
    nonisolated public func isProcessTrusted() -> Bool {
        trustChecker()
    }

    /// Checks the current system accessibility permission state and updates published `isTrusted`.
    @discardableResult
    public func checkTrustStatus() -> Bool {
        let trusted = isProcessTrusted()
        if self.isTrusted != trusted {
            self.isTrusted = trusted
            logger.info("Accessibility permission status changed: \(trusted, privacy: .public)")
        }
        return trusted
    }

    /// Prompts the user with the system-standard Accessibility dialog if not already trusted.
    public func promptForPermission() {
        guard !checkTrustStatus() else { return }
        logger.info("Prompting user for Accessibility permission via system dialog.")
        // String literal avoids referencing non-concurrency-safe C global kAXTrustedCheckOptionPrompt
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: kCFBooleanTrue] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        checkTrustStatus()
    }

    /// Opens macOS System Settings directly to Privacy & Security > Accessibility.
    public func openSystemSettings() {
        if let url = settingsURL {
            logger.info("Opening macOS System Settings at Accessibility pane.")
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts polling the trust status periodically to detect when the user grants permission.
    public func startObserving(interval: TimeInterval = 1.0) {
        stopObserving()
        checkTrustStatus()
        timerState.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkTrustStatus()
            }
        }
    }

    /// Stops polling the trust status.
    public func stopObserving() {
        timerState.invalidate()
    }
}
