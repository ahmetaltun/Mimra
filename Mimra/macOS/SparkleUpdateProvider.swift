// ==============================================================================
// Mimra — Sparkle Update Provider (P9-05 / F-062, T-REL-01)
// Production driver integrating Sparkle 2 (SPUStandardUpdaterController).
// Handles update checks, delegate callbacks, and zero-telemetry enforcement.
// ==============================================================================

import Foundation
import Sparkle

/// Production update engine backed by Sparkle 2.
@MainActor
public final class SparkleUpdateProvider: NSObject, UpdateProvider, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    public var updater: SPUUpdater? {
        updaterController?.updater
    }

    public override init() {
        super.init()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.updaterController = controller

        // Observe canCheckForUpdates for reactivity
        self.canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { _, _ in
            Task { @MainActor in
                UpdateService.shared.updateFromProvider()
            }
        }
    }

    public var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? true
    }

    public var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? true }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    public var automaticallyDownloadsUpdates: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    public var updateCheckInterval: TimeInterval {
        get { updater?.updateCheckInterval ?? 86400 }
        set { updater?.updateCheckInterval = newValue }
    }

    public var lastUpdateCheckDate: Date? {
        updater?.lastUpdateCheckDate
    }

    public var feedURL: URL? {
        updater?.feedURL
    }

    public func checkForUpdates() {
        updater?.checkForUpdates()
    }

    public func checkForUpdatesInBackground() {
        updater?.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let statusText: String?
        if let error = error as NSError? {
            // Error code 1001 corresponds to SUNoUpdateError in Sparkle
            if error.domain == SUSparkleErrorDomain && error.code == 1001 {
                statusText = "Mimra is up to date."
            } else {
                statusText = "Update check notice: \(error.localizedDescription)"
            }
        } else {
            statusText = "Update check completed."
        }

        UpdateService.shared.setStatusMessage(statusText)
        UpdateService.shared.updateFromProvider()
    }
}
