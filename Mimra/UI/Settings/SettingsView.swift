import SwiftUI
import Foundation
import AppKit
import Carbon

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
        await OCRService.shared.cancelAll()
        if UserDefaults.standard.bool(forKey: "clearSystemClipboard") {
            NSPasteboard.general.clearContents()
        }
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
        await OCRService.shared.cancelAll()
        if UserDefaults.standard.bool(forKey: "clearSystemClipboard") {
            NSPasteboard.general.clearContents()
        }
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
                    Text("2,000 items (Maximum Limit)").tag(2000)
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
// Mimra — General Settings Tab (P7-01 / F-020, F-056, F-062, F-064, T-SET-01, T-REL-01)
// Launch at login, paste mode, audio feedback, and system clipboard cleansing.
// ==============================================================================

public struct GeneralSettingsTab: View {
    @ObservedObject var launchAtLoginService = LaunchAtLoginService.shared
    @ObservedObject var soundService = SoundFeedbackService.shared
    @ObservedObject var accessibilityService = AccessibilityService.shared
    @ObservedObject var localizationService = LocalizationService.shared

    @AppStorage("pasteAutomatically") private var pasteAutomatically: Bool = true
    @AppStorage("moveToTopOnPaste") private var moveToTopOnPaste: Bool = true
    @AppStorage("clearSystemClipboard") private var clearSystemClipboard: Bool = false
    @AppStorage("cycleModeEnabled") private var cycleModeEnabled: Bool = true
    @AppStorage("retentionMaxCount") private var maxHistoryItems: Int = 200

    let engineVersion: String

    public init(engineVersion: String = coreVersion()) {
        self.engineVersion = engineVersion
    }

    public var body: some View {
        Form {
            Section("Launch & Startup") {
                Toggle("Launch Mimra at login", isOn: Binding(
                    get: { launchAtLoginService.isEnabled },
                    set: { launchAtLoginService.setEnabled($0) }
                ))
                .disabled(!launchAtLoginService.isSupported)

                if launchAtLoginService.requiresApproval {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Approval required in macOS System Settings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Open Login Items") {
                            launchAtLoginService.openSystemSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                } else if !launchAtLoginService.isSupported {
                    Text("Launch at login requires Mimra to run as a packaged application bundle.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let errorMsg = launchAtLoginService.lastErrorMessage {
                    Text(errorMsg)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section("Language & Localization") {
                Picker("Language", selection: $localizationService.currentLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }

                Text("Supports English, Japanese, German, Turkish, and Arabic with automatic layout expansion and RTL text direction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History Item Limit") {
                Picker("Maximum History Items", selection: $maxHistoryItems) {
                    Text("50 items").tag(50)
                    Text("100 items").tag(100)
                    Text("200 items (Recommended)").tag(200)
                    Text("500 items").tag(500)
                    Text("1,000 items").tag(1000)
                    Text("2,000 items (Maximum Limit)").tag(2000)
                }
                .onChange(of: maxHistoryItems) { _, newValue in
                    let age = UserDefaults.standard.object(forKey: "retentionMaxAgeDays") as? Int ?? 30
                    let size = UserDefaults.standard.object(forKey: "retentionMaxSizeBytes") as? Int64 ?? (100 * 1024 * 1024)
                    let policy = RetentionPolicyDto(
                        maxCount: UInt32(newValue),
                        maxAgeDays: age > 0 ? UInt32(age) : nil,
                        maxSizeBytes: size > 0 ? UInt64(size) : nil
                    )
                    Task {
                        await CoreClient.shared.setRetentionPolicy(policy: policy)
                    }
                }

                Text("Controls the maximum number of items retained in history (solid limit: 2,000). When exceeded, older unpinned clips are automatically pruned. Pinned items are always preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paste Behavior & Permissions") {
                Toggle("Paste automatically into target app", isOn: $pasteAutomatically)

                Text("When enabled, selecting an item pastes it directly into the previous app. Hold ⌥ (Option) to copy without pasting. When disabled, selecting copies to clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Move item to top when chosen", isOn: $moveToTopOnPaste)

                Text("When enabled, selecting an item moves it to the top of the history list for quick repeated use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Section("Audio Feedback") {
                Toggle("Play sound on copy and paste", isOn: $soundService.isEnabled)

                if soundService.isEnabled {
                    HStack {
                        Picker("Sound Effect", selection: $soundService.selectedSound) {
                            ForEach(SoundEffect.allCases) { effect in
                                Text(effect.displayName).tag(effect)
                            }
                        }
                        .frame(maxWidth: 220)

                        Spacer()

                        Button("Test Sound") {
                            soundService.testSound()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Clipboard Cleansing") {
                Toggle("Clear system clipboard when clearing history", isOn: $clearSystemClipboard)

                Text("When clearing unpinned items or clearing all history, also clear macOS's active system pasteboard so no content remains in the system clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Summon & Keyboard Cycling") {
                Toggle("Cycle through history with summon key", isOn: $cycleModeEnabled)
                Text("Hold the summon shortcut modifier and press the summon key again to cycle through items. Releasing the modifier commits the selection (Quick Switcher).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Educational Guide & Privacy") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome & Privacy Guide")
                            .font(.body)
                        Text("Review continuous history, Accessibility auto-paste, sensitive exclusions, and privacy safeguards.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Guide...") {
                        OnboardingWindowController.shared.show()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Open Welcome & Privacy Guide")
                }
            }

            Section("Application & Engine Core") {
                LabeledContent("Platform", value: "macOS 15.0+ (Apple Silicon)")
                LabeledContent("Status", value: "Menu Bar Agent Active")
                LabeledContent("RustCore Engine", value: "v\(engineVersion)")
                LabeledContent("Deduplication", value: "BLAKE3 Cryptographic Hashing")
                LabeledContent("Search & Storage", value: "SQLite + FTS5 (WAL Mode)")
            }
        }
        .formStyle(.grouped)
    }
}

// ==============================================================================
// Mimra — Appearance Settings Tab (P7-02 / F-028, F-032, F-034, F-035, F-058, T-SET-03)
// Visual customization: theme, elements visibility, position, menu bar, and dimensions.
// ==============================================================================

public struct AppearanceSettingsTab: View {
    @ObservedObject var appearanceConfig = AppearanceConfiguration.shared

    @AppStorage("showColorSwatches") private var showColorSwatches: Bool = true
    @AppStorage("showUrlPreviews") private var showUrlPreviews: Bool = true
    @AppStorage("showSourceAppIcon") private var showSourceAppIcon: Bool = true

    // Slideout Preview preferences (P6-02 / F-040, Requirement 6)
    @AppStorage("previewDisplayMode") private var previewDisplayModeRaw: String = PreviewDisplayMode.manual.rawValue
    @AppStorage("previewAutoOpenEnabled") private var previewAutoOpenEnabled: Bool = false
    @AppStorage("previewDelayMs") private var previewDelayMs: Int = 400

    // Mouse hover selection preferences
    @AppStorage("hoverSelectionMode") private var hoverSelectionModeRaw: String = HoverSelectionMode.immediate.rawValue
    @AppStorage("hoverSelectionDelayMs") private var hoverSelectionDelayMs: Int = 250

    public init() {}

    public var body: some View {
        Form {
            Section("Theme & Display") {
                Picker("Application Theme", selection: $appearanceConfig.theme) {
                    ForEach(AppearanceTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
            }

            Section("Window Layout & Elements") {
                Toggle("Show search bar", isOn: $appearanceConfig.showSearchField)
                Toggle("Show window header title", isOn: $appearanceConfig.showTitle)
                Toggle("Show footer toolbar", isOn: $appearanceConfig.showFooter)

                Text("When the search bar or footer is hidden, searching by typing, keyboard navigation, and ⌘, (Command-,) settings remain fully accessible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Panel Positioning") {
                Picker("Position", selection: $appearanceConfig.positionMode) {
                    ForEach(PanelPositionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text("Controls where the history panel appears when summoned via global shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu Bar Customization") {
                Picker("Status Bar Icon", selection: $appearanceConfig.iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                Toggle("Show recent copy snippet in menu bar", isOn: $appearanceConfig.showRecentCopyInMenuBar)
            }

            Section("History Item Style") {
                Picker("Row Style", selection: $appearanceConfig.rowStyle) {
                    ForEach(HistoryRowStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text("Standard displays title and snippet preview on two lines. Compact displays single-line items, allowing significantly more clipboard clips to fit on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Item Previews in List") {
                Toggle("Show HEX color swatch", isOn: $showColorSwatches)
                Toggle("Show URL domain badges", isOn: $showUrlPreviews)
                Toggle("Show source application icon", isOn: $showSourceAppIcon)
            }

            Section("Dimensions & Sizing") {
                HStack {
                    Text("Panel Width")
                    Spacer()
                    Slider(value: Binding(
                        get: { Double(appearanceConfig.panelWidth) },
                        set: { appearanceConfig.panelWidth = CGFloat(round($0)) }
                    ), in: 340...640)
                    .frame(width: 160)
                    Text("\(Int(appearanceConfig.panelWidth)) pt")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                HStack {
                    Text("Panel Height")
                    Spacer()
                    Slider(value: Binding(
                        get: { Double(appearanceConfig.panelHeight) },
                        set: { appearanceConfig.panelHeight = CGFloat(round($0)) }
                    ), in: 360...1000)
                    .frame(width: 160)
                    Text("\(Int(appearanceConfig.panelHeight)) pt")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                HStack {
                    Text("Preview Width")
                    Spacer()
                    Slider(value: Binding(
                        get: { Double(appearanceConfig.previewWidth) },
                        set: { appearanceConfig.previewWidth = CGFloat(round($0)) }
                    ), in: 280...540)
                    .frame(width: 160)
                    Text("\(Int(appearanceConfig.previewWidth)) pt")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                Button("Reset Dimensions to Defaults") {
                    appearanceConfig.resetDimensionsToDefaults()
                }
            }

            Section("Mouse Hover Selection") {
                Picker("Hover Behavior", selection: Binding(
                    get: {
                        HoverSelectionMode(rawValue: hoverSelectionModeRaw) ?? .immediate
                    },
                    set: { newMode in
                        hoverSelectionModeRaw = newMode.rawValue
                        appearanceConfig.hoverSelectionMode = newMode
                    }
                )) {
                    ForEach(HoverSelectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if (HoverSelectionMode(rawValue: hoverSelectionModeRaw) ?? .immediate) == .delayed {
                    Picker("Hover Delay", selection: Binding(
                        get: {
                            hoverSelectionDelayMs
                        },
                        set: { newDelay in
                            hoverSelectionDelayMs = newDelay
                            appearanceConfig.hoverSelectionDelayMs = newDelay
                        }
                    )) {
                        Text("Snappy (150 ms)").tag(150)
                        Text("Normal (250 ms)").tag(250)
                        Text("Relaxed (400 ms)").tag(400)
                    }
                }

                Text(hoverDescription(for: HoverSelectionMode(rawValue: hoverSelectionModeRaw) ?? .immediate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Slideout Preview") {
                Picker("Preview Behavior", selection: Binding(
                    get: {
                        PreviewDisplayMode(rawValue: previewDisplayModeRaw) ?? (previewAutoOpenEnabled ? .delayed : .manual)
                    },
                    set: { newMode in
                        previewDisplayModeRaw = newMode.rawValue
                        previewAutoOpenEnabled = (newMode != .manual)
                    }
                )) {
                    Text("Hidden by default (Toggle with shortcut)").tag(PreviewDisplayMode.manual)
                    Text("Show immediately with history window").tag(PreviewDisplayMode.immediate)
                    Text("Show with delay on selection").tag(PreviewDisplayMode.delayed)
                }

                if (PreviewDisplayMode(rawValue: previewDisplayModeRaw) ?? (previewAutoOpenEnabled ? .delayed : .manual)) == .delayed {
                    Picker("Preview Delay", selection: $previewDelayMs) {
                        Text("Fast (200 ms)").tag(200)
                        Text("Normal (400 ms)").tag(400)
                        Text("Relaxed (600 ms)").tag(600)
                        Text("Slow (1000 ms)").tag(1000)
                    }
                }

                Text("Shortcut: Toggle preview anytime inside history using ⌃Space, ⌥Space, or ⌘Y.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func hoverDescription(for mode: HoverSelectionMode) -> String {
        switch mode {
        case .immediate:
            return "Moving the mouse cursor over an item selects it and updates the preview immediately."
        case .delayed:
            return "Moving the mouse across items won't trigger previews immediately. The cursor must pause on an item to select it."
        case .disabled:
            return "Cursor movement is ignored for selection. Navigate using keyboard arrow keys or click an item to commit."
        }
    }
}

// ==============================================================================
// Mimra — Search & Sorting Settings Tab (P7-03 / F-049, F-050, F-051, F-054)
// Search algorithms, match highlights, OCR indexing inclusion, and ordering.
// ==============================================================================

public struct SearchSettingsTab: View {
    @AppStorage("searchMode") private var searchModeRaw: String = "fuzzy"
    @AppStorage("searchHighlightStyle") private var searchHighlightStyleRaw: String = SearchHighlightStyle.bold.rawValue
    @AppStorage("pinArrangement") private var pinArrangementRaw: String = "top"
    @AppStorage("historySortMode") private var historySortModeRaw: String = "recency"
    @AppStorage("searchByRelevance") private var searchByRelevance: Bool = true
    @AppStorage("includeOcrInSearch") private var includeOcrInSearch: Bool = true

    public init() {}

    public var body: some View {
        Form {
            Section("Search Mode & Engine") {
                Picker("Algorithm", selection: $searchModeRaw) {
                    Text("Mixed / Fuzzy (Subsequence + Substring)").tag("fuzzy")
                    Text("Exact Substring").tag("exact")
                    Text("Regular Expression (Rust Regex)").tag("regex")
                }

                Toggle("Include recognized image text (OCR)", isOn: $includeOcrInSearch)

                Text("Fuzzy search matches acronyms and consecutive letters with recency boosts. Exact search requires strict substring matches. Regex supports Rust linear-time regex syntax.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Search Highlights") {
                Picker("Match Highlight Style", selection: $searchHighlightStyleRaw) {
                    ForEach(SearchHighlightStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }

                Text("Styling used to highlight matching characters in titles and content snippets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("Pin placement controls whether pinned items stay grouped at the top or bottom of the history list, or mixed naturally in chronological order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// ==============================================================================
// Mimra — Privacy Settings Tab (P7-04 / F-009, F-010, F-057, T-SET-02)
// Excluded applications, custom ignored UTIs, pause controls, and built-in protections.
// ==============================================================================

public struct PrivacySettingsTab: View {
    @ObservedObject var privacyConfig = PrivacyConfiguration.shared

    @State private var newUtiText: String = ""
    @State private var utiErrorMessage: String? = nil
    @State private var appToRemove: IgnoredApplication? = nil
    @State private var utiToRemove: String? = nil

    public init() {}

    public var body: some View {
        Form {
            Section("Capture Controls & State") {
                Toggle("Pause clipboard capture", isOn: $privacyConfig.isPaused)

                HStack {
                    Button(action: {
                        privacyConfig.ignoreNextCopy = true
                    }) {
                        Label(
                            privacyConfig.ignoreNextCopy ? "Ignore Next Copy (Armed)" : "Ignore Next Copy",
                            systemImage: privacyConfig.ignoreNextCopy ? "shield.fill" : "shield"
                        )
                    }
                    .disabled(privacyConfig.isPaused)

                    if privacyConfig.ignoreNextCopy {
                        Text("Next copy event will be dropped without storing.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Toggle("Ignore remote Universal Clipboard payloads", isOn: $privacyConfig.ignoreUniversalClipboard)

                Text("When paused, Mimra stops recording all clipboard items. 'Ignore Next Copy' silently drops only the immediate next copy action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Excluded Applications (Never Recorded)") {
                if privacyConfig.ignoredApplications.isEmpty {
                    Text("No applications excluded. Copies from all apps will be recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(privacyConfig.ignoredApplications) { app in
                            HStack(spacing: 10) {
                                if let icon = AppIconService.shared.cachedIcon(for: app.bundleId) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                } else {
                                    Image(systemName: "app.dashed")
                                        .frame(width: 18, height: 18)
                                        .foregroundColor(.secondary)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.body)
                                    Text(app.bundleId)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button(action: {
                                    appToRemove = app
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Remove exclusion for \(app.name)")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(minHeight: 80, maxHeight: 140)
                }

                HStack(spacing: 12) {
                    Menu {
                        let available = privacyConfig.getRunningApplications()
                        if available.isEmpty {
                            Text("No other running applications found")
                        } else {
                            ForEach(available) { running in
                                Button(running.name) {
                                    try? privacyConfig.addApplication(
                                        bundleId: running.bundleId,
                                        name: running.name,
                                        path: running.path
                                    )
                                }
                            }
                        }
                    } label: {
                        Label("Add Running Application...", systemImage: "plus.app")
                    }

                    Button(action: {
                        _ = try? privacyConfig.browseAndAddApplication()
                    }) {
                        Label("Browse File...", systemImage: "folder")
                    }
                }

                Text("Supports applications located anywhere on disk, including outside /Applications (F-010, T-PRIV-03).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom Ignored Pasteboard Types (UTIs)") {
                if privacyConfig.customIgnoredUtis.isEmpty {
                    Text("No custom UTIs defined. Only standard formats and concealed markers are evaluated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(privacyConfig.customIgnoredUtis, id: \.self) { uti in
                            HStack {
                                Image(systemName: "tag.slash")
                                    .foregroundColor(.orange)
                                Text(uti)
                                    .font(.system(.body, design: .monospaced))

                                Spacer()

                                Button(action: {
                                    utiToRemove = uti
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Remove ignored UTI \(uti)")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(minHeight: 60, maxHeight: 110)
                }

                HStack {
                    TextField("e.g. com.company.secret or org.custom.*", text: $newUtiText)
                        .textFieldStyle(.roundedBorder)

                    Button("Add UTI") {
                        do {
                            try privacyConfig.addCustomUti(newUtiText)
                            newUtiText = ""
                            utiErrorMessage = nil
                        } catch {
                            utiErrorMessage = error.localizedDescription
                        }
                    }
                    .disabled(newUtiText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let err = utiErrorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Text("Matching pasteboard items (exact or prefix wildcards like *.secret) are dropped before payload bytes are read into memory (F-009, T-PRIV-02).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Built-In Sensitive Marker Guards") {
                Text("Password managers and secure apps tag sensitive copies. Mimra automatically filters all known concealed markers before data touches memory or disk:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("• 1Password (`com.agilebits.onepassword`)\n• Bitwarden (`com.bitwarden.desktop`, `com.8bit.bitwarden`)\n• KeePassXC (`org.keepassxc.keepassxc`)\n• Apple System Markers (`org.nspasteboard.ConcealedType`, `AutoGeneratedType`, `TransientType`)\n• Strongbox, LastPass, Dashlane, Enpass, NordPass, RoboForm")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                LabeledContent("Network Access", value: "Zero (Strictly Offline)")
                LabeledContent("Telemetry / Analytics", value: "Disabled")
            }
        }
        .formStyle(.grouped)
        .alert("Remove Application Exclusion?", isPresented: Binding(
            get: { appToRemove != nil },
            set: { if !$0 { appToRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { appToRemove = nil }
            Button("Remove", role: .destructive) {
                if let app = appToRemove {
                    privacyConfig.removeApplication(bundleId: app.bundleId)
                    appToRemove = nil
                }
            }
        } message: {
            if let app = appToRemove {
                Text("Copies from '\(app.name)' will once again be recorded into clipboard history.")
            }
        }
        .alert("Remove Ignored UTI?", isPresented: Binding(
            get: { utiToRemove != nil },
            set: { if !$0 { utiToRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { utiToRemove = nil }
            Button("Remove", role: .destructive) {
                if let uti = utiToRemove {
                    privacyConfig.removeCustomUti(uti)
                    utiToRemove = nil
                }
            }
        } message: {
            if let uti = utiToRemove {
                Text("Pasteboard representations matching '\(uti)' will no longer be excluded.")
            }
        }
    }
}

// ==============================================================================
// Mimra — Hotkeys Settings Tab (P7-05 / F-023, T-KEY-02)
// Record, modify, validate, and reset global and in-panel shortcuts.
// ==============================================================================

public struct HotkeysSettingsTab: View {
    @ObservedObject var hotkeyConfig = HotkeyConfiguration.shared

    @State private var recordingAction: HotkeyActionType? = nil
    @State private var errorMessage: String? = nil
    @State private var keyMonitor: Any? = nil

    public init() {}

    public var body: some View {
        Form {
            if let err = errorMessage {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(err)
                            .font(.callout)
                            .foregroundColor(.red)
                        Spacer()
                        Button(action: { errorMessage = nil }) {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Global System Shortcut") {
                hotkeyRow(for: .summon)

                Text("Summon shortcut is registered natively using macOS Carbon HIToolbox. Does not require Accessibility or keystroke monitoring permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("In-Panel Keyboard Shortcuts") {
                hotkeyRow(for: .pin)
                hotkeyRow(for: .delete)
                hotkeyRow(for: .preview)
                hotkeyRow(for: .plainPaste)

                Text("Panel shortcuts are local to the history window and never intercept keystrokes in other applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quick-Pick & System Workflows") {
                LabeledContent("Quick Pick Items 1–9", value: "⌘1 … ⌘9")
                LabeledContent("Plain Text Quick Pick", value: "⇧⌘1 … ⇧⌘9")
                LabeledContent("Quick Switcher (Cycle Mode)", value: "Hold modifier + Summon")
                LabeledContent("Edit Pinned Clip", value: "⌘E")
                LabeledContent("Reorder Pinned Item", value: "⌥⌘↑ / ⌥⌘↓")
            }

            Section {
                Button("Restore All Default Shortcuts") {
                    hotkeyConfig.resetAllToDefaults()
                    errorMessage = nil
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            setupMonitor()
        }
        .onDisappear {
            teardownMonitor()
        }
    }

    @ViewBuilder
    private func hotkeyRow(for action: HotkeyActionType) -> some View {
        let current = hotkeyConfig.shortcut(for: action)
        let isRecording = recordingAction == action
        let isDefault = current == hotkeyConfig.defaultShortcut(for: action)

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.body)
                Text(action.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isRecording {
                Text("Press shortcut… (Esc to cancel)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(6)
            } else {
                Text(current.displayString)
                    .font(.system(.body, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(6)
            }

            Button(isRecording ? "Cancel" : "Record") {
                if isRecording {
                    recordingAction = nil
                } else {
                    errorMessage = nil
                    recordingAction = action
                }
            }
            .controlSize(.small)

            if !isDefault {
                Button("Reset") {
                    hotkeyConfig.resetToDefault(for: action)
                    errorMessage = nil
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func setupMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = self.recordingAction else { return event }

            // Escape cancels recording
            if event.keyCode == UInt32(kVK_Escape) && event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                self.recordingAction = nil
                return nil
            }

            // Must have meaningful key press
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let newShortcut = KeyShortcut(keyCode: UInt32(event.keyCode), modifierFlags: flags)

            do {
                try self.hotkeyConfig.setShortcut(newShortcut, for: action)
                self.recordingAction = nil
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
                self.recordingAction = nil
            }

            return nil
        }
    }

    private func teardownMonitor() {
        if let mon = keyMonitor {
            NSEvent.removeMonitor(mon)
            keyMonitor = nil
        }
    }
}

// ==============================================================================
// Mimra — Updates Settings Tab (P9-05 / F-062, T-REL-01)
// Software update preferences, check button, and cryptographic security status.
// ==============================================================================

public struct UpdatesSettingsTab: View {
    @ObservedObject var updateService = UpdateService.shared
    let engineVersion: String

    public init(engineVersion: String = coreVersion()) {
        self.engineVersion = engineVersion
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (Build \(build))"
    }

    public var body: some View {
        Form {
            Section("Current Version & Status") {
                LabeledContent("Application Version", value: appVersionString)
                LabeledContent("RustCore Engine", value: "v\(engineVersion) (arm64)")
                LabeledContent("Last Update Check", value: updateService.formattedLastCheckDate)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Software Updates")
                            .font(.body)
                        if let status = updateService.statusMessage {
                            Text(status)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Check for newer versions and security releases of Mimra.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Button(action: {
                        updateService.checkForUpdates()
                    }) {
                        if updateService.isChecking {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.horizontal, 8)
                        } else {
                            Text("Check Now...")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(!updateService.canCheckForUpdates || updateService.isChecking)
                }
            }

            Section("Automatic Updates") {
                Toggle("Automatically check for updates", isOn: $updateService.automaticallyChecksForUpdates)

                Text("When enabled, Mimra automatically checks for updates on launch and in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if updateService.automaticallyChecksForUpdates {
                    Picker("Check Frequency", selection: $updateService.updateCheckInterval) {
                        ForEach(UpdateCheckFrequency.allCases) { freq in
                            Text(freq.displayName).tag(freq.rawValue)
                        }
                    }

                    Toggle("Automatically download new updates", isOn: $updateService.automaticallyDownloadsUpdates)

                    Text("When enabled, new update packages are downloaded silently in the background and ready to install on relaunch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Security & Privacy Guarantee") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.green)
                        Text("Cryptographic Ed25519 Signatures")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    Text("Every update archive is cryptographically signed with an Ed25519 key and notarized by Apple. Downgrades or modified packages are strictly rejected.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()
                        .padding(.vertical, 2)

                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.accentColor)
                        Text("Zero Telemetry Policy")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    Text("Update checks transmit only standard HTTP GET requests to GitHub over HTTPS. No system profiles, hardware IDs, tokens, or clipboard contents are ever sent.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}

// ==============================================================================
// Mimra — Settings Category Definition & Main Settings View
// ==============================================================================

public enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case appearance = "Appearance"
    case hotkeys = "Hotkeys"
    case search = "Search & Sorting"
    case storage = "Storage"
    case privacy = "Privacy"
    case updates = "Updates"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .general: return "gear"
        case .appearance: return "paintpalette"
        case .hotkeys: return "command"
        case .search: return "arrow.up.arrow.down.circle"
        case .storage: return "cylinder.split.1x2"
        case .privacy: return "hand.raised"
        case .updates: return "arrow.triangle.2.circlepath.circle"
        }
    }
}

public struct SettingsView: View {
    @State private var engineVersion: String = coreVersion()
    @ObservedObject private var accessibilityService = AccessibilityService.shared
    @StateObject private var storageViewModel: StorageSettingsViewModel

    @State private var selectedCategory: SettingsCategory = .general

    @AppStorage("pasteAutomatically") private var pasteAutomatically: Bool = true
    @AppStorage("cycleModeEnabled") private var cycleModeEnabled: Bool = true
    @AppStorage("showColorSwatches") private var showColorSwatches: Bool = true
    @AppStorage("showUrlPreviews") private var showUrlPreviews: Bool = true
    @AppStorage("showSourceAppIcon") private var showSourceAppIcon: Bool = true

    // Slideout Preview preferences (P6-02 / F-040, T-PREV-02, Requirement 6)
    @AppStorage("previewDisplayMode") private var previewDisplayModeRaw: String = PreviewDisplayMode.manual.rawValue
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
        HStack(spacing: 0) {
            // Left Navigation Sidebar
            VStack(spacing: 4) {
                ForEach(SettingsCategory.allCases) { category in
                    Button(action: {
                        selectedCategory = category
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: category.icon)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 18)
                                .foregroundColor(selectedCategory == category ? .white : .accentColor)

                            Text(category.rawValue)
                                .font(.system(size: 13, weight: selectedCategory == category ? .semibold : .regular))
                                .foregroundColor(selectedCategory == category ? .white : .primary)

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            selectedCategory == category
                                ? RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor)
                                : RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.rawValue)
                }

                Spacer()

                // Sidebar Footer (App Info & Quit Button)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Mimra")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("Engine \(engineVersion)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.horizontal, 2)

                    Button(action: {
                        NSApp.terminate(nil)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "power")
                                .font(.system(size: 11, weight: .medium))
                            Text("Quit Mimra")
                                .font(.system(size: 12))
                            Spacer()
                            Text("⌘Q")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Quit Mimra (⌘Q)")
                    .accessibilityLabel("Quit Mimra")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .padding(.top, 16)
            .padding(.horizontal, 8)
            .frame(width: 190)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // Active Category Detail Pane
            Group {
                switch selectedCategory {
                case .general:
                    GeneralSettingsTab(engineVersion: engineVersion)
                case .appearance:
                    AppearanceSettingsTab()
                case .hotkeys:
                    HotkeysSettingsTab()
                case .search:
                    SearchSettingsTab()
                case .storage:
                    StorageSettingsTab(viewModel: storageViewModel)
                case .privacy:
                    PrivacySettingsTab()
                case .updates:
                    UpdatesSettingsTab(engineVersion: engineVersion)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 530)
        .task {
            accessibilityService.startObserving()
        }
        .onDisappear {
            accessibilityService.stopObserving()
        }
    }
}
