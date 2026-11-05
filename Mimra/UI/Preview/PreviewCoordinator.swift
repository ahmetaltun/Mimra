// ==============================================================================
// Mimra — Preview Coordinator
// Coordinates slideout preview panel lifecycle, screen bounds, and parent attachment.
// Linked Feature: F-039, F-040 (T-PREV-01, T-PREV-02)
// ==============================================================================

import AppKit
import SwiftUI

/// Manages the slideout preview panel, screen alignment, parent attachment,
/// dynamic height sizing up to history window height, and mouse transparency.
@MainActor
public final class PreviewCoordinator: NSObject {
    public static let displayModeKey = "previewDisplayMode"
    public static let autoOpenEnabledKey = "previewAutoOpenEnabled"
    public static let delayMsKey = "previewDelayMs"

    public private(set) var previewPanel: PreviewPanel?
    public private(set) var isPreviewVisible: Bool = false

    public var previewWidth: CGFloat {
        get { AppearanceConfiguration.shared.previewWidth }
        set {
            AppearanceConfiguration.shared.previewWidth = newValue
            if isPreviewVisible { updateLayout() }
        }
    }

    public var previewHeight: CGFloat = AppearanceConfiguration.shared.panelHeight {
        didSet {
            if oldValue != previewHeight && isPreviewVisible {
                updateLayout()
            }
        }
    }

    public var gap: CGFloat = 6.0
    public var preferredSide: PreviewSide = .right

    /// Configurable preview display mode (manual/default, immediate, delayed).
    public var displayMode: PreviewDisplayMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.displayModeKey),
               let mode = PreviewDisplayMode(rawValue: raw) {
                return mode
            }
            if let legacyAutoOpen = UserDefaults.standard.object(forKey: Self.autoOpenEnabledKey) as? Bool, legacyAutoOpen {
                return .delayed
            }
            return .manual
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.displayModeKey)
            UserDefaults.standard.set(newValue != .manual, forKey: Self.autoOpenEnabledKey)
            if newValue == .manual && !isPreviewVisible {
                cancelAutoOpenTimer()
            }
        }
    }

    // Auto-open settings bridging for backwards compatibility (P6-02 / F-040, T-PREV-02)
    public var isAutoOpenEnabled: Bool {
        get {
            displayMode != .manual
        }
        set {
            displayMode = newValue ? .delayed : .manual
        }
    }

    public var autoOpenDelayMs: Int {
        get {
            (UserDefaults.standard.object(forKey: Self.delayMsKey) as? Int) ?? 400
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.delayMsKey)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChanged(_:)),
            name: AppearanceConfiguration.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Calculates the preview panel height to always match the history window height.
    public func calculateContentHeight(
        for item: HistoryItemSummaryDto?,
        fullText: String? = nil,
        maxHeight: CGFloat
    ) -> CGFloat {
        return maxHeight
    }

    /// Returns or instantiates the slideout preview panel.
    @discardableResult
    public func getOrCreatePreviewPanel() -> PreviewPanel {
        if let existing = previewPanel {
            return existing
        }

        let effectiveHeight = parentPanel?.frame.height ?? AppearanceConfiguration.shared.panelHeight
        self.previewHeight = effectiveHeight
        let initialRect = NSRect(x: 0, y: 0, width: previewWidth, height: effectiveHeight)
        let panel = PreviewPanel(contentRect: initialRect)

        let rootView = PreviewContainerView(
            item: currentItem,
            coreClient: coreClient,
            onClose: { [weak self] in
                self?.hide()
            },
            onFullTextLoaded: { [weak self] fullText in
                self?.handleFullTextLoaded(fullText)
            }
        )
        panel.contentView = NSHostingView(rootView: rootView)

        self.previewPanel = panel
        return panel
    }

    /// Cancels any active auto-open debounce timer.
    public func cancelAutoOpenTimer() {
        autoOpenTask?.cancel()
        autoOpenTask = nil
    }

    /// Invoked when the parent history window appears to apply the active display mode (Req 6).
    public func handleParentDidShow(item: HistoryItemSummaryDto?, parent: FloatingPanel) {
        cancelAutoOpenTimer()
        self.parentPanel = parent
        self.currentItem = item

        switch displayMode {
        case .manual:
            break
        case .immediate:
            show(for: item, parent: parent)
        case .delayed:
            scheduleAutoOpen(for: item, parent: parent)
        }
    }

    /// Handles selection changes from the list according to the active display mode (Req 6).
    public func handleSelectionChanged(item: HistoryItemSummaryDto?, parent: FloatingPanel) {
        cancelAutoOpenTimer()
        self.currentItem = item

        switch displayMode {
        case .manual:
            if isPreviewVisible {
                updateItemIfVisible(item)
            }
        case .immediate:
            if isPreviewVisible {
                updateItemIfVisible(item)
            } else if parent.isVisible {
                show(for: item, parent: parent)
            }
        case .delayed:
            if isPreviewVisible {
                updateItemIfVisible(item)
            } else if parent.isVisible {
                scheduleAutoOpen(for: item, parent: parent)
            }
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

        // Set preview height same as history window height
        self.previewHeight = parent.frame.height
        panel.maxSize = NSSize(width: 1200, height: parent.frame.height)

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
        guard isPreviewVisible, let parent = parentPanel else { return }

        self.previewHeight = parent.frame.height
        updateHostingContent(item: item)
        updateLayout()
    }

    private func handleFullTextLoaded(_ fullText: String) {
        guard isPreviewVisible, let parent = parentPanel else { return }
        self.previewHeight = parent.frame.height
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

        // Set preview height same as history window height
        self.previewHeight = parent.frame.height
        panel.maxSize = NSSize(width: 1200, height: parent.frame.height)

        let placement = PreviewBoundsCalculator.calculatePlacement(
            parentFrame: parent.frame,
            previewSize: CGSize(width: previewWidth, height: previewHeight),
            screenVisibleFrame: visibleFrame,
            gap: gap,
            preferredSide: preferredSide
        )

        panel.setFrame(placement.frame, display: true)
    }

    /// Scrolls the preview document content vertically by delta pixels.
    public func scrollPreview(by delta: CGFloat) {
        guard isPreviewVisible, let panel = previewPanel else { return }
        guard let hostingView = panel.contentView as? NSHostingView<PreviewContainerView> else { return }
        if let scrollView = findScrollView(in: hostingView) {
            let currentOrigin = scrollView.contentView.bounds.origin
            let maxScrollY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentSize.height)
            let newY = min(max(0, currentOrigin.y + delta), maxScrollY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: newY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView {
            return sv
        }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) {
                return found
            }
        }
        return nil
    }

    private func updateHostingContent(item: HistoryItemSummaryDto?) {
        guard let panel = previewPanel,
              let hostingView = panel.contentView as? NSHostingView<PreviewContainerView> else {
            return
        }
        hostingView.rootView = PreviewContainerView(
            item: item,
            coreClient: coreClient,
            onClose: { [weak self] in
                self?.hide()
            },
            onFullTextLoaded: { [weak self] fullText in
                self?.handleFullTextLoaded(fullText)
            }
        )
    }

    @objc private func handleScreenParametersChanged(_ notification: Notification) {
        updateLayout()
    }

    @objc private func handleAppearanceChanged(_ notification: Notification) {
        let effectiveHeight = parentPanel?.frame.height ?? AppearanceConfiguration.shared.panelHeight
        self.previewHeight = effectiveHeight
        if let panel = previewPanel {
            if isPreviewVisible {
                updateLayout()
            } else {
                panel.setContentSize(NSSize(width: AppearanceConfiguration.shared.previewWidth, height: effectiveHeight))
            }
        }
    }
}
