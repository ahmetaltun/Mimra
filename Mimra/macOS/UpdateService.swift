// ==============================================================================
// Mimra — Update Service (P9-05 / F-062, T-REL-01)
// Clean architecture abstraction managing application software update lifecycle.
// Zero-telemetry policy, Ed25519 signature verification, and Sparkle 2 integration.
// ==============================================================================

import Foundation
import Combine

/// Standard check frequencies for automatic update polling.
public enum UpdateCheckFrequency: TimeInterval, CaseIterable, Identifiable, Sendable {
    case daily = 86400
    case weekly = 604800
    case monthly = 2592000

    public var id: TimeInterval { rawValue }

    public var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

/// Protocol defining the underlying update engine (Sparkle or test double).
@MainActor
public protocol UpdateProvider: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
    var lastUpdateCheckDate: Date? { get }
    var feedURL: URL? { get }

    func checkForUpdates()
    func checkForUpdatesInBackground()
}

/// Observable service coordinating application updates and SwiftUI presentation.
@MainActor
public final class UpdateService: ObservableObject {
    public static let didCheckForUpdatesNotification = Notification.Name("MimraUpdateServiceDidCheckForUpdates")

    /// Factory for the default provider (allows lazy decoupling in CLI test runners).
    public static var defaultProviderFactory: @MainActor () -> UpdateProvider = {
        return NoopUpdateProvider()
    }

    public static let shared = UpdateService()

    private let provider: UpdateProvider
    private var timerCancellable: AnyCancellable?

    @Published public private(set) var canCheckForUpdates: Bool = true
    @Published public var automaticallyChecksForUpdates: Bool {
        didSet {
            provider.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: "SUEnableAutomaticChecks")
        }
    }

    @Published public var automaticallyDownloadsUpdates: Bool {
        didSet {
            provider.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            UserDefaults.standard.set(automaticallyDownloadsUpdates, forKey: "SUAllowsAutomaticUpdates")
        }
    }

    @Published public var updateCheckInterval: TimeInterval {
        didSet {
            provider.updateCheckInterval = updateCheckInterval
            UserDefaults.standard.set(updateCheckInterval, forKey: "SUScheduledCheckInterval")
        }
    }

    @Published public private(set) var lastUpdateCheckDate: Date?
    @Published public private(set) var isChecking: Bool = false
    @Published public private(set) var statusMessage: String?

    public init(provider: UpdateProvider? = nil) {
        let activeProvider = provider ?? UpdateService.defaultProviderFactory()
        self.provider = activeProvider

        // Read stored preferences with secure defaults (automatic checks enabled by default)
        let autoCheck = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        let autoDownload = UserDefaults.standard.object(forKey: "SUAllowsAutomaticUpdates") as? Bool ?? false
        let interval = UserDefaults.standard.object(forKey: "SUScheduledCheckInterval") as? TimeInterval ?? UpdateCheckFrequency.daily.rawValue

        self.automaticallyChecksForUpdates = autoCheck
        self.automaticallyDownloadsUpdates = autoDownload
        self.updateCheckInterval = interval

        self.canCheckForUpdates = activeProvider.canCheckForUpdates
        self.lastUpdateCheckDate = activeProvider.lastUpdateCheckDate

        activeProvider.automaticallyChecksForUpdates = autoCheck
        activeProvider.automaticallyDownloadsUpdates = autoDownload
        activeProvider.updateCheckInterval = interval
    }

    /// User-initiated interactive check for updates.
    public func checkForUpdates() {
        guard canCheckForUpdates else { return }
        isChecking = true
        statusMessage = "Checking for updates..."
        provider.checkForUpdates()
    }

    /// Headless background check according to policy.
    public func checkForUpdatesInBackground() {
        guard automaticallyChecksForUpdates else { return }
        provider.checkForUpdatesInBackground()
    }

    /// Syncs state from provider (called on delegate callbacks or KVO changes).
    public func updateFromProvider() {
        self.canCheckForUpdates = provider.canCheckForUpdates
        self.lastUpdateCheckDate = provider.lastUpdateCheckDate
        self.isChecking = false
        NotificationCenter.default.post(name: Self.didCheckForUpdatesNotification, object: self)
    }

    /// Updates status message cleanly without logging private or clipboard data.
    public func setStatusMessage(_ message: String?) {
        self.statusMessage = message
        self.isChecking = false
    }

    /// Formatted description of the last update check timestamp.
    public var formattedLastCheckDate: String {
        guard let date = lastUpdateCheckDate else {
            return "Never"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Fallback no-op provider for environments without active Sparkle controller.
@MainActor
public final class NoopUpdateProvider: UpdateProvider {
    public var canCheckForUpdates: Bool = true
    public var automaticallyChecksForUpdates: Bool = true
    public var automaticallyDownloadsUpdates: Bool = false
    public var updateCheckInterval: TimeInterval = 86400
    public var lastUpdateCheckDate: Date? = nil
    public var feedURL: URL? = nil

    public init() {}

    public func checkForUpdates() {}
    public func checkForUpdatesInBackground() {}
}
