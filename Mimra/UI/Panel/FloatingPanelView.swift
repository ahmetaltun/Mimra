// ==============================================================================
// Mimra — Floating Panel View
// SwiftUI content for the floating search panel, item list, empty states, and footer.
// Linked Features: F-018, F-019
// Test IDs: T-UI-02, T-UI-03
// ==============================================================================

import SwiftUI

@MainActor
public struct FloatingPanelView: View {
    @ObservedObject public var viewModel: PanelViewModel
    @ObservedObject public var accessibilityService: AccessibilityService
    @FocusState private var isSearchFocused: Bool

    public init(viewModel: PanelViewModel, accessibilityService: AccessibilityService? = nil) {
        self.viewModel = viewModel
        self.accessibilityService = accessibilityService ?? AccessibilityService.shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Search Header Bar
            PanelSearchBar(
                text: $viewModel.searchText,
                isFocused: $isSearchFocused,
                onClear: {
                    viewModel.searchText = ""
                }
            )

            Divider()
                .opacity(0.4)

            // Copy-Only Mode Informational Banner (when Accessibility is not granted)
            if !accessibilityService.isTrusted {
                CopyOnlyBanner(onEnable: {
                    accessibilityService.promptForPermission()
                })
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
                                    PanelItemRow(
                                        item: item,
                                        shortcutIndex: index < 9 ? (index + 1) : nil,
                                        isSelected: index == viewModel.selectedIndex,
                                        coreClient: viewModel.coreClient
                                    )
                                    .id(item.id)
                                    .onHover { isHovered in
                                        if isHovered {
                                            viewModel.selectIndex(index, fromHover: true)
                                        }
                                    }
                                    .onTapGesture {
                                        viewModel.selectIndex(index, fromHover: false)
                                        viewModel.commitSelection()
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

            Divider()
                .opacity(0.4)

            // 3. Compact Footer Action Bar
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
        .frame(minWidth: 340, idealWidth: 440, maxWidth: 800, minHeight: 320, idealHeight: 540, maxHeight: 1000)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .task {
            // Apply persisted sorting & pin arrangement preferences
            if let pinArr = UserDefaults.standard.string(forKey: "pinArrangement") {
                switch pinArr {
                case "bottom": viewModel.pinArrangement = .bottom
                case "inline": viewModel.pinArrangement = .inline
                default: viewModel.pinArrangement = .top
                }
            }
            if let sortMode = UserDefaults.standard.string(forKey: "historySortMode") {
                switch sortMode {
                case "copyCount": viewModel.sortMode = .copyCount
                case "firstCopied": viewModel.sortMode = .firstCopied
                default: viewModel.sortMode = .recency
                }
            }
            if UserDefaults.standard.object(forKey: "searchByRelevance") != nil {
                viewModel.searchByRelevance = UserDefaults.standard.bool(forKey: "searchByRelevance")
            }

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

            TextField("Search clipboard history...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(isFocused)

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - History Item Row Component

struct PanelItemRow: View {
    let item: HistoryItemSummaryDto
    let shortcutIndex: Int?
    let isSelected: Bool
    var coreClient: CoreClient? = nil

    @AppStorage("showColorSwatches") private var showColorSwatches: Bool = true
    @AppStorage("showUrlPreviews") private var showUrlPreviews: Bool = true
    @AppStorage("showSourceAppIcon") private var showSourceAppIcon: Bool = true
    @AppStorage("searchHighlightStyle") private var searchHighlightStyleRaw: String = SearchHighlightStyle.bold.rawValue
    @State private var isHovered: Bool = false

    private var highlightStyle: SearchHighlightStyle {
        SearchHighlightStyle(rawValue: searchHighlightStyleRaw) ?? .bold
    }

    private var detectedColor: HexColorInfo? {
        showColorSwatches ? ColorDetector.detect(in: item.title) : nil
    }

    private var detectedUrl: UrlInfo? {
        showUrlPreviews ? UrlDetector.detect(in: item.title) : nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Type icon, cached image thumbnail, or color swatch (P3-02, P3-04)
            ItemThumbnailView(
                itemId: item.id,
                contentKind: item.contentKind,
                title: item.title,
                availableUtis: item.availableUtis,
                isSelected: isSelected,
                coreClient: coreClient
            )

            // Text title and preview snippet
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    HighlightedLabel(
                        text: item.title.isEmpty ? "Untitled" : item.title,
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
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
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

                    // Quick-pick shortcut badge (⌘1 - ⌘9)
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

                if !item.snippet.isEmpty {
                    HighlightedLabel(
                        text: item.snippet,
                        ranges: item.snippetHighlights,
                        isSelected: isSelected,
                        baseFont: .system(size: 11),
                        defaultColor: .secondary,
                        highlightStyle: highlightStyle
                    )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isHovered = hovering
        }
    }

    private func isFileVanished(path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let cleanPath: String
        if firstLine.hasPrefix("file://") {
            guard let url = URL(string: firstLine) else { return false }
            cleanPath = url.path
        } else if firstLine.hasPrefix("/") {
            cleanPath = firstLine
        } else {
            return false
        }
        return !FileManager.default.fileExists(atPath: cleanPath)
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
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(isSelected ? Color.white.opacity(0.3) : Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
            } else if showColorSwatches, let color = ColorDetector.detect(in: title) {
                ColorSwatchView(colorInfo: color, size: 22, cornerRadius: 4)
            } else {
                Image(systemName: iconForKind(contentKind))
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white : .accentColor)
                    .frame(width: 22, height: 22)
            }
        }
        .task(id: itemId) {
            guard contentKind == "image", !hasAttemptedLoad, let client = coreClient else { return }
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
        case "rich_text":
            return "text.quote"
        case "image":
            return "photo"
        case "file_urls":
            return "folder"
        default:
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

            Spacer()

            // Shortcut hints
            HStack(spacing: 8) {
                ShortcutHint(key: "↑↓", label: "Navigate")
                ShortcutHint(key: "↵", label: "Paste")
                ShortcutHint(key: "⎋", label: "Dismiss")
            }

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
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
