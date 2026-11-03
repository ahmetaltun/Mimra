import SwiftUI
import Foundation
import AppKit

// ==============================================================================
// Mimra — Storage Settings View Model (P4-06 / F-025, F-055, T-HIST-01, T-HIST-05)
// Off-main actor storage metrics, retention sweeps, and distinct clear confirmations.
// ==============================================================================

@MainActor
public final class StorageSettingsViewModel: ObservableObject {
    public let coreClient: CoreClient

    @Published public var stats: StorageStatsDto? = nil
    @Published public var isLoading: Bool = false
    @Published public var isPerformingAction: Bool = false
    @Published public var statusMessage: String? = nil
    @Published public var isErrorMessage: Bool = false

    // Alerts for distinct confirmations (F-025, T-HIST-01)
    @Published public var showClearUnpinnedAlert: Bool = false
    @Published public var showClearAllAlert: Bool = false

    // Retention policy settings (F-055, P4-05)
    // 0 represents unlimited / disabled for that dimension
    @Published public var maxCount: Int {
        didSet {
            UserDefaults.standard.set(maxCount, forKey: "retentionMaxCount")
            syncPolicyToEngine()
        }
    }
    @Published public var maxAgeDays: Int {
        didSet {
            UserDefaults.standard.set(maxAgeDays, forKey: "retentionMaxAgeDays")
            syncPolicyToEngine()
        }
    }
    @Published public var maxSizeBytes: Int64 {
        didSet {
            UserDefaults.standard.set(maxSizeBytes, forKey: "retentionMaxSizeBytes")
            syncPolicyToEngine()
        }
    }

    public init(coreClient: CoreClient? = nil) {
        self.coreClient = coreClient ?? CoreClient.shared

        // Load persisted preferences or fallback to sensible defaults
        let savedCount = UserDefaults.standard.object(forKey: "retentionMaxCount") as? Int ?? 200
        let savedAge = UserDefaults.standard.object(forKey: "retentionMaxAgeDays") as? Int ?? 30
        let savedSize = UserDefaults.standard.object(forKey: "retentionMaxSizeBytes") as? Int64 ?? (100 * 1024 * 1024)

        self.maxCount = savedCount
        self.maxAgeDays = savedAge
        self.maxSizeBytes = savedSize

        // Sync initial policy to engine
        syncPolicyToEngine()
    }

    public var formattedDbSize: String {
        guard let stats = stats else { return "Calculating..." }
        return ByteCountFormatter.string(fromByteCount: Int64(stats.dbSizeBytes), countStyle: .file)
    }

    public var currentPolicyDto: RetentionPolicyDto {
        RetentionPolicyDto(
            maxCount: maxCount > 0 ? UInt32(maxCount) : nil,
            maxAgeDays: maxAgeDays > 0 ? UInt32(maxAgeDays) : nil,
            maxSizeBytes: maxSizeBytes > 0 ? UInt64(maxSizeBytes) : nil
        )
    }

    public func syncPolicyToEngine() {
        let policy = currentPolicyDto
        Task {
            await coreClient.setRetentionPolicy(policy: policy)
        }
    }

    public func loadStats() async {
        isLoading = true
        do {
            let s = try await coreClient.getStats()
            self.stats = s
        } catch {
            self.statusMessage = "Failed to load database stats: \(error.localizedDescription)"
            self.isErrorMessage = true
        }
        isLoading = false
    }

    public func applyRetentionPolicy() async {
        isPerformingAction = true
        statusMessage = nil
        do {
            let policy = currentPolicyDto
            await coreClient.setRetentionPolicy(policy: policy)
            let report = try await coreClient.enforceRetention(policy: policy)
            _ = try? await coreClient.checkpointWal()
            await loadStats()
            let freedStr = ByteCountFormatter.string(fromByteCount: Int64(report.freedBytes), countStyle: .file)
            self.statusMessage = "Retention policy applied: Evicted \(report.totalEvicted) unpinned items, freed \(freedStr)."
            self.isErrorMessage = false
        } catch {
            self.statusMessage = "Failed to enforce retention: \(error.localizedDescription)"
            self.isErrorMessage = true
        }
        isPerformingAction = false
    }

    public func optimizeDatabase() async {
        isPerformingAction = true
        statusMessage = nil
        do {
            _ = try await coreClient.checkpointWal()
            try await coreClient.vacuumDatabase()
            await loadStats()
            self.statusMessage = "Database optimization completed. WAL checkpointed and freed pages reclaimed."
            self.isErrorMessage = false
        } catch {
            self.statusMessage = "Failed to optimize database: \(error.localizedDescription)"
            self.isErrorMessage = true
        }
        isPerformingAction = false
    }

    public func confirmClearUnpinned() async {
        isPerformingAction = true
        statusMessage = nil
        do {
            let count = try await coreClient.clearUnpinned()
            _ = try? await coreClient.checkpointWal()
            await loadStats()
            self.statusMessage = "Cleared \(count) unpinned items. Pinned items were preserved."
            self.isErrorMessage = false
        } catch {
            self.statusMessage = "Failed to clear unpinned items: \(error.localizedDescription)"
            self.isErrorMessage = true
        }
        isPerformingAction = false
    }

    public func confirmClearAll() async {
        isPerformingAction = true
        statusMessage = nil
        do {
            let count = try await coreClient.clearAll()
            _ = try? await coreClient.checkpointWal()
            try? await coreClient.vacuumDatabase()
            await loadStats()
            self.statusMessage = "Permanently cleared all \(count) history items and pinned clips."
            self.isErrorMessage = false
        } catch {
            self.statusMessage = "Failed to clear all history: \(error.localizedDescription)"
            self.isErrorMessage = true
        }
        isPerformingAction = false
    }

    public var recoveryReport: DatabaseRecoveryReportDto? {
        coreClient.recoveryReport
    }

    public func verifyDatabaseIntegrity() async {
        isPerformingAction = true
        statusMessage = nil
        do {
            try await coreClient.verifyIntegrity()
            self.statusMessage = "Database integrity check passed: B-tree, foreign keys, and FTS5 search index are 100% valid."
            self.isErrorMessage = false
        } catch {
            self.statusMessage = "Database integrity check failed: \(error.localizedDescription)"
            self.isErrorMessage = true
        }
        isPerformingAction = false
    }

    public func createBackup() async {
        let panel = NSSavePanel()
        panel.title = "Save Mimra Database Backup"
        panel.nameFieldStringValue = "mimra-backup-\(Int(Date().timeIntervalSince1970)).sqlite"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            isPerformingAction = true
            statusMessage = nil
            do {
                try await coreClient.backupDatabase(to: url.path)
                self.statusMessage = "Database backup saved to: \(url.lastPathComponent)"
                self.isErrorMessage = false
            } catch {
                self.statusMessage = "Failed to create backup: \(error.localizedDescription)"
                self.isErrorMessage = true
            }
            isPerformingAction = false
        }
    }
}

// ==============================================================================
// Mimra — Storage Settings Tab View
// ==============================================================================

public struct StorageSettingsTab: View {
    @ObservedObject public var viewModel: StorageSettingsViewModel

    // Format enablement settings (F-013, F-015, T-TYPE-05)
    @AppStorage(ClipboardTypeConfiguration.storePlainTextKey) private var storePlainText: Bool = true
    @AppStorage(ClipboardTypeConfiguration.storeRichTextKey) private var storeRichText: Bool = true
    @AppStorage(ClipboardTypeConfiguration.storeImagesKey) private var storeImages: Bool = true
    @AppStorage(ClipboardTypeConfiguration.storeFilesKey) private var storeFiles: Bool = true

    public init(viewModel: StorageSettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            if let message = viewModel.statusMessage {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.isErrorMessage ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(viewModel.isErrorMessage ? .red : .green)
                        Text(message)
                            .font(.callout)
                            .foregroundColor(viewModel.isErrorMessage ? .red : .primary)
                        Spacer()
                        Button(action: { viewModel.statusMessage = nil }) {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Database Metrics") {
                LabeledContent("Database Disk Size", value: viewModel.formattedDbSize)
                LabeledContent("Total History Items", value: "\(viewModel.stats?.totalItems ?? 0)")
                LabeledContent("Pinned Items (Protected)", value: "\(viewModel.stats?.pinnedItems ?? 0)")
                LabeledContent("Unpinned Items", value: "\(viewModel.stats?.unpinnedItems ?? 0)")
                LabeledContent("Data Representations", value: "\(viewModel.stats?.totalRepresentations ?? 0)")

                HStack {
                    Button(action: {
                        Task { await viewModel.optimizeDatabase() }
                    }) {
                        Label("Optimize Database", systemImage: "sparkles")
                    }
                    .disabled(viewModel.isPerformingAction || viewModel.isLoading)

                    Button(action: {
                        Task { await viewModel.loadStats() }
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }
            }

            Section("History Retention Limits") {
                Picker("Item Count Limit", selection: $viewModel.maxCount) {
                    Text("50 items").tag(50)
                    Text("100 items").tag(100)
                    Text("200 items (Recommended)").tag(200)
                    Text("500 items").tag(500)
                    Text("1,000 items").tag(1000)
                    Text("Unlimited").tag(0)
                }

                Picker("Retention Duration", selection: $viewModel.maxAgeDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days (Recommended)").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("365 days (1 Year)").tag(365)
                    Text("Unlimited").tag(0)
                }

                Picker("Storage Budget", selection: $viewModel.maxSizeBytes) {
                    Text("25 MB").tag(Int64(25 * 1024 * 1024))
                    Text("50 MB").tag(Int64(50 * 1024 * 1024))
                    Text("100 MB (Recommended)").tag(Int64(100 * 1024 * 1024))
                    Text("250 MB").tag(Int64(250 * 1024 * 1024))
                    Text("500 MB").tag(Int64(500 * 1024 * 1024))
                    Text("1 GB").tag(Int64(1024 * 1024 * 1024))
                    Text("Unlimited").tag(Int64(0))
                }

                HStack {
                    Button(action: {
                        Task { await viewModel.applyRetentionPolicy() }
                    }) {
                        Label("Apply & Enforce Retention", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(viewModel.isPerformingAction || viewModel.isLoading)
                }

                Text("Unpinned items exceeding count, age, or storage limits are automatically pruned. Pinned items are 100% immune to retention eviction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Supported Formats") {
                Toggle("Plain text & URLs", isOn: $storePlainText)
                Toggle("Rich text (HTML & RTF)", isOn: $storeRichText)
                Toggle("Images (PNG, TIFF, JPEG, HEIC)", isOn: $storeImages)
                Toggle("File references", isOn: $storeFiles)
            }

            Section("History Clear Actions") {
                HStack(spacing: 12) {
                    Button(action: {
                        viewModel.showClearUnpinnedAlert = true
                    }) {
                        Label("Clear Unpinned...", systemImage: "trash")
                    }
                    .disabled(viewModel.isPerformingAction)

                    Button(role: .destructive, action: {
                        viewModel.showClearAllAlert = true
                    }) {
                        Label("Clear All History...", systemImage: "trash.fill")
                    }
                    .disabled(viewModel.isPerformingAction)
                }

                Text("Clearing unpinned history keeps pinned items intact. Clearing all permanently erases all clips including pinned anchors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Backup & Recovery") {
                if let report = viewModel.recoveryReport, report.wasRecovered {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Database Recovered", systemImage: "bandage.fill")
                            .font(.headline)
                            .foregroundColor(.orange)
                        Text("A damaged database was detected and quarantined at:")
                            .font(.caption)
                        Text(report.quarantinedBackupPath ?? "Unknown path")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Salvaged \(report.salvagedItemsCount) items into fresh database.")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 4)
                }

                HStack(spacing: 12) {
                    Button(action: {
                        Task { await viewModel.createBackup() }
                    }) {
                        Label("Create Backup...", systemImage: "arrow.down.doc")
                    }
                    .disabled(viewModel.isPerformingAction)

                    Button(action: {
                        Task { await viewModel.verifyDatabaseIntegrity() }
                    }) {
                        Label("Verify Integrity", systemImage: "checkmark.shield")
                    }
                    .disabled(viewModel.isPerformingAction)
                }

                Text("Backups are atomic and crash-consistent snapshots. Database integrity verification checks table consistency, foreign keys, and FTS5 search index triggers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Clear Unpinned History?", isPresented: $viewModel.showClearUnpinnedAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Unpinned", role: .destructive) {
                Task {
                    await viewModel.confirmClearUnpinned()
                }
            }
        } message: {
            Text("This will permanently remove all unpinned items from clipboard history. Pinned clips will not be deleted.")
        }
        .alert("Clear All History (Including Pinned)?", isPresented: $viewModel.showClearAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All Items", role: .destructive) {
                Task {
                    await viewModel.confirmClearAll()
                }
            }
        } message: {
            Text("This will permanently delete ALL clipboard history items, including all pinned clips. This action cannot be undone.")
        }
        .task {
            await viewModel.loadStats()
        }
    }
}

// ==============================================================================
// Mimra — Main Settings View
// ==============================================================================

public struct SettingsView: View {
    @State private var engineVersion: String = coreVersion()
    @ObservedObject private var accessibilityService = AccessibilityService.shared
    @StateObject private var storageViewModel: StorageSettingsViewModel

    @AppStorage("pasteAutomatically") private var pasteAutomatically: Bool = true
    @AppStorage("cycleModeEnabled") private var cycleModeEnabled: Bool = true
    @AppStorage("showColorSwatches") private var showColorSwatches: Bool = true
    @AppStorage("showUrlPreviews") private var showUrlPreviews: Bool = true
    @AppStorage("showSourceAppIcon") private var showSourceAppIcon: Bool = true

    // Slideout Preview preferences (P6-02 / F-040, T-PREV-02)
    @AppStorage("previewAutoOpenEnabled") private var previewAutoOpenEnabled: Bool = false
    @AppStorage("previewDelayMs") private var previewDelayMs: Int = 400

    // Search and sorting preferences (P4-04 / F-019, F-024, F-050, F-054)
    @AppStorage("searchHighlightStyle") private var searchHighlightStyleRaw: String = SearchHighlightStyle.bold.rawValue
    @AppStorage("pinArrangement") private var pinArrangementRaw: String = "top"
    @AppStorage("historySortMode") private var historySortModeRaw: String = "recency"
    @AppStorage("searchByRelevance") private var searchByRelevance: Bool = true

    public init(coreClient: CoreClient? = nil) {
        _storageViewModel = StateObject(wrappedValue: StorageSettingsViewModel(coreClient: coreClient))
    }

    public var body: some View {
        TabView {
            Form {
                Section("Application") {
                    LabeledContent("Name", value: "Mimra")
                    LabeledContent("Platform", value: "macOS 15.0+ (Apple Silicon)")
                    LabeledContent("Status", value: "Menu Bar Agent Active")
                }

                Section("Paste Behavior & Permissions") {
                    Toggle("Paste automatically into target app", isOn: $pasteAutomatically)

                    HStack {
                        Text("Accessibility Permission")
                        Spacer()
                        if accessibilityService.isTrusted {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button("Grant Permission...") {
                                accessibilityService.promptForPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    if !accessibilityService.isTrusted {
                        HStack {
                            Text("Copy-Only Mode active until permission is granted in macOS System Settings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Open System Settings") {
                                accessibilityService.openSystemSettings()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }

                Section("Summon & Keyboard Cycling") {
                    Toggle("Cycle through history with summon key", isOn: $cycleModeEnabled)
                    Text("Hold the summon shortcut modifier and press the summon key again to cycle through items. Releasing the modifier commits the selection (Quick Switcher).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Engine Core") {
                    LabeledContent("RustCore Engine", value: "v\(engineVersion)")
                    LabeledContent("Deduplication", value: "BLAKE3 Cryptographic Hashing")
                    LabeledContent("Search & Storage", value: "SQLite + FTS5 (WAL Mode)")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gear")
            }

            Form {
                Section("Item Previews") {
                    Toggle("Show HEX color swatch", isOn: $showColorSwatches)
                    Toggle("Show URL domain badges", isOn: $showUrlPreviews)
                    Toggle("Show source application icon", isOn: $showSourceAppIcon)
                }

                Section("Slideout Preview") {
                    Toggle("Open preview automatically on selection", isOn: $previewAutoOpenEnabled)

                    if previewAutoOpenEnabled {
                        Picker("Auto-Open Delay", selection: $previewDelayMs) {
                            Text("Fast (200 ms)").tag(200)
                            Text("Normal (400 ms)").tag(400)
                            Text("Relaxed (600 ms)").tag(600)
                            Text("Slow (1000 ms)").tag(1000)
                        }
                    }

                    Text("Toggle manually anytime inside history using ⌃Space (Control-Space). Shortcut is strictly local to the history window and never registered globally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Information") {
                    Text("When color swatches are enabled, recognized #RGB and #RRGGBB color codes display an inline visual color swatch. Copied text remains the primary payload on paste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Appearance", systemImage: "paintpalette")
            }

            Form {
                Section("Search Highlights") {
                    Picker("Match Highlight Style", selection: $searchHighlightStyleRaw) {
                        ForEach(SearchHighlightStyle.allCases, id: \.rawValue) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                }

                Section("History Sorting & Pins") {
                    Picker("Pin Placement", selection: $pinArrangementRaw) {
                        Text("Top of list").tag("top")
                        Text("Bottom of list").tag("bottom")
                        Text("Inline (mixed)").tag("inline")
                    }

                    Picker("Sort History By", selection: $historySortModeRaw) {
                        Text("Recency (last copied)").tag("recency")
                        Text("Number of copies").tag("copyCount")
                        Text("First copied (creation)").tag("firstCopied")
                    }

                    Toggle("Rank search results by relevance", isOn: $searchByRelevance)
                }

                Section("Information") {
                    Text("Highlight styles indicate matching characters in titles and snippets during active searches. Pin placement controls whether pinned clips stay grouped at the top, bottom, or naturally mixed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Search & Sorting", systemImage: "arrow.up.arrow.down.circle")
            }

            StorageSettingsTab(viewModel: storageViewModel)
                .tabItem {
                    Label("Storage", systemImage: "cylinder.split.1x2")
                }

            Form {
                Section("Security & Privacy") {
                    Text("Mimra excludes sensitive markers from password managers and ignored applications before any data reaches disk.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    
                    LabeledContent("Network Access", value: "Zero (Strictly Offline)")
                    LabeledContent("Telemetry", value: "Disabled")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Privacy", systemImage: "hand.raised")
            }
        }
        .frame(width: 540, height: 480)
        .task {
            accessibilityService.startObserving()
        }
        .onDisappear {
            accessibilityService.stopObserving()
        }
    }
}
