// ==============================================================================
// Mimra — Onboarding Service & Educational Guide (P7-08 / F-061, T-PASTE-03)
// Manages first-launch educational onboarding state, explaining continuous history,
// accessibility auto-paste, sensitive exclusions, privacy controls, and copy-only mode.
// ==============================================================================

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "OnboardingService")

/// Step descriptors for the educational onboarding flow.
public enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case continuousHistory = 0
    case accessibilityAndPaste = 1
    case privacyAndExclusions = 2
    case shortcutsAndUsage = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .continuousHistory:
            return "Continuous History, 100% On-Device"
        case .accessibilityAndPaste:
            return "Accessibility & Auto-Paste"
        case .privacyAndExclusions:
            return "Built-in Privacy & Exclusions"
        case .shortcutsAndUsage:
            return "Ready to Supercharge Your Workflow"
        }
    }

    public var subtitle: String {
        switch self {
        case .continuousHistory:
            return "Never lose a copied snippet, link, or image again."
        case .accessibilityAndPaste:
            return "Effortless pasting with graceful copy-only fallback."
        case .privacyAndExclusions:
            return "Your passwords and sensitive credentials never touch disk."
        case .shortcutsAndUsage:
            return "Fast summoning and keyboard quick-picks at your fingertips."
        }
    }

    public var iconName: String {
        switch self {
        case .continuousHistory:
            return "clock.arrow.circlepath"
        case .accessibilityAndPaste:
            return "doc.on.clipboard"
        case .privacyAndExclusions:
            return "shield.lefthalf.filled"
        case .shortcutsAndUsage:
            return "command"
        }
    }

    public var descriptionText: String {
        switch self {
        case .continuousHistory:
            return "Mimra continuously captures your clipboard history and organizes it locally on your Mac using a lightning-fast SQLite database. All data remains exclusively on your device—zero network requests, zero telemetry, and zero tracking."
        case .accessibilityAndPaste:
            return "To paste directly into your active app when you select a clip, macOS requires Accessibility permission. If you prefer not to grant this permission, Mimra continues working in Copy-Only Mode: simply select any item to copy it, then press ⌘V manually."
        case .privacyAndExclusions:
            return "Mimra automatically protects your confidential data. Clipboard markers from 1Password, Bitwarden, Apple Keychain, and secure text fields are discarded before reaching memory or disk. You can also exclude entire applications and custom pasteboard types anytime in Settings."
        case .shortcutsAndUsage:
            return "Summon Mimra anytime by pressing ⇧⌘C. Use ⌘1 through ⌘9 for instant quick-picks, ⌥P to pin your favorite clips, and ⌥⌫ to delete items. You can customize all shortcuts in Settings."
        }
    }
}

/// Central observable model managing onboarding presentation and state.
@MainActor
public final class OnboardingService: ObservableObject {
    public static let shared = OnboardingService()

    public static let hasCompletedOnboardingKey = "hasCompletedOnboarding"

    private let defaults: UserDefaults

    @Published public var hasCompletedOnboarding: Bool {
        didSet {
            defaults.set(hasCompletedOnboarding, forKey: Self.hasCompletedOnboardingKey)
            logger.info("Onboarding completed state updated: \(self.hasCompletedOnboarding, privacy: .public)")
        }
    }

    @Published public var currentStepIndex: Int = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: Self.hasCompletedOnboardingKey)
    }

    /// Whether onboarding should be shown to the user.
    public var shouldShowOnboarding: Bool {
        !hasCompletedOnboarding
    }

    /// Current onboarding step.
    public var currentStep: OnboardingStep {
        OnboardingStep(rawValue: currentStepIndex) ?? .continuousHistory
    }

    /// Advances to the next onboarding step or marks completion if at the final step.
    public func advanceStep() {
        if currentStepIndex < OnboardingStep.allCases.count - 1 {
            currentStepIndex += 1
        } else {
            completeOnboarding()
        }
    }

    /// Moves back to the previous step.
    public func previousStep() {
        if currentStepIndex > 0 {
            currentStepIndex -= 1
        }
    }

    /// Marks onboarding as completed.
    public func completeOnboarding() {
        hasCompletedOnboarding = true
        currentStepIndex = 0
    }

    /// Resets onboarding state for educational review or testing.
    public func resetOnboarding() {
        hasCompletedOnboarding = false
        currentStepIndex = 0
    }
}
