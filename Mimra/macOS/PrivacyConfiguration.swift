// ==============================================================================
// Mimra — Privacy Configuration & Exclusion Manager (P7-04 / F-009, F-010, F-057)
// Manages ignored applications (including outside /Applications), custom UTIs,
// pause state, and single-shot ignore-next capture under Swift 6.
// ==============================================================================

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "PrivacyConfiguration")

/// Typed, descriptive errors for privacy settings operations with explanatory remediation messages.
public enum PrivacyConfigurationError: LocalizedError, Sendable {
    case emptyUti
    case duplicateUti(String)
    case invalidUtiCharacters(String)
    case duplicateApplication(String)
    case invalidApplication(String)

    public var errorDescription: String? {
        switch self {
        case .emptyUti:
            return "Ignored pasteboard type cannot be empty."
        case .duplicateUti(let uti):
            return "The type '\(uti)' is already in the ignored list."
        case .invalidUtiCharacters(let uti):
            return "Invalid UTI '\(uti)': UTIs should only contain letters, numbers, dots, hyphens, and optional trailing wildcards (*)."
        case .duplicateApplication(let name):
            return "Application '\(name)' is already on the exclusion list."
        case .invalidApplication(let details):
            return "Failed to inspect application bundle: \(details)"
        }
    }
}

/// Central observable model managing application exclusions, custom ignored UTIs, and pause states.
@MainActor
public final class PrivacyConfiguration: ObservableObject {
    public static let shared = PrivacyConfiguration()

    public static let didChangeNotification = Notification.Name("MimraPrivacyConfigurationDidChange")

    public static let isPausedKey = "privacyIsPaused"
    public static let ignoreUniversalClipboardKey = "privacyIgnoreUniversalClipboard"
    public static let ignoredApplicationsKey = "privacyIgnoredApplications"
    public static let customIgnoredUtisKey = "privacyCustomIgnoredUtis"

    @Published public var isPaused: Bool {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: Self.isPausedKey)
            postChangeNotification()
        }
    }

    @Published public var ignoreNextCopy: Bool = false {
        didSet {
            postChangeNotification()
        }
    }

    @Published public var ignoreUniversalClipboard: Bool {
        didSet {
            UserDefaults.standard.set(ignoreUniversalClipboard, forKey: Self.ignoreUniversalClipboardKey)
            postChangeNotification()
        }
    }

    @Published public var ignoredApplications: [IgnoredApplication] {
        didSet {
            persistApplications()
            postChangeNotification()
        }
    }

    @Published public var customIgnoredUtis: [String] {
        didSet {
            UserDefaults.standard.set(customIgnoredUtis, forKey: Self.customIgnoredUtisKey)
            postChangeNotification()
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.isPaused = defaults.bool(forKey: Self.isPausedKey)
        self.ignoreUniversalClipboard = defaults.bool(forKey: Self.ignoreUniversalClipboardKey)

        if let data = defaults.data(forKey: Self.ignoredApplicationsKey),
           let apps = try? JSONDecoder().decode([IgnoredApplication].self, from: data) {
            self.ignoredApplications = apps
        } else {
            self.ignoredApplications = []
        }

        if let utis = defaults.stringArray(forKey: Self.customIgnoredUtisKey) {
            self.customIgnoredUtis = utis
        } else {
            self.customIgnoredUtis = []
        }
    }

    private func persistApplications() {
        if let data = try? JSONEncoder().encode(ignoredApplications) {
            UserDefaults.standard.set(data, forKey: Self.ignoredApplicationsKey)
        }
    }

    private func postChangeNotification() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - Application Exclusion Management (F-010, T-PRIV-03)

    /// Adds an application exclusion by bundle ID, name, and optional binary path.
    public func addApplication(bundleId: String, name: String, path: String? = nil) throws {
        let trimmedId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw PrivacyConfigurationError.invalidApplication("Bundle identifier or path identifier cannot be empty.")
        }

        if ignoredApplications.contains(where: { $0.bundleId.caseInsensitiveCompare(trimmedId) == .orderedSame }) {
            throw PrivacyConfigurationError.duplicateApplication(trimmedName.isEmpty ? trimmedId : trimmedName)
        }

        let app = IgnoredApplication(
            bundleId: trimmedId,
            name: trimmedName.isEmpty ? trimmedId : trimmedName,
            path: path
        )
        ignoredApplications.append(app)
        logger.info("Added ignored application: \(app.name, privacy: .public) (\(app.bundleId, privacy: .public))")
    }

    /// Removes an application exclusion by bundle ID.
    public func removeApplication(bundleId: String) {
        ignoredApplications.removeAll(where: { $0.bundleId == bundleId })
        logger.info("Removed ignored application bundle ID: \(bundleId, privacy: .public)")
    }

    /// Presents an NSOpenPanel to browse and select any application bundle or binary outside /Applications (F-010, T-PRIV-03).
    public func browseAndAddApplication() throws -> IgnoredApplication? {
        let panel = NSOpenPanel()
        panel.title = "Select Application to Exclude from Mimra"
        panel.prompt = "Exclude Application"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application, .unixExecutable]

        if panel.runModal() == .OK, let url = panel.url {
            return try addApplicationFromFile(at: url)
        }
        return nil
    }

    /// Inspects an application bundle or binary at a given file URL and adds it to exclusions (F-010, T-PRIV-03).
    @discardableResult
    public func addApplicationFromFile(at url: URL) throws -> IgnoredApplication {
        let path = url.path
        let bundle = Bundle(url: url)
        let bundleId = bundle?.bundleIdentifier ?? "path:\(path)"
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? url.deletingPathExtension().lastPathComponent

        try addApplication(bundleId: bundleId, name: displayName, path: path)
        return IgnoredApplication(bundleId: bundleId, name: displayName, path: path)
    }

    /// Returns a list of currently running GUI applications excluding Mimra itself.
    public func getRunningApplications() -> [IgnoredApplication] {
        let currentBundleId = Bundle.main.bundleIdentifier ?? "com.mimra.app"
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != currentBundleId }
            .compactMap { app in
                guard let bundleId = app.bundleIdentifier else { return nil }
                let name = app.localizedName ?? bundleId
                let path = app.bundleURL?.path ?? app.executableURL?.path
                return IgnoredApplication(bundleId: bundleId, name: name, path: path)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Custom UTI Management (F-009, T-PRIV-02)

    /// Validates a candidate UTI string.
    public static func validateUti(_ rawUti: String) throws -> String {
        let trimmed = rawUti.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PrivacyConfigurationError.emptyUti
        }

        // Permitted characters: letters, digits, period, hyphen, underscore, and optional asterisk
        let validCharSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_*")
        guard trimmed.rangeOfCharacter(from: validCharSet.inverted) == nil else {
            throw PrivacyConfigurationError.invalidUtiCharacters(trimmed)
        }

        return trimmed
    }

    /// Adds a validated custom UTI pattern to the ignore list (F-009, T-PRIV-02).
    public func addCustomUti(_ rawUti: String) throws {
        let validated = try Self.validateUti(rawUti)

        if customIgnoredUtis.contains(where: { $0.caseInsensitiveCompare(validated) == .orderedSame }) {
            throw PrivacyConfigurationError.duplicateUti(validated)
        }

        customIgnoredUtis.append(validated)
        logger.info("Added custom ignored UTI: \(validated, privacy: .public)")
    }

    /// Removes a custom UTI from the ignore list.
    public func removeCustomUti(_ uti: String) {
        customIgnoredUtis.removeAll(where: { $0.caseInsensitiveCompare(uti) == .orderedSame })
        logger.info("Removed custom ignored UTI: \(uti, privacy: .public)")
    }

    // MARK: - PrivacyFilter Synchronization

    /// Synchronizes active configuration state to a thread-safe PrivacyFilter.
    public func sync(to filter: PrivacyFilter) {
        filter.isPaused = isPaused
        filter.ignoreUniversalClipboard = ignoreUniversalClipboard
        if ignoreNextCopy {
            filter.ignoreNextCopy = true
            // Disarm local flag once handed over to the active filter
            self.ignoreNextCopy = false
        }
        filter.ignoredApplications = ignoredApplications
        filter.customIgnoredUtis = Set(customIgnoredUtis)
    }
}
