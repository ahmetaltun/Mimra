// ==============================================================================
// Mimra — Native Text Preview View (AppKit NSTextView Wrapper)
// High-performance text rendering with non-contiguous layout and accessibility selection.
// Designed to scroll massive text buffers (<= 1 MB) without UI freeze.
// Linked Feature: F-041 (T-PREV-03)
// ==============================================================================

import AppKit
import SwiftUI

/// High-performance AppKit NSTextView wrapped for SwiftUI.
/// Configured with non-contiguous layout to lazily compute glyphs, ensuring smooth
/// 60/120 fps scrolling for large documents (<= 1 MB) without main thread blockages.
public struct NativeTextPreviewView: NSViewRepresentable {
    public let text: String
    public var isMonospaced: Bool
    public var fontSize: CGFloat

    public init(text: String, isMonospaced: Bool = false, fontSize: CGFloat = 12) {
        self.text = text
        self.isMonospaced = isMonospaced
        self.fontSize = fontSize
    }

    public func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()

        // Critical: Non-contiguous layout computes glyph positions on-demand
        // for the visible viewport only, avoiding multi-second hangs on 1 MB buffers.
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let font = isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
        textView.font = font

        textView.string = text
        scrollView.documentView = textView

        return scrollView
    }

    public func updateScrollView(_ scrollView: NSScrollView) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
            // Reset scroll position to top when switching items
            if let documentView = scrollView.documentView {
                documentView.scroll(.zero)
            }
        }

        let targetFont = isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)

        if textView.font != targetFont {
            textView.font = targetFont
        }
    }

    public func makeNSView(context: Context) -> NSScrollView {
        makeScrollView()
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        updateScrollView(scrollView)
    }
}
