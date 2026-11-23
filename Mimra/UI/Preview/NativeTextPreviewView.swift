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
    public var attributedText: NSAttributedString?
    public var isMonospaced: Bool
    public var fontSize: CGFloat

    public init(
        text: String,
        attributedText: NSAttributedString? = nil,
        isMonospaced: Bool = false,
        fontSize: CGFloat = 12
    ) {
        self.text = text
        self.attributedText = attributedText
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

        let contentWidth = max(240.0, scrollView.contentSize.width)
        let contentSize = NSSize(width: contentWidth, height: max(100.0, scrollView.contentSize.height))

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()

        // Critical: Non-contiguous layout computes glyph positions on-demand
        // for the visible viewport only, avoiding multi-second hangs on 1 MB buffers.
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            containerSize: NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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

        if let attr = attributedText {
            textView.textStorage?.setAttributedString(attr)
        } else {
            textView.string = text
        }
        scrollView.documentView = textView
        textView.sizeToFit()

        return scrollView
    }

    public func updateScrollView(_ scrollView: NSScrollView) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let currentWidth = scrollView.contentSize.width
        if currentWidth > 0 && abs(textView.frame.size.width - currentWidth) > 1.0 {
            textView.frame.size.width = currentWidth
            textView.textContainer?.containerSize = NSSize(width: currentWidth, height: .greatestFiniteMagnitude)
            textView.sizeToFit()
        }

        if let attr = attributedText {
            let currentAttr = textView.attributedString()
            if !currentAttr.isEqual(to: attr) {
                let textChanged = textView.string != attr.string
                textView.textStorage?.setAttributedString(attr)
                textView.sizeToFit()
                if textChanged {
                    scrollView.contentView.scroll(to: .zero)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        } else {
            let targetFont = isMonospaced
                ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                : NSFont.systemFont(ofSize: fontSize)
            let plainAttributes: [NSAttributedString.Key: Any] = [
                .font: targetFont,
                .foregroundColor: NSColor.textColor
            ]

            let textChanged = textView.string != text
            if textChanged || hasNonPlainAttributes(textView, expectedFont: targetFont) {
                textView.textStorage?.setAttributedString(NSAttributedString(
                    string: text,
                    attributes: plainAttributes
                ))
                textView.font = targetFont
                textView.textColor = .textColor
                textView.typingAttributes = plainAttributes
                textView.sizeToFit()
                if textChanged {
                    scrollView.contentView.scroll(to: .zero)
                }
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else if textView.font != targetFont || textView.typingAttributes[.backgroundColor] != nil {
                textView.font = targetFont
                textView.textColor = .textColor
                textView.typingAttributes = plainAttributes
                textView.sizeToFit()
            }
        }
    }

    private func hasNonPlainAttributes(_ textView: NSTextView, expectedFont: NSFont) -> Bool {
        guard let storage = textView.textStorage, storage.length > 0 else { return false }
        var effectiveRange = NSRange(location: 0, length: 0)
        let attrs = storage.attributes(at: 0, effectiveRange: &effectiveRange)
        if effectiveRange.length < storage.length {
            return true
        }
        for (key, value) in attrs {
            switch key {
            case .font:
                if (value as? NSFont) != expectedFont {
                    return true
                }
            case .foregroundColor:
                if (value as? NSColor) != NSColor.textColor {
                    return true
                }
            case .paragraphStyle:
                if let style = value as? NSParagraphStyle, style != NSParagraphStyle.default {
                    return true
                }
            default:
                return true
            }
        }
        return false
    }

    public func makeNSView(context: Context) -> NSScrollView {
        makeScrollView()
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        updateScrollView(scrollView)
    }
}
