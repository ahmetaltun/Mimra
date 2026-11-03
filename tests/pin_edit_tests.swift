// ==============================================================================
// Mimra — In-Preview Pin Editing & Transactional Reindexing Integration Tests
// Linked Features: F-045, F-024
// Test IDs: T-PIN-02
// Verification: In-preview text editing for pinned items, transactional FTS5
// reindexing, retained pin UUID and shortcuts, copy/paste fidelity, and
// preservation of unrelated representations without corruption.
// ==============================================================================

import AppKit
import Foundation

@main
struct PinEditTests {
    @MainActor
    static func main() async {
        print("=== Running Pin Editing & Reindexing Tests (P5-04 / F-045, T-PIN-02) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_pin_edit_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("pin_edit.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        do {
            print("\nStep 1: Ingest Initial Dataset (2 Pinned Items, 1 Unpinned Item)...")
            let core = try CoreClient(databasePath: dbPath)
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            // Item 1: Plain text pinned item
            let cap1 = RawCapture(
                timestampMs: nowMs,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Initial Text Alpha".data(using: .utf8)!)
                ]
            )
            let res1 = try await core.ingest(capture: cap1)

            // Item 2: Multi-representation pinned item (plain text + HTML + source attribution)
            let cap2 = RawCapture(
                timestampMs: nowMs + 10,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Original Rich Item".data(using: .utf8)!),
                    RawRepresentation(groupIndex: 0, uti: "public.html", payload: "<p>Original Rich Item</p>".data(using: .utf8)!),
                    RawRepresentation(groupIndex: 0, uti: "org.nspasteboard.source", payload: "com.apple.Safari".data(using: .utf8)!)
                ]
            )
            let res2 = try await core.ingest(capture: cap2)

            // Item 3: Unpinned item
            let cap3 = RawCapture(
                timestampMs: nowMs + 20,
                sourceBundleId: "com.google.Chrome",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Unpinned Delta".data(using: .utf8)!)
                ]
            )
            let res3 = try await core.ingest(capture: cap3)

            // Pin items 1 and 2 with custom shortcuts and explicit pin orders
            try await core.setPin(itemId: res1.itemId, isPinned: true, pinKey: "[", pinOrder: 0)
            try await core.setPin(itemId: res2.itemId, isPinned: true, pinKey: "k", pinOrder: 1)

            // Verify initial search matches
            let searchAlpha = try await core.searchPage(query: "Alpha", mode: .exact, limit: 10, offset: 0)
            assert(searchAlpha.count == 1 && searchAlpha[0].id == res1.itemId, "Search for 'Alpha' must match Item 1")

            let searchRich = try await core.searchPage(query: "Original", mode: .exact, limit: 10, offset: 0)
            assert(searchRich.count == 1 && searchRich[0].id == res2.itemId, "Search for 'Original' must match Item 2")
            print("✓ Initial dataset, pinning, and FTS5 search index verified.")

            print("\nStep 2: Core editPinnedItemText Execution on Item 1 (F-045)...")
            let updated1 = try await core.editPinnedItemText(
                itemId: res1.itemId,
                newText: "Updated Text Omega"
            )

            // Verify returned summary
            assert(updated1.id == res1.itemId, "FAIL: Item ID must be retained across text edit")
            assert(updated1.title == "Updated Text Omega", "FAIL: Title must reflect new content")
            assert(updated1.isPinned == true, "FAIL: Item must remain pinned")
            assert(updated1.pinKey == "[", "FAIL: Custom shortcut '[' must be preserved")
            assert(updated1.pinOrder == 0, "FAIL: pinOrder 0 must be preserved")

            // Verify payload update via fetchPayload
            let payload1 = try await core.fetchPayload(itemId: res1.itemId, uti: "public.utf8-plain-text")
            assert(payload1 != nil, "Payload must exist")
            let text1 = String(data: payload1!, encoding: .utf8)
            assert(text1 == "Updated Text Omega", "Payload must match edited text exactly")

            // Verify FTS5 transactional index update
            let searchOmega = try await core.searchPage(query: "Omega", mode: .exact, limit: 10, offset: 0)
            assert(searchOmega.count == 1 && searchOmega[0].id == res1.itemId, "Search for 'Omega' must match edited Item 1")

            let oldSearch = try await core.searchPage(query: "Alpha", mode: .exact, limit: 10, offset: 0)
            assert(oldSearch.isEmpty, "Old content 'Alpha' must no longer appear in search results")
            print("✓ Plain text pin edited, retained ID/shortcut, and transactional FTS5 reindexing verified.")

            print("\nStep 3: Multi-Representation Editing & Unrelated Representation Integrity...")
            let updated2 = try await core.editPinnedItemText(
                itemId: res2.itemId,
                newText: "Revised Multi-Rep Article"
            )

            assert(updated2.id == res2.itemId, "Item 2 ID must be retained")
            assert(updated2.title == "Revised Multi-Rep Article", "Title must reflect revised text")
            assert(updated2.pinKey == "k", "Shortcut 'k' must be preserved")

            // Verify plain text representation
            let repText2 = try await core.fetchPayload(itemId: res2.itemId, uti: "public.utf8-plain-text")
            assert(String(data: repText2!, encoding: .utf8) == "Revised Multi-Rep Article")

            // Verify HTML representation was updated to match
            let repHtml2 = try await core.fetchPayload(itemId: res2.itemId, uti: "public.html")
            assert(repHtml2 != nil, "HTML representation must exist")
            let htmlStr = String(data: repHtml2!, encoding: .utf8)!
            assert(htmlStr.contains("Revised Multi-Rep Article"), "HTML representation must contain revised text: \(htmlStr)")

            // Verify unrelated metadata representation (org.nspasteboard.source) was preserved
            let repSource = try await core.fetchPayload(itemId: res2.itemId, uti: "org.nspasteboard.source")
            assert(repSource != nil, "Unrelated representation 'org.nspasteboard.source' must NOT be corrupted or lost")
            assert(String(data: repSource!, encoding: .utf8) == "com.apple.Safari", "Source attribution must be intact")
            print("✓ Multi-representation pin edited: text and HTML updated; unrelated representations preserved.")

            print("\nStep 4: Edge Cases & Error Boundaries (T-PIN-02)...")
            // A. Attempting to edit unpinned item (res3) -> must fail
            var caughtUnpinned = false
            do {
                _ = try await core.editPinnedItemText(itemId: res3.itemId, newText: "Attempt Edit Unpinned")
            } catch CoreError.InvalidInput(let details) {
                caughtUnpinned = true
                assert(details.contains("not pinned"), "Expected error message to mention item is not pinned: \(details)")
            }
            assert(caughtUnpinned, "FAIL: editPinnedItemText did not reject unpinned item")

            // B. Attempting to edit with empty/whitespace text -> must fail
            var caughtEmpty = false
            do {
                _ = try await core.editPinnedItemText(itemId: res1.itemId, newText: "   \n  \t  ")
            } catch CoreError.InvalidInput(let details) {
                caughtEmpty = true
                assert(details.contains("empty"), "Expected error message to mention empty text: \(details)")
            }
            assert(caughtEmpty, "FAIL: editPinnedItemText did not reject empty text")

            // C. Attempting to edit non-existent UUID -> must fail
            var caughtNotFound = false
            do {
                _ = try await core.editPinnedItemText(itemId: UUID().uuidString, newText: "Non-existent")
            } catch CoreError.ItemNotFound(let id) {
                caughtNotFound = true
                assert(!id.isEmpty, "ItemNotFound error should report missing id")
            }
            assert(caughtNotFound, "FAIL: editPinnedItemText did not reject non-existent UUID")
            print("✓ Error handling verified: unpinned, empty, and non-existent IDs rejected with typed errors.")

            print("\nStep 5: PanelViewModel startEditing / commitEditing Integration...")
            let coordinator = PanelCoordinator(coreClient: core)
            let vm = coordinator.viewModel
            await vm.loadData()

            assert(vm.items.count == 3, "ViewModel should have loaded 3 items")
            let itemToEdit = vm.items.first(where: { $0.id == res1.itemId })!

            // Start editing
            await vm.startEditing(item: itemToEdit)
            assert(vm.editingPinItem?.id == res1.itemId, "editingPinItem should be set to item 1")
            assert(vm.editingPinText == "Updated Text Omega", "editingPinText should be pre-populated with current payload")

            // Modify text in editor
            vm.editingPinText = "Final Polished Title"
            let commitSuccess = await vm.commitEditing()
            assert(commitSuccess, "commitEditing should succeed")

            assert(vm.editingPinItem == nil, "editingPinItem should be reset to nil after commit")
            assert(vm.editingPinText.isEmpty, "editingPinText should be cleared after commit")

            // Verify ViewModel updated in-memory items
            let reloadedItem = vm.items.first(where: { $0.id == res1.itemId })!
            assert(reloadedItem.title == "Final Polished Title", "In-memory list item must reflect new title")
            print("✓ PanelViewModel editing lifecycle (startEditing, edit text, commitEditing) verified.")

            print("\nStep 6: Keyboard Event Interception (⌘E, Esc, ⌘↵)...")
            // Select Item 1 in ViewModel
            vm.selectIndex(0, fromHover: false)
            assert(vm.selectedItem?.id == res1.itemId)

            // Simulate Command-E (keyCode 14)
            let cmdEEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "e",
                charactersIgnoringModifiers: "e",
                isARepeat: false,
                keyCode: 14
            )!

            let cmdEHandled = coordinator.handlePanelKeyDown(event: cmdEEvent)
            assert(cmdEHandled, "Command-E must be handled by panel coordinator")

            // Wait for background Task in coordinator to set editing state
            try await Task.sleep(nanoseconds: 100_000_000)
            assert(vm.editingPinItem?.id == res1.itemId, "Command-E should enter editing mode for selected item")

            // Simulate Escape (keyCode 53) while editing -> cancels edit
            let escapeEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 53
            )!

            let escapeHandled = coordinator.handlePanelKeyDown(event: escapeEvent)
            assert(escapeHandled, "Escape must be handled during active editing")
            assert(vm.editingPinItem == nil, "Escape must cancel editing mode")

            // Re-open via startEditing, edit text, and simulate Command-Return (keyCode 36)
            await vm.startEditing(item: itemToEdit)
            vm.editingPinText = "Keyboard Shortcut Edited Title"

            let cmdReturnEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )!

            let cmdReturnHandled = coordinator.handlePanelKeyDown(event: cmdReturnEvent)
            assert(cmdReturnHandled, "Command-Return must be handled during active editing")

            try await Task.sleep(nanoseconds: 100_000_000)
            assert(vm.editingPinItem == nil, "Command-Return should commit and exit editing mode")

            let finalItem = vm.items.first(where: { $0.id == res1.itemId })!
            assert(finalItem.title == "Keyboard Shortcut Edited Title", "Item title must reflect ⌘↵ commit")
            print("✓ Keyboard event handling (⌘E to open, Esc to cancel, ⌘↵ to save) verified.")

            print("\nStep 7: Database Cold Relaunch Determinism & Search Durability (DoD)...")
            // Reopen database with fresh CoreClient
            let freshCore = try CoreClient(databasePath: dbPath)
            let relaunchedList = try await freshCore.listPageWithSort(
                sortMode: .recency,
                pinArrangement: .top,
                limit: 10,
                offset: 0
            )

            assert(relaunchedList.count == 3, "Expected 3 items after relaunch")
            let relaunchedItem1 = relaunchedList.first(where: { $0.id == res1.itemId })!
            assert(relaunchedItem1.title == "Keyboard Shortcut Edited Title", "Edited title must persist across relaunch")
            assert(relaunchedItem1.isPinned == true, "Pinned status must persist")
            assert(relaunchedItem1.pinKey == "[", "Shortcut '[' must persist")

            let searchRelaunch = try await freshCore.searchPage(
                query: "Keyboard",
                mode: .exact,
                limit: 10,
                offset: 0
            )
            assert(searchRelaunch.count == 1 && searchRelaunch[0].id == res1.itemId, "FTS5 index must find edited item after relaunch")

            print("✓ Cold relaunch determinism verified: edited content, retained ID, shortcuts, and FTS5 search intact.")

            print("\n🎉 ALL PIN EDITING & REINDEXING INTEGRATION TESTS PASSED (P5-04 / F-045, T-PIN-02)!")
        } catch {
            fatalError("Pin editing tests failed with error: \(error)")
        }
    }
}
