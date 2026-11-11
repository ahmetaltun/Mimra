// ==============================================================================
// Mimra — Application Delegate
// Lifecycle manager initializing CoreClient, ClipboardMonitor, and Status Bar.
// ==============================================================================

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coreClient: CoreClient?
    private var clipboardMonitor: ClipboardMonitor?
    private var panelCoordinator: PanelCoordinator?
    private var hotkeyManager: HotkeyManager?
    private var statusBarCoordinator: StatusBarCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            // 1. Initialize RustCore storage engine off-main actor
            let client = CoreClient.shared
            client.loadPersistedRetentionPolicy()
            self.coreClient = client

            // 2. Initialize Update Service with Sparkle 2 (P9-05 / F-062)
            UpdateService.defaultProviderFactory = {
                SparkleUpdateProvider()
            }
            _ = UpdateService.shared

            // Check if resilient recovery occurred on startup (P4-07 / T-DB-01)
            if let report = client.recoveryReport, report.wasRecovered {
                let backupPath = report.quarantinedBackupPath ?? "Application Support/com.mimra.app"
                let count = report.salvagedItemsCount
                NSLog("Mimra database recovered. Quarantined backup: \(backupPath), salvaged items: \(count)")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Mimra Database Recovered"
                    alert.informativeText = "A damaged database file was detected and safely quarantined at:\n\(backupPath)\n\nMimra salvaged \(count) clipboard items. No history was permanently lost."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }

            // 2. Initialize Clipboard Monitor on @MainActor
            let monitor = ClipboardMonitor(coreClient: client)
            monitor.onIngest = { _ in
                SoundFeedbackService.shared.playFeedbackSound()
            }
            self.clipboardMonitor = monitor
            monitor.startMonitoring()

            // Observe format enablement updates from Settings (F-013)
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak monitor] _ in
                MainActor.assumeIsolated {
                    monitor?.reloadTypeConfiguration()
                }
            }

            // Sync initial privacy configuration and observe updates (F-009, F-010, F-057)
            PrivacyConfiguration.shared.sync(to: monitor.privacyFilter)
            NotificationCenter.default.addObserver(
                forName: PrivacyConfiguration.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak monitor] _ in
                MainActor.assumeIsolated {
                    if let monitor = monitor {
                        PrivacyConfiguration.shared.sync(to: monitor.privacyFilter)
                    }
                }
            }

            // 3. Initialize Panel Coordinator
            let panelCoord = PanelCoordinator(coreClient: client)
            panelCoord.pasteCoordinator.onAudioFeedback = {
                SoundFeedbackService.shared.playFeedbackSound()
            }
            self.panelCoordinator = panelCoord

            // 4. Initialize Hotkey Manager and Register Summon Shortcut (F-017, F-023, F-031)
            let hotkey = HotkeyManager()
            let summonShortcut = HotkeyConfiguration.shared.summonShortcut
            panelCoord.summonKeyCode = summonShortcut.keyCode
            panelCoord.summonModifiers = summonShortcut.modifierFlags

            hotkey.registerSummonShortcut(summonShortcut) { [weak panelCoord] in
                panelCoord?.handleSummonHotkey()
            }
            self.hotkeyManager = hotkey

            // Observe hotkey configuration updates from Settings (P7-05 / F-023)
            NotificationCenter.default.addObserver(
                forName: HotkeyConfiguration.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak panelCoord] _ in
                MainActor.assumeIsolated {
                    guard let self = self, let hotkey = self.hotkeyManager else { return }
                    let updatedSummon = HotkeyConfiguration.shared.summonShortcut
                    panelCoord?.summonKeyCode = updatedSummon.keyCode
                    panelCoord?.summonModifiers = updatedSummon.modifierFlags
                    hotkey.registerSummonShortcut(updatedSummon) { [weak panelCoord] in
                        panelCoord?.handleSummonHotkey()
                    }
                }
            }

            // 5. Initialize Status Bar Coordinator
            let coordinator = StatusBarCoordinator(
                coreClient: client,
                monitor: monitor,
                panelCoordinator: panelCoord
            )
            coordinator.setup()
            self.statusBarCoordinator = coordinator

            // 6. Present Educational Onboarding Guide on First Launch (P7-08 / F-061)
            if OnboardingService.shared.shouldShowOnboarding {
                OnboardingWindowController.shared.show()
            }
        } catch {
            let errorMsg: String
            if case let CoreError.SchemaMismatch(details) = error {
                errorMsg = "Database version mismatch: \(details)"
            } else if case let CoreError.DiskFullOrIoError(details) = error {
                errorMsg = "Disk full or I/O failure: \(details)"
            } else {
                errorMsg = error.localizedDescription
            }
            NSLog("Failed to initialize Mimra services: \(errorMsg)")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Mimra Startup Notice"
                alert.informativeText = "Mimra encountered an issue while initializing its local database:\n\n\(errorMsg)\n\nPlease check available disk space or update Mimra."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean shutdown
        hotkeyManager?.unregisterSummonHotkey()
        self.hotkeyManager = nil
        panelCoordinator?.hide()
        self.panelCoordinator = nil
        clipboardMonitor?.stopMonitoring()
        self.clipboardMonitor = nil
        self.statusBarCoordinator = nil
        self.coreClient = nil
    }
}
