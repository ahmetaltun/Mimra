// ==============================================================================
// Mimra — Preview Coordinator
// Coordinates slideout preview panel lifecycle, screen bounds, and parent attachment.
// Linked Feature: F-039 (T-PREV-01)
// ==============================================================================

import AppKit
import SwiftUI

/// Manages the slideout preview panel, screen alignment, parent attachment,
/// and mouse transparency.
@MainActor
public final class PreviewCoordinator: NSObject {
    public private(set) var previewPanel: PreviewPanel?
    public private(set) var isPreviewVisible: Bool = false

    public var previewWidth: CGFloat = 360 {
        didSet {
            if oldValue != previewWidth && isPreviewVisible {
                updateLayout()
            }
        }
    }

    public var previewHeight: CGFloat = 460 {
        didSet {
            if oldValue != previewHeight && isPreviewVisible {
                updateLayout()
            }
        }
    }

    public var gap: CGFloat = 6.0
    public var preferredSide: PreviewSide = .right

    // Auto-open settings and debounce timer state (P6-02 / F-040, T-PREV-02)
    public var isAutoOpenEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "previewAutoOpenEnabled") as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "previewAutoOpenEnabled")
            if !newValue && !isPreviewVisible {
                cancelAutoOpenTimer()
            }
        }
    }

    public var autoOpenDelayMs: Int {
        get {
            (UserDefaults.standard.object(forKey: "previewDelayMs") as? Int) ?? 400
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "previewDelayMs")
        }
    }

    private var autoOpenTask: Task<Void, Never>?

    public private(set) var currentItem: HistoryItemSummaryDto?
    public private(set) weak var parentPanel: FloatingPanel?
    public let coreClient: CoreClient?

    public var onVisibilityChanged: ((Bool) -> Void)?

    public init(coreClient: CoreClient? = nil) {
        self.coreClient = coreClient
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Returns or instantiates the slideout preview panel.
    @discardableResult
    public func getOrCreatePreviewPanel() -> PreviewPanel {
        if let existing = previewPanel {
            return existing
        }

        let initialRect = NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight)
        let panel = PreviewPanel(contentRect: initialRect)

        let rootView = PreviewContainerView(item: currentItem, coreClient: coreClient, onClose: { [weak self] in
            self?.hide()
        })
        panel.contentView = NSHostingView(rootView: rootView)

        self.previewPanel = panel
        return panel
    }

    /// Cancels any active auto-open debounce timer.
    public func cancelAutoOpenTimer() {
        autoOpenTask?.cancel()
        autoOpenTask = nil
    }

    /// Handles selection changes from the list, updating the preview immediately if already open
    /// or initiating an auto-open timer if auto-open is enabled and the preview is closed (P6-02 / F-040).
    public func handleSelectionChanged(item: HistoryItemSummaryDto?, parent: FloatingPanel) {
        cancelAutoOpenTimer()
        self.currentItem = item

        if isPreviewVisible {
            updateHostingContent(item: item)
        } else if isAutoOpenEnabled && parent.isVisible {
            scheduleAutoOpen(for: item, parent: parent)
        }
    }

    private func scheduleAutoOpen(for item: HistoryItemSummaryDto?, parent: FloatingPanel) {
        let delayNs = UInt64(max(50, autoOpenDelayMs)) * 1_000_000
        autoOpenTask = Task { @MainActor [weak self, weak parent] in
            do {
                try await Task.sleep(nanoseconds: delayNs)
            } catch {
                return // Task was cancelled
            }
            guard let self = self, !Task.isCancelled, let parent = parent, parent.isVisible else {
                return
            }
            self.show(for: item, parent: parent)
        }
    }

    /// Shows or updates the preview panel for the specified history item.
    public func show(for item: HistoryItemSummaryDto?, parent: FloatingPanel) {
        cancelAutoOpenTimer()
        self.parentPanel = parent
        self.currentItem = item

        let panel = getOrCreatePreviewPanel()
        updateHostingContent(item: item)

        // Compute optimal clamped placement
        let screen = parent.screen
            ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let placement = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: parent.frame,
            previewSize: CGSize(width: previewWidth, height: previewHeight),
            screenVisibleFrame: visibleFrame,
            gap: gap,
            preferredSide: preferredSide
        )

        panel.setFrame(placement.frame, display: true)
        panel.setMouseInterceptionEnabled(true)

        // Attach as child window if not already attached
        if panel.parent == nil {
            parent.addChildWindow(panel, ordered: .above)
        }

        panel.orderFront(nil)
        isPreviewVisible = true
        onVisibilityChanged?(true)
    }

    /// Updates the preview content if the preview panel is currently visible.
    public func updateItemIfVisible(_ item: HistoryItemSummaryDto?) {
        self.currentItem = item
        guard isPreviewVisible else { return }
        updateHostingContent(item: item)
    }

    /// Hides the preview panel and guarantees zero mouse event interception (DoD).
    public func hide() {
        cancelAutoOpenTimer()
        guard isPreviewVisible || previewPanel?.isVisible == true else { return }

        isPreviewVisible = false
        if let panel = previewPanel {
            panel.setMouseInterceptionEnabled(false)
            if let parent = parentPanel {
                parent.removeChildWindow(panel)
            } else if let parent = panel.parent {
                parent.removeChildWindow(panel)
            }
            panel.orderOut(nil)
        }

        onVisibilityChanged?(false)
    }

    /// Toggles the preview panel on or off.
    public func toggle(for item: HistoryItemSummaryDto?, parent: FloatingPanel) {
        cancelAutoOpenTimer()
        if isPreviewVisible {
            hide()
        } else {
            show(for: item, parent: parent)
        }
    }

    /// Re-anchors and recalculates preview placement when parent moves or screen resizes.
    public func updateLayout() {
        guard isPreviewVisible, let parent = parentPanel, let panel = previewPanel else { return }

        let screen = parent.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let placement = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: parent.frame,
            previewSize: CGSize(width: previewWidth, height: previewHeight),
            screenVisibleFrame: visibleFrame,
            gap: gap,
            preferredSide: preferredSide
        )

        panel.setFrame(placement.frame, display: true)
    }

    private func updateHostingContent(item: HistoryItemSummaryDto?) {
        guard let panel = previewPanel,
              let hostingView = panel.contentView as? NSHostingView<PreviewContainerView> else {
            return
        }
        hostingView.rootView = PreviewContainerView(item: item, coreClient: coreClient, onClose: { [weak self] in
            self?.hide()
        })
    }

    @objc private func handleScreenParametersChanged(_ notification: Notification) {
        updateLayout()
    }
}
