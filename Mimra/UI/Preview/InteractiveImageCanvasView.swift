// ==============================================================================
// Mimra — Interactive Image Canvas View (AppKit NSScrollView Wrapper)
// Supports two-finger trackpad pinch-to-zoom (even in non-key NSPanel),
// click-and-drag panning, double-click fit/1:1 toggle, Option+Scroll zoom,
// and automatic fit-to-window on initial load and panel resize.
// ==============================================================================

import AppKit
import SwiftUI

/// Controller allowing SwiftUI toolbar buttons and keyboard shortcuts to drive zoom.
@MainActor
public final class ImageZoomController: ObservableObject {
    @Published public var zoomScale: CGFloat = 1.0
    @Published public var fitScale: CGFloat = 1.0
    @Published public var isFitMode: Bool = true

    weak var scrollView: NSScrollView?
    var imageSize: NSSize = .zero

    public init() {}

    public var zoomPercentage: Int {
        Int(round(zoomScale * 100))
    }

    public func zoomIn() {
        guard let sv = scrollView else { return }
        let next = min(sv.maxMagnification, sv.magnification * 1.25)
        applyMagnification(next, fit: false)
    }

    public func zoomOut() {
        guard let sv = scrollView else { return }
        let next = max(sv.minMagnification, sv.magnification / 1.25)
        applyMagnification(next, fit: false)
    }

    public func resetToFit() {
        guard let sv = scrollView, sv.bounds.width > 20, sv.bounds.height > 20 else { return }
        let fit = computeFitMagnification()
        fitScale = fit
        sv.minMagnification = min(0.05, fit * 0.5)
        applyMagnification(fit, fit: true)
    }

    public func zoomToActualSize() {
        applyMagnification(1.0, fit: false)
    }

    public func toggleFitOrActualSize(at pointInDoc: NSPoint? = nil) {
        let fit = computeFitMagnification()
        if abs(zoomScale - fit) < 0.03 {
            let target: CGFloat = fit < 0.95 ? 1.0 : 2.0
            if let sv = scrollView, let pt = pointInDoc {
                isFitMode = false
                sv.animator().setMagnification(target, centeredAt: pt)
                zoomScale = target
            } else {
                applyMagnification(target, fit: false)
            }
        } else {
            resetToFit()
        }
    }

    func computeFitMagnification() -> CGFloat {
        guard let sv = scrollView,
              imageSize.width > 0, imageSize.height > 0,
              sv.bounds.width > 20, sv.bounds.height > 20 else {
            return 1.0
        }
        let padding: CGFloat = 24
        let availW = max(40, sv.bounds.width - padding)
        let availH = max(40, sv.bounds.height - padding)
        let scale = min(availW / imageSize.width, availH / imageSize.height)
        return min(1.0, max(0.02, scale))
    }

    private func applyMagnification(_ mag: CGFloat, fit: Bool) {
        guard let sv = scrollView else { return }
        isFitMode = fit
        let center = NSPoint(x: imageSize.width / 2.0, y: imageSize.height / 2.0)
        sv.setMagnification(mag, centeredAt: center)
        zoomScale = sv.magnification
    }
}

/// NSScrollView subclass that automatically keeps the image fitted when `isFitMode` is true
/// as SwiftUI completes layout or the user resizes the preview panel.
private final class ZoomableImageScrollView: NSScrollView {
    weak var controller: ImageZoomController?
    private var lastLayoutSize: NSSize = .zero

    override func layout() {
        super.layout()
        let currentSize = bounds.size
        if currentSize.width > 20 && currentSize.height > 20 &&
           (abs(currentSize.width - lastLayoutSize.width) > 1.0 ||
            abs(currentSize.height - lastLayoutSize.height) > 1.0) {
            lastLayoutSize = currentSize
            if let controller = controller, controller.isFitMode {
                controller.resetToFit()
            }
        }
    }
}

/// NSClipView subclass that keeps the document centered when smaller than the viewport.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let docView = documentView else { return rect }
        let docFrame = docView.frame

        if proposedBounds.size.width > docFrame.size.width {
            rect.origin.x = (docFrame.size.width - proposedBounds.size.width) / 2.0
        }
        if proposedBounds.size.height > docFrame.size.height {
            rect.origin.y = (docFrame.size.height - proposedBounds.size.height) / 2.0
        }
        return rect
    }
}

/// Custom document view supporting click-drag panning, double-click zoom, and Option+Scroll zoom.
private final class PannableImageDocumentView: NSImageView {
    weak var controller: ImageZoomController?
    private var isDragging = false
    private var dragStartScreenPoint: NSPoint = .zero
    private var dragStartClipOrigin: NSPoint = .zero

    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        discardCursorRects()
        if let sv = enclosingScrollView,
           let doc = sv.documentView,
           (doc.frame.width * sv.magnification > sv.contentSize.width + 2 ||
            doc.frame.height * sv.magnification > sv.contentSize.height + 2) {
            addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let pt = convert(event.locationInWindow, from: nil)
            controller?.toggleFitOrActualSize(at: pt)
            return
        }
        guard let sv = enclosingScrollView else {
            super.mouseDown(with: event)
            return
        }
        isDragging = true
        dragStartScreenPoint = NSEvent.mouseLocation
        dragStartClipOrigin = sv.contentView.bounds.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let sv = enclosingScrollView else {
            super.mouseDragged(with: event)
            return
        }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartScreenPoint.x
        let dy = current.y - dragStartScreenPoint.y
        let mag = max(0.05, sv.magnification)

        let newOrigin = NSPoint(
            x: dragStartClipOrigin.x - dx / mag,
            y: dragStartClipOrigin.y + (isFlipped ? -dy : dy) / mag
        )
        let constrained = sv.contentView.constrainBoundsRect(
            NSRect(origin: newOrigin, size: sv.contentView.bounds.size)
        )
        sv.contentView.scroll(to: constrained.origin)
        sv.reflectScrolledClipView(sv.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            NSCursor.pop()
            window?.invalidateCursorRects(for: self)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            guard let sv = enclosingScrollView else { return }
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return }
            let factor = 1.0 + (delta * 0.015)
            let clampedFactor = max(0.85, min(1.15, factor))
            let nextMag = max(sv.minMagnification, min(sv.maxMagnification, sv.magnification * clampedFactor))
            let pt = convert(event.locationInWindow, from: nil)
            controller?.isFitMode = false
            sv.setMagnification(nextMag, centeredAt: pt)
            controller?.zoomScale = sv.magnification
            return
        }
        super.scrollWheel(with: event)
    }
}

/// SwiftUI wrapper around AppKit's magnifying/pannable NSScrollView.
public struct InteractiveImageCanvasView: NSViewRepresentable {
    public let image: NSImage
    @ObservedObject public var controller: ImageZoomController

    public init(image: NSImage, controller: ImageZoomController) {
        self.image = image
        self.controller = controller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ZoomableImageScrollView()
        scrollView.controller = controller
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 8.0

        let imageView = PannableImageDocumentView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        imageView.layer?.shadowColor = NSColor.black.cgColor
        imageView.layer?.shadowOpacity = 0.18
        imageView.layer?.shadowRadius = 6
        imageView.layer?.shadowOffset = CGSize(width: 0, height: -3)
        imageView.layer?.shadowPath = CGPath(rect: imageView.bounds, transform: nil)
        imageView.controller = controller

        scrollView.documentView = imageView
        controller.scrollView = scrollView
        controller.imageSize = image.size
        controller.isFitMode = true

        context.coordinator.observe(scrollView: scrollView)

        DispatchQueue.main.async {
            controller.resetToFit()
        }

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? PannableImageDocumentView else { return }
        if imageView.image !== image {
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
            imageView.layer?.shadowPath = CGPath(rect: imageView.bounds, transform: nil)
            controller.imageSize = image.size
            controller.isFitMode = true
            DispatchQueue.main.async {
                controller.resetToFit()
            }
        }
    }

    private final class ObserverBox: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        var eventMonitor: Any? = nil
        deinit {
            for obs in tokens {
                NotificationCenter.default.removeObserver(obs)
            }
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    @MainActor
    public final class Coordinator: NSObject {
        let controller: ImageZoomController
        private let observerBox = ObserverBox()

        init(controller: ImageZoomController) {
            self.controller = controller
        }

        func observe(scrollView: NSScrollView) {
            let magObs = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self = self, let sv = scrollView else { return }
                    self.controller.zoomScale = sv.magnification
                    let fit = self.controller.computeFitMagnification()
                    self.controller.isFitMode = abs(sv.magnification - fit) < 0.03
                }
            }
            let boundsObs = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self = self, let sv = scrollView else { return }
                    if abs(self.controller.zoomScale - sv.magnification) > 0.005 {
                        self.controller.zoomScale = sv.magnification
                    }
                }
            }
            observerBox.tokens = [magObs, boundsObs]

            // Local .magnify monitor guarantees two-finger trackpad pinch works inside
            // non-key NSPanel + SwiftUI NSHostingView, centered at the pointer.
            observerBox.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self, weak scrollView] event in
                guard let self = self,
                      let sv = scrollView,
                      let win = sv.window,
                      win.isVisible,
                      event.window === win,
                      let docView = sv.documentView else {
                    return event
                }
                let ptInScroll = sv.convert(event.locationInWindow, from: nil)
                guard sv.bounds.contains(ptInScroll) else {
                    return event
                }

                let nextMag = max(
                    sv.minMagnification,
                    min(sv.maxMagnification, sv.magnification * (1.0 + event.magnification))
                )
                let ptInDoc = docView.convert(event.locationInWindow, from: nil)
                self.controller.isFitMode = false
                sv.setMagnification(nextMag, centeredAt: ptInDoc)
                self.controller.zoomScale = sv.magnification
                return nil
            }
        }
    }
}
