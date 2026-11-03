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

            // 3. Initialize Status Bar Coordinator
            let coordinator = StatusBarCoordinator(coreClient: client, monitor: monitor)
            coordinator.setup()
            self.statusBarCoordinator = coordinator
        } catch {
            NSLog("Failed to initialize Mimra services: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean shutdown
        clipboardMonitor?.stopMonitoring()
        self.clipboardMonitor = nil
        self.statusBarCoordinator = nil
        self.coreClient = nil
    }
}
