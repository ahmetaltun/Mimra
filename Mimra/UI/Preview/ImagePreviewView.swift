// ==============================================================================
// Mimra — Image Preview View
// Renders image previews with aspect ratio preservation, checkerboard backdrop,
// dimension/format/byte size metadata pills, and quick copy action.
// Linked Feature: F-042
// Test ID: T-PREV-04
// ==============================================================================

import AppKit
import SwiftUI

/// Checkerboard pattern backdrop enabling clear visualization of transparent PNGs and icons.
struct CheckerboardBackdropView: View {
    let tileSize: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / tileSize))
            let rows = Int(ceil(size.height / tileSize))

            for row in 0..<rows {
                for col in 0..<cols {
                    if (row + col) % 2 == 0 {
                        let rect = CGRect(
                            x: CGFloat(col) * tileSize,
                            y: CGFloat(row) * tileSize,
                            width: tileSize,
                            height: tileSize
                        )
                        context.fill(Path(rect), with: .color(Color.primary.opacity(0.04)))
                    }
                }
            }
        }
    }
}

/// Display state representing background on-device OCR lifecycle.
public enum OCRDisplayState: Equatable, Sendable {
    case idle
    case loading
    case success(text: String)
    case noTextDetected
    case failed(error: String)
}

/// View mode when an image has recognized OCR text.
public enum ImageOCRViewMode: String, CaseIterable, Sendable {
    case split = "Split"
    case imageOnly = "Image"
    case ocrOnly = "OCR"
}

/// SwiftUI View rendering image previews with zoom/pan navigation, OCR view modes, and metadata.
@MainActor
public struct ImagePreviewView: View {
    public let item: HistoryItemSummaryDto
    public let coreClient: CoreClient?
    @ObservedObject public var zoomController: ImageZoomController

    @State private var previewPayload: ImagePreviewPayload? = nil
    @State private var isLoading: Bool = true
    @State private var hasError: Bool = false
    @State private var isCopiedNotificationShown: Bool = false
    @State private var ocrState: OCRDisplayState = .idle
    @State private var isOcrCopiedNotificationShown: Bool = false
    @State private var ocrViewMode: ImageOCRViewMode = .split

    public init(
        item: HistoryItemSummaryDto,
        coreClient: CoreClient? = nil,
        zoomController: ImageZoomController? = nil
    ) {
        self.item = item
        self.coreClient = coreClient
        self._zoomController = ObservedObject(wrappedValue: zoomController ?? ImageZoomController())
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Image Details Toolbar (Dimensions, Format, Byte Size, Quick Copy)
            toolbarBar

            Divider().opacity(0.2)

            // Main Canvas / OCR Area
            if case .success(let ocrText) = ocrState, !ocrText.isEmpty, ocrViewMode == .ocrOnly {
                VStack(alignment: .leading, spacing: 0) {
                    ocrHeaderBar(ocrText: ocrText)
                    Divider().opacity(0.15)
                    NativeTextPreviewView(text: ocrText, isMonospaced: false, fontSize: 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ZStack(alignment: .bottomTrailing) {
                    // Subtle transparent checkerboard backdrop
                    CheckerboardBackdropView()

                    if let payload = previewPayload {
                        InteractiveImageCanvasView(image: payload.image, controller: zoomController)
                            .accessibilityLabel("Image preview: \(payload.metadata.format), \(payload.metadata.width) by \(payload.metadata.height)")

                        // Floating Zoom HUD
                        zoomHudPill
                            .padding(10)
                    } else if isLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading preview...")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if hasError {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 26))
                                .foregroundColor(.secondary.opacity(0.7))
                            Text("Unable to preview image")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(formattedByteSize(item.byteSize))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                // Optional Recognized Text Drawer in Split mode
                if case .success(let ocrText) = ocrState, !ocrText.isEmpty, ocrViewMode == .split {
                    Divider().opacity(0.2)
                    ocrTextSection(ocrText: ocrText)
                }
            }

            Divider().opacity(0.2)

            // Compact Metadata Footer
            compactMetadataBar
        }
        .task(id: item.id) {
            await loadAll()
        }
    }

    // MARK: - Subviews

    private var toolbarBar: some View {
        HStack(spacing: 8) {
            // Left: OCR View Mode Switcher (if OCR text exists) or compact format/dimensions pill
            if case .success(let ocrText) = ocrState, !ocrText.isEmpty {
                HStack(spacing: 2) {
                    ForEach(ImageOCRViewMode.allCases, id: \.self) { mode in
                        Button(action: { ocrViewMode = mode }) {
                            Text(mode.rawValue)
                                .font(.system(size: 10, weight: ocrViewMode == mode ? .semibold : .regular))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(ocrViewMode == mode ? Color.accentColor.opacity(0.18) : Color.clear)
                                .foregroundColor(ocrViewMode == mode ? .accentColor : .secondary)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(5)
                .fixedSize(horizontal: true, vertical: false)
            } else if let payload = previewPayload {
                HStack(spacing: 6) {
                    Text(payload.metadata.format)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(4)
                        .foregroundColor(.primary)

                    Text("\(payload.metadata.pixelDimensionsString) px")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(formattedByteSize(item.byteSize))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Right: OCR Status / Copy OCR + Copy Image
            HStack(spacing: 8) {
                ocrToolbarItem

                if case .success(let ocrText) = ocrState, !ocrText.isEmpty {
                    Divider()
                        .frame(height: 12)
                        .opacity(0.3)
                } else if ocrState == .loading || ocrState == .noTextDetected {
                    Divider()
                        .frame(height: 12)
                        .opacity(0.3)
                }

                Button(action: copyImageToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopiedNotificationShown ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(isCopiedNotificationShown ? "Copied" : "Copy Image")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
                    .foregroundColor(isCopiedNotificationShown ? .green : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy image to clipboard")
                .help("Copy original image to clipboard")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private var ocrToolbarItem: some View {
        switch ocrState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
                Text("Scanning...")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        case .success(let ocrText):
            if !ocrText.isEmpty {
                Button(action: copyOcrTextToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isOcrCopiedNotificationShown ? "checkmark" : "text.viewfinder")
                            .font(.system(size: 10))
                        Text(isOcrCopiedNotificationShown ? "Copied" : "Copy OCR")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
                    .foregroundColor(isOcrCopiedNotificationShown ? .green : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy OCR extracted text to clipboard")
                .help("Copy extracted OCR text to clipboard")
            }
        case .noTextDetected:
            HStack(spacing: 3) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 9.5))
                Text("No text")
                    .font(.system(size: 9.5))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(.secondary.opacity(0.5))
            .help("On-device Vision scanned this image and found no readable text")
        case .failed(let error):
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9.5))
                Text("OCR error")
                    .font(.system(size: 9.5))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(.secondary.opacity(0.6))
            .help("OCR extraction failed: \(error)")
        }
    }

    private var zoomHudPill: some View {
        HStack(spacing: 6) {
            Button(action: { zoomController.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Zoom out (⌥-)")

            Text("\(zoomController.zoomPercentage)%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(minWidth: 34)

            Button(action: { zoomController.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Zoom in (⌥+)")

            Divider()
                .frame(height: 11)
                .opacity(0.4)

            Button(action: { zoomController.resetToFit() }) {
                Text("Fit")
                    .font(.system(size: 9.5, weight: zoomController.isFitMode ? .bold : .regular))
                    .foregroundColor(zoomController.isFitMode ? .accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help("Fit to window (⌥0)")

            Button(action: { zoomController.zoomToActualSize() }) {
                Text("1:1")
                    .font(.system(size: 9.5, weight: (!zoomController.isFitMode && zoomController.zoomPercentage == 100) ? .bold : .regular))
                    .foregroundColor((!zoomController.isFitMode && zoomController.zoomPercentage == 100) ? .accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help("Actual pixel size (100%)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.75)
        )
        .cornerRadius(6)
        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    private func ocrHeaderBar(ocrText: String) -> some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 9))
                Text("RECOGNIZED TEXT")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(.secondary.opacity(0.7))

            Spacer()

            Text("\(ocrText.count) chars")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
    }

    private func ocrTextSection(ocrText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 9))
                    Text("RECOGNIZED TEXT")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.secondary.opacity(0.7))

                Spacer()

                Text("\(ocrText.count) chars")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            ScrollView {
                Text(ocrText)
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 75)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.015))
    }

    private var compactMetadataBar: some View {
        HStack(spacing: 8) {
            if let payload = previewPayload {
                Text("\(payload.metadata.pixelDimensionsString) px (\(payload.metadata.aspectRatioString))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)

                Text("•")
                    .foregroundColor(.secondary.opacity(0.4))

                Text(payload.metadata.format)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)

                Text("•")
                    .foregroundColor(.secondary.opacity(0.4))

                Text(formattedByteSize(payload.metadata.byteSize))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)

                if let cs = payload.metadata.colorSpace {
                    Text("•")
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(cs)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            } else {
                Text(formattedByteSize(item.byteSize))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            Text("\(item.copyCount)x • \(relativeDateString(from: item.lastCopiedAtMs))")
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Actions

    private func loadAll() async {
        ocrState = .idle
        ocrViewMode = .split
        async let preview: () = loadPreview()
        async let ocr: () = loadOcrText()
        _ = await (preview, ocr)
    }

    private func loadPreview() async {
        hasError = false

        // Check synchronous cache first for instant display
        if let cached = ImagePreviewService.shared.cachedPreview(for: item.id) {
            self.previewPayload = cached
            self.isLoading = false
            return
        }

        self.previewPayload = nil
        self.isLoading = true

        // Debounce uncached SQLite + ImageIO decode during fast key-repeat scrubbing
        try? await Task.sleep(nanoseconds: 70_000_000)
        if Task.isCancelled { return }

        guard let client = coreClient else {
            self.isLoading = false
            self.hasError = true
            return
        }

        let primaryUti = item.availableUtis.first(where: {
            $0 == "public.png" || $0 == "public.heic" || $0 == "public.jpeg" || $0 == "public.tiff"
        })

        let result = await ImagePreviewService.shared.preview(
            for: item.id,
            utiHint: primaryUti
        ) {
            guard !Task.isCancelled,
                  let reps = try? await client.getItemRepresentations(itemId: item.id) else {
                return nil
            }
            let imageRep = reps.first(where: {
                $0.uti == "public.png" ||
                $0.uti == "public.heic" ||
                $0.uti == "public.jpeg" ||
                $0.uti == "public.tiff" ||
                $0.uti == "NSTypedPasteboardItemPboardType"
            })
            return imageRep?.payload
        }

        if !Task.isCancelled {
            self.previewPayload = result
            self.isLoading = false
            self.hasError = (result == nil)
        }
    }

    private func loadOcrText() async {
        guard let client = coreClient else {
            self.ocrState = .idle
            return
        }

        // Wait for user to pause on an image before querying/running heavy Vision OCR
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }

        self.ocrState = .loading

        // Check if OCR text is already stored in the database
        do {
            if let stored = try await client.getOcrText(itemId: item.id) {
                if Task.isCancelled { return }
                if stored.isEmpty {
                    self.ocrState = .noTextDetected
                } else {
                    self.ocrState = .success(text: stored)
                }
                return
            }
        } catch {
            // Ignore query error and fall back to on-demand OCR
        }

        if Task.isCancelled { return }

        // Otherwise retrieve image payload and perform on-device Vision recognition on-demand
        guard let reps = try? await client.getItemRepresentations(itemId: item.id),
              !Task.isCancelled,
              let imageRep = reps.first(where: {
                  $0.uti == "public.png" ||
                  $0.uti == "public.heic" ||
                  $0.uti == "public.jpeg" ||
                  $0.uti == "public.tiff"
              }) else {
            if !Task.isCancelled {
                self.ocrState = .noTextDetected
            }
            return
        }

        let currentItemId = item.id
        do {
            let extracted = try await withTaskCancellationHandler {
                try await OCRService.shared.recognizeAndIndex(
                    itemId: currentItemId,
                    imageData: imageRep.payload,
                    coreClient: client
                )
            } onCancel: {
                Task {
                    await OCRService.shared.cancel(itemId: currentItemId)
                }
            }
            if !Task.isCancelled {
                if extracted.isEmpty {
                    self.ocrState = .noTextDetected
                } else {
                    self.ocrState = .success(text: extracted)
                }
            }
        } catch is CancellationError {
            // Task was cancelled cleanly
        } catch {
            if !Task.isCancelled {
                self.ocrState = .failed(error: error.localizedDescription)
            }
        }
    }

    private func copyOcrTextToClipboard() {
        guard case .success(let text) = ocrState, !text.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()

        let pbItem = NSPasteboardItem()
        pbItem.setString(text, forType: .string)

        // Stamp provenance to prevent self-recapture loops (F-012, F-020)
        pbItem.setData(Data(), forType: ClipboardProvenance.provenanceType)
        pbItem.setString(ClipboardProvenance.mimraBundleIdentifier, forType: ClipboardProvenance.sourceAppType)

        let success = pb.writeObjects([pbItem])
        if success {
            ClipboardProvenance.shared.recordSelfWrite(on: pb)
            isOcrCopiedNotificationShown = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                isOcrCopiedNotificationShown = false
            }
        }
    }

    private func copyImageToClipboard() {
        guard let client = coreClient else { return }

        Task {
            guard let reps = try? await client.getItemRepresentations(itemId: item.id),
                  let imageRep = reps.first(where: {
                      $0.uti == "public.png" ||
                      $0.uti == "public.heic" ||
                      $0.uti == "public.jpeg" ||
                      $0.uti == "public.tiff"
                  }) else {
                return
            }

            let pb = NSPasteboard.general
            pb.clearContents()

            let pbItem = NSPasteboardItem()
            pbItem.setData(imageRep.payload, forType: NSPasteboard.PasteboardType(imageRep.uti))

            // Provide TIFF fallback for apps expecting standard TIFF pasteboard representation
            if let img = previewPayload?.image, let tiff = img.tiffRepresentation {
                pbItem.setData(tiff, forType: .tiff)
            }

            // Stamp provenance to prevent self-recapture loops (F-012, F-020)
            pbItem.setData(Data(), forType: ClipboardProvenance.provenanceType)
            pbItem.setString(ClipboardProvenance.mimraBundleIdentifier, forType: ClipboardProvenance.sourceAppType)

            let success = pb.writeObjects([pbItem])
            if success {
                ClipboardProvenance.shared.recordSelfWrite(on: pb)
                isCopiedNotificationShown = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                isCopiedNotificationShown = false
            }
        }
    }

    private func formattedByteSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func formattedByteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func relativeDateString(from timestampMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
