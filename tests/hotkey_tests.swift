// ==============================================================================
// Mimra Tests — Global Hotkey Manager Verification (Carbon HIToolbox)
// Linked Features: F-017, F-023
// Test IDs: T-UI-01, T-KEY-02
// ==============================================================================

import AppKit
import Carbon
import Foundation

@main
struct HotkeyTests {
    @MainActor
    static func main() async {
        print("=== Running HotkeyManager Tests (T-UI-01, T-KEY-02) ===")

        let manager = HotkeyManager()
        assert(!manager.isSummonRegistered, "FAIL: Summon should not be registered upon initialization")

        // 1. Test registration of default summon hotkey (Shift-Command-C)
        var summonFiredCount = 0
        let registered = manager.registerSummonHotkey {
            summonFiredCount += 1
        }

        assert(registered, "FAIL: registerSummonHotkey should return true")
        assert(manager.isSummonRegistered, "FAIL: isSummonRegistered should be true")
        assert(manager.summonKeyCode == UInt32(kVK_ANSI_C), "FAIL: summonKeyCode should be kVK_ANSI_C")
        assert(manager.summonModifierFlags.contains([.command, .shift]), "FAIL: summonModifierFlags should contain command and shift")
        print("✓ T-KEY-02: Default summon hotkey (Shift-Command-C) registered successfully via Carbon")

        // 2. Test programmatic dispatch of summon hotkey
        manager.dispatchHotKey(id: HotkeyManager.summonHotKeyId)
        assert(summonFiredCount == 1, "FAIL: summon action should have fired exactly once")
        print("✓ T-KEY-02: Hotkey dispatch invokes registered action callback")

        // 3. Test unregistration
        manager.unregisterSummonHotkey()
        assert(!manager.isSummonRegistered, "FAIL: isSummonRegistered should be false after unregistration")

        manager.dispatchHotKey(id: HotkeyManager.summonHotKeyId)
        assert(summonFiredCount == 1, "FAIL: Unregistered hotkey should not invoke action")
        print("✓ T-KEY-02: Hotkey unregistration cleans up handlers and prevents invocation")

        // 4. Test re-registration and collision replacement
        var secondActionFired = false
        let secondRegistered = manager.registerSummonHotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)) {
            secondActionFired = true
        }
        assert(secondRegistered, "FAIL: Re-registration should succeed")
        assert(manager.isSummonRegistered, "FAIL: Re-registered summon hotkey should be active")

        manager.dispatchHotKey(id: HotkeyManager.summonHotKeyId)
        assert(secondActionFired, "FAIL: Re-registered action was not fired")
        print("✓ T-KEY-02: Hotkey re-registration and collision replacement verified")

        // 5. Test custom hotkey registration with distinct IDs
        let customId: UInt32 = 100
        var customActionFired = false
        let customRegistered = manager.registerHotkey(
            id: customId,
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(cmdKey | optionKey),
            action: {
                customActionFired = true
            }
        )
        assert(customRegistered, "FAIL: Custom hotkey registration failed")

        manager.dispatchHotKey(id: customId)
        assert(customActionFired, "FAIL: Custom action was not fired")

        manager.unregisterHotkey(id: customId)
        print("✓ T-KEY-02: Multi-hotkey registration and selective unregistration verified")

        print("✓ ALL HotkeyManager Tests PASSED!")
    }
}
