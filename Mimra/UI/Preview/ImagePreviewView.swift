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

/// SwiftUI View rendering image previews with high fidelity and aspect ratio scaling.
@MainActor
public struct ImagePreviewView: View {
    public let item: HistoryItemSummaryDto
    public let coreClient: CoreClient?

    @State private var previewPayload: ImagePreviewPayload? = nil
    @State private var isLoading: Bool = true
    @State private var hasError: Bool = false
    @State private var isCopiedNotificationShown: Bool = false
    @State private var ocrState: OCRDisplayState = .idle
    @State private var isOcrCopiedNotificationShown: Bool = false

    public init(item: HistoryItemSummaryDto, coreClient: CoreClient? = nil) {
        self.item = item
        self.coreClient = coreClient
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Image Details Toolbar (Dimensions, Format, Byte Size, Quick Copy)
            toolbarBar

            Divider().opacity(0.2)

            // Main Canvas Area with Aspect Ratio preservation
            ZStack {
                // Subtle transparent checkerboard backdrop
                CheckerboardBackdropView()

                if let payload = previewPayload {
                    Image(nsImage: payload.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                        .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 3)
                } else if isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading preview...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Optional Recognized Text Drawer (if text recognized by on-device Vision)
            if case .success(let ocrText) = ocrState, !ocrText.isEmpty {
                Divider().opacity(0.2)
                ocrTextSection(ocrText: ocrText)
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
            if let payload = previewPayload {
                // Dimensions & Aspect Ratio Pill
                HStack(spacing: 4) {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 9))
                    Text("\(payload.metadata.pixelDimensionsString) px")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text("(\(payload.metadata.aspectRatioString))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .foregroundColor(.secondary)

                Text("•")
                    .foregroundColor(.secondary.opacity(0.4))

                // Format Pill
                Text(payload.metadata.format)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
                    .foregroundColor(.primary)

                Text("•")
                    .foregroundColor(.secondary.opacity(0.4))

                // File Size Pill
                Text(formattedByteSize(payload.metadata.byteSize))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                if let colorSpace = payload.metadata.colorSpace {
                    Text("•")
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(colorSpace)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            } else {
                Text(formattedByteSize(item.byteSize))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // OCR Extraction Status & Action (F-044, T-OCR-02)
            ocrToolbarItem

            Text("•")
                .foregroundColor(.secondary.opacity(0.3))

            // Quick Copy Image Action
            Button(action: copyImageToClipboard) {
                HStack(spacing: 3) {
                    Image(systemName: isCopiedNotificationShown ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                    Text(isCopiedNotificationShown ? "Copied" : "Copy Image")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(isCopiedNotificationShown ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy original image to clipboard")
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
                Text("Scanning text...")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        case .success(let ocrText):
            if !ocrText.isEmpty {
                Button(action: copyOcrTextToClipboard) {
                    HStack(spacing: 3) {
                        Image(systemName: isOcrCopiedNotificationShown ? "checkmark" : "text.viewfinder")
                            .font(.system(size: 10))
                        Text(isOcrCopiedNotificationShown ? "Copied Text" : "Copy OCR Text")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(isOcrCopiedNotificationShown ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy extracted OCR text to clipboard")
            }
        case .noTextDetected:
            HStack(spacing: 3) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 9))
                Text("No text")
                    .font(.system(size: 9))
            }
            .foregroundColor(.secondary.opacity(0.5))
            .help("On-device Vision scanned this image and found no readable text")
        case .failed(let error):
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                Text("OCR error")
                    .font(.system(size: 9))
            }
            .foregroundColor(.secondary.opacity(0.6))
            .help("OCR extraction failed: \(error)")
        }
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
        HStack(spacing: 12) {
            Text(formattedByteSize(item.byteSize))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)

            Text("\(item.copyCount)x copied")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            Spacer()

            Text("Last copied \(relativeDateString(from: item.lastCopiedAtMs))")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Actions

    private func loadAll() async {
        ocrState = .idle
        async let preview: () = loadPreview()
        async let ocr: () = loadOcrText()
        _ = await (preview, ocr)
    }

    private func loadPreview() async {
        isLoading = true
        hasError = false

        // Check synchronous cache first
        if let cached = ImagePreviewService.shared.cachedPreview(for: item.id) {
            self.previewPayload = cached
            self.isLoading = false
            return
        }

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
            guard let reps = try? await client.getItemRepresentations(itemId: item.id) else {
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

        // Otherwise retrieve image payload and perform on-device Vision recognition on-demand
        guard let reps = try? await client.getItemRepresentations(itemId: item.id),
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

        do {
            let extracted = try await OCRService.shared.recognizeAndIndex(
                itemId: item.id,
                imageData: imageRep.payload,
                coreClient: client
            )
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
