// ==============================================================================
// Mimra — Preview Bounds Calculator
// Pure, deterministic geometry calculation for slideout preview positioning.
// Linked Feature: F-039 (T-PREV-01)
// ==============================================================================

import Foundation
import CoreGraphics

/// Preferred attachment side for the preview panel relative to the parent history panel.
public enum PreviewSide: String, Equatable, Sendable {
    case right
    case left
}

/// Calculated placement for the preview panel.
public struct PreviewPlacement: Equatable, Sendable {
    public let frame: CGRect
    public let side: PreviewSide

    public init(frame: CGRect, side: PreviewSide) {
        self.frame = frame
        self.side = side
    }
}

/// Pure geometric calculator for determining slideout preview coordinates and screen clamping.
public enum PreviewBoundsCalculator {

    /// Calculates the optimal frame and placement side for the preview panel.
    ///
    /// - Parameters:
    ///   - parentFrame: The global screen frame of the parent `FloatingPanel`.
    ///   - previewSize: The desired width and height of the preview panel.
    ///   - screenVisibleFrame: The visible frame of the active display (excluding dock & menubar).
    ///   - gap: The horizontal spacing between the parent and preview window (default 6.0).
    ///   - preferredSide: Preferred side to attach to (default `.right`).
    /// - Returns: A `PreviewPlacement` containing the clamped `CGRect` and the resolved `PreviewSide`.
    public static func calculatePlacement(
        parentFrame: CGRect,
        previewSize: CGSize,
        screenVisibleFrame: CGRect,
        gap: CGFloat = 6.0,
        preferredSide: PreviewSide = .right
    ) -> PreviewPlacement {
        // 1. Constrain size to visible screen dimensions to prevent off-screen overflow on tiny displays
        let effectiveWidth = min(previewSize.width, max(100.0, screenVisibleFrame.width))
        let effectiveHeight = min(previewSize.height, max(100.0, screenVisibleFrame.height))

        let rightX = parentFrame.maxX + gap
        let leftX = parentFrame.minX - gap - effectiveWidth

        var chosenX: CGFloat
        var chosenSide: PreviewSide

        if preferredSide == .right {
            // Check if right side fits within screenVisibleFrame
            if rightX + effectiveWidth <= screenVisibleFrame.maxX {
                chosenX = rightX
                chosenSide = .right
            } else if leftX >= screenVisibleFrame.minX {
                // Flip to left side
                chosenX = leftX
                chosenSide = .left
            } else {
                // Neither side fits completely: choose the side with more available room
                let spaceRight = screenVisibleFrame.maxX - parentFrame.maxX
                let spaceLeft = parentFrame.minX - screenVisibleFrame.minX
                if spaceRight >= spaceLeft {
                    chosenX = min(rightX, screenVisibleFrame.maxX - effectiveWidth)
                    chosenSide = .right
                } else {
                    chosenX = max(leftX, screenVisibleFrame.minX)
                    chosenSide = .left
                }
            }
        } else {
            // Preferred side is left
            if leftX >= screenVisibleFrame.minX {
                chosenX = leftX
                chosenSide = .left
            } else if rightX + effectiveWidth <= screenVisibleFrame.maxX {
                // Flip to right side
                chosenX = rightX
                chosenSide = .right
            } else {
                let spaceRight = screenVisibleFrame.maxX - parentFrame.maxX
                let spaceLeft = parentFrame.minX - screenVisibleFrame.minX
                if spaceLeft >= spaceRight {
                    chosenX = max(leftX, screenVisibleFrame.minX)
                    chosenSide = .left
                } else {
                    chosenX = min(rightX, screenVisibleFrame.maxX - effectiveWidth)
                    chosenSide = .right
                }
            }
        }

        // 2. Vertical alignment: Align top edges (in AppKit, maxY is top edge)
        var targetY = parentFrame.maxY - effectiveHeight

        // Clamp vertically within screen visible bounds
        if targetY < screenVisibleFrame.minY {
            targetY = screenVisibleFrame.minY
        }
        if targetY + effectiveHeight > screenVisibleFrame.maxY {
            targetY = screenVisibleFrame.maxY - effectiveHeight
        }

        // Final sanity clamping on horizontal axis
        if chosenX < screenVisibleFrame.minX {
            chosenX = screenVisibleFrame.minX
        }
        if chosenX + effectiveWidth > screenVisibleFrame.maxX {
            chosenX = screenVisibleFrame.maxX - effectiveWidth
        }

        let finalFrame = CGRect(
            x: round(chosenX),
            y: round(targetY),
            width: round(effectiveWidth),
            height: round(effectiveHeight)
        )

        return PreviewPlacement(frame: finalFrame, side: chosenSide)
    }
}
