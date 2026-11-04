// ==============================================================================
// Mimra — Preview Container View
// Visual container and layout for the slideout preview panel with NativeTextPreviewView.
// Linked Features: F-039, F-041 (T-PREV-01, T-PREV-03)
// ==============================================================================

import AppKit
import SwiftUI

/// Main content view hosted inside `PreviewPanel`.
@MainActor
public struct PreviewContainerView: View {
    public let item: HistoryItemSummaryDto?
    public let coreClient: CoreClient?
    public var onClose: (() -> Void)?
    public var onFullTextLoaded: ((String) -> Void)?

    @State private var fullText: String? = nil
    @State private var isMonospaced: Bool = false
    @State private var isCopiedNotificationShown: Bool = false

    public init(
        item: HistoryItemSummaryDto?,
        coreClient: CoreClient? = nil,
        onClose: (() -> Void)? = nil,
        onFullTextLoaded: ((String) -> Void)? = nil
    ) {
        self.item = item
        self.coreClient = coreClient
        self.onClose = onClose
        self.onFullTextLoaded = onFullTextLoaded
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()
                .opacity(0.3)

            // Content Area
            if let item = item {
                let isImage = item.contentKind.lowercased() == "image" ||
                              item.availableUtis.contains(where: { ["public.png", "public.tiff", "public.jpeg", "public.heic"].contains($0) })
                if isImage {
                    ImagePreviewView(item: item, coreClient: coreClient)
                } else if item.contentKind.lowercased() == "text" || item.contentKind.lowercased() == "richtext" || item.contentKind.lowercased() == "rich_text" {
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
            guard let client = coreClient, let itemId = item?.id else {
                fullText = nil
                return
            }
            if let reps = try? await client.getItemRepresentations(itemId: itemId),
               let textRep = reps.first(where: {
                   $0.uti == "public.utf8-plain-text" ||
                   $0.uti == "NSStringPboardType" ||
                   $0.uti == "public.plain-text" ||
                   $0.uti == "text/plain"
               }),
               let decoded = String(data: textRep.payload, encoding: .utf8) {
                if !Task.isCancelled {
                    self.fullText = decoded
                    self.onFullTextLoaded?(decoded)
                }
            } else {
                if !Task.isCancelled {
                    self.fullText = nil
                }
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

        return VStack(alignment: .leading, spacing: 0) {
            // Text Toolbar (Stats, Monospace Toggle, Quick Copy)
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

                // Monospace font toggle
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

                // Quick copy full text button
                Button(action: {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(displayText, forType: .string)
                    isCopiedNotificationShown = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        isCopiedNotificationShown = false
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: isCopiedNotificationShown ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        if isCopiedNotificationShown {
                            Text("Copied")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .foregroundColor(isCopiedNotificationShown ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy full text to clipboard")
                .help("Copy full text to clipboard")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))

            Divider().opacity(0.2)

            // Native Text View with non-contiguous layout (handles <= 1 MB seamlessly)
            NativeTextPreviewView(text: displayText, isMonospaced: isMonospaced)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.2)

            // Compact Metadata Footer
            compactMetadataBar(for: item)
        }
    }

    private func nonTextItemPreviewView(for item: HistoryItemSummaryDto) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Primary Title / Content Display
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

                // Metadata Section
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
        HStack {
            Text("Preview Attached")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
            Text("Toggle: ⌃Space")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
        case "richtext": return "Rich Text"
        case "image": return "Image"
        case "fileurl": return "File Reference"
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
