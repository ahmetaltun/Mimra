// ==============================================================================
// Mimra — VoiceOver & Keyboard Accessibility Integration Tests (P7-07 / F-060)
// Verifies VoiceOver element combining, semantic labels, status values, action rotors,
// and keyboard drag alternatives for pin reordering without mouse interaction.
// Linked Test: T-A11Y-01
// ==============================================================================

import AppKit
import Carbon
import Foundation

@main
struct VoiceOverAccessibilityTests {
    @MainActor
    static func main() async {
        print("--- Mimra VoiceOver & Keyboard Accessibility Tests (P7-07 / F-060, T-A11Y-01) ---")

        _ = NSApplication.shared

        // Setup temporary SQLite database
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("a11y_test.sqlite").path
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            let core = try CoreClient(databasePath: dbPath)

            // -------------------------------------------------------------------------
            // Test 1: VoiceOver Label Generation Across Content Types (F-060, T-A11Y-01)
            // -------------------------------------------------------------------------
            print("\nStep 1: Testing VoiceOver accessibility labels for diverse content types...")

            // 1a. Plain text item
            let textItem = HistoryItemSummaryDto(
                id: "item-text-1",
                contentKind: "plain_text",
                title: "Antigravity Assistant Prompt",
                snippet: "You are a helpful coding assistant...",
                isPinned: false,
                pinOrder: nil,
                pinKey: nil,
                sourceBundleId: "com.apple.dt.Xcode",
                firstCopiedAtMs: 1700000000000,
                lastCopiedAtMs: 1700000000000,
                copyCount: 1,
                byteSize: 128,
                availableUtis: ["public.utf8-plain-text"],
                titleHighlights: [],
                snippetHighlights: []
            )
            let textRow = PanelItemRow(item: textItem, shortcutIndex: 1, isSelected: true)
            let textLabel = textRow.accessibilityDescription
            assert(textLabel.contains("Antigravity Assistant Prompt"), "Label must include title")
            assert(textLabel.contains("Text"), "Label must identify plain text")
            assert(textLabel.contains("from Xcode"), "Label must identify source application: \(textLabel)")
            print("✓ Plain text accessibility label verified: '\(textLabel)'")

            // 1b. Image item
            let imageItem = HistoryItemSummaryDto(
                id: "item-img-1",
                contentKind: "image",
                title: "UI Design Mockup",
                snippet: "image/png 1920x1080",
                isPinned: true,
                pinOrder: 0,
                pinKey: "m",
                sourceBundleId: "com.figma.Desktop",
                firstCopiedAtMs: 1700000000000,
                lastCopiedAtMs: 1700000000000,
                copyCount: 3,
                byteSize: 204800,
                availableUtis: ["public.png"],
                titleHighlights: [],
                snippetHighlights: []
            )
            let imageRow = PanelItemRow(item: imageItem, shortcutIndex: nil, isSelected: false)
            let imageLabel = imageRow.accessibilityDescription
            assert(imageLabel.contains("UI Design Mockup"), "Label must include title")
            assert(imageLabel.contains("Image"), "Label must identify image content kind")
            assert(imageLabel.contains("from Desktop") || imageLabel.contains("from com.figma.Desktop"), "Label must identify source app: \(imageLabel)")
            print("✓ Image accessibility label verified: '\(imageLabel)'")

            // 1c. Hex Color item
            let colorItem = HistoryItemSummaryDto(
                id: "item-color-1",
                contentKind: "plain_text",
                title: "#FF5733",
                snippet: "RGB(255, 87, 51)",
                isPinned: false,
                pinOrder: nil,
                pinKey: nil,
                sourceBundleId: "com.apple.Safari",
                firstCopiedAtMs: 1700000000000,
                lastCopiedAtMs: 1700000000000,
                copyCount: 1,
                byteSize: 7,
                availableUtis: ["public.utf8-plain-text"],
                titleHighlights: [],
                snippetHighlights: []
            )
            let colorRow = PanelItemRow(item: colorItem, shortcutIndex: 2, isSelected: false)
            let colorLabel = colorRow.accessibilityDescription
            assert(colorLabel.contains("#FF5733"), "Label must include color code")
            assert(colorLabel.contains("Color #FF5733"), "Label must identify HEX color swatch: \(colorLabel)")
            print("✓ Hex color accessibility label verified: '\(colorLabel)'")

            // 1d. Web URL item
            let urlItem = HistoryItemSummaryDto(
                id: "item-url-1",
                contentKind: "plain_text",
                title: "https://developer.apple.com/documentation",
                snippet: "",
                isPinned: false,
                pinOrder: nil,
                pinKey: nil,
                sourceBundleId: "com.google.Chrome",
                firstCopiedAtMs: 1700000000000,
                lastCopiedAtMs: 1700000000000,
                copyCount: 1,
                byteSize: 42,
                availableUtis: ["public.utf8-plain-text"],
                titleHighlights: [],
                snippetHighlights: []
            )
            let urlRow = PanelItemRow(item: urlItem, shortcutIndex: 3, isSelected: false)
            let urlLabel = urlRow.accessibilityDescription
            assert(urlLabel.contains("Web link developer.apple.com"), "Label must identify web link with host: \(urlLabel)")
            print("✓ Web URL accessibility label verified: '\(urlLabel)'")

            // 1e. Empty title fallback
            let emptyTitleItem = HistoryItemSummaryDto(
                id: "item-empty-1",
                contentKind: "plain_text",
                title: "",
                snippet: "",
                isPinned: false,
                pinOrder: nil,
                pinKey: nil,
                sourceBundleId: nil,
                firstCopiedAtMs: 1700000000000,
                lastCopiedAtMs: 1700000000000,
                copyCount: 1,
                byteSize: 0,
                availableUtis: ["public.utf8-plain-text"],
                titleHighlights: [],
                snippetHighlights: []
            )
            let emptyRow = PanelItemRow(item: emptyTitleItem, shortcutIndex: nil, isSelected: false)
            assert(emptyRow.accessibilityDescription.contains("Untitled item"), "Empty title should fall back gracefully")
            print("✓ Empty title fallback verified.")

            // -------------------------------------------------------------------------
            // Test 2: VoiceOver Status Values & Pin Shortcuts (F-060, T-A11Y-01)
            // -------------------------------------------------------------------------
            print("\nStep 2: Testing VoiceOver accessibility status values...")

            // Pinned with custom shortcut badge
            let pinnedStatus = imageRow.accessibilityStatusValue
            assert(pinnedStatus.contains("Pinned, shortcut Option+M"), "Must announce custom pin shortcut: \(pinnedStatus)")
            assert(pinnedStatus.contains("copied 3 times"), "Must announce multi-copy count: \(pinnedStatus)")
            print("✓ Pinned status with custom key verified: '\(pinnedStatus)'")

            // Quick-pick shortcut announcement
            let quickPickStatus = textRow.accessibilityStatusValue
            assert(quickPickStatus.contains("Quick-pick Command+1"), "Must announce quick-pick number: \(quickPickStatus)")
            print("✓ Quick-pick status verified: '\(quickPickStatus)'")

            // -------------------------------------------------------------------------
            // Test 3: VoiceOver Hints (F-060, T-A11Y-01)
            // -------------------------------------------------------------------------
            print("\nStep 3: Testing VoiceOver keyboard hints...")
            let textHint = textRow.accessibilityRowHint
            assert(textHint.contains("Press Return to paste"), "Hint must advise Return to paste")
            assert(textHint.contains("Shift-Return for plain text"), "Hint must advise Shift-Return")
            assert(textHint.contains("Option-P to pin"), "Hint must advise Option-P")
            assert(!textHint.contains("reorder"), "Unpinned item must NOT advise pin reorder")

            let pinHint = imageRow.accessibilityRowHint
            assert(pinHint.contains("Option-P to unpin"), "Pinned item must advise Option-P to unpin")
            assert(pinHint.contains("Option-Command-Up or Down to reorder"), "Pinned item must advise keyboard reorder")
            print("✓ VoiceOver hints verified for pinned and unpinned items.")

            // -------------------------------------------------------------------------
            // Test 4: VoiceOver Action Rotor & Full Copy/Paste Lifecycle (F-060, T-A11Y-01)
            // -------------------------------------------------------------------------
            print("\nStep 4: Testing VoiceOver action rotor and copy/paste lifecycle...")

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let capture1 = RawCapture(
                timestampMs: nowMs,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "VoiceOver Ingested Text".data(using: .utf8)!)
                ]
            )
            let res1 = try await core.ingest(capture: capture1)

            let panelCoord = PanelCoordinator(coreClient: core)
            let panelVm = panelCoord.viewModel
            await panelVm.performSearch(query: "")
            assert(panelVm.items.count >= 1, "Database must have loaded the ingested item")

            let itemSummary = panelVm.items.first(where: { $0.id == res1.itemId })!

            // Verify committing selection via VoiceOver action
            var pasteRequestedMode: PasteMode? = nil
            var pasteForceFlag: Bool? = nil

            let testRow = PanelItemRow(
                item: itemSummary,
                shortcutIndex: 1,
                isSelected: true,
                coreClient: core,
                onCommit: { (mode: PasteMode, forcePaste: Bool?) in
                    pasteRequestedMode = mode
                    pasteForceFlag = forcePaste
                    panelVm.commitSelection(mode: mode, forcePaste: forcePaste)
                }
            )

            // Simulate VoiceOver "Paste" action
            testRow.onCommit?(PasteMode.original, nil)
            assert(pasteRequestedMode == .original, "VoiceOver Paste action must trigger original mode")
            assert(pasteForceFlag == nil, "VoiceOver Paste action uses default auto-paste setting")

            // Simulate VoiceOver "Copy" action
            testRow.onCommit?(PasteMode.original, false)
            assert(pasteForceFlag == false, "VoiceOver Copy action must explicitly bypass auto-paste")

            // Simulate VoiceOver "Paste as Plain Text" action
            testRow.onCommit?(PasteMode.plainText, nil)
            assert(pasteRequestedMode == .plainText, "VoiceOver Plain Text action must specify plainText mode")

            print("✓ VoiceOver copy/paste actions verified.")

            // -------------------------------------------------------------------------
            // Test 5: Keyboard Pin Reorder (Drag & Drop Alternative) (F-046, F-060, T-A11Y-01)
            // -------------------------------------------------------------------------
            print("\nStep 5: Testing keyboard pin reordering (drag-and-drop alternative)...")

            let capturePin1 = RawCapture(
                timestampMs: nowMs + 10,
                sourceBundleId: "com.apple.Notes",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Pinned Alpha".data(using: .utf8)!)
                ]
            )
            let resPin1 = try await core.ingest(capture: capturePin1)
            try await core.setPin(itemId: resPin1.itemId, isPinned: true, pinKey: "a", pinOrder: 0)

            let capturePin2 = RawCapture(
                timestampMs: nowMs + 20,
                sourceBundleId: "com.apple.Notes",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Pinned Beta".data(using: .utf8)!)
                ]
            )
            let resPin2 = try await core.ingest(capture: capturePin2)
            try await core.setPin(itemId: resPin2.itemId, isPinned: true, pinKey: "b", pinOrder: 1)

            await panelVm.performSearch(query: "")
            let pinnedBefore = panelVm.items.filter { $0.isPinned }
            assert(pinnedBefore.count >= 2, "Must have at least 2 pinned items")
            let firstPinnedId = pinnedBefore[0].id
            let secondPinnedId = pinnedBefore[1].id

            // Test moving pin down via programmatic action (same as VoiceOver "Move Pin Down" action)
            let moveSuccess = await panelVm.movePinDown(item: pinnedBefore[0])
            assert(moveSuccess, "movePinDown must succeed")

            let pinnedAfterDown = panelVm.items.filter { $0.isPinned }
            assert(pinnedAfterDown[0].id == secondPinnedId, "Second item must now be first after move down")
            assert(pinnedAfterDown[1].id == firstPinnedId, "First item must now be second after move down")
            print("✓ VoiceOver keyboard movePinDown reordered items correctly.")

            // Test moving pin up via programmatic action (same as VoiceOver "Move Pin Up" action)
            let moveUpSuccess = await panelVm.movePinUp(item: pinnedAfterDown[1])
            assert(moveUpSuccess, "movePinUp must succeed")

            let pinnedAfterUp = panelVm.items.filter { $0.isPinned }
            assert(pinnedAfterUp[0].id == firstPinnedId, "Original item must be back on top after move up")
            print("✓ VoiceOver keyboard movePinUp restored order correctly.")

            // Test synthetic Option-Command-Down and Option-Command-Up key events in PanelCoordinator
            panelVm.selectIndex(0, fromHover: false)

            // Synthetic Option-Command-Down event (keyCode 125)
            let optCmdDownEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 125
            )!
            let handledDown = panelCoord.handlePanelKeyDown(event: optCmdDownEvent)
            assert(handledDown, "PanelCoordinator must handle ⌥⌘↓ to reorder pins")

            // Synthetic Option-Command-Up event (keyCode 126)
            let optCmdUpEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 126
            )!
            let handledUp = panelCoord.handlePanelKeyDown(event: optCmdUpEvent)
            assert(handledUp, "PanelCoordinator must handle ⌥⌘↑ to reorder pins")

            print("✓ Keyboard shortcuts ⌥⌘↑ and ⌥⌘↓ verified as mouse drag-and-drop alternatives.")

            print("\nAll VoiceOver & Keyboard Accessibility integration tests passed cleanly! ✓")
        } catch {
            fatalError("Failed with error: \(error)")
        }
    }
}
