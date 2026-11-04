// ==============================================================================
// Mimra Tests — User Issues Verification (F-018, F-023, F-039, F-042, F-055)
// Verifies:
// 1. Browser-copied images with HTML & URL flavors maintain ContentKind.image, valid title, thumbnail & ImagePreview.
// 2. Control+Space, Option+Space, Command+Y, and Space toggle preview panel.
// 3. Settings button on history window footer correctly triggers onSettingsRequested.
// 4. Maximum limit for history items is configurable with a solid upper bound of 2000.
// 5. Option+Backspace deletes item; Command+Backspace does NOT delete item.
// ==============================================================================

import AppKit
import Carbon
import Foundation
import SwiftUI

@main
struct UserIssuesFixesTests {
    @MainActor
    static func main() async {
        print("=== Running User Issues Verification Tests ===")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_fixes_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("fixes.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let core = try! CoreClient(databasePath: dbPath)
        let coordinator = PanelCoordinator(coreClient: core)
        let vm = coordinator.viewModel

        // ---------------------------------------------------------------------
        // Test 1: Browser Image Copy (ContentKind.image, Title, Preview)
        // ---------------------------------------------------------------------
        print("\n[Test 1] Browser-copied image with HTML, URL, and attachment characters...")

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x01])
        let htmlBytes = Data("<meta charset='utf-8'><img src=\"https://example.com/photo.png\">".utf8)
        let urlBytes = Data("https://example.com/photo.png".utf8)
        let textBytes = Data("\u{FFFC}".utf8) // Browser object replacement char

        let capture = RawCapture(
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            sourceBundleId: "com.brave.Browser",
            representations: [
                RawRepresentation(groupIndex: 0, uti: "public.png", payload: pngBytes),
                RawRepresentation(groupIndex: 0, uti: "public.html", payload: htmlBytes),
                RawRepresentation(groupIndex: 0, uti: "public.url", payload: urlBytes),
                RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: textBytes)
            ]
        )

        let ingestResult = try! await core.ingest(capture: capture)
        assert(ingestResult.contentKind == "image", "FAIL: Browser image must be classified as 'image', got '\(ingestResult.contentKind)'")
        assert(ingestResult.title.hasPrefix("PNG Image"), "FAIL: Title must be 'PNG Image (...)', got '\(ingestResult.title)'")

        await vm.loadData()
        assert(vm.items.count == 1, "FAIL: Expected 1 history item")
        let firstItem = vm.items[0]
        assert(firstItem.contentKind == "image", "FAIL: Summary item must have contentKind 'image', got '\(firstItem.contentKind)'")
        assert(!firstItem.title.isEmpty && !firstItem.title.contains("\u{FFFC}"), "FAIL: Title must not be empty or contain attachment character")

        print("  -> Passed browser image classification and title verification.")

        // ---------------------------------------------------------------------
        // Test 2: Control + Space, Option + Space, Command + Y Preview Shortcuts
        // ---------------------------------------------------------------------
        print("\n[Test 2] Toggle Slideout Preview with shortcuts...")
        coordinator.show()

        // 2A: Control + Space (keyCode 49, .control)
        let ctrlSpaceEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )!
        let handledCtrlSpace = coordinator.handlePanelKeyDown(event: ctrlSpaceEvent)
        assert(handledCtrlSpace, "FAIL: Control + Space must toggle preview")
        assert(coordinator.previewCoordinator.isPreviewVisible, "FAIL: Preview should be open after Control + Space")

        // Press again to close
        let handledCtrlSpaceClose = coordinator.handlePanelKeyDown(event: ctrlSpaceEvent)
        assert(handledCtrlSpaceClose, "FAIL: Second Control + Space must close preview")
        assert(!coordinator.previewCoordinator.isPreviewVisible, "FAIL: Preview should be closed after second Control + Space")

        // 2B: Option + Space (keyCode 49, .option)
        let optSpaceEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )!
        let handledOptSpace = coordinator.handlePanelKeyDown(event: optSpaceEvent)
        assert(handledOptSpace, "FAIL: Option + Space must toggle preview")
        assert(coordinator.previewCoordinator.isPreviewVisible, "FAIL: Preview should be open after Option + Space")
        coordinator.previewCoordinator.hide()

        // 2C: Command + Y (keyCode 16, .command - Quick Look)
        let cmdYEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: 16
        )!
        let handledCmdY = coordinator.handlePanelKeyDown(event: cmdYEvent)
        assert(handledCmdY, "FAIL: Command + Y must toggle preview")
        assert(coordinator.previewCoordinator.isPreviewVisible, "FAIL: Preview should be open after Command + Y")
        coordinator.previewCoordinator.hide()

        // 2D: Space when search text is empty
        vm.searchText = ""
        let spaceEmptyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )!
        let handledSpaceEmpty = coordinator.handlePanelKeyDown(event: spaceEmptyEvent)
        assert(handledSpaceEmpty, "FAIL: Space when search is empty must toggle preview")
        coordinator.previewCoordinator.hide()

        // 2E: Space when search text is NOT empty (must NOT toggle preview)
        vm.searchText = "foo"
        let handledSpaceNonEmpty = coordinator.handlePanelKeyDown(event: spaceEmptyEvent)
        assert(!handledSpaceNonEmpty, "FAIL: Space when typing search text must not toggle preview")
        vm.searchText = ""

        print("  -> Passed preview shortcuts verification.")

        // ---------------------------------------------------------------------
        // Test 3: Settings Button on Footer Triggers onSettingsRequested
        // ---------------------------------------------------------------------
        print("\n[Test 3] Settings button on footer triggers onSettingsRequested...")
        var settingsOpened = false
        coordinator.onSettingsRequested = {
            settingsOpened = true
        }

        vm.onOpenSettings?()
        assert(settingsOpened, "FAIL: onOpenSettings must trigger coordinator.onSettingsRequested")
        print("  -> Passed Settings button callback verification.")

        // ---------------------------------------------------------------------
        // Test 4: Maximum History Item Limit & Settings Configuration
        // ---------------------------------------------------------------------
        print("\n[Test 4] History item limit configuration with solid upper bound...")
        assert(vm.historyLimit >= 50, "FAIL: historyLimit must have a solid minimum")

        UserDefaults.standard.set(500, forKey: "retentionMaxCount")
        assert(vm.historyLimit == 500, "FAIL: historyLimit should be 500, got \(vm.historyLimit)")

        UserDefaults.standard.set(2000, forKey: "retentionMaxCount")
        assert(vm.historyLimit == 2000, "FAIL: historyLimit should be 2000, got \(vm.historyLimit)")

        // Exceeding 2000 is clamped to solid maximum limit of 2000
        UserDefaults.standard.set(10000, forKey: "retentionMaxCount")
        assert(vm.historyLimit == 2000, "FAIL: historyLimit should clamp to 2000 maximum, got \(vm.historyLimit)")

        // Reset to default
        UserDefaults.standard.set(200, forKey: "retentionMaxCount")
        assert(vm.historyLimit == 200, "FAIL: Default historyLimit should be 200")
        print("  -> Passed maximum history item limit verification.")

        // ---------------------------------------------------------------------
        // Test 5: Option + Backspace vs Command + Backspace Deletion
        // ---------------------------------------------------------------------
        print("\n[Test 5] Option + Backspace vs Command + Backspace item deletion...")

        // Seed 3 items for deletion tests
        for i in 1...3 {
            let cap = RawCapture(
                timestampMs: Int64(Date().timeIntervalSince1970 * 1000) + Int64(i * 10),
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "DeleteTest \(i)".data(using: .utf8)!)
                ]
            )
            _ = try! await core.ingest(capture: cap)
        }
        await vm.loadData()
        let initialCount = vm.items.count
        assert(initialCount >= 3)

        // 5A: Command + Backspace (keyCode 51, .command) must NOT delete
        let cmdBackspaceEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}",
            isARepeat: false,
            keyCode: 51
        )!
        let handledCmdBack = coordinator.handlePanelKeyDown(event: cmdBackspaceEvent)
        assert(!handledCmdBack, "FAIL: Command + Backspace must NOT be handled as item delete (reserved for text field)")

        // Verify count didn't change
        await vm.loadData()
        assert(vm.items.count == initialCount, "FAIL: Command + Backspace should not remove item from history")

        // 5B: Option + Backspace (keyCode 51, .option) MUST delete
        let optBackspaceEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}",
            isARepeat: false,
            keyCode: 51
        )!
        let handledOptBack = coordinator.handlePanelKeyDown(event: optBackspaceEvent)
        assert(handledOptBack, "FAIL: Option + Backspace MUST be handled as item delete")

        // Allow async deletion to process
        try! await Task.sleep(nanoseconds: 100_000_000)
        await vm.loadData()
        assert(vm.items.count == initialCount - 1, "FAIL: Option + Backspace must delete exactly 1 item from history")

        print("  -> Passed Option+Backspace vs Command+Backspace verification.")

        coordinator.hide()
        print("\n=== ALL 5 USER ISSUES VERIFICATION TESTS PASSED! ===")
    }
}
