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
            self.coreClient = client

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

            // 4. Initialize Hotkey Manager and Register Shift-Command-C (F-017, F-023)
            let hotkey = HotkeyManager()
            hotkey.registerSummonHotkey { [weak panelCoord] in
                panelCoord?.toggle()
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
            NSLog("Failed to initialize Mimra services: \(error.localizedDescription)")
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
