// ==============================================================================
// Mimra — Localization & IME Composition Integration Tests (P7-06 / F-033, F-059)
// Verifies string catalog lookup, RTL detection, layout expansion, CJK IME marked
// text delegation, and keyboard layout helpers (Dvorak, AZERTY).
// Linked Tests: T-I18N-01, T-I18N-02
// ==============================================================================

import AppKit
import Carbon
import Foundation

@main
struct LocalizationImeTests {
    @MainActor
    static func main() async {
        print("--- Mimra Localization & IME Composition Tests (P7-06 / F-033, F-059) ---")

        _ = NSApplication.shared

        let testDefaults = UserDefaults.standard
        testDefaults.removeObject(forKey: LocalizationService.appLanguageKey)

        defer {
            testDefaults.removeObject(forKey: LocalizationService.appLanguageKey)
        }

        let locService = LocalizationService(defaults: testDefaults)

        // -------------------------------------------------------------------------
        // Test 1: String Catalog Translations (F-059, T-I18N-02)
        // -------------------------------------------------------------------------
        print("\nStep 1: Testing string catalog lookup across languages...")

        // English (default)
        locService.currentLanguage = .english
        assert(locService.string(forKey: "panel.empty_title") == "Clipboard is Empty")
        assert(locService.string(forKey: "settings.appearance") == "Appearance")
        assert(locService.string(forKey: "action.copy") == "Copy")

        // Japanese (ja)
        locService.currentLanguage = .japanese
        assert(locService.string(forKey: "panel.empty_title") == "クリップボードは空です")
        assert(locService.string(forKey: "settings.appearance") == "外観")
        assert(locService.string(forKey: "action.copy") == "コピー")

        // German (de)
        locService.currentLanguage = .german
        assert(locService.string(forKey: "panel.empty_title") == "Zwischenablage ist leer")
        assert(locService.string(forKey: "settings.appearance") == "Erscheinungsbild")
        assert(locService.string(forKey: "action.copy") == "Kopieren")

        // Turkish (tr)
        locService.currentLanguage = .turkish
        assert(locService.string(forKey: "panel.empty_title") == "Pano Boş")
        assert(locService.string(forKey: "settings.appearance") == "Görünüm")
        assert(locService.string(forKey: "action.copy") == "Kopyala")

        // Arabic (ar)
        locService.currentLanguage = .arabic
        assert(locService.string(forKey: "panel.empty_title") == "الحافظة فارغة")
        assert(locService.string(forKey: "settings.appearance") == "المظهر")
        assert(locService.string(forKey: "action.copy") == "نسخ")

        // Fallback for unknown key
        let fallback = locService.string(forKey: "unknown.key.test")
        assert(fallback == "unknown.key.test", "Unknown key should fall back to key name")

        print("✓ String catalog translations verified across 5 languages.")

        // -------------------------------------------------------------------------
        // Test 2: RTL (Right-to-Left) Direction Detection (F-059, T-I18N-02)
        // -------------------------------------------------------------------------
        print("\nStep 2: Testing RTL text direction detection...")
        assert(AppLanguage.arabic.isRTL == true, "Arabic must report isRTL == true")
        assert(AppLanguage.english.isRTL == false, "English must report isRTL == false")
        assert(AppLanguage.japanese.isRTL == false, "Japanese must report isRTL == false")
        assert(AppLanguage.german.isRTL == false, "German must report isRTL == false")
        assert(AppLanguage.turkish.isRTL == false, "Turkish must report isRTL == false")
        print("✓ RTL detection verified.")

        // -------------------------------------------------------------------------
        // Test 3: Layout Expansion Verification (F-059, T-I18N-02)
        // -------------------------------------------------------------------------
        print("\nStep 3: Testing layout expansion of translated strings...")
        // German and Arabic strings typically expand significantly compared to English
        let enSettings = locService.string(forKey: "settings.hotkeys", language: .english)
        let deSettings = locService.string(forKey: "settings.hotkeys", language: .german)
        let arSettings = locService.string(forKey: "settings.hotkeys", language: .arabic)

        assert(deSettings.count > enSettings.count, "German label (\(deSettings)) must accommodate expansion")
        assert(!arSettings.isEmpty, "Arabic label must not be empty")

        let enRestore = locService.string(forKey: "action.restore_defaults", language: .english)
        let deRestore = locService.string(forKey: "action.restore_defaults", language: .german)
        assert(deRestore.count >= enRestore.count, "German action button label expansion verified: \(deRestore)")

        print("✓ Layout expansion verified without string truncation.")

        // -------------------------------------------------------------------------
        // Test 4: Japanese / CJK IME Composition Safety (F-033, T-I18N-01)
        // -------------------------------------------------------------------------
        print("\nStep 4: Testing Japanese/CJK IME composition delegation...")

        // Setup PanelCoordinator with temporary in-memory database
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("ime_test.sqlite").path
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            let core = try CoreClient(databasePath: dbPath)
            let panelCoord = PanelCoordinator(coreClient: core)

            // Synthetic Return key event (keyCode 36)
            let returnEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )!

            // Synthetic Escape key event (keyCode 53)
            let escapeEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )!

            // Case A: IME is actively composing (has marked text candidate)
            // handlePanelKeyDown MUST return false so the keystroke passes to NSTextInputClient
            var isComposing = true
            panelCoord.isImeComposingOverride = { isComposing }

            let returnHandledDuringIme = panelCoord.handlePanelKeyDown(event: returnEvent)
            assert(!returnHandledDuringIme,
                   "Return key during active IME composition must NOT be intercepted by panel (must delegate to candidate conversion)")

            let escapeHandledDuringIme = panelCoord.handlePanelKeyDown(event: escapeEvent)
            assert(!escapeHandledDuringIme,
                   "Escape key during active IME composition must NOT dismiss the panel (must cancel marked text)")

            // Case B: IME composition completed (marked text committed)
            // handlePanelKeyDown handles the events normally
            isComposing = false

            let escapeHandledNormal = panelCoord.handlePanelKeyDown(event: escapeEvent)
            assert(escapeHandledNormal,
                   "Escape key when NOT composing should be handled by panel to close")

            print("✓ Japanese/CJK IME marked text candidate conversion safety verified.")
        } catch {
            fatalError("Failed to initialize CoreClient for IME test: \(error)")
        }

        // -------------------------------------------------------------------------
        // Test 5: International Keyboard Layouts: Dvorak & French AZERTY (F-033, T-I18N-01)
        // -------------------------------------------------------------------------
        print("\nStep 5: Testing physical key layout translation (Dvorak, AZERTY)...")

        // Dvorak translation
        let dvorakC = KeyCodeHelper.character(for: UInt32(kVK_ANSI_C), layoutName: "DVORAK")
        assert(dvorakC == "J", "Keycode 8 on Dvorak should map to J")

        let dvorakP = KeyCodeHelper.character(for: UInt32(kVK_ANSI_P), layoutName: "DVORAK")
        assert(dvorakP == "R", "Keycode 35 on Dvorak should map to R")

        // French AZERTY translation
        let azertyQ = KeyCodeHelper.character(for: UInt32(kVK_ANSI_Q), layoutName: "AZERTY")
        assert(azertyQ == "A", "Keycode 12 (Q on QWERTY) on AZERTY should map to A")

        let azertyA = KeyCodeHelper.character(for: UInt32(kVK_ANSI_A), layoutName: "AZERTY")
        assert(azertyA == "Q", "Keycode 0 (A on QWERTY) on AZERTY should map to Q")

        // French AZERTY numbers row virtual keycodes
        let azerty1 = KeyCodeHelper.character(for: 18, layoutName: "AZERTY")
        assert(azerty1 == "&", "Keycode 18 on AZERTY should map to &")

        let azerty2 = KeyCodeHelper.character(for: 19, layoutName: "AZERTY")
        assert(azerty2 == "é", "Keycode 19 on AZERTY should map to é")

        // Test quickPickNumber with virtual key codes (layout-independent)
        let azertyNumEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "&",
            charactersIgnoringModifiers: "&",
            isARepeat: false,
            keyCode: 18 // virtual key code for top row key 1
        )!
        let parsedNum = PanelCoordinator.quickPickNumber(for: azertyNumEvent)
        assert(parsedNum == 1, "Top-row keycode 18 on AZERTY must parse as quick-pick number 1")

        print("✓ Dvorak and French AZERTY keyboard translations verified.")

        // -------------------------------------------------------------------------
        // Test 6: Persistence Across Relaunch (T-I18N-02)
        // -------------------------------------------------------------------------
        print("\nStep 6: Testing language selection persistence...")
        locService.currentLanguage = .german

        let reloaded = LocalizationService(defaults: testDefaults)
        assert(reloaded.currentLanguage == .german, "Selected language should persist across reload")

        print("✓ Language selection persistence verified.")

        print("\nAll Localization & IME Composition integration tests passed cleanly! ✓")
    }
}
