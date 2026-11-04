// ==============================================================================
// Mimra — Hotkey Settings & Collision Integration Tests (P7-05 / F-023, T-KEY-02)
// Verifies default shortcut bindings, custom shortcut persistence, reserved system
// shortcut rejection, internal collision detection, dynamic Carbon registration,
// and reset-to-defaults under Swift 6 strict concurrency.
// ==============================================================================

import AppKit
import Carbon
import Foundation

@main
struct HotkeySettingsTests {
    @MainActor
    static func main() async {
        print("--- Mimra Hotkey Settings & Collision Tests (P7-05 / F-023, T-KEY-02) ---")

        _ = NSApplication.shared

        let testDefaults = UserDefaults.standard
        let hotkeyKeys = [
            "hotkey_summon",
            "hotkey_pin",
            "hotkey_delete",
            "hotkey_preview",
            "hotkey_plainPaste"
        ]
        for key in hotkeyKeys {
            testDefaults.removeObject(forKey: key)
        }

        defer {
            for key in hotkeyKeys {
                testDefaults.removeObject(forKey: key)
            }
        }

        let config = HotkeyConfiguration(defaults: testDefaults)

        // -------------------------------------------------------------------------
        // Test 1: Default Shortcuts & Display Strings (F-023)
        // -------------------------------------------------------------------------
        print("\nStep 1: Testing default shortcuts and display representations...")
        assert(config.summonShortcut == HotkeyConfiguration.defaultSummon, "Default summon shortcut mismatch")
        assert(config.pinShortcut == HotkeyConfiguration.defaultPin, "Default pin shortcut mismatch")
        assert(config.deleteShortcut == HotkeyConfiguration.defaultDelete, "Default delete shortcut mismatch")
        assert(config.previewShortcut == HotkeyConfiguration.defaultPreview, "Default preview shortcut mismatch")
        assert(config.plainPasteShortcut == HotkeyConfiguration.defaultPlainPaste, "Default plain paste shortcut mismatch")

        assert(config.summonShortcut.displayString == "⇧⌘C", "Summon display string expected ⇧⌘C, got \(config.summonShortcut.displayString)")
        assert(config.pinShortcut.displayString == "⌥P", "Pin display string expected ⌥P, got \(config.pinShortcut.displayString)")
        assert(config.deleteShortcut.displayString == "⌥Delete", "Delete display string expected ⌥Delete, got \(config.deleteShortcut.displayString)")
        assert(config.previewShortcut.displayString == "⌃Space", "Preview display string expected ⌃Space, got \(config.previewShortcut.displayString)")
        assert(config.plainPasteShortcut.displayString == "⇧Return", "Plain paste display string expected ⇧Return, got \(config.plainPasteShortcut.displayString)")

        print("✓ Default shortcuts and display strings verified.")

        // -------------------------------------------------------------------------
        // Test 2: Validation Rules & Modifiers Requirement (T-KEY-02)
        // -------------------------------------------------------------------------
        print("\nStep 2: Testing modifier requirement for global summon...")
        let bareC = KeyShortcut(keyCode: UInt32(kVK_ANSI_C), modifierFlags: [])
        do {
            try config.setShortcut(bareC, for: .summon)
            fatalError("Setting bare letter without modifiers for global summon should throw error")
        } catch HotkeyError.missingModifiers {
            // expected
        } catch {
            fatalError("Unexpected error for bare summon key: \(error)")
        }
        print("✓ Missing modifiers rejection verified.")

        // -------------------------------------------------------------------------
        // Test 3: System Reserved Shortcuts Rejection (T-KEY-02)
        // -------------------------------------------------------------------------
        print("\nStep 3: Testing rejection of macOS reserved system shortcuts...")
        let cmdQ = KeyShortcut(keyCode: UInt32(kVK_ANSI_Q), modifierFlags: [.command])
        do {
            try config.setShortcut(cmdQ, for: .summon)
            fatalError("Setting Command-Q should throw reservedSystemShortcut")
        } catch let HotkeyError.reservedSystemShortcut(str) {
            assert(str == "⌘Q")
        } catch {
            fatalError("Unexpected error for ⌘Q: \(error)")
        }

        let cmdW = KeyShortcut(keyCode: UInt32(kVK_ANSI_W), modifierFlags: [.command])
        do {
            try config.setShortcut(cmdW, for: .pin)
            fatalError("Setting Command-W should throw reservedSystemShortcut")
        } catch HotkeyError.reservedSystemShortcut {
            // expected
        } catch {
            fatalError("Unexpected error for ⌘W: \(error)")
        }

        let cmdV = KeyShortcut(keyCode: UInt32(kVK_ANSI_V), modifierFlags: [.command])
        do {
            try config.setShortcut(cmdV, for: .preview)
            fatalError("Setting Command-V should throw reservedSystemShortcut")
        } catch HotkeyError.reservedSystemShortcut {
            // expected
        } catch {
            fatalError("Unexpected error for ⌘V: \(error)")
        }
        print("✓ Reserved system shortcuts (⌘Q, ⌘W, ⌘V) rejection verified.")

        // -------------------------------------------------------------------------
        // Test 4: Internal Collision Detection (T-KEY-02)
        // -------------------------------------------------------------------------
        print("\nStep 4: Testing collision detection between configured actions...")
        // Pin is currently ⌥P. Attempt to set Summon to ⌥P
        let optP = KeyShortcut(keyCode: UInt32(kVK_ANSI_P), modifierFlags: [.option])
        do {
            try config.setShortcut(optP, for: .summon)
            fatalError("Setting summon to ⌥P should collide with Pin")
        } catch let HotkeyError.collision(action, shortcut) {
            assert(shortcut == "⌥P")
            assert(action == HotkeyActionType.pin.title)
        } catch {
            fatalError("Unexpected error for collision: \(error)")
        }

        // Preview is currently ⌃Space. Attempt to set Delete to ⌃Space
        let ctrlSpace = KeyShortcut(keyCode: UInt32(kVK_Space), modifierFlags: [.control])
        do {
            try config.setShortcut(ctrlSpace, for: .delete)
            fatalError("Setting delete to ⌃Space should collide with Preview")
        } catch let HotkeyError.collision(action, _) {
            assert(action == HotkeyActionType.preview.title)
        } catch {
            fatalError("Unexpected error for collision: \(error)")
        }
        print("✓ Internal collision detection verified.")

        // -------------------------------------------------------------------------
        // Test 5: Valid Custom Shortcut Modification & Dynamic Carbon Registration (F-023)
        // -------------------------------------------------------------------------
        print("\nStep 5: Testing valid shortcut modification and Carbon registration...")
        let manager = HotkeyManager()

        // Change summon to ⇧⌘V (keyCode 9)
        let newSummon = KeyShortcut(keyCode: UInt32(kVK_ANSI_V), modifierFlags: [.command, .shift])
        do {
            try config.setShortcut(newSummon, for: .summon)
        } catch {
            fatalError("Failed to set valid summon shortcut: \(error)")
        }
        assert(config.summonShortcut == newSummon, "Summon shortcut should be updated")

        var summonFired = false
        let registered = manager.registerSummonShortcut(config.summonShortcut) {
            summonFired = true
        }
        assert(registered, "Carbon hotkey registration for new shortcut should succeed")
        assert(manager.isSummonRegistered, "HotkeyManager should report registered")
        assert(manager.summonKeyCode == UInt32(kVK_ANSI_V), "HotkeyManager keyCode should be updated")

        manager.dispatchHotKey(id: HotkeyManager.summonHotKeyId)
        assert(summonFired, "Dispatched summon hotkey should trigger callback")

        manager.unregisterSummonHotkey()
        print("✓ Dynamic Carbon hotkey registration verified.")

        // -------------------------------------------------------------------------
        // Test 6: Persistence & Restoration Across Re-instantiation (T-SET-03)
        // -------------------------------------------------------------------------
        print("\nStep 6: Testing persistence across HotkeyConfiguration re-instantiation...")
        let customPin = KeyShortcut(keyCode: UInt32(kVK_ANSI_K), modifierFlags: [.control, .command])
        try? config.setShortcut(customPin, for: .pin)

        let reloadedConfig = HotkeyConfiguration(defaults: testDefaults)
        assert(reloadedConfig.summonShortcut == newSummon, "Persisted summon shortcut mismatch")
        assert(reloadedConfig.pinShortcut == customPin, "Persisted pin shortcut mismatch")

        // Test Reset to Default for single action
        reloadedConfig.resetToDefault(for: .summon)
        assert(reloadedConfig.summonShortcut == HotkeyConfiguration.defaultSummon, "Reset summon should restore default")
        assert(reloadedConfig.pinShortcut == customPin, "Other shortcuts should remain unchanged")

        // Test Reset All to Defaults
        reloadedConfig.resetAllToDefaults()
        assert(reloadedConfig.summonShortcut == HotkeyConfiguration.defaultSummon, "Reset all should restore default summon")
        assert(reloadedConfig.pinShortcut == HotkeyConfiguration.defaultPin, "Reset all should restore default pin")
        assert(reloadedConfig.deleteShortcut == HotkeyConfiguration.defaultDelete, "Reset all should restore default delete")
        assert(reloadedConfig.previewShortcut == HotkeyConfiguration.defaultPreview, "Reset all should restore default preview")
        assert(reloadedConfig.plainPasteShortcut == HotkeyConfiguration.defaultPlainPaste, "Reset all should restore default plain paste")

        print("✓ Persistence and default restoration verified.")

        print("\nAll Hotkey Settings & Collision integration tests passed cleanly! ✓")
    }
}
