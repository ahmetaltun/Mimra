// ==============================================================================
// Mimra — Hotkey Configuration & Collision Handler (P7-05 / F-023, T-KEY-02)
// Manages configurable shortcuts for summon, pin, delete, preview, and plain paste.
// Enforces collision prevention, reserved system shortcut protection, and persistence.
// ==============================================================================

import AppKit
import Carbon
import Foundation
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "HotkeyConfiguration")

/// Supported configurable shortcut actions in Mimra.
public enum HotkeyActionType: String, CaseIterable, Identifiable, Sendable {
    case summon = "summon"
    case pin = "pin"
    case delete = "delete"
    case preview = "preview"
    case plainPaste = "plainPaste"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .summon: return "Summon History Panel"
        case .pin: return "Toggle Pin / Unpin Selected Clip"
        case .delete: return "Delete Selected Clip"
        case .preview: return "Toggle Slideout Preview"
        case .plainPaste: return "Paste as Plain Text"
        }
    }

    public var isGlobal: Bool {
        self == .summon
    }

    public var description: String {
        switch self {
        case .summon:
            return "Global shortcut registered with macOS to open Mimra from anywhere."
        case .pin:
            return "Panel shortcut to pin or unpin the selected clipboard item."
        case .delete:
            return "Panel shortcut to permanently remove the selected item from history."
        case .preview:
            return "Panel shortcut to toggle the attached slideout preview window."
        case .plainPaste:
            return "Panel shortcut to strip rich formatting and paste raw plain text."
        }
    }
}

/// Representation of a keyboard shortcut with key code, modifiers, and display string.
public struct KeyShortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifierFlagsRaw: UInt
    public var displayString: String

    public init(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags, displayString: String = "") {
        self.keyCode = keyCode
        let cleanedFlags = modifierFlags.intersection([.command, .shift, .option, .control])
        self.modifierFlagsRaw = cleanedFlags.rawValue
        self.displayString = displayString.isEmpty ? Self.computeDisplayString(keyCode: keyCode, modifierFlags: cleanedFlags) : displayString
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
    }

    public var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    public static func computeDisplayString(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) -> String {
        var res = ""
        if modifierFlags.contains(.control) { res += "⌃" }
        if modifierFlags.contains(.option) { res += "⌥" }
        if modifierFlags.contains(.shift) { res += "⇧" }
        if modifierFlags.contains(.command) { res += "⌘" }
        res += keyName(for: keyCode)
        return res
    }

    public static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case UInt32(kVK_ANSI_A): return "A"
        case UInt32(kVK_ANSI_B): return "B"
        case UInt32(kVK_ANSI_C): return "C"
        case UInt32(kVK_ANSI_D): return "D"
        case UInt32(kVK_ANSI_E): return "E"
        case UInt32(kVK_ANSI_F): return "F"
        case UInt32(kVK_ANSI_G): return "G"
        case UInt32(kVK_ANSI_H): return "H"
        case UInt32(kVK_ANSI_I): return "I"
        case UInt32(kVK_ANSI_J): return "J"
        case UInt32(kVK_ANSI_K): return "K"
        case UInt32(kVK_ANSI_L): return "L"
        case UInt32(kVK_ANSI_M): return "M"
        case UInt32(kVK_ANSI_N): return "N"
        case UInt32(kVK_ANSI_O): return "O"
        case UInt32(kVK_ANSI_P): return "P"
        case UInt32(kVK_ANSI_Q): return "Q"
        case UInt32(kVK_ANSI_R): return "R"
        case UInt32(kVK_ANSI_S): return "S"
        case UInt32(kVK_ANSI_T): return "T"
        case UInt32(kVK_ANSI_U): return "U"
        case UInt32(kVK_ANSI_V): return "V"
        case UInt32(kVK_ANSI_W): return "W"
        case UInt32(kVK_ANSI_X): return "X"
        case UInt32(kVK_ANSI_Y): return "Y"
        case UInt32(kVK_ANSI_Z): return "Z"
        case UInt32(kVK_Space): return "Space"
        case UInt32(kVK_Delete): return "Delete"
        case UInt32(kVK_Return): return "Return"
        case UInt32(kVK_Escape): return "Esc"
        case UInt32(kVK_Tab): return "Tab"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 116: return "Page Up"
        case 121: return "Page Down"
        case 115: return "Home"
        case 119: return "End"
        default:
            return "Key(\(keyCode))"
        }
    }
}

/// Errors raised when validating or changing keyboard shortcuts.
public enum HotkeyError: LocalizedError, Sendable {
    case missingModifiers
    case reservedSystemShortcut(String)
    case collision(action: String, shortcut: String)
    case registrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingModifiers:
            return "Global shortcuts must include at least one modifier key (⌘, ⌥, ⌃, or ⇧) to prevent capturing standard typing."
        case .reservedSystemShortcut(let shortcut):
            return "'\(shortcut)' is a macOS reserved system shortcut (e.g. Quit, Close, Hide, Preferences) and cannot be assigned."
        case .collision(let action, let shortcut):
            return "Shortcut '\(shortcut)' conflicts with existing assignment for '\(action)'."
        case .registrationFailed(let details):
            return "Failed to register global hotkey with macOS: \(details)"
        }
    }
}

/// Central observable model managing and validating keyboard shortcuts.
@MainActor
public final class HotkeyConfiguration: ObservableObject {
    public static let shared = HotkeyConfiguration()

    public static let didChangeNotification = Notification.Name("MimraHotkeyConfigurationDidChange")

    // Default shortcut definitions (F-023)
    public static let defaultSummon = KeyShortcut(
        keyCode: UInt32(kVK_ANSI_C),
        modifierFlags: [.command, .shift]
    )
    public static let defaultPin = KeyShortcut(
        keyCode: UInt32(kVK_ANSI_P),
        modifierFlags: [.option]
    )
    public static let defaultDelete = KeyShortcut(
        keyCode: UInt32(kVK_Delete),
        modifierFlags: [.option]
    )
    public static let defaultPreview = KeyShortcut(
        keyCode: UInt32(kVK_Space),
        modifierFlags: [.control]
    )
    public static let defaultPlainPaste = KeyShortcut(
        keyCode: UInt32(kVK_Return),
        modifierFlags: [.shift]
    )

    private let defaults: UserDefaults

    @Published public var summonShortcut: KeyShortcut {
        didSet {
            save(summonShortcut, forKey: "hotkey_summon")
            postChange()
        }
    }

    @Published public var pinShortcut: KeyShortcut {
        didSet {
            save(pinShortcut, forKey: "hotkey_pin")
            postChange()
        }
    }

    @Published public var deleteShortcut: KeyShortcut {
        didSet {
            save(deleteShortcut, forKey: "hotkey_delete")
            postChange()
        }
    }

    @Published public var previewShortcut: KeyShortcut {
        didSet {
            save(previewShortcut, forKey: "hotkey_preview")
            postChange()
        }
    }

    @Published public var plainPasteShortcut: KeyShortcut {
        didSet {
            save(plainPasteShortcut, forKey: "hotkey_plainPaste")
            postChange()
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.summonShortcut = Self.load(from: defaults, key: "hotkey_summon") ?? Self.defaultSummon
        self.pinShortcut = Self.load(from: defaults, key: "hotkey_pin") ?? Self.defaultPin
        self.deleteShortcut = Self.load(from: defaults, key: "hotkey_delete") ?? Self.defaultDelete
        self.previewShortcut = Self.load(from: defaults, key: "hotkey_preview") ?? Self.defaultPreview
        self.plainPasteShortcut = Self.load(from: defaults, key: "hotkey_plainPaste") ?? Self.defaultPlainPaste
    }

    private static func load(from defaults: UserDefaults, key: String) -> KeyShortcut? {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(KeyShortcut.self, from: data) else {
            return nil
        }
        return shortcut
    }

    private func save(_ shortcut: KeyShortcut, forKey key: String) {
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key)
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func shortcut(for action: HotkeyActionType) -> KeyShortcut {
        switch action {
        case .summon: return summonShortcut
        case .pin: return pinShortcut
        case .delete: return deleteShortcut
        case .preview: return previewShortcut
        case .plainPaste: return plainPasteShortcut
        }
    }

    public func defaultShortcut(for action: HotkeyActionType) -> KeyShortcut {
        switch action {
        case .summon: return Self.defaultSummon
        case .pin: return Self.defaultPin
        case .delete: return Self.defaultDelete
        case .preview: return Self.defaultPreview
        case .plainPaste: return Self.defaultPlainPaste
        }
    }

    // MARK: - Validation & Collision Checking (T-KEY-02)

    /// Validates a shortcut for an action, preventing reserved system shortcuts and internal collisions.
    public func validateShortcut(_ shortcut: KeyShortcut, for action: HotkeyActionType) throws {
        // 1. Modifiers check: global summon requires at least one modifier
        if action == .summon {
            let mods = shortcut.modifierFlags.intersection([.command, .shift, .option, .control])
            guard !mods.isEmpty else {
                throw HotkeyError.missingModifiers
            }
        }

        // 2. Reserved system shortcut checks (⌘Q, ⌘W, ⌘H, ⌘,, ⌘C, ⌘V, ⌘X, ⌘Z, ⌘A)
        if shortcut.modifierFlags == .command {
            switch shortcut.keyCode {
            case UInt32(kVK_ANSI_Q), // Quit
                 UInt32(kVK_ANSI_W), // Close
                 UInt32(kVK_ANSI_H), // Hide
                 UInt32(kVK_ANSI_C), // Copy
                 UInt32(kVK_ANSI_V), // Paste
                 UInt32(kVK_ANSI_X), // Cut
                 UInt32(kVK_ANSI_Z), // Undo
                 UInt32(kVK_ANSI_A): // Select All
                throw HotkeyError.reservedSystemShortcut(shortcut.displayString)
            default:
                break
            }
        }
        if shortcut.modifierFlags == .command && shortcut.displayString.contains(",") {
            throw HotkeyError.reservedSystemShortcut(shortcut.displayString)
        }

        // 3. Collision check against all other configured shortcuts
        for otherAction in HotkeyActionType.allCases where otherAction != action {
            let other = self.shortcut(for: otherAction)
            if other.keyCode == shortcut.keyCode &&
               other.modifierFlags.intersection([.command, .shift, .option, .control]) ==
               shortcut.modifierFlags.intersection([.command, .shift, .option, .control]) {
                throw HotkeyError.collision(action: otherAction.title, shortcut: shortcut.displayString)
            }
        }
    }

    /// Updates shortcut for a given action after validating.
    public func setShortcut(_ shortcut: KeyShortcut, for action: HotkeyActionType) throws {
        try validateShortcut(shortcut, for: action)
        switch action {
        case .summon: self.summonShortcut = shortcut
        case .pin: self.pinShortcut = shortcut
        case .delete: self.deleteShortcut = shortcut
        case .preview: self.previewShortcut = shortcut
        case .plainPaste: self.plainPasteShortcut = shortcut
        }
        logger.info("Updated shortcut for \(action.rawValue, privacy: .public): \(shortcut.displayString, privacy: .public)")
    }

    /// Resets a specific action to its default shortcut.
    public func resetToDefault(for action: HotkeyActionType) {
        let def = defaultShortcut(for: action)
        try? setShortcut(def, for: action)
    }

    /// Resets all actions to their default shortcuts.
    public func resetAllToDefaults() {
        self.summonShortcut = Self.defaultSummon
        self.pinShortcut = Self.defaultPin
        self.deleteShortcut = Self.defaultDelete
        self.previewShortcut = Self.defaultPreview
        self.plainPasteShortcut = Self.defaultPlainPaste
        logger.info("Reset all shortcuts to defaults.")
    }
}
