import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarCoordinator: StatusBarCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize status bar item in the system menu bar
        let coordinator = StatusBarCoordinator()
        coordinator.setup()
        self.statusBarCoordinator = coordinator
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean shutdown
        self.statusBarCoordinator = nil
    }
}
