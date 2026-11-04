// ==============================================================================
// Mimra — Onboarding View & Window Controller (P7-08 / F-061, T-PASTE-03)
// Visual educational onboarding experience explaining continuous clipboard history,
// Accessibility auto-paste, sensitive exclusions, and copy-only fallback mode.
// ==============================================================================

import AppKit
import SwiftUI

/// Main SwiftUI view rendering the educational onboarding cards.
@MainActor
public struct OnboardingView: View {
    @ObservedObject var onboardingService: OnboardingService
    @ObservedObject var accessibilityService: AccessibilityService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onDismiss: () -> Void

    @MainActor
    public init(
        onboardingService: OnboardingService,
        accessibilityService: AccessibilityService,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.onboardingService = onboardingService
        self.accessibilityService = accessibilityService
        self.onDismiss = onDismiss
    }

    @MainActor
    public init(onDismiss: @escaping () -> Void = {}) {
        self.init(
            onboardingService: .shared,
            accessibilityService: .shared,
            onDismiss: onDismiss
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header: App Logo and Step Indicator
            headerSection
                .padding(.top, 24)
                .padding(.horizontal, 30)

            Spacer()

            // Main Content: Step Card
            stepContentSection
                .padding(.horizontal, 36)

            Spacer()

            // Footer: Navigation Buttons
            footerSection
                .padding(.horizontal, 30)
                .padding(.bottom, 24)
        }
        .frame(width: 520, height: 440)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Subviews

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "paperclip.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)

                Text("Welcome to Mimra")
                    .font(.system(size: 20, weight: .bold))

                Spacer()

                Button {
                    onboardingService.completeOnboarding()
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip onboarding and close")
            }

            // Step Progress Dots
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases) { step in
                    Capsule()
                        .fill(step.rawValue <= onboardingService.currentStepIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: step.rawValue == onboardingService.currentStepIndex ? 24 : 8, height: 4)
                        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: onboardingService.currentStepIndex)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(onboardingService.currentStepIndex + 1) of \(OnboardingStep.allCases.count): \(onboardingService.currentStep.title)")
        }
    }

    @ViewBuilder
    private var stepContentSection: some View {
        let step = onboardingService.currentStep

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 48, height: 48)

                    Image(systemName: step.iconName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(step.subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Text(step.descriptionText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            // Special Interactive Elements for Accessibility Step (F-061, T-PASTE-03)
            if step == .accessibilityAndPaste {
                accessibilityStatusCard
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var accessibilityStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: accessibilityService.isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(accessibilityService.isTrusted ? .green : .orange)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(accessibilityService.isTrusted ? "Accessibility Permission Granted" : "Copy-Only Mode Active")
                    .font(.system(size: 12, weight: .semibold))
                Text(accessibilityService.isTrusted ? "Auto-paste into previous application is ready." : "Selecting clips copies to clipboard. Manual ⌘V required.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !accessibilityService.isTrusted {
                Button("Grant Permission...") {
                    accessibilityService.promptForPermission()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11, weight: .medium))
                .accessibilityLabel("Grant Accessibility Permission in macOS System Settings")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accessibilityService.isTrusted ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
        )
    }

    @ViewBuilder
    private var footerSection: some View {
        HStack {
            if onboardingService.currentStepIndex > 0 {
                Button("Previous") {
                    onboardingService.previousStep()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .accessibilityLabel("Go to previous step")
            }

            Spacer()

            if onboardingService.currentStepIndex < OnboardingStep.allCases.count - 1 {
                Button("Continue") {
                    onboardingService.advanceStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Continue to next step")
            } else {
                Button("Get Started") {
                    onboardingService.completeOnboarding()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Complete onboarding and start using Mimra")
            }
        }
    }
}

/// Dedicated AppKit window controller managing the onboarding window.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    public static let shared = OnboardingWindowController()

    private var window: NSWindow?

    public func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Welcome to Mimra"
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.delegate = self

        let view = OnboardingView(
            onboardingService: .shared,
            accessibilityService: .shared,
            onDismiss: { [weak self] in
                self?.close()
            }
        )
        newWindow.contentView = NSHostingView(rootView: view)

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.close()
        window = nil
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
