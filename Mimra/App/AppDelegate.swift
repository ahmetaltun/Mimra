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
            let client = try CoreClient()
            CoreClient.setSharedInstance(client)
            self.coreClient = client

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
            self.clipboardMonitor = monitor
            monitor.startMonitoring()

            // Observe format enablement updates from Settings (F-013)
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak monitor] _ in
                monitor?.reloadTypeConfiguration()
            }

            // 3. Initialize Panel Coordinator
            let panelCoord = PanelCoordinator(coreClient: client)
            self.panelCoordinator = panelCoord

            // 4. Initialize Hotkey Manager and Register Shift-Command-C (F-017, F-023, F-031)
            let hotkey = HotkeyManager()
            panelCoord.summonKeyCode = hotkey.summonKeyCode
            panelCoord.summonModifiers = hotkey.summonModifierFlags

            hotkey.registerSummonHotkey { [weak panelCoord] in
                panelCoord?.handleSummonHotkey()
            }
            self.hotkeyManager = hotkey

            // 5. Initialize Status Bar Coordinator
            let coordinator = StatusBarCoordinator(
                coreClient: client,
                monitor: monitor,
                panelCoordinator: panelCoord
            )
            coordinator.setup()
            self.statusBarCoordinator = coordinator
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
