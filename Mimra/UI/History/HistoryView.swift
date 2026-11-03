// ==============================================================================
// Mimra — History View (Persistence UI Stub)
// Displays recent clipboard history items retrieved from SQLite via CoreClient.
// Linked Features: F-052
// Test IDs: T-HIST-02
// ==============================================================================

import SwiftUI

public struct HistoryView: View {
    @State private var items: [HistoryItemSummaryDto] = []
    @State private var stats: StorageStatsDto?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    public let coreClient: CoreClient

    public init(coreClient: CoreClient) {
        self.coreClient = coreClient
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Clipboard History")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                if let stats = stats {
                    Text("\(stats.totalItems) items (\(formatBytes(stats.dbSizeBytes)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    Task { await loadData() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Refresh history")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // List of history items or empty placeholder
            if isLoading && items.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading clipboard history...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No Clipboard Items")
                        .font(.headline)
                    Text("Items copied to the clipboard will appear here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(items, id: \.id) { item in
                        HistoryRowView(item: item)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer action bar
            HStack {
                Button(role: .destructive, action: {
                    Task {
                        _ = try? await coreClient.clearUnpinned()
                        await loadData()
                    }
                }) {
                    Text("Clear Unpinned")
                        .font(.caption)
                }

                Spacer()

                Button(role: .destructive, action: {
                    Task {
                        _ = try? await coreClient.clearAll()
                        await loadData()
                    }
                }) {
                    Text("Clear All")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 420, minHeight: 320)
        .task {
            await loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mimraClipboardDidIngest)) { _ in
            Task { await loadData() }
        }
    }

    private func loadData() async {
        isLoading = true
        do {
            let loaded = try await coreClient.listPage(limit: 50, offset: 0)
            let loadedStats = try await coreClient.getStats()
            await MainActor.run {
                self.items = loaded
                self.stats = loadedStats
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// Row view displaying an individual clipboard history entry.
struct HistoryRowView: View {
    let item: HistoryItemSummaryDto

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconForKind(item.contentKind))
                .foregroundColor(.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.body)
                        .lineLimit(1)

                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }

                    Spacer()

                    if item.copyCount > 1 {
                        Text("\(item.copyCount)x")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                }

                if !item.snippet.isEmpty {
                    Text(item.snippet)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func iconForKind(_ kind: String) -> String {
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
