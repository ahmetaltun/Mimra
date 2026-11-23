// ==============================================================================
// Mimra — File Reference Preview View
// Rich preview for copied file URLs: native Finder icon, existence badge,
// file metadata, Reveal in Finder, Copy Path, and safe inline quick preview.
// ==============================================================================

import AppKit
import SwiftUI

/// Parsed file entry for preview display.
public struct PreviewFileEntry: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let path: String
    public let name: String
    public let exists: Bool
    public let isDirectory: Bool
    public let fileSize: Int64?
    public let modifiedAt: Date?
}

@MainActor
public struct FilePreviewView: View {
    public let item: HistoryItemSummaryDto
    public let coreClient: CoreClient?

    @State private var entries: [PreviewFileEntry] = []
    @State private var inlineImage: NSImage? = nil
    @State private var inlineText: String? = nil
    @State private var copiedPathId: String? = nil

    public init(item: HistoryItemSummaryDto, coreClient: CoreClient? = nil) {
        self.item = item
        self.coreClient = coreClient
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if entries.isEmpty {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .textSelection(.enabled)
                } else {
                    ForEach(entries) { entry in
                        fileCard(for: entry)
                    }

                    if let img = inlineImage {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("FILE PREVIEW")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.7))

                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 240)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        }
                    } else if let text = inlineText {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("FILE CONTENTS PREVIEW")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.7))

                            Text(text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(6)
                        }
                    }
                }
            }
            .padding(12)
        }
        .task(id: item.id) {
            await loadFileEntries()
        }
    }

    private func fileCard(for entry: PreviewFileEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                    .resizable()
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)

                        Text(entry.exists ? "Available" : "Missing")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((entry.exists ? Color.green : Color.orange).opacity(0.15))
                            .foregroundColor(entry.exists ? .green : .orange)
                            .cornerRadius(4)
                    }

                    Text(entry.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 10) {
                if let size = entry.fileSize, !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                } else if entry.isDirectory {
                    Text("Folder")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                if let mod = entry.modifiedAt {
                    Text("•")
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Modified \(mod.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { copyPath(entry.path, id: entry.id) }) {
                    HStack(spacing: 3) {
                        Image(systemName: copiedPathId == entry.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(copiedPathId == entry.id ? "Copied" : "Copy Path")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(copiedPathId == entry.id ? .green : .secondary)
                }
                .buttonStyle(.plain)

                if entry.exists {
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                            Text("Reveal")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func loadFileEntries() async {
        inlineImage = nil
        inlineText = nil

        var rawLines: [String] = []
        if let client = coreClient,
           let reps = try? await client.getItemRepresentations(itemId: item.id) {
            let fileReps = reps.filter { $0.uti == "public.file-url" }
            for rep in fileReps {
                if let str = String(data: rep.payload, encoding: .utf8) {
                    rawLines.append(contentsOf: str.components(separatedBy: .newlines))
                }
            }
        }
        if rawLines.isEmpty {
            rawLines = item.snippet.components(separatedBy: .newlines)
        }

        var parsed: [PreviewFileEntry] = []
        var seenPaths = Set<String>()

        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let resolvedUrl: URL?
            if trimmed.hasPrefix("file://") {
                if let u = URL(string: trimmed) {
                    resolvedUrl = (u as NSURL).filePathURL ?? u
                } else {
                    resolvedUrl = nil
                }
            } else if trimmed.hasPrefix("/") {
                resolvedUrl = URL(fileURLWithPath: trimmed)
            } else {
                resolvedUrl = nil
            }

            guard let url = resolvedUrl else { continue }
            let path = url.path
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            var size: Int64? = nil
            var modDate: Date? = nil
            if exists, let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                size = (attrs[.size] as? NSNumber)?.int64Value
                modDate = attrs[.modificationDate] as? Date
            }

            parsed.append(PreviewFileEntry(
                id: path,
                url: url,
                path: path,
                name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                exists: exists,
                isDirectory: isDir.boolValue,
                fileSize: size,
                modifiedAt: modDate
            ))
        }

        if Task.isCancelled { return }
        self.entries = parsed

        // Inline preview for single existing file (bounded size)
        if parsed.count == 1, let first = parsed.first, first.exists, !first.isDirectory {
            let ext = first.url.pathExtension.lowercased()
            let imageExts = Set(["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp"])
            let textExts = Set(["txt", "md", "markdown", "json", "yaml", "yml", "swift", "rs", "py", "ts", "js", "log", "csv"])
            let size = first.fileSize ?? 0

            if imageExts.contains(ext), size <= 10 * 1024 * 1024 {
                if let data = try? Data(contentsOf: first.url),
                   let decoded = ImagePreviewService.decodePreview(from: data, maxPixelSize: 1200) {
                    if !Task.isCancelled {
                        self.inlineImage = decoded.image
                    }
                }
            } else if textExts.contains(ext), size <= 128 * 1024 {
                if let content = try? String(contentsOf: first.url, encoding: .utf8) {
                    if !Task.isCancelled {
                        self.inlineText = String(content.prefix(4000))
                    }
                }
            }
        }
    }

    private func copyPath(_ path: String, id: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let pbItem = NSPasteboardItem()
        pbItem.setString(path, forType: .string)
        pbItem.setData(Data(), forType: ClipboardProvenance.provenanceType)
        pbItem.setString(ClipboardProvenance.mimraBundleIdentifier, forType: ClipboardProvenance.sourceAppType)
        if pb.writeObjects([pbItem]) {
            ClipboardProvenance.shared.recordSelfWrite(on: pb)
            copiedPathId = id
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if copiedPathId == id { copiedPathId = nil }
            }
        }
    }
}
