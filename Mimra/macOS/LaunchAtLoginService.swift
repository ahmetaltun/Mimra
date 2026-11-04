// ==============================================================================
// Mimra — Launch At Login Service (P7-01 / F-062, T-REL-01)
// Apple SMAppService.mainApp integration for modern macOS 15.0+ Apple Silicon.
// ==============================================================================

import Foundation
import ServiceManagement

/// Protocol defining the system login item provider for testability and sandbox isolation.
public protocol LaunchAtLoginProvider: Sendable {
    func getStatus() -> SMAppService.Status
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

/// System provider backed by macOS ServiceManagement `SMAppService.mainApp`.
public final class SystemLaunchAtLoginProvider: LaunchAtLoginProvider, @unchecked Sendable {
    public init() {}

    public func getStatus() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Explanatory error types for launch-at-login failures.
public enum LaunchAtLoginError: LocalizedError, Equatable {
    case registrationFailed(String)
    case unregistrationFailed(String)
    case requiresApproval
    case serviceNotFound

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let reason):
            return "Failed to register Mimra as a login item: \(reason). Please check System Settings > General > Login Items."
        case .unregistrationFailed(let reason):
            return "Failed to unregister Mimra login item: \(reason)."
        case .requiresApproval:
            return "Mimra login item requires user approval. Please enable it in System Settings > General > Login Items."
        case .serviceNotFound:
            return "Launch at login service not found. This feature requires Mimra to run as a packaged application bundle."
        }
    }
}

/// Observable service managing the launch-at-login state for SwiftUI and app lifecycle.
@MainActor
public final class LaunchAtLoginService: ObservableObject {
    public static let shared = LaunchAtLoginService()

    private let provider: LaunchAtLoginProvider

    @Published public private(set) var status: SMAppService.Status
    @Published public private(set) var lastErrorMessage: String? = nil

    public init(provider: LaunchAtLoginProvider = SystemLaunchAtLoginProvider()) {
        self.provider = provider
        self.status = provider.getStatus()
    }

    /// Whether Mimra is registered and enabled to launch at user login.
    public var isEnabled: Bool {
        status == .enabled
    }

    /// Whether the user needs to approve the login item in macOS System Settings.
    public var requiresApproval: Bool {
        status == .requiresApproval
    }

    /// Whether the service is supported in the current environment (e.g. running from app bundle).
    public var isSupported: Bool {
        status != .notFound
    }

    /// Refreshes the service status from macOS ServiceManagement.
    public func refreshStatus() {
        self.status = provider.getStatus()
    }

    /// Updates the launch-at-login preference by registering or unregistering with macOS.
    public func setEnabled(_ enable: Bool) {
        lastErrorMessage = nil
        do {
            if enable {
                try provider.register()
            } else {
                try provider.unregister()
            }
            refreshStatus()
        } catch {
            let errorMsg: String
            if status == .requiresApproval {
                errorMsg = LaunchAtLoginError.requiresApproval.localizedDescription
            } else if status == .notFound {
                errorMsg = LaunchAtLoginError.serviceNotFound.localizedDescription
            } else if enable {
                errorMsg = LaunchAtLoginError.registrationFailed(error.localizedDescription).localizedDescription
            } else {
                errorMsg = LaunchAtLoginError.unregistrationFailed(error.localizedDescription).localizedDescription
            }
            self.lastErrorMessage = errorMsg
            refreshStatus()
        }
    }

    /// Opens macOS System Settings directly to the Login Items pane.
    public func openSystemSettings() {
        provider.openSystemSettingsLoginItems()
    }
}
