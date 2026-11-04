// ==============================================================================
// Mimra — Floating Panel View
// SwiftUI content for the floating search panel, item list, empty states, and footer.
// Linked Features: F-018, F-019
// Test IDs: T-UI-02, T-UI-03
// ==============================================================================

import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct FloatingPanelView: View {
    @ObservedObject public var viewModel: PanelViewModel
    @ObservedObject public var accessibilityService: AccessibilityService
    @FocusState private var isSearchFocused: Bool

    @AppStorage("showSearchField") private var showSearchField: Bool = true
    @AppStorage("showTitle") private var showTitle: Bool = false
    @AppStorage("showFooter") private var showFooter: Bool = true

    public init(viewModel: PanelViewModel, accessibilityService: AccessibilityService? = nil) {
        self.viewModel = viewModel
        self.accessibilityService = accessibilityService ?? AccessibilityService.shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 0. Optional Header Title Bar (F-028, T-UI-05)
            if showTitle {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 11))
                    Text("Mimra Clipboard")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                    .opacity(0.4)
            }

            // 1. Search Header Bar (F-028, T-UI-05)
            if showSearchField {
                PanelSearchBar(
                    text: $viewModel.searchText,
                    isFocused: $isSearchFocused,
                    onClear: {
                        viewModel.searchText = ""
                    }
                )

                Divider()
                    .opacity(0.4)
            }


            // Regex Syntax Error Warning Banner (P4-03)
            if let regexErr = viewModel.regexErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                    Text("Invalid Regex: \(regexErr)")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.08))
                Divider()
                    .opacity(0.4)
            }

            // 2. Main Content Area (Items list or empty state)
            Group {
                if viewModel.isLoading && viewModel.items.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("Loading clipboard history...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.items.isEmpty {
                    PanelEmptyStateView(
                        iconName: "doc.on.clipboard",
                        title: "Clipboard is Empty",
                        subtitle: "Items copied to the clipboard will appear here automatically."
                    )
                } else if viewModel.filteredItems.isEmpty {
                    PanelEmptyStateView(
                        iconName: "magnifyingglass",
                        title: "No Matches Found",
                        subtitle: "No clipboard items match '\(viewModel.searchText)'."
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
                                    // Section Header for top section when mixed pinned & unpinned items exist (P5-07 / F-036, T-UI-10)
                                    if index == 0 && viewModel.hasMixedPinnedAndUnpinned {
                                        if viewModel.pinArrangement == .top && item.isPinned {
                                            HStack {
                                                Text("PINNED")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundColor(.secondary.opacity(0.65))
                                                    .padding(.leading, 8)
                                                Spacer()
                                            }
                                            .padding(.top, 2)
                                            .padding(.bottom, 2)
                                        } else if viewModel.pinArrangement == .bottom && !item.isPinned {
                                            HStack {
                                                Text("HISTORY")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundColor(.secondary.opacity(0.65))
                                                    .padding(.leading, 8)
                                                Spacer()
                                            }
                                            .padding(.top, 2)
                                            .padding(.bottom, 2)
                                        }
                                    }

                                    PanelItemRow(
                                        item: item,
                                        shortcutIndex: index < 9 ? (index + 1) : nil,
                                        isSelected: index == viewModel.selectedIndex,
                                        coreClient: viewModel.coreClient,
                                        onTogglePin: {
                                            Task {
                                                _ = await viewModel.togglePin(for: item)
                                            }
                                        },
                                        onSetPinKey: { newKey in
                                            Task {
                                                _ = await viewModel.setPinKey(for: item, key: newKey)
                                            }
                                        },
                                        onMovePinUp: {
                                            Task {
                                                _ = await viewModel.movePinUp(item: item)
                                            }
                                        },
                                        onMovePinDown: {
                                            Task {
                                                _ = await viewModel.movePinDown(item: item)
                                            }
                                        },
                                        onEditPin: {
                                            Task {
                                                await viewModel.startEditing(item: item)
                                            }
                                        },
                                        onCommit: { mode, forcePaste in
                                            viewModel.selectIndex(index, fromHover: false)
                                            viewModel.commitSelection(mode: mode, forcePaste: forcePaste)
                                        },
                                        onDelete: {
                                            Task {
                                                _ = await viewModel.deleteItem(itemId: item.id)
                                            }
                                        }
                                    )
                                    .id(item.id)
                                    .modifier(PinDragAndDropModifier(item: item, viewModel: viewModel))
                                    .onHover { isHovered in
                                        if isHovered {
                                            viewModel.selectIndex(index, fromHover: true)
                                        }
                                    }
                                    .onTapGesture {
                                        viewModel.selectIndex(index, fromHover: false)
                                        viewModel.commitSelection()
                                    }

                                    // Stable section divider separating pinned items from history (P5-01 / F-036)
                                    if viewModel.pinArrangement == .top && item.isPinned && (index + 1 < viewModel.filteredItems.count) && !viewModel.filteredItems[index + 1].isPinned {
                                        HStack {
                                            Text("HISTORY")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.secondary.opacity(0.65))
                                                .padding(.leading, 8)
                                            Spacer()
                                        }
                                        .padding(.top, 4)
                                        .padding(.bottom, 2)
                                        Divider()
                                            .opacity(0.25)
                                            .padding(.horizontal, 6)
                                            .padding(.bottom, 2)
                                    } else if viewModel.pinArrangement == .bottom && !item.isPinned && (index + 1 < viewModel.filteredItems.count) && viewModel.filteredItems[index + 1].isPinned {
                                        HStack {
                                            Text("PINNED")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.secondary.opacity(0.65))
                                                .padding(.leading, 8)
                                            Spacer()
                                        }
                                        .padding(.top, 4)
                                        .padding(.bottom, 2)
                                        Divider()
                                            .opacity(0.25)
                                            .padding(.horizontal, 6)
                                            .padding(.bottom, 2)
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                        .onChange(of: viewModel.selectedIndex) { _, newIndex in
                            if newIndex >= 0 && newIndex < viewModel.filteredItems.count {
                                let targetId = viewModel.filteredItems[newIndex].id
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    proxy.scrollTo(targetId, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 3. Compact Footer Action Bar (F-028, T-UI-05)
            if showFooter {
                Divider()
                    .opacity(0.4)

                PanelFooterBar(
                    itemCount: viewModel.filteredItems.count,
                    totalCount: viewModel.items.count,
                    onSettings: {
                        viewModel.onOpenSettings?()
                    },
                    onDismiss: {
                        viewModel.onDismiss?()
                    }
                )
            }
        }
        .frame(minWidth: 340, idealWidth: 440, maxWidth: 800, minHeight: 320, idealHeight: 756, maxHeight: 1000)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .ignoresSafeArea()
        .overlay(
            PinEditorOverlay(viewModel: viewModel)
        )
        .task {
            // Apply persisted search, sorting & pin arrangement preferences (P7-03 / F-049)
            viewModel.reloadSearchSettings()

            await viewModel.loadData()
            isSearchFocused = true
            accessibilityService.startObserving()
        }
        .onDisappear {
            accessibilityService.stopObserving()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mimraClipboardDidIngest)) { _ in
            Task { await viewModel.loadData() }
        }
    }
}

// MARK: - Search Bar Component

struct PanelSearchBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            TextField("Search clipboard history...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(isFocused)
                .accessibilityLabel("Search clipboard history")

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search text")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - In-Preview Pin Text Editor Overlay (P5-04 / F-045, T-PIN-02)

struct PinEditorOverlay: View {
    @ObservedObject var viewModel: PanelViewModel
    @FocusState private var isTextEditorFocused: Bool

    var body: some View {
        if let item = viewModel.editingPinItem {
            ZStack {
                Color.black.opacity(0.35)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        viewModel.cancelEditing()
                    }

                VStack(alignment: .leading, spacing: 10) {
                    // Header
                    HStack {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                        Text("Edit Pinned Item")
                            .font(.system(size: 13, weight: .semibold))
                        if let pinKey = item.pinKey, !pinKey.isEmpty {
                            Text("⌥\(pinKey.uppercased())")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(3)
                        }
                        Spacer()
                        Button {
                            viewModel.cancelEditing()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel editing")
                        .help("Cancel editing (Esc)")
                    }

                    // Text Editor
                    TextEditor(text: $viewModel.editingPinText)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($isTextEditorFocused)
                        .accessibilityLabel("Pinned item text editor")
                        .padding(6)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                        )
                        .frame(minHeight: 120, maxHeight: 220)

                    // Footer actions
                    HStack {
                        Text("\(viewModel.editingPinText.count) characters")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .accessibilityLabel("\(viewModel.editingPinText.count) characters in editor")

                        Spacer()

                        Button("Cancel") {
                            viewModel.cancelEditing()
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Cancel editing")

                        Button("Save Changes") {
                            Task {
                                _ = await viewModel.commitEditing()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Save pinned item changes")
                        .disabled(viewModel.editingPinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(14)
                .background(.ultraThinMaterial)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 5)
                .padding(16)
                .task {
                    isTextEditorFocused = true
                }
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Pin Drag and Drop Reordering Modifier (P5-03 / F-046)

struct PinDragAndDropModifier: ViewModifier {
    let item: HistoryItemSummaryDto
    @ObservedObject var viewModel: PanelViewModel

    func body(content: Content) -> some View {
        if item.isPinned {
            content
                .onDrag {
                    NSItemProvider(object: item.id as NSString)
                }
                .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                        if let sourceId = string as? String {
                            Task { @MainActor in
                                _ = await viewModel.movePin(sourceId: sourceId, targetId: item.id)
                            }
                        }
                    }
                    return true
                }
        } else {
            content
        }
    }
}

// MARK: - History Item Row Component

struct PanelItemRow: View {
    let item: HistoryItemSummaryDto
    let shortcutIndex: Int?
    let isSelected: Bool
    var coreClient: CoreClient? = nil
    var onTogglePin: (() -> Void)? = nil
    var onSetPinKey: ((String?) -> Void)? = nil
    var onMovePinUp: (() -> Void)? = nil
    var onMovePinDown: (() -> Void)? = nil
    var onEditPin: (() -> Void)? = nil
    var onCommit: ((PasteMode, Bool?) -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @AppStorage("showColorSwatches") private var showColorSwatches: Bool = true
    @AppStorage("showUrlPreviews") private var showUrlPreviews: Bool = true
    @AppStorage("showSourceAppIcon") private var showSourceAppIcon: Bool = true
    @AppStorage("searchHighlightStyle") private var searchHighlightStyleRaw: String = SearchHighlightStyle.bold.rawValue
    @AppStorage("historyRowStyle") private var rowStyleRaw: String = "standard"
    @State private var isHovered: Bool = false

    private var isCompact: Bool {
        rowStyleRaw == "compact"
    }

    private var highlightStyle: SearchHighlightStyle {
        SearchHighlightStyle(rawValue: searchHighlightStyleRaw) ?? .bold
    }

    private var detectedColor: HexColorInfo? {
        showColorSwatches ? ColorDetector.detect(in: item.title) : nil
    }

    private var detectedUrl: UrlInfo? {
        showUrlPreviews ? UrlDetector.detect(in: item.title) : nil
    }

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var backgroundView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)

            if isSelected && (colorSchemeContrast == .increased || differentiateWithoutColor) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary, lineWidth: 2)
            }
        }
    }

    var body: some View {
        rowContent
            .padding(.horizontal, 10)
            .padding(.vertical, isCompact ? 4 : 7)
            .background(backgroundView)
            .contentShape(Rectangle())
            .help(item.title)
            .onHover { hovering in
                self.isHovered = hovering
            }
            .contextMenu {
                contextMenuItems
            }
            .modifier(RowAccessibilityModifier(
                item: item,
                isSelected: isSelected,
                description: accessibilityDescription,
                statusValue: accessibilityStatusValue,
                rowHint: accessibilityRowHint,
                onCommit: onCommit,
                onTogglePin: onTogglePin,
                onEditPin: onEditPin,
                onMovePinUp: onMovePinUp,
                onMovePinDown: onMovePinDown,
                onDelete: onDelete
            ))
    }

    @ViewBuilder
    private var rowContent: some View {
        if isCompact {
            compactRowContent
        } else {
            standardRowContent
        }
    }

    @ViewBuilder
    private var compactRowContent: some View {
        HStack(alignment: .center, spacing: 8) {
            ItemThumbnailView(
                itemId: item.id,
                contentKind: item.contentKind,
                title: item.title,
                availableUtis: item.availableUtis,
                isSelected: isSelected,
                coreClient: coreClient,
                size: 16
            )

            HighlightedLabel(
                text: displayTitle,
                ranges: item.titleHighlights,
                isSelected: isSelected,
                baseFont: .system(size: 12, weight: .medium),
                defaultColor: .primary,
                highlightStyle: highlightStyle
            )
            .lineLimit(1)
            .truncationMode(.tail)

            if let color = detectedColor {
                ColorSwatchView(colorInfo: color, size: 10, cornerRadius: 2)
            }

            if let urlInfo = detectedUrl {
                UrlBadgeView(urlInfo: urlInfo, isSelected: isSelected)
            }

            if item.isPinned {
                Button {
                    onTogglePin?()
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .help("Unpin item (⌥P)")
            } else if isHovered {
                Button {
                    onTogglePin?()
                } label: {
                    Image(systemName: "pin")
                        .font(.system(size: 8))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
                .buttonStyle(.plain)
                .help("Pin item (⌥P)")
            }

            if item.contentKind == "file_urls" && isFileVanished(path: item.snippet) {
                Text("missing")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(Color.red.opacity(0.18))
                    .foregroundColor(isSelected ? .white : .red)
                    .cornerRadius(2)
            }

            if item.copyCount > 1 {
                Text("\(item.copyCount)x")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                    .foregroundColor(isSelected ? .white : .secondary)
                    .cornerRadius(2)
            }

            Spacer(minLength: 4)

            // Click-safe external browser launcher (explicit button on hover only)
            if let urlInfo = detectedUrl, isHovered, let url = urlInfo.url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
                }
                .buttonStyle(.plain)
                .help("Open in Browser")
            }

            // Source application icon
            if showSourceAppIcon, let bundleId = item.sourceBundleId, !bundleId.isEmpty {
                SourceAppIconView(bundleId: bundleId, size: 13)
                    .help(bundleId)
            }

            // Pinned and quick-pick shortcut badges
            HStack(spacing: 3) {
                if let pinKey = item.pinKey, !pinKey.isEmpty {
                    Text("⌥\(pinKey.uppercased())")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(isSelected ? .white.opacity(0.9) : .orange)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(isSelected ? Color.white.opacity(0.18) : Color.orange.opacity(0.12))
                        .cornerRadius(3)
                }
                if let key = shortcutIndex {
                    Text("⌘\(key)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(isSelected ? Color.white.opacity(0.15) : Color.primary.opacity(0.06))
                        .cornerRadius(3)
                }
            }
        }
    }

    @ViewBuilder
    private var standardRowContent: some View {
        HStack(alignment: .center, spacing: 10) {
            // Type icon, cached image thumbnail, or color swatch (P3-02, P3-04)
            ItemThumbnailView(
                itemId: item.id,
                contentKind: item.contentKind,
                title: item.title,
                availableUtis: item.availableUtis,
                isSelected: isSelected,
                coreClient: coreClient,
                size: 22
            )

            // Text title and preview snippet
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    HighlightedLabel(
                        text: displayTitle,
                        ranges: item.titleHighlights,
                        isSelected: isSelected,
                        baseFont: .system(size: 12, weight: .medium),
                        defaultColor: .primary,
                        highlightStyle: highlightStyle
                    )

                    if let color = detectedColor {
                        ColorSwatchView(colorInfo: color, size: 12, cornerRadius: 2.5)
                    }

                    if let urlInfo = detectedUrl {
                        UrlBadgeView(urlInfo: urlInfo, isSelected: isSelected)
                    }

                    if item.isPinned {
                        Button {
                            onTogglePin?()
                        } label: {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Unpin item (⌥P)")
                    } else if isHovered {
                        Button {
                            onTogglePin?()
                        } label: {
                            Image(systemName: "pin")
                                .font(.system(size: 9))
                                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Pin item (⌥P)")
                    }

                    if item.contentKind == "file_urls" && isFileVanished(path: item.snippet) {
                        Text("missing")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.18))
                            .foregroundColor(isSelected ? .white : .red)
                            .cornerRadius(3)
                    }

                    if item.copyCount > 1 {
                        Text("\(item.copyCount)x")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                            .foregroundColor(isSelected ? .white : .secondary)
                            .cornerRadius(3)
                    }

                    Spacer()

                    // Click-safe external browser launcher (explicit button on hover only)
                    if let urlInfo = detectedUrl, isHovered, let url = urlInfo.url {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11))
                                .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open in Browser")
                    }

                    // Source application icon (P3-05, F-011)
                    if showSourceAppIcon, let bundleId = item.sourceBundleId, !bundleId.isEmpty {
                        SourceAppIconView(bundleId: bundleId, size: 14)
                            .help(bundleId)
                    }

                    // Pinned shortcut badge (⌥KEY) and/or Quick-pick shortcut badge (⌘1 - ⌘9) (P5-05 / F-022)
                    HStack(spacing: 3) {
                        if let pinKey = item.pinKey, !pinKey.isEmpty {
                            Text("⌥\(pinKey.uppercased())")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(isSelected ? .white.opacity(0.9) : .orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(isSelected ? Color.white.opacity(0.18) : Color.orange.opacity(0.12))
                                .cornerRadius(4)
                        }
                        if let key = shortcutIndex {
                            Text("⌘\(key)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(isSelected ? Color.white.opacity(0.15) : Color.primary.opacity(0.06))
                                .cornerRadius(4)
                        }
                    }
                }

                if !displaySnippet.isEmpty {
                    HighlightedLabel(
                        text: displaySnippet,
                        ranges: item.snippetHighlights,
                        isSelected: isSelected,
                        baseFont: .system(size: 11),
                        defaultColor: .secondary,
                        highlightStyle: highlightStyle
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(item.isPinned ? "Unpin Item (⌥P)" : "Pin Item (⌥P)") {
            onTogglePin?()
        }
        if item.isPinned, let key = item.pinKey, !key.isEmpty {
            Button("Remove Shortcut (⌥\(key.uppercased()))") {
                onSetPinKey?(nil)
            }
        }
        if item.isPinned {
            Divider()
            Button("Edit Pin Content... (⌘E)") {
                onEditPin?()
            }
            Button("Move Pin Up (⌥⌘↑)") {
                onMovePinUp?()
            }
            Button("Move Pin Down (⌥⌘↓)") {
                onMovePinDown?()
            }
        }
        Divider()
        Button("Copy to Clipboard") {
            onCommit?(.original, false)
        }
        Button("Paste as Plain Text (⇧↵)") {
            onCommit?(.plainText, nil)
        }
        Divider()
        Button("Delete Item (⌥⌫)", role: .destructive) {
            onDelete?()
        }
    }

    // MARK: - VoiceOver Accessibility (P7-07 / F-060, T-A11Y-01)

    var accessibilityDescription: String {
        var parts: [String] = []

        // 1. Content Title or Fallback
        let titleText = (displayTitle.isEmpty || displayTitle == "Untitled") ? "Untitled item" : displayTitle
        parts.append(titleText)

        // 2. Content Type Description
        let typeDescription: String
        switch item.contentKind {
        case "image":
            typeDescription = "Image"
        case "file_urls":
            typeDescription = "File"
        case "rich_text":
            typeDescription = "Formatted text"
        default:
            if let color = detectedColor {
                typeDescription = "Color \(color.hexString)"
            } else if let url = detectedUrl {
                typeDescription = "Web link \(url.host)"
            } else {
                typeDescription = "Text"
            }
        }
        parts.append(typeDescription)

        // 3. Source Application
        if let bundleId = item.sourceBundleId, !bundleId.isEmpty {
            let appName = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
            parts.append("from \(appName)")
        }

        return parts.joined(separator: ", ")
    }

    var accessibilityStatusValue: String {
        var values: [String] = []

        if item.isPinned {
            if let pinKey = item.pinKey, !pinKey.isEmpty {
                values.append("Pinned, shortcut Option+\(pinKey.uppercased())")
            } else {
                values.append("Pinned")
            }
        }

        if item.copyCount > 1 {
            values.append("copied \(item.copyCount) times")
        }

        if item.contentKind == "file_urls" && isFileVanished(path: item.snippet) {
            values.append("missing on disk")
        }

        if let shortcut = shortcutIndex {
            values.append("Quick-pick Command+\(shortcut)")
        }

        return values.joined(separator: ", ")
    }

    var accessibilityRowHint: String {
        var hints: [String] = [
            "Press Return to paste",
            "Shift-Return for plain text",
            "Option-P to \(item.isPinned ? "unpin" : "pin")",
            "Option-Delete to delete"
        ]
        if item.isPinned {
            hints.append("Option-Command-Up or Down to reorder")
        }
        return hints.joined(separator: ", ")
    }

    private var displayTitle: String {
        if item.contentKind == "file_urls" {
            if item.title.hasPrefix("id=") || item.title.contains("/.file/id=") {
                let firstLine = item.snippet.components(separatedBy: .newlines).first ?? item.snippet
                if let url = URL(string: firstLine), let resolved = (url as NSURL).filePathURL {
                    return resolved.lastPathComponent
                }
                return "File Reference"
            }
        }
        return item.title.isEmpty ? "Untitled" : item.title
    }

    private var displaySnippet: String {
        guard item.contentKind == "file_urls" else { return item.snippet }
        let lines = item.snippet.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("/.file/id="), let url = URL(string: trimmed), let resolved = (url as NSURL).filePathURL {
                return resolved.path
            }
            if trimmed.hasPrefix("file://localhost") {
                let sub = String(trimmed.dropFirst("file://localhost".count))
                return sub.removingPercentEncoding ?? sub
            } else if trimmed.hasPrefix("file://") {
                let sub = String(trimmed.dropFirst("file://".count))
                return sub.removingPercentEncoding ?? sub
            }
            return trimmed
        }
        return lines.joined(separator: "\n")
    }

    private func isFileVanished(path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let cleanPath: String
        if firstLine.contains("/.file/id=") {
            if let url = URL(string: firstLine), let resolved = (url as NSURL).filePathURL {
                cleanPath = resolved.path
            } else {
                return false
            }
        } else if firstLine.hasPrefix("file://") {
            guard let url = URL(string: firstLine) else { return false }
            let resolved = (url as NSURL).filePathURL ?? url
            cleanPath = resolved.path
        } else if firstLine.hasPrefix("/") {
            cleanPath = firstLine
        } else {
            return false
        }
        return !FileManager.default.fileExists(atPath: cleanPath)
    }
}

// MARK: - Row Accessibility Modifier (P7-07 / F-060, T-A11Y-01)

private struct RowAccessibilityModifier: ViewModifier {
    let item: HistoryItemSummaryDto
    let isSelected: Bool
    let description: String
    let statusValue: String
    let rowHint: String
    let onCommit: ((PasteMode, Bool?) -> Void)?
    let onTogglePin: (() -> Void)?
    let onEditPin: (() -> Void)?
    let onMovePinUp: (() -> Void)?
    let onMovePinDown: (() -> Void)?
    let onDelete: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(description)
            .accessibilityValue(statusValue)
            .accessibilityHint(rowHint)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityAction(named: "Paste") { onCommit?(.original, nil) }
            .accessibilityAction(named: "Copy") { onCommit?(.original, false) }
            .accessibilityAction(named: "Paste as Plain Text") { onCommit?(.plainText, nil) }
            .accessibilityAction(named: item.isPinned ? "Unpin Item" : "Pin Item") { onTogglePin?() }
            .accessibilityAction(named: "Edit Pin Content") { onEditPin?() }
            .accessibilityAction(named: "Move Pin Up") { onMovePinUp?() }
            .accessibilityAction(named: "Move Pin Down") { onMovePinDown?() }
            .accessibilityAction(named: "Delete Item") { onDelete?() }
    }
}

// MARK: - Reusable Asynchronous Item Thumbnail Component

struct ItemThumbnailView: View {
    let itemId: String
    let contentKind: String
    var title: String = ""
    var availableUtis: [String] = []
    let isSelected: Bool
    let coreClient: CoreClient?
    var size: CGFloat = 22

    @AppStorage("showColorSwatches") private var showColorSwatches: Bool = true
    @AppStorage("showUrlPreviews") private var showUrlPreviews: Bool = true

    @State private var thumbnail: NSImage?
    @State private var hasAttemptedLoad = false

    var body: some View {
        Group {
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size <= 18 ? 3 : 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: size <= 18 ? 3 : 4, style: .continuous)
                            .stroke(isSelected ? Color.white.opacity(0.3) : Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
            } else if showColorSwatches, let color = ColorDetector.detect(in: title) {
                ColorSwatchView(colorInfo: color, size: size, cornerRadius: size <= 18 ? 3 : 4)
            } else {
                Image(systemName: iconForKind(contentKind))
                    .font(.system(size: size <= 18 ? 11 : 13))
                    .foregroundColor(isSelected ? .white : .accentColor)
                    .frame(width: size, height: size)
            }
        }
        .task(id: itemId) {
            let isImageItem = contentKind == "image" ||
                              availableUtis.contains(where: { ["public.png", "public.tiff", "public.jpeg", "public.heic"].contains($0) })
            guard isImageItem, !hasAttemptedLoad, let client = coreClient else { return }
            hasAttemptedLoad = true
            if let cached = ImageThumbnailService.shared.cachedThumbnail(for: itemId) {
                self.thumbnail = cached
                return
            }
            let loaded = await ImageThumbnailService.shared.thumbnail(for: itemId) {
                for uti in ["public.png", "public.tiff", "public.jpeg", "public.heic"] {
                    if let data = try? await client.fetchPayload(itemId: itemId, uti: uti) {
                        return data
                    }
                }
                return nil
            }
            if let loaded = loaded {
                self.thumbnail = loaded
            }
        }
    }

    private func iconForKind(_ kind: String) -> String {
        if showUrlPreviews && (UrlDetector.detect(in: title) != nil || availableUtis.contains("public.url")) {
            return "link"
        }
        switch kind {
        case "text":
            return "text.alignleft"
        case "rich_text", "richtext":
            return "text.quote"
        case "image":
            return "photo"
        case "file_urls":
            return "folder"
        default:
            if availableUtis.contains(where: { ["public.png", "public.tiff", "public.jpeg", "public.heic"].contains($0) }) {
                return "photo"
            }
            return "square.stack.3d.down.right"
        }
    }
}

// MARK: - Empty State Component

struct PanelEmptyStateView: View {
    let iconName: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.8))
                .padding(.bottom, 4)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Compact Footer Bar Component

struct PanelFooterBar: View {
    let itemCount: Int
    let totalCount: Int
    let onSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(itemCount) of \(totalCount) items")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .accessibilityLabel("\(itemCount) of \(totalCount) items in history")

            Spacer()

            // Shortcut hints
            HStack(spacing: 8) {
                ShortcutHint(key: "↑↓", label: "Navigate")
                ShortcutHint(key: "↵", label: "Paste")
                ShortcutHint(key: "⎋", label: "Dismiss")
            }
            .accessibilityHidden(true)

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Mimra Settings")
            .help("Open Mimra Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct ShortcutHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(3)

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Copy-Only Mode Banner Component

struct CopyOnlyBanner: View {
    var onEnable: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 1) {
                Text("Copy-Only Mode Active")
                    .font(.system(size: 11, weight: .semibold))
                Text("Press ⌘V to paste manually. Grant Accessibility to auto-paste.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Enable...") {
                onEnable()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(.system(size: 10, weight: .medium))
            .accessibilityLabel("Enable auto-paste in Accessibility Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - Highlight Styles (P4-04 / F-050)

public enum SearchHighlightStyle: String, CaseIterable, Codable, Sendable {
    case bold = "bold"
    case underline = "underline"
    case italic = "italic"
    case boldUnderline = "boldUnderline"
    case accent = "accent"
    case none = "none"

    public var displayName: String {
        switch self {
        case .bold: return "Bold"
        case .underline: return "Underline"
        case .italic: return "Italic"
        case .boldUnderline: return "Bold & Underline"
        case .accent: return "Accent Color"
        case .none: return "None"
        }
    }
}

// MARK: - Highlighted Label Component (P4-02, P4-04)

struct HighlightedLabel: View {
    let text: String
    let ranges: [HighlightRangeDto]
    let isSelected: Bool
    let baseFont: Font
    let defaultColor: Color
    var highlightStyle: SearchHighlightStyle = .bold

    var body: some View {
        if ranges.isEmpty || highlightStyle == .none {
            Text(text)
                .font(baseFont)
                .foregroundColor(isSelected ? .white : defaultColor)
                .lineLimit(1)
        } else {
            Text(makeAttributedString())
                .lineLimit(1)
        }
    }

    private func makeAttributedString() -> AttributedString {
        var attr = AttributedString(text)
        let nsText = text as NSString
        let highlightColor: Color = isSelected ? Color.white : Color.accentColor

        attr.font = baseFont
        attr.foregroundColor = isSelected ? .white : defaultColor

        guard highlightStyle != .none else { return attr }

        for r in ranges {
            let nsRange = NSRange(location: Int(r.start), length: Int(r.length))
            if nsRange.location + nsRange.length <= nsText.length,
               let swiftRange = Range(nsRange, in: text),
               let attrRange = Range(swiftRange, in: attr) {
                switch highlightStyle {
                case .bold:
                    attr[attrRange].font = .system(size: 12, weight: .bold)
                case .underline:
                    attr[attrRange].underlineStyle = .single
                case .italic:
                    attr[attrRange].font = .system(size: 12).italic()
                case .boldUnderline:
                    attr[attrRange].font = .system(size: 12, weight: .bold)
                    attr[attrRange].underlineStyle = .single
                case .accent:
                    attr[attrRange].font = .system(size: 12, weight: .bold)
                    attr[attrRange].foregroundColor = highlightColor
                case .none:
                    break
                }
            }
        }
        return attr
    }
}
