// ==============================================================================
// Mimra — Pin Shortcut Assignment & Punctuation Corpus Integration Tests
// Linked Features: F-024
// Test IDs: T-PIN-01
// Verification: Enforce unique bindings, reserved key conflicts, non-US layouts,
// and full punctuation key corpus: [];'./-=\
// ==============================================================================

import Foundation
import AppKit

@main
struct PinShortcutAssignmentTests {
    @MainActor
    static func main() async {
        print("--- Mimra Pin Shortcut Assignment Tests (P5-02 / F-024, T-PIN-01) ---")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("pin_shortcut_test.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        do {
            let core = try CoreClient(databasePath: dbPath)
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            print("\nStep 1: Ingest test items for shortcut assignment...")
            let capture1 = RawCapture(
                timestampMs: nowMs,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Item 1 Payload".data(using: .utf8)!)
                ]
            )
            let res1 = try await core.ingest(capture: capture1)

            let capture2 = RawCapture(
                timestampMs: nowMs + 100,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Item 2 Payload".data(using: .utf8)!)
                ]
            )
            let res2 = try await core.ingest(capture: capture2)

            // Pin both items
            try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: nil, pinOrder: 0)
            try await core.setPin(itemId: res2.itemId, isPinned: true, pinKey: nil, pinOrder: 1)
            print("✓ Items ingested and pinned.")

            print("\nStep 2: Test Reserved Key Conflicts (Option-P Protection)...")
            var caughtReservedP = false
            do {
                try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: "p", pinOrder: 0)
            } catch CoreError.PinKeyConflict(let key, let details) {
                caughtReservedP = true
                assert(key == "p", "Conflicting key must be 'p'")
                assert(details.contains("reserved"), "Details must explain key is reserved: \(details)")
            } catch {
                fatalError("Unexpected error type for reserved key 'p': \(error)")
            }
            assert(caughtReservedP, "Assigning 'p' must fail due to reserved Option-P conflict")

            var caughtReservedCapitalP = false
            do {
                try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: "P", pinOrder: 0)
            } catch CoreError.PinKeyConflict(let key, _) {
                caughtReservedCapitalP = true
                assert(key == "P", "Conflicting key must report 'P'")
            } catch {
                fatalError("Unexpected error for reserved key 'P': \(error)")
            }
            assert(caughtReservedCapitalP, "Assigning 'P' must fail due to reserved Option-P conflict")
            print("✓ Reserved key 'p'/'P' safely rejected with typed PinKeyConflict error.")

            print("\nStep 3: Test Invalid Input Validation (empty, whitespace, multi-character)...")
            var caughtEmpty = false
            do {
                _ = try await core.validatePinKey(key: "")
            } catch CoreError.InvalidInput {
                caughtEmpty = true
            }
            assert(caughtEmpty, "Empty pin key must be rejected")

            var caughtWhitespace = false
            do {
                _ = try await core.validatePinKey(key: "   ")
            } catch CoreError.InvalidInput {
                caughtWhitespace = true
            }
            assert(caughtWhitespace, "Whitespace pin key must be rejected")

            var caughtMultiChar = false
            do {
                _ = try await core.validatePinKey(key: "xyz")
            } catch CoreError.InvalidInput {
                caughtMultiChar = true
            }
            assert(caughtMultiChar, "Multi-character pin key must be rejected")
            print("✓ Empty, whitespace, and multi-character inputs rejected.")

            print("\nStep 4: Test Full Punctuation Test Corpus ([] ; ' . / - = \\)...")
            let punctuationCorpus = ["[", "]", ";", "'", ".", "/", "-", "=", "\\"]
            for punct in punctuationCorpus {
                let validated = try await core.validatePinKey(key: punct)
                assert(validated == punct, "Validated punctuation key must match: \(punct)")

                try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: punct, pinOrder: 0)
                let page = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
                let item = page.first(where: { $0.id == res1.itemId })!
                assert(item.pinKey == punct, "Item 1 pinKey must equal punctuation key '\(punct)'")
            }
            print("✓ All 9 characters in punctuation corpus [ ] ; ' . / - = \\ successfully assigned and stored.")

            print("\nStep 5: Test Non-US Keyboard Layout Corpus (ä, ö, ü, ß, é, è, ç, ñ, å, ş)...")
            let nonUsCorpus = ["ä", "ö", "ü", "ß", "é", "è", "ç", "ñ", "å", "ş"]
            for nonUs in nonUsCorpus {
                let validated = try await core.validatePinKey(key: nonUs)
                assert(validated == nonUs.lowercased(), "Validated non-US key must match lowercase: \(nonUs)")

                try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: nonUs, pinOrder: 0)
                let page = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
                let item = page.first(where: { $0.id == res1.itemId })!
                assert(item.pinKey == nonUs.lowercased(), "Item 1 pinKey must equal non-US key '\(nonUs)'")
            }
            print("✓ Non-US keyboard layout corpus verified across European and Turkish symbols.")

            print("\nStep 6: Test Unique Binding Enforcement & Case-Insensitive Collisions...")
            // Assign ';' to Item 1
            try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: ";", pinOrder: 0)

            // Attempting to assign ';' to Item 2 must fail
            var caughtPunctCollision = false
            do {
                try await core.setPin(itemId: res2.itemId, isPinned: true, pinKey: ";", pinOrder: 1)
            } catch CoreError.PinKeyConflict(let key, let details) {
                caughtPunctCollision = true
                assert(key == ";", "Collision must report key ';'")
                assert(details.contains("already assigned"), "Details must explain key collision")
            }
            assert(caughtPunctCollision, "Duplicate assignment of ';' must fail")

            // Assign 'k' to Item 1
            try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: "k", pinOrder: 0)

            // Attempting to assign uppercase 'K' to Item 2 must fail with case-insensitive collision
            var caughtCaseCollision = false
            do {
                try await core.setPin(itemId: res2.itemId, isPinned: true, pinKey: "K", pinOrder: 1)
            } catch CoreError.PinKeyConflict(let key, _) {
                caughtCaseCollision = true
                assert(key == "k", "Collision must report normalized key 'k'")
            }
            assert(caughtCaseCollision, "Case-insensitive duplicate assignment of 'K' must fail")

            // Clear shortcut on Item 1 -> allows Item 2 to claim 'k'
            try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: nil, pinOrder: 0)
            try await core.setPin(itemId: res2.itemId, isPinned: true, pinKey: "k", pinOrder: 1)
            let pageUpdated = try await core.listPageWithSort(sortMode: .recency, pinArrangement: .top, limit: 10, offset: 0)
            assert(pageUpdated.first(where: { $0.id == res1.itemId })?.pinKey == nil)
            assert(pageUpdated.first(where: { $0.id == res2.itemId })?.pinKey == "k")
            print("✓ Unique bindings and case-insensitive collision detection enforced.")

            print("\nStep 7: Test Keyboard Event Simulation via PanelCoordinator...")
            // Assign punctuation key '[' to Item 1 and ']' to Item 2
            try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: "[", pinOrder: 0)
            try await core.setPin(itemId: res2.itemId, isPinned: true, pinKey: "]", pinOrder: 1)

            let coordinator = PanelCoordinator(coreClient: core)
            await coordinator.viewModel.loadData()

            var committedItem: HistoryItemSummaryDto?
            var committedMode: PasteMode?
            coordinator.onItemCommitted = { item, mode, forcePaste in
                committedItem = item
                committedMode = mode
            }

            // A. Simulate Option + [
            let optBracketEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "“",
                charactersIgnoringModifiers: "[",
                isARepeat: false,
                keyCode: 33
            )!

            let handled1 = coordinator.handlePanelKeyDown(event: optBracketEvent)
            assert(handled1, "Option + [ must be handled by panel")
            assert(committedItem?.id == res1.itemId, "Option + [ must commit Item 1")
            assert(committedMode == .original, "Option + [ must commit in .original mode")

            // B. Simulate Option + Shift + ] (Plain Text)
            committedItem = nil
            committedMode = nil

            let optShiftBracketEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "‘",
                charactersIgnoringModifiers: "]",
                isARepeat: false,
                keyCode: 30
            )!

            let handled2 = coordinator.handlePanelKeyDown(event: optShiftBracketEvent)
            assert(handled2, "Option + Shift + ] must be handled by panel")
            assert(committedItem?.id == res2.itemId, "Option + Shift + ] must commit Item 2")
            assert(committedMode == .plainText, "Option + Shift + ] must commit in .plainText mode")

            // C. Simulate Non-US layout event (Option + ä)
            try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: "ä", pinOrder: 0)
            await coordinator.viewModel.loadData()

            committedItem = nil
            let optNonUsEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "ä",
                charactersIgnoringModifiers: "ä",
                isARepeat: false,
                keyCode: 39
            )!

            let handled3 = coordinator.handlePanelKeyDown(event: optNonUsEvent)
            assert(handled3, "Option + ä must be handled by panel")
            assert(committedItem?.id == res1.itemId, "Option + ä must commit Item 1")
            print("✓ Keyboard event handling for punctuation and non-US layouts verified.")

            print("\nStep 8: Test PanelViewModel setPinKey Method & Selection Preservation...")
            let viewModel = PanelViewModel(coreClient: core)
            await viewModel.loadData()
            assert(viewModel.items.count == 2)

            viewModel.selectIndex(1)
            let selectedBefore = viewModel.selectedItem
            assert(selectedBefore?.id == res2.itemId)

            // Update pinKey to '=' via ViewModel
            let ok = await viewModel.setPinKey(for: selectedBefore!, key: "=")
            assert(ok, "setPinKey must succeed")

            // Selection must be preserved on Item 2
            assert(viewModel.selectedItem?.id == res2.itemId, "Active selection preserved")
            assert(viewModel.selectedItem?.pinKey == "=", "New pinKey '=' reflected in ViewModel")

            // Clear pinKey via ViewModel
            let clearedOk = await viewModel.setPinKey(for: viewModel.selectedItem!, key: nil)
            assert(clearedOk, "Clearing pinKey must succeed")
            assert(viewModel.selectedItem?.pinKey == nil, "Pin key cleared in ViewModel")
            print("✓ PanelViewModel setPinKey integration and selection stability verified.")

            print("\n✓ ALL PIN SHORTCUT ASSIGNMENT INTEGRATION TESTS PASSED (P5-02 / DoD Satisfied)!")
        } catch {
            fatalError("Pin shortcut assignment test failed: \(error)")
        }
    }
}
