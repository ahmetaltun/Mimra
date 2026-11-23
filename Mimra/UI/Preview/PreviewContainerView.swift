// ==============================================================================
// Mimra — Preview Container View
// Visual container and layout for the slideout preview panel with formatters,
// Color/URL/File inspectors, interactive image zoom, and quick actions.
// Linked Features: F-039, F-041, F-042 (T-PREV-01, T-PREV-03, T-PREV-04)
// ==============================================================================

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared observable state bridging PreviewCoordinator keyboard shortcuts to PreviewContainerView.
@MainActor
public final class PreviewViewState: ObservableObject {
    @Published public var isFormattedMode: Bool = AppearanceConfiguration.shared.defaultToFormattedPreview
    public let zoomController = ImageZoomController()

    public init() {}

    public func resetForNewItem() {
        isFormattedMode = AppearanceConfiguration.shared.defaultToFormattedPreview
    }

    public func toggleFormattedMode() {
        isFormattedMode.toggle()
    }
}

/// Main content view hosted inside `PreviewPanel`.
private struct AttributedStringBox: @unchecked Sendable {
    let attributedString: NSAttributedString?
}

@MainActor
public struct PreviewContainerView: View {
    public let item: HistoryItemSummaryDto?
    public let coreClient: CoreClient?
    @ObservedObject public var viewState: PreviewViewState
    public var onClose: (() -> Void)?
    public var onFullTextLoaded: ((String) -> Void)?
    public var onPaste: (() -> Void)?
    public var onPastePlain: (() -> Void)?
    public var onEditPin: (() -> Void)?

    @State private var fullText: String? = nil
    @State private var rtfData: Data? = nil
    @State private var htmlData: Data? = nil
    @State private var detectedFormat: DetectedTextFormat = .plain
    @State private var formattedAttributedText: NSAttributedString? = nil
    @State private var formattedPlainCopyText: String? = nil
    @State private var isMonospaced: Bool = false
    @State private var copiedKind: String? = nil

    public init(
        item: HistoryItemSummaryDto?,
        coreClient: CoreClient? = nil,
        viewState: PreviewViewState? = nil,
        onClose: (() -> Void)? = nil,
        onFullTextLoaded: ((String) -> Void)? = nil,
        onPaste: (() -> Void)? = nil,
        onPastePlain: (() -> Void)? = nil,
        onEditPin: (() -> Void)? = nil
    ) {
        self.item = item
        self.coreClient = coreClient
        self._viewState = ObservedObject(wrappedValue: viewState ?? PreviewViewState())
        self.onClose = onClose
        self.onFullTextLoaded = onFullTextLoaded
        self.onPaste = onPaste
        self.onPastePlain = onPastePlain
        self.onEditPin = onEditPin
    }

    private var isImageItem: Bool {
        guard let item = item else { return false }
        return item.contentKind.lowercased() == "image" ||
               item.availableUtis.contains(where: { ["public.png", "public.tiff", "public.jpeg", "public.heic"].contains($0) })
    }

    private var isTextItem: Bool {
        guard let item = item else { return false }
        let kind = item.contentKind.lowercased()
        return kind == "text" || kind == "richtext" || kind == "rich_text"
    }

    private var isFileItem: Bool {
        guard let item = item else { return false }
        let kind = item.contentKind.lowercased()
        return kind == "file_urls" || kind == "fileurl" || kind == "files" ||
               item.availableUtis.contains("public.file-url")
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()
                .opacity(0.3)

            // Content Area
            if let item = item {
                if isImageItem {
                    ImagePreviewView(
                        item: item,
                        coreClient: coreClient,
                        zoomController: viewState.zoomController
                    )
                } else if isFileItem && !isTextItem {
                    FilePreviewView(item: item, coreClient: coreClient)
                } else if isTextItem {
                    textItemPreviewView(for: item)
                } else {
                    nonTextItemPreviewView(for: item)
                }
            } else {
                emptyPlaceholderView
            }

            Divider()
                .opacity(0.3)

            // Footer Bar
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
        .task(id: item?.id) {
            viewState.resetForNewItem()
            await loadItemContent()
        }
    }

    // MARK: - Content Loading & Format Detection

    private func loadItemContent() async {
        // Clear stale state immediately when switching items
        fullText = nil
        rtfData = nil
        htmlData = nil
        detectedFormat = .plain
        formattedAttributedText = nil
        formattedPlainCopyText = nil

        guard let client = coreClient, let item = item else {
            return
        }

        // Image and file previews load their own representations/files directly; avoid duplicate SQLite reads.
        if isImageItem || (isFileItem && !isTextItem) {
            return
        }

        // Debounce heavy SQLite + formatting work during fast key-repeat scrubbing
        try? await Task.sleep(nanoseconds: 70_000_000)
        if Task.isCancelled { return }

        guard let reps = try? await client.getItemRepresentations(itemId: item.id),
              !Task.isCancelled else {
            return
        }

        let textRep = reps.first(where: {
            $0.uti == "public.utf8-plain-text" ||
            $0.uti == "NSStringPboardType" ||
            $0.uti == "public.plain-text" ||
            $0.uti == "text/plain"
        })
        let rtfRep = reps.first(where: { $0.uti == "public.rtf" })
        let htmlRep = reps.first(where: { $0.uti == "public.html" })

        let decodedText = textRep.flatMap { String(data: $0.payload, encoding: .utf8) }
        let rawRtf = rtfRep?.payload
        let rawHtml = htmlRep?.payload
        let snippet = item.snippet
        let availableUtis = item.availableUtis

        // Run format detection and non-HTML formatting off @MainActor
        let (format, bgAttrBox, bgPrettyPlain) = await Task.detached(priority: .userInitiated) {
            let detected = TextFormatDetector.detect(
                text: decodedText ?? snippet,
                availableUtis: availableUtis,
                hasRtfData: rawRtf != nil,
                hasHtmlData: rawHtml != nil
            )

            var attr: NSAttributedString? = nil
            var prettyPlain: String? = nil

            switch detected {
            case .json:
                if let src = decodedText ?? (snippet.isEmpty ? nil : snippet),
                   let pretty = JsonTextFormatter.prettyPrint(src) {
                    attr = JsonTextFormatter.attributedHighlight(pretty, fontSize: 12)
                    prettyPlain = pretty
                }
            case .markdown:
                if let src = decodedText ?? (snippet.isEmpty ? nil : snippet) {
                    attr = MarkdownAttributedRenderer.render(src, baseFontSize: 12.5)
                    prettyPlain = attr?.string
                }
            case .rtf:
                if let data = rawRtf {
                    attr = RichTextAttributedRenderer.renderRtf(data)
                    prettyPlain = attr?.string
                }
            case .html, .plain:
                break
            }

            return (detected, AttributedStringBox(attributedString: attr), prettyPlain)
        }.value

        if Task.isCancelled { return }

        var attr = bgAttrBox.attributedString
        var prettyPlain = bgPrettyPlain
        if format == .html, let data = rawHtml, let htmlStr = String(data: data, encoding: .utf8) {
            attr = RichTextAttributedRenderer.renderHtml(htmlStr, baseFontSize: 12.5)
            prettyPlain = attr?.string
        }

        if !Task.isCancelled {
            self.fullText = decodedText
            self.rtfData = rawRtf
            self.htmlData = rawHtml
            self.detectedFormat = format
            self.formattedAttributedText = attr
            self.formattedPlainCopyText = prettyPlain
            if let decodedText = decodedText {
                self.onFullTextLoaded?(decodedText)
            }
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack(spacing: 8) {
            if let item = item {
                if let bundleId = item.sourceBundleId, !bundleId.isEmpty {
                    SourceAppIconView(bundleId: bundleId, size: 16)
                }

                Text(kindDisplayName(for: item.contentKind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                if let badge = detectedFormat.badgeLabel, isTextItem {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.14))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                }

                if item.isPinned {
                    HStack(spacing: 2) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.accentColor)
                        if let key = item.pinKey {
                            Text("⌥\(key.uppercased())")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(4)
                }
            } else {
                Image(systemName: "eye")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text("Item Preview")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary.opacity(0.7))
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close preview")
                .help("Close preview (^Space)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func textItemPreviewView(for item: HistoryItemSummaryDto) -> some View {
        let displayText = fullText ?? (item.snippet.isEmpty ? item.title : item.snippet)
        let lineCount = displayText.split(separator: "\n", omittingEmptySubsequences: false).count
        let detectedColor = ColorDetector.detect(in: displayText)
        let detectedUrl = detectedColor == nil ? UrlDetector.detect(in: displayText) : nil
        let canFormat = detectedFormat.isFormattable && formattedAttributedText != nil
        let showingFormatted = canFormat && viewState.isFormattedMode

        return VStack(alignment: .leading, spacing: 0) {
            // Text Toolbar (Stats, Original/Formatted Switch, Monospace Toggle, Copy Choice)
            HStack(spacing: 8) {
                Text("\(displayText.count) chars")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("•")
                    .foregroundColor(.secondary.opacity(0.4))
                Text("\(lineCount) lines")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                // Original / Formatted Switch Action Button
                if canFormat {
                    HStack(spacing: 2) {
                        Button(action: { viewState.isFormattedMode = false }) {
                            Text("Original")
                                .font(.system(size: 9.5, weight: !showingFormatted ? .semibold : .regular))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(!showingFormatted ? Color.accentColor.opacity(0.18) : Color.clear)
                                .foregroundColor(!showingFormatted ? .accentColor : .secondary)
                                .cornerRadius(3)
                        }
                        .buttonStyle(.plain)

                        Button(action: { viewState.isFormattedMode = true }) {
                            Text("Formatted")
                                .font(.system(size: 9.5, weight: showingFormatted ? .semibold : .regular))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(showingFormatted ? Color.accentColor.opacity(0.18) : Color.clear)
                                .foregroundColor(showingFormatted ? .accentColor : .secondary)
                                .cornerRadius(3)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(2)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(5)
                    .help("Switch between Original and Formatted view (⌥F)")
                }

                // Monospace font toggle (when in Original mode)
                if !showingFormatted {
                    Button(action: {
                        isMonospaced.toggle()
                    }) {
                        Image(systemName: isMonospaced ? "textformat.characters" : "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(isMonospaced ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isMonospaced ? "Switch to proportional font" : "Switch to monospaced font")
                    .help(isMonospaced ? "Switch to proportional font" : "Switch to monospaced font")
                }

                // Copy Action: Choice Menu when Formatted, Direct Copy when Original
                if showingFormatted {
                    Menu {
                        Button("Copy Formatted") {
                            copyFormattedContent(fallbackText: displayText)
                        }
                        Button("Copy Original Text") {
                            copyPlainString(displayText, label: "Original")
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copiedKind != nil ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(copiedKind != nil ? "Copied \(copiedKind!)" : "Copy")
                                .font(.system(size: 9.5, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7))
                        }
                        .foregroundColor(copiedKind != nil ? .green : .secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose to copy Formatted or Original text")
                } else {
                    Button(action: {
                        copyPlainString(displayText, label: "Text")
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: copiedKind != nil ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            if copiedKind != nil {
                                Text("Copied")
                                    .font(.system(size: 9, weight: .medium))
                            }
                        }
                        .foregroundColor(copiedKind != nil ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy full text to clipboard")
                    .help("Copy full text to clipboard")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))

            Divider().opacity(0.2)

            // Optional Color or URL Inspector Card
            if let colorInfo = detectedColor {
                ColorInspectorCard(colorInfo: colorInfo)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            } else if let urlInfo = detectedUrl {
                UrlInspectorCard(urlInfo: urlInfo)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }

            // Native Text View with non-contiguous layout
            NativeTextPreviewView(
                text: displayText,
                attributedText: showingFormatted ? formattedAttributedText : nil,
                isMonospaced: isMonospaced
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.2)

            // Compact Metadata Footer
            compactMetadataBar(for: item)
        }
    }

    private func nonTextItemPreviewView(for item: HistoryItemSummaryDto) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)

                    if !item.snippet.isEmpty && item.snippet != item.title {
                        Text(item.snippet)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("METADATA")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.6))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        metadataPill(title: "Size", value: formattedByteSize(item.byteSize))
                        metadataPill(title: "Copies", value: "\(item.copyCount)x")
                        metadataPill(title: "First Copied", value: relativeDateString(from: item.firstCopiedAtMs))
                        metadataPill(title: "Last Copied", value: relativeDateString(from: item.lastCopiedAtMs))
                    }

                    if !item.availableUtis.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("REPRESENTATIONS")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.6))
                                .padding(.top, 4)

                            FlowLayout(spacing: 4) {
                                ForEach(item.availableUtis, id: \.self) { uti in
                                    Text(uti)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.06))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func compactMetadataBar(for item: HistoryItemSummaryDto) -> some View {
        HStack(spacing: 12) {
            Text(formattedByteSize(item.byteSize))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)

            Text("\(item.copyCount)x copied")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            Spacer()

            if let firstUti = item.availableUtis.first {
                Text(firstUti)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.02))
    }

    private var emptyPlaceholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Item Selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Text("Select an item in history to see its full preview.")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            if item != nil {
                if let onPaste = onPaste {
                    footerActionButton(title: "Paste", shortcut: "↵", action: onPaste)
                }
                if isTextItem, let onPastePlain = onPastePlain {
                    footerActionButton(title: "Plain", shortcut: "⇧↵", action: onPastePlain)
                }
                if item?.isPinned == true, let onEditPin = onEditPin {
                    footerActionButton(title: "Edit", shortcut: "⌘E", action: onEditPin)
                }
                if isImageItem {
                    footerActionButton(title: "Save As…", shortcut: nil) {
                        saveCurrentImageAs()
                    }
                }
            } else {
                Text("Preview Attached")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Spacer()

            Text("⌃Space")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func footerActionButton(title: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Copy & Save Helpers

    private func copyPlainString(_ text: String, label: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let pbItem = NSPasteboardItem()
        pbItem.setString(text, forType: .string)
        pbItem.setData(Data(), forType: ClipboardProvenance.provenanceType)
        pbItem.setString(ClipboardProvenance.mimraBundleIdentifier, forType: ClipboardProvenance.sourceAppType)
        if pb.writeObjects([pbItem]) {
            ClipboardProvenance.shared.recordSelfWrite(on: pb)
            showCopiedFeedback(label)
        }
    }

    private func copyFormattedContent(fallbackText: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let pbItem = NSPasteboardItem()

        switch detectedFormat {
        case .json:
            let pretty = formattedPlainCopyText ?? fallbackText
            pbItem.setString(pretty, forType: .string)
        case .markdown, .rtf, .html:
            if let attr = formattedAttributedText,
               let rtf = try? attr.data(
                   from: NSRange(location: 0, length: attr.length),
                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
               ) {
                pbItem.setData(rtf, forType: .rtf)
            }
            pbItem.setString(formattedPlainCopyText ?? fallbackText, forType: .string)
        case .plain:
            pbItem.setString(fallbackText, forType: .string)
        }

        pbItem.setData(Data(), forType: ClipboardProvenance.provenanceType)
        pbItem.setString(ClipboardProvenance.mimraBundleIdentifier, forType: ClipboardProvenance.sourceAppType)
        if pb.writeObjects([pbItem]) {
            ClipboardProvenance.shared.recordSelfWrite(on: pb)
            showCopiedFeedback("Formatted")
        }
    }

    private func showCopiedFeedback(_ label: String) {
        copiedKind = label
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedKind == label {
                copiedKind = nil
            }
        }
    }

    private func saveCurrentImageAs() {
        guard let item = item, let client = coreClient else { return }
        Task {
            guard let reps = try? await client.getItemRepresentations(itemId: item.id),
                  let imageRep = reps.first(where: {
                      ["public.png", "public.heic", "public.jpeg", "public.tiff"].contains($0.uti)
                  }) else {
                return
            }

            let ext: String
            switch imageRep.uti {
            case "public.jpeg": ext = "jpg"
            case "public.heic": ext = "heic"
            case "public.tiff": ext = "tiff"
            default: ext = "png"
            }

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Mimra-Image.\(ext)"
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let dest = panel.url {
                try? imageRep.payload.write(to: dest)
            }
        }
    }

    private func metadataPill(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(4)
    }

    private func kindDisplayName(for kind: String) -> String {
        switch kind.lowercased() {
        case "text": return "Plain Text"
        case "richtext", "rich_text": return "Rich Text"
        case "image": return "Image"
        case "fileurl", "file_urls", "files": return "File Reference"
        case "color": return "Color"
        case "url": return "Web Link"
        default: return kind.capitalized
        }
    }

    private func formattedByteSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func relativeDateString(from timestampMs: Int64) -> String {
        guard timestampMs > 0 else { return "Just now" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Simple flow layout helper for tags/UTIs.
public struct FlowLayout: Layout {
    public var spacing: CGFloat

    public init(spacing: CGFloat = 4) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
        height = currentY + rowHeight
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
    }
}
