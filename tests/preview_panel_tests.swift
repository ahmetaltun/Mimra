// ==============================================================================
// Mimra — Preview Panel Integration & Bounds Verification Tests
// Tests geometry calculation, flip behavior, mouse transparency, child attachment,
// and rapid toggling for Slideout Preview (P6-01 / F-039, T-PREV-01).
// ==============================================================================

import AppKit
import Foundation
import SwiftUI

@main
@MainActor
struct PreviewPanelTestsRunner {
    static func main() async {
        print("=== Running Slideout Preview Panel Tests (T-PREV-01 / P6-01) ===")

        testGeometryRightPlacement()
        testGeometryLeftFlipOnRightOverflow()
        testGeometryVerticalClamping()
        testGeometryNarrowScreenFallback()
        testPreviewPanelWindowAttributes()
        testMouseTransparencyAndChildAttachment()
        testContentUpdateOnSelectionChange()
        testRapidTogglesStability()
        testMainPanelHideDismissesPreview()
        testScreenParametersNotificationHandling()

        print("=== All Preview Panel Tests PASSED (10/10) ===")
    }

    // MARK: - Test 1: Geometry Right Placement

    static func testGeometryRightPlacement() {
        print("  [Test 1] Geometry right placement when space permits...")

        let parentFrame = CGRect(x: 500, y: 300, width: 440, height: 540)
        let previewSize = CGSize(width: 360, height: 460)
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let placement = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: parentFrame,
            previewSize: previewSize,
            screenVisibleFrame: screenFrame,
            gap: 6.0,
            preferredSide: .right
        )

        assert(placement.side == .right, "Expected .right placement, got \(placement.side)")
        let expectedX = parentFrame.maxX + 6.0
        assert(placement.frame.origin.x == expectedX, "Expected x=\(expectedX), got \(placement.frame.origin.x)")
        assert(placement.frame.width == 360, "Expected width=360, got \(placement.frame.width)")
        assert(placement.frame.height == 460, "Expected height=460, got \(placement.frame.height)")
        // Top alignment: maxY of preview matches maxY of parent
        assert(placement.frame.maxY == parentFrame.maxY, "Expected maxY=\(parentFrame.maxY), got \(placement.frame.maxY)")

        print("  -> Passed right placement check.")
    }

    // MARK: - Test 2: Geometry Left Flip on Right Overflow

    static func testGeometryLeftFlipOnRightOverflow() {
        print("  [Test 2] Geometry flips to left side when right edge exceeds display...")

        let parentFrame = CGRect(x: 1600, y: 300, width: 440, height: 540)
        let previewSize = CGSize(width: 360, height: 460)
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // 1600 + 440 + 6 + 360 = 2406 > 1920 -> must flip left
        let placement = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: parentFrame,
            previewSize: previewSize,
            screenVisibleFrame: screenFrame,
            gap: 6.0,
            preferredSide: .right
        )

        assert(placement.side == .left, "Expected .left placement due to overflow, got \(placement.side)")
        let expectedX = parentFrame.minX - 6.0 - 360.0
        assert(placement.frame.origin.x == expectedX, "Expected x=\(expectedX), got \(placement.frame.origin.x)")
        assert(placement.frame.maxX <= parentFrame.minX, "Preview must be to the left of parent")

        print("  -> Passed left flip check.")
    }

    // MARK: - Test 3: Geometry Vertical Clamping

    static func testGeometryVerticalClamping() {
        print("  [Test 3] Geometry vertical clamping within visible screen bounds...")

        let screenFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055) // Menu bar at top

        // Case A: Parent near top edge (preview must not exceed screen maxY)
        let topParent = CGRect(x: 500, y: 700, width: 440, height: 500)
        let placementTop = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: topParent,
            previewSize: CGSize(width: 360, height: 460),
            screenVisibleFrame: screenFrame,
            gap: 6.0
        )
        assert(placementTop.frame.maxY <= screenFrame.maxY, "Preview must not exceed screen top")

        // Case B: Parent near bottom edge (preview must not fall below screen minY)
        let bottomParent = CGRect(x: 500, y: 30, width: 440, height: 200)
        let placementBottom = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: bottomParent,
            previewSize: CGSize(width: 360, height: 460),
            screenVisibleFrame: screenFrame,
            gap: 6.0
        )
        assert(placementBottom.frame.minY >= screenFrame.minY, "Preview must not drop below screen bottom")

        print("  -> Passed vertical clamping check.")
    }

    // MARK: - Test 4: Narrow Screen Fallback

    static func testGeometryNarrowScreenFallback() {
        print("  [Test 4] Narrow screen fallback clamping...")

        let narrowScreen = CGRect(x: 0, y: 0, width: 600, height: 600)
        let largeParent = CGRect(x: 100, y: 50, width: 400, height: 500)
        let previewSize = CGSize(width: 360, height: 460)

        let placement = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: largeParent,
            previewSize: previewSize,
            screenVisibleFrame: narrowScreen,
            gap: 6.0
        )

        assert(placement.frame.minX >= narrowScreen.minX, "Preview must not start before screen left")
        assert(placement.frame.maxX <= narrowScreen.maxX, "Preview must not extend past screen right")

        print("  -> Passed narrow screen fallback check.")
    }

    // MARK: - Test 5: Window Attributes

    static func testPreviewPanelWindowAttributes() {
        print("  [Test 5] PreviewPanel non-activating and window attributes...")

        let panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460))

        assert(!panel.canBecomeKey, "PreviewPanel must NOT become key window")
        assert(!panel.canBecomeMain, "PreviewPanel must NOT become main window")
        assert(panel.level == .floating, "PreviewPanel must be at .floating level")
        assert(!panel.isReleasedWhenClosed, "Panel must not release on close")
        assert(panel.collectionBehavior.contains(.canJoinAllSpaces), "Panel must join all spaces")
        assert(panel.collectionBehavior.contains(.fullScreenAuxiliary), "Panel must be fullScreenAuxiliary")

        // Verify standard window buttons are hidden
        assert(panel.standardWindowButton(.closeButton)?.isHidden != false, "PreviewPanel close button must be hidden")
        assert(panel.standardWindowButton(.miniaturizeButton)?.isHidden != false, "PreviewPanel miniaturize button must be hidden")
        assert(panel.standardWindowButton(.zoomButton)?.isHidden != false, "PreviewPanel zoom button must be hidden")

        print("  -> Passed window attributes check.")
    }

    // MARK: - Test 6: Mouse Transparency and Child Attachment

    static func testMouseTransparencyAndChildAttachment() {
        print("  [Test 6] Mouse transparency on hide and child window attachment...")

        let parent = FloatingPanel(contentRect: NSRect(x: 400, y: 300, width: 440, height: 540))
        let coordinator = PreviewCoordinator()

        let dummyItem = HistoryItemSummaryDto(
            id: "test-item-1",
            contentKind: "text",
            title: "Preview Test Item",
            snippet: "Preview Snippet Content",
            isPinned: false,
            pinOrder: nil,
            pinKey: nil,
            sourceBundleId: "com.apple.Notes",
            firstCopiedAtMs: 1000,
            lastCopiedAtMs: 2000,
            copyCount: 1,
            byteSize: 128,
            availableUtis: ["public.utf8-plain-text"],
            titleHighlights: [],
            snippetHighlights: []
        )

        // Show preview
        coordinator.show(for: dummyItem, parent: parent)

        guard let previewPanel = coordinator.previewPanel else {
            fatalError("PreviewPanel was not instantiated")
        }

        assert(coordinator.isPreviewVisible, "Preview must be marked visible")
        assert(!previewPanel.ignoresMouseEvents, "Active preview must NOT ignore mouse events")
        assert(parent.childWindows?.contains(previewPanel) == true, "Preview must be attached as child window")

        // Hide preview
        coordinator.hide()

        assert(!coordinator.isPreviewVisible, "Preview must be marked hidden")
        assert(previewPanel.ignoresMouseEvents, "Hidden preview MUST ignore mouse events (mouse transparency)")
        assert(parent.childWindows?.contains(previewPanel) != true, "Preview must be detached from parent child windows")

        print("  -> Passed mouse transparency and child attachment check.")
    }

    // MARK: - Test 7: Content Update on Selection Change

    static func testContentUpdateOnSelectionChange() {
        print("  [Test 7] Content update when selection changes...")

        let parent = FloatingPanel(contentRect: NSRect(x: 400, y: 300, width: 440, height: 540))
        let coordinator = PreviewCoordinator()

        let item1 = HistoryItemSummaryDto(
            id: "item-1",
            contentKind: "text",
            title: "First Item",
            snippet: "First Snippet",
            isPinned: false,
            pinOrder: nil,
            pinKey: nil,
            sourceBundleId: nil,
            firstCopiedAtMs: 100,
            lastCopiedAtMs: 100,
            copyCount: 1,
            byteSize: 50,
            availableUtis: ["public.utf8-plain-text"],
            titleHighlights: [],
            snippetHighlights: []
        )

        let item2 = HistoryItemSummaryDto(
            id: "item-2",
            contentKind: "image",
            title: "Second Item Image",
            snippet: "1920x1080 PNG",
            isPinned: true,
            pinOrder: 1,
            pinKey: "1",
            sourceBundleId: "com.apple.Safari",
            firstCopiedAtMs: 200,
            lastCopiedAtMs: 200,
            copyCount: 2,
            byteSize: 10240,
            availableUtis: ["public.png"],
            titleHighlights: [],
            snippetHighlights: []
        )

        coordinator.show(for: item1, parent: parent)
        assert(coordinator.currentItem?.id == "item-1", "Expected item-1 active")

        coordinator.updateItemIfVisible(item2)
        assert(coordinator.currentItem?.id == "item-2", "Expected item-2 active after selection change")

        coordinator.hide()
        print("  -> Passed content update check.")
    }

    // MARK: - Test 8: Rapid Toggles Stability

    static func testRapidTogglesStability() {
        print("  [Test 8] Rapid toggles stability (50 cycles)...")

        let parent = FloatingPanel(contentRect: NSRect(x: 400, y: 300, width: 440, height: 540))
        let coordinator = PreviewCoordinator()

        let dummyItem = HistoryItemSummaryDto(
            id: "rapid-item",
            contentKind: "text",
            title: "Rapid Toggle Item",
            snippet: "Snippet",
            isPinned: false,
            pinOrder: nil,
            pinKey: nil,
            sourceBundleId: nil,
            firstCopiedAtMs: 10,
            lastCopiedAtMs: 20,
            copyCount: 1,
            byteSize: 10,
            availableUtis: ["public.utf8-plain-text"],
            titleHighlights: [],
            snippetHighlights: []
        )

        for _ in 0..<50 {
            coordinator.toggle(for: dummyItem, parent: parent)
        }

        // Even number of toggles leaves it hidden
        assert(!coordinator.isPreviewVisible, "Expected hidden after even toggles")
        if let panel = coordinator.previewPanel {
            assert(panel.ignoresMouseEvents, "Expected mouse events ignored when hidden")
            assert(parent.childWindows?.contains(panel) != true, "Expected detached from child windows")
        }

        print("  -> Passed 50 rapid toggles check.")
    }

    // MARK: - Test 9: Main Panel Hide Dismisses Preview

    static func testMainPanelHideDismissesPreview() {
        print("  [Test 9] Main panel coordinator hide dismisses preview...")

        let tempDb = "/tmp/mimra_prev_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDb)
        }

        do {
            let client = try CoreClient(databasePath: tempDb)
            let panelCoord = PanelCoordinator(coreClient: client)
            _ = panelCoord.getOrCreatePanel()

            // Toggle preview
            panelCoord.togglePreview()
            assert(panelCoord.previewCoordinator.isPreviewVisible, "Preview must be visible")

            // Hiding main panel must dismiss preview
            panelCoord.hide()
            assert(!panelCoord.previewCoordinator.isPreviewVisible, "Preview must be dismissed when main panel hides")
            assert(panelCoord.previewCoordinator.previewPanel?.ignoresMouseEvents == true, "Mouse events must be ignored")
        } catch {
            fatalError("Failed initializing CoreClient: \(error)")
        }

        print("  -> Passed main panel hide dismisses preview check.")
    }

    // MARK: - Test 10: Screen Parameters Notification

    static func testScreenParametersNotificationHandling() {
        print("  [Test 10] Screen parameters notification handling...")

        let parent = FloatingPanel(contentRect: NSRect(x: 400, y: 300, width: 440, height: 540))
        let coordinator = PreviewCoordinator()

        coordinator.show(for: nil, parent: parent)
        assert(coordinator.isPreviewVisible, "Preview must be visible")

        // Post display change notification
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        assert(coordinator.isPreviewVisible, "Preview remains visible after display parameter change")
        coordinator.hide()

        print("  -> Passed screen parameters notification check.")
    }
}
