// ==============================================================================
// Mimra Tests — Search Interaction & Keyboard Navigation Verification
// Linked Features: F-019
// Test IDs: T-UI-03
// ==============================================================================

import AppKit
import Foundation
import QuartzCore

@main
struct SearchInteractionTests {
    @MainActor
    static func main() async {
        print("=== Running Search Interaction & Keyboard Tests (T-UI-03) ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_search_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.db").path

        let core = try! CoreClient(databasePath: dbPath)
        let coordinator = PanelCoordinator(coreClient: core)
        let vm = coordinator.viewModel

        // Create 4 test items
        let item1 = HistoryItemSummaryDto(
            id: "id-1",
            contentKind: "text",
            title: "Alpha Clip",
            snippet: "The first quick brown fox",
            isPinned: false,
            pinOrder: nil,
            pinKey: nil,
            sourceBundleId: "com.apple.Terminal",
            firstCopiedAtMs: 1000,
            lastCopiedAtMs: 4000,
            copyCount: 1,
            byteSize: 30,
            availableUtis: ["public.utf8-plain-text"]
        )
        let item2 = HistoryItemSummaryDto(
            id: "id-2",
            contentKind: "text",
            title: "Beta Clip",
            snippet: "Secondary payload information",
            isPinned: true,
            pinOrder: 1,
            pinKey: nil,
            sourceBundleId: "com.apple.Safari",
            firstCopiedAtMs: 2000,
            lastCopiedAtMs: 3000,
            copyCount: 2,
            byteSize: 45,
            availableUtis: ["public.utf8-plain-text"]
        )
        let item3 = HistoryItemSummaryDto(
            id: "id-3",
            contentKind: "rich_text",
            title: "Gamma Clip",
            snippet: "Third formatted content",
            isPinned: false,
            pinOrder: nil,
            pinKey: nil,
            sourceBundleId: "com.google.Chrome",
            firstCopiedAtMs: 1500,
            lastCopiedAtMs: 2500,
            copyCount: 1,
            byteSize: 60,
            availableUtis: ["public.rtf", "public.utf8-plain-text"]
        )
        let item4 = HistoryItemSummaryDto(
            id: "id-4",
            contentKind: "file_urls",
            title: "Delta Clip",
            snippet: "Fourth file reference",
            isPinned: false,
            pinOrder: nil,
            pinKey: nil,
            sourceBundleId: "com.apple.Finder",
            firstCopiedAtMs: 500,
            lastCopiedAtMs: 1000,
            copyCount: 1,
            byteSize: 120,
            availableUtis: ["public.file-url"]
        )

        vm.items = [item1, item2, item3, item4]
        assert(vm.filteredItems.count == 4, "FAIL: Initial filtered items count must be 4")
        assert(vm.selectedIndex == 0, "FAIL: Initial selectedIndex must be 0")

        // ---------------------------------------------------------------------
        // 1. Up / Down Arrow Navigation & Wrapping (F-019)
        // ---------------------------------------------------------------------
        vm.selectNext()
        assert(vm.selectedIndex == 1, "FAIL: selectNext should advance to 1")

        vm.selectNext()
        assert(vm.selectedIndex == 2, "FAIL: selectNext should advance to 2")

        vm.selectNext()
        assert(vm.selectedIndex == 3, "FAIL: selectNext should advance to 3")

        // Wrapping at bottom
        vm.selectNext()
        assert(vm.selectedIndex == 0, "FAIL: selectNext at bottom should wrap around to 0")

        // Wrapping at top
        vm.selectPrevious()
        assert(vm.selectedIndex == 3, "FAIL: selectPrevious at 0 should wrap around to 3")

        vm.selectPrevious()
        assert(vm.selectedIndex == 2, "FAIL: selectPrevious should move to 2")
        print("✓ T-UI-03: Up/Down arrow selection navigation with wrapping verified")

        // ---------------------------------------------------------------------
        // 2. Search as You Type & Selection Reset (F-019)
        // ---------------------------------------------------------------------
        vm.selectedIndex = 2
        vm.searchText = "fox"
        assert(vm.filteredItems.count == 1, "FAIL: Search 'fox' should match exactly 1 item")
        assert(vm.filteredItems.first?.id == "id-1", "FAIL: Matched item should be Alpha Clip")
        assert(vm.selectedIndex == 0, "FAIL: Search text change must reset selectedIndex to 0")

        // Case-insensitive match on title
        vm.searchText = "BETA"
        assert(vm.filteredItems.count == 1, "FAIL: Case-insensitive 'BETA' should match 1 item")
        assert(vm.filteredItems.first?.id == "id-2", "FAIL: Matched item should be Beta Clip")

        // Reset search query
        vm.searchText = ""
        assert(vm.filteredItems.count == 4, "FAIL: Clearing search should restore all 4 items")
        print("✓ T-UI-03: Search-as-you-type and automatic selection reset verified")

        // ---------------------------------------------------------------------
        // 3. Spurious Hover Override Protection (T-UI-03)
        // ---------------------------------------------------------------------
        vm.selectedIndex = 0
        vm.selectNext() // Keyboard navigation sets lastKeyboardNavTime to CACurrentMediaTime()
        assert(vm.selectedIndex == 1, "FAIL: Selection should be at 1")

        // Attempt immediate hover event (within 250ms of keyboard navigation)
        vm.selectIndex(3, fromHover: true)
        assert(vm.selectedIndex == 1, "FAIL: Accidental mouse hover within 250ms of keyboard nav must be ignored!")
        print("✓ T-UI-03: Spurious hover override immediately after keyboard navigation successfully prevented")

        // ---------------------------------------------------------------------
        // 4. Quick-Pick Shortcuts (⌘1 - ⌘9) (F-022)
        // ---------------------------------------------------------------------
        var committedItem: HistoryItemSummaryDto?
        var committedMode: PasteMode?
        vm.onCommitItem = { item, mode, forcePaste in
            committedItem = item
            committedMode = mode
        }

        vm.quickPick(number: 3)
        assert(committedItem?.id == "id-3", "FAIL: Quick-pick ⌘3 did not commit item 3")
        assert(committedMode == .original, "FAIL: Quick-pick ⌘3 should default to original mode")
        assert(vm.selectedIndex == 2, "FAIL: Quick-pick ⌘3 did not set selectedIndex to 2")
        print("✓ T-UI-03 / F-022: Quick-pick shortcut ⌘1..⌘9 commits target row")

        // ---------------------------------------------------------------------
        // 5. Return Key Commit & Escape Dismissal
        // ---------------------------------------------------------------------
        vm.items = [item1, item2, item3, item4]
        vm.selectedIndex = 1
        committedItem = nil
        committedMode = nil
        vm.commitSelection()
        assert(committedItem?.id == "id-2", "FAIL: commitSelection should commit currently selected item")
        assert(committedMode == .original, "FAIL: commitSelection should default to original mode")
        print("✓ T-UI-03: Return key commits current selection")

        // ---------------------------------------------------------------------
        // 6. Local Key Event Handling via PanelCoordinator
        // ---------------------------------------------------------------------
        // Simulated Down Arrow (keyCode 125)
        let downEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 125
        )!
        let downHandled = coordinator.handlePanelKeyDown(event: downEvent)
        assert(downHandled, "FAIL: Down arrow key event was not handled")

        // Simulated Up Arrow (keyCode 126)
        let upEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 126
        )!
        let upHandled = coordinator.handlePanelKeyDown(event: upEvent)
        assert(upHandled, "FAIL: Up arrow key event was not handled")

        // Simulated Return (keyCode 36)
        committedItem = nil
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
        let returnHandled = coordinator.handlePanelKeyDown(event: returnEvent)
        assert(returnHandled, "FAIL: Return key event was not handled")
        assert(committedItem != nil, "FAIL: Return key event did not trigger commit")

        // Simulated Escape (keyCode 53)
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
        assert(escapeHandled, "FAIL: Escape key event was not handled")

        try? FileManager.default.removeItem(at: tempDir)

        print("✓ T-UI-03: PanelCoordinator keyboard event interceptor verified")
        print("✓ ALL Search Interaction & Keyboard Tests PASSED!")
    }
}
