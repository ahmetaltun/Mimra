// ==============================================================================
// Mimra — Global Hotkey Manager (Carbon HIToolbox)
// Registers and handles global summon shortcut without Accessibility permissions.
// Linked Features: F-017, F-023
// Test IDs: T-UI-01, T-KEY-02
// ==============================================================================

import AppKit
import Carbon

/// Global hotkey event dispatcher C callback.
private func mimraCarbonEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ theEvent: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let theEvent = theEvent, let userData = userData else {
        return noErr
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        theEvent,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    if status == noErr {
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        let hotKeyId = hotKeyID.id
        Task { @MainActor in
            manager.dispatchHotKey(id: hotKeyId)
        }
    }

    return noErr
}

/// Nonisolated, thread-safe Carbon state wrapper holding raw OS pointers.
final class CarbonHotKeyState: @unchecked Sendable {
    var eventHandlerRef: EventHandlerRef?
    var registeredHotKeys: [UInt32: EventHotKeyRef] = [:]

    deinit {
        for (_, hotKeyRef) in registeredHotKeys {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }
}

/// Manages global system hotkeys using native Carbon HIToolbox APIs.
/// Does NOT require Accessibility permissions (AXIsProcessTrusted), satisfying ADR-008.
@MainActor
public final class HotkeyManager {
    public static let signature: OSType = 0x4D4D5241 // 'MMRA'
    public static let summonHotKeyId: UInt32 = 1

    public typealias HotkeyAction = () -> Void

    private let state = CarbonHotKeyState()
    private var actions: [UInt32: HotkeyAction] = [:]

    public private(set) var summonKeyCode: UInt32 = UInt32(kVK_ANSI_C)
    public private(set) var summonCarbonModifiers: UInt32 = UInt32(cmdKey | shiftKey)

    /// Converts Carbon modifier bitmask into AppKit NSEvent.ModifierFlags.
    public static func carbonModifiersToNSEventModifierFlags(_ carbonMods: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if (carbonMods & UInt32(cmdKey)) != 0 { flags.insert(.command) }
        if (carbonMods & UInt32(shiftKey)) != 0 { flags.insert(.shift) }
        if (carbonMods & UInt32(optionKey)) != 0 { flags.insert(.option) }
        if (carbonMods & UInt32(controlKey)) != 0 { flags.insert(.control) }
        return flags
    }

    /// AppKit ModifierFlags representation of registered summon modifiers.
    public var summonModifierFlags: NSEvent.ModifierFlags {
        HotkeyManager.carbonModifiersToNSEventModifierFlags(summonCarbonModifiers)
    }

    public init() {
        installCarbonHandler()
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let target = GetEventDispatcherTarget()
        let userData = Unmanaged.passUnretained(self).toOpaque()

        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            target,
            mimraCarbonEventHandler,
            1,
            &eventType,
            userData,
            &handler
        )

        if status == noErr {
            state.eventHandlerRef = handler
        } else {
            NSLog("Mimra: Failed to install Carbon event handler. OSStatus=\(status)")
        }
    }

    /// Registers the summon hotkey from a KeyShortcut configuration model (P7-05 / F-023).
    @discardableResult
    public func registerSummonShortcut(
        _ shortcut: KeyShortcut,
        action: @escaping HotkeyAction
    ) -> Bool {
        return registerSummonHotkey(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.carbonModifiers,
            action: action
        )
    }

    /// Registers the default summon hotkey (Shift-Command-C, keyCode=8).
    @discardableResult
    public func registerSummonHotkey(
        keyCode: UInt32 = UInt32(kVK_ANSI_C),
        modifiers: UInt32 = UInt32(cmdKey | shiftKey),
        action: @escaping HotkeyAction
    ) -> Bool {
        self.summonKeyCode = keyCode
        self.summonCarbonModifiers = modifiers
        return registerHotkey(id: HotkeyManager.summonHotKeyId, keyCode: keyCode, modifiers: modifiers, action: action)
    }

    /// Registers a custom global hotkey with a given ID, key code, and Carbon modifiers.
    @discardableResult
    public func registerHotkey(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping HotkeyAction
    ) -> Bool {
        // Unregister existing key if present
        if state.registeredHotKeys[id] != nil {
            unregisterHotkey(id: id)
        }

        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: id)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            state.registeredHotKeys[id] = ref
            actions[id] = action
            return true
        } else {
            NSLog("Mimra: Failed to register hotkey id=\(id) (OSStatus=\(status))")
            return false
        }
    }

    /// Unregisters the global summon hotkey.
    public func unregisterSummonHotkey() {
        unregisterHotkey(id: HotkeyManager.summonHotKeyId)
    }

    /// Unregisters a hotkey by its unique identifier.
    public func unregisterHotkey(id: UInt32) {
        if let ref = state.registeredHotKeys.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: id)
    }

    /// Unregisters all registered hotkeys and clears handlers.
    public func unregisterAll() {
        for (_, hotKeyRef) in state.registeredHotKeys {
            UnregisterEventHotKey(hotKeyRef)
        }
        state.registeredHotKeys.removeAll()
        actions.removeAll()
    }

    /// Returns true if the summon hotkey is currently registered.
    public var isSummonRegistered: Bool {
        return state.registeredHotKeys[HotkeyManager.summonHotKeyId] != nil
    }

    /// Dispatches an event by hotkey ID.
    public func dispatchHotKey(id: UInt32) {
        actions[id]?()
    }
}
