// ==============================================================================
// Mimra — Appearance Configuration & Manager (P7-02 / F-028, F-032, F-034, F-035, F-058)
// Central configuration for theme, positioning, menu bar appearance, and sizing.
// ==============================================================================

import AppKit
import Foundation
import CoreGraphics

/// Supported UI theme modes (F-034, T-UI-08).
public enum AppearanceTheme: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return "System (Automatic)"
        case .light: return "Light Mode"
        case .dark: return "Dark Mode"
        }
    }
}

/// Positioning modes for the history floating panel (F-032, T-UI-07).
public enum PanelPositionMode: String, CaseIterable, Identifiable, Sendable {
    case centerActive = "centerActive"
    case atCursor = "atCursor"
    case centerMain = "centerMain"
    case underStatusItem = "underStatusItem"
    case rememberLast = "rememberLast"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .centerActive: return "Center of Active Screen"
        case .atCursor: return "At Mouse Cursor"
        case .centerMain: return "Center of Main Screen"
        case .underStatusItem: return "Under Menu Bar Icon"
        case .rememberLast: return "Remember Last Position"
        }
    }
}

/// Menu bar icon choices (F-035, T-UI-09).
public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case defaultIcon = "default"
    case clipboard = "clipboard"
    case minimal = "minimal"
    case scissors = "scissors"
    case hidden = "hidden"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .defaultIcon: return "Standard Clipboard"
        case .clipboard: return "List Clipboard"
        case .minimal: return "Minimal Paperclip"
        case .scissors: return "Scissors"
        case .hidden: return "Hidden (Hotkey Only)"
        }
    }

    public var systemSymbolName: String? {
        switch self {
        case .defaultIcon: return "doc.on.clipboard"
        case .clipboard: return "list.clipboard"
        case .minimal: return "paperclip"
        case .scissors: return "scissors"
        case .hidden: return nil
        }
    }
}

/// User configurable display behavior for the slideout preview window.
public enum PreviewDisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// Preview window is hidden by default and toggled via keyboard shortcut (Default Option 6.1).
    case manual = "manual"
    /// Preview window is shown immediately alongside the history window (Option 1 - 6.2).
    case immediate = "immediate"
    /// Preview window is shown with a delay on selection (Option 2 - 6.3).
    case delayed = "delayed"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .manual:
            return "Hidden by default (Toggle with shortcut)"
        case .immediate:
            return "Show immediately with history window"
        case .delayed:
            return "Show with delay on selection"
        }
    }
}

/// Observable singleton managing application appearance, dimensions, and live updates.
@MainActor
public final class AppearanceConfiguration: ObservableObject {
    public static let shared = AppearanceConfiguration()

    public static let didChangeNotification = Notification.Name("MimraAppearanceDidChangeNotification")

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // Keys
    public static let themeKey = "appearanceTheme"
    public static let positionModeKey = "panelPositionMode"
    public static let iconStyleKey = "menuBarIconStyle"
    public static let showRecentCopyInMenuBarKey = "showRecentCopyInMenuBar"
    public static let showSearchFieldKey = "showSearchField"
    public static let showTitleKey = "showTitle"
    public static let showFooterKey = "showFooter"
    public static let panelWidthKey = "panelWidth"
    public static let panelHeightKey = "panelHeight"
    public static let previewWidthKey = "previewWidth"
    public static let lastSavedOriginXKey = "lastSavedOriginX"
    public static let lastSavedOriginYKey = "lastSavedOriginY"

    public var theme: AppearanceTheme {
        get {
            let val = userDefaults.string(forKey: Self.themeKey) ?? AppearanceTheme.system.rawValue
            return AppearanceTheme(rawValue: val) ?? .system
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Self.themeKey)
            applyTheme()
            notifyChange()
        }
    }

    public var positionMode: PanelPositionMode {
        get {
            let val = userDefaults.string(forKey: Self.positionModeKey) ?? PanelPositionMode.centerActive.rawValue
            return PanelPositionMode(rawValue: val) ?? .centerActive
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Self.positionModeKey)
            notifyChange()
        }
    }

    public var iconStyle: MenuBarIconStyle {
        get {
            let val = userDefaults.string(forKey: Self.iconStyleKey) ?? MenuBarIconStyle.defaultIcon.rawValue
            return MenuBarIconStyle(rawValue: val) ?? .defaultIcon
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Self.iconStyleKey)
            notifyChange()
        }
    }

    public var showRecentCopyInMenuBar: Bool {
        get { userDefaults.bool(forKey: Self.showRecentCopyInMenuBarKey) }
        set {
            userDefaults.set(newValue, forKey: Self.showRecentCopyInMenuBarKey)
            notifyChange()
        }
    }

    public var showSearchField: Bool {
        get {
            if userDefaults.object(forKey: Self.showSearchFieldKey) == nil { return true }
            return userDefaults.bool(forKey: Self.showSearchFieldKey)
        }
        set {
            userDefaults.set(newValue, forKey: Self.showSearchFieldKey)
            notifyChange()
        }
    }

    public var showTitle: Bool {
        get { userDefaults.bool(forKey: Self.showTitleKey) }
        set {
            userDefaults.set(newValue, forKey: Self.showTitleKey)
            notifyChange()
        }
    }

    public var showFooter: Bool {
        get {
            if userDefaults.object(forKey: Self.showFooterKey) == nil { return true }
            return userDefaults.bool(forKey: Self.showFooterKey)
        }
        set {
            userDefaults.set(newValue, forKey: Self.showFooterKey)
            notifyChange()
        }
    }

    public var panelWidth: CGFloat {
        get {
            let val = userDefaults.double(forKey: Self.panelWidthKey)
            return val >= 320 ? CGFloat(val) : 440
        }
        set {
            userDefaults.set(Double(newValue), forKey: Self.panelWidthKey)
            notifyChange()
        }
    }

    public var panelHeight: CGFloat {
        get {
            let val = userDefaults.double(forKey: Self.panelHeightKey)
            return val >= 300 ? CGFloat(val) : 756
        }
        set {
            userDefaults.set(Double(newValue), forKey: Self.panelHeightKey)
            notifyChange()
        }
    }

    public var previewWidth: CGFloat {
        get {
            let val = userDefaults.double(forKey: Self.previewWidthKey)
            return val >= 260 ? CGFloat(val) : 360
        }
        set {
            userDefaults.set(Double(newValue), forKey: Self.previewWidthKey)
            notifyChange()
        }
    }

    /// Saves the current panel origin for `.rememberLast` mode.
    public func saveLastPosition(origin: NSPoint) {
        userDefaults.set(Double(origin.x), forKey: Self.lastSavedOriginXKey)
        userDefaults.set(Double(origin.y), forKey: Self.lastSavedOriginYKey)
    }

    /// Returns the last saved origin, if available.
    public func lastSavedPosition() -> NSPoint? {
        if userDefaults.object(forKey: Self.lastSavedOriginXKey) != nil &&
           userDefaults.object(forKey: Self.lastSavedOriginYKey) != nil {
            let x = userDefaults.double(forKey: Self.lastSavedOriginXKey)
            let y = userDefaults.double(forKey: Self.lastSavedOriginYKey)
            return NSPoint(x: x, y: y)
        }
        return nil
    }

    /// Applies the configured theme to NSApp immediately (F-034, T-UI-08).
    public func applyTheme() {
        _ = NSApplication.shared
        switch theme {
        case .system:
            NSApp?.appearance = nil
        case .light:
            NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Pure geometric placement calculation for floating panel positioning modes.
    public static func computePanelOrigin(
        panelSize: CGSize,
        mode: PanelPositionMode,
        mouseLocation: NSPoint,
        screenVisibleFrame: CGRect,
        statusItemFrame: CGRect? = nil,
        lastPosition: NSPoint? = nil
    ) -> NSPoint {
        switch mode {
        case .centerActive, .centerMain:
            let originX = round(screenVisibleFrame.origin.x + (screenVisibleFrame.width - panelSize.width) / 2.0)
            let originY = round(screenVisibleFrame.origin.y + (screenVisibleFrame.height - panelSize.height) / 2.0)
            return NSPoint(x: originX, y: originY)

        case .atCursor:
            var x = mouseLocation.x - 40
            var y = mouseLocation.y - panelSize.height + 20
            x = max(screenVisibleFrame.minX, min(x, screenVisibleFrame.maxX - panelSize.width))
            y = max(screenVisibleFrame.minY, min(y, screenVisibleFrame.maxY - panelSize.height))
            return NSPoint(x: round(x), y: round(y))

        case .underStatusItem:
            if let sf = statusItemFrame {
                var x = round(sf.midX - panelSize.width / 2.0)
                var y = round(sf.minY - panelSize.height - 4)
                x = max(screenVisibleFrame.minX, min(x, screenVisibleFrame.maxX - panelSize.width))
                y = max(screenVisibleFrame.minY, min(y, screenVisibleFrame.maxY - panelSize.height))
                return NSPoint(x: x, y: y)
            } else {
                let originX = round(screenVisibleFrame.origin.x + (screenVisibleFrame.width - panelSize.width) / 2.0)
                let originY = round(screenVisibleFrame.origin.y + (screenVisibleFrame.height - panelSize.height) / 2.0)
                return NSPoint(x: originX, y: originY)
            }

        case .rememberLast:
            if let lp = lastPosition {
                let x = max(screenVisibleFrame.minX, min(lp.x, screenVisibleFrame.maxX - panelSize.width))
                let y = max(screenVisibleFrame.minY, min(lp.y, screenVisibleFrame.maxY - panelSize.height))
                return NSPoint(x: round(x), y: round(y))
            } else {
                let originX = round(screenVisibleFrame.origin.x + (screenVisibleFrame.width - panelSize.width) / 2.0)
                let originY = round(screenVisibleFrame.origin.y + (screenVisibleFrame.height - panelSize.height) / 2.0)
                return NSPoint(x: originX, y: originY)
            }
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
