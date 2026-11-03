// ==============================================================================
// Mimra — Clipboard Monitor
// Actively monitors NSPasteboard.general for system-wide clipboard changes,
// applies privacy pre-filtering, validates UTIs, and dispatches to RustCore.
// Linked Features: F-001, F-002, F-003, F-004, F-005, F-007, F-011, F-015
// Test IDs: T-CAP-01, T-CAP-02, T-CAP-03, T-PRIV-05
// ==============================================================================

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "ClipboardMonitor")

extension Notification.Name {
    public static let mimraClipboardDidIngest = Notification.Name("MimraClipboardDidIngestNotification")
}

@MainActor
public final class ClipboardMonitor: ObservableObject {
    public static let maxPayloadSizeBytes: Int = 10 * 1024 * 1024 // 10 MB per representation

    private let pasteboard: NSPasteboard
    public let privacyFilter: PrivacyFilter
    public let provenanceGuard: ClipboardProvenance
    public let coreClient: CoreClient

    private var timer: Timer?
    private var lastChangeCount: Int = -1

    /// Timestamp (uptime nanoseconds) of the most recent capture for burst debouncing (F-012, T-CAP-05).
    private var lastCaptureUptimeNanos: UInt64 = 0
    /// Lightweight hash of the most recent capture for rapid burst deduplication (F-012, T-CAP-05).
    private var lastCaptureFingerprint: Int = 0

    @Published public private(set) var isMonitoring: Bool = false
    public var pollingInterval: TimeInterval = 0.5 {
        didSet {
            if isMonitoring {
                restartMonitoring()
            }
        }
    }

    /// Callback invoked whenever a new item is successfully ingested.
    public var onIngest: (@MainActor (IngestResultDto) -> Void)?

    /// Canonical mapping of supported pasteboard UTIs to standardize representations (F-015).
    public static var supportedUtiMappings: [String: String] {
        ClipboardTypeConfiguration.supportedUtiMappings
    }

    /// User configuration governing which format categories are captured (F-013, F-015).
    public var typeConfiguration: ClipboardTypeConfiguration {
        didSet {
            privacyFilter.typeConfiguration = typeConfiguration
        }
    }

    public init(
        pasteboard: NSPasteboard = .general,
        privacyFilter: PrivacyFilter = PrivacyFilter(),
        provenanceGuard: ClipboardProvenance = ClipboardProvenance(),
        typeConfiguration: ClipboardTypeConfiguration = ClipboardTypeConfiguration.load(),
        coreClient: CoreClient
    ) {
        self.pasteboard = pasteboard
        self.privacyFilter = privacyFilter
        self.provenanceGuard = provenanceGuard
        self.typeConfiguration = typeConfiguration
        self.privacyFilter.typeConfiguration = typeConfiguration
        self.coreClient = coreClient
        self.lastChangeCount = pasteboard.changeCount
    }

    /// Reloads format enablement settings from UserDefaults (F-013).
    public func reloadTypeConfiguration(from defaults: UserDefaults = .standard) {
        self.typeConfiguration = ClipboardTypeConfiguration.load(from: defaults)
    }

    // MARK: - Lifecycle

    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastChangeCount = pasteboard.changeCount

        timer = Timer.scheduledTimer(
            withTimeInterval: pollingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForChanges()
            }
        }
        logger.info("Clipboard monitor started with polling interval \(self.pollingInterval, privacy: .public)s")
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        logger.info("Clipboard monitor stopped.")
    }

    private func restartMonitoring() {
        stopMonitoring()
        startMonitoring()
    }

    // MARK: - Polling & Processing

    /// Polls the pasteboard immediately for changes (can be called manually or by the timer).
    public func checkForChanges() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else {
            return
        }

        // Update change count immediately to avoid repeated processing of same snapshot
        lastChangeCount = currentChangeCount

        // 1. Guard against self-recapture (P1-07, F-012, F-020)
        if provenanceGuard.isSelfGenerated(changeCount: currentChangeCount, pasteboard: pasteboard) {
            logger.debug("Skipping clipboard capture: item originated from Mimra.")
            return
        }

        // 2. Identify source application (F-011)
        let sourceBundleId = detectSourceBundleId()

        // 3. Privacy Pre-Filtering (P1-06, F-008, F-009, F-010, F-014, F-026)
        let decision = privacyFilter.shouldCapture(
            pasteboard: pasteboard,
            sourceBundleId: sourceBundleId
        )

        switch decision {
        case .drop(let reason):
            logger.info("Clipboard capture skipped: \(reason.description, privacy: .public)")
            return
        case .capture:
            break
        }

        // 4. Extract allowed representations
        guard let capture = extractRawCapture(sourceBundleId: sourceBundleId) else {
            logger.debug("No allowlisted representations found in clipboard change count \(currentChangeCount, privacy: .public).")
            return
        }

        // 4b. Rapid burst debouncing (F-012, T-CAP-05)
        // Multi-stage clipboard writes from editors or complex apps (e.g. VS Code, Excel) can trigger multiple
        // changeCounts within < 100ms. If the representations and content are identical, debounce to prevent storms.
        var hasher = Hasher()
        hasher.combine(sourceBundleId ?? "")
        hasher.combine(capture.representations.count)
        for rep in capture.representations {
            hasher.combine(rep.groupIndex)
            hasher.combine(rep.uti)
            hasher.combine(rep.payload.count)
            hasher.combine(rep.payload.prefix(64))
        }
        let currentFingerprint = hasher.finalize()

        let nowUptime = DispatchTime.now().uptimeNanoseconds
        let elapsedNanos = nowUptime >= lastCaptureUptimeNanos ? (nowUptime - lastCaptureUptimeNanos) : 0
        let elapsedMs = Double(elapsedNanos) / 1_000_000.0

        if elapsedMs < 100.0 && lastCaptureFingerprint == currentFingerprint {
            logger.debug("Debouncing rapid clipboard burst (\(elapsedMs, privacy: .public)ms) with identical content.")
            return
        }

        lastCaptureUptimeNanos = nowUptime
        lastCaptureFingerprint = currentFingerprint

        // 5. Ingest into RustCore via background actor (off main thread)
        Task {
            do {
                let outcome = try await coreClient.ingest(capture: capture)
                await MainActor.run {
                    self.onIngest?(outcome)
                    NotificationCenter.default.post(
                        name: .mimraClipboardDidIngest,
                        object: self,
                        userInfo: ["outcome": outcome]
                    )
                }
            } catch {
                logger.error("Failed to ingest clipboard capture into RustCore: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Extraction Helpers

    private func detectSourceBundleId() -> String? {
        // Try reading explicit source attribution marker if present (F-011)
        if let items = pasteboard.pasteboardItems {
            for item in items {
                if let source = item.string(forType: ClipboardProvenance.sourceAppType),
                   !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return source.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let data = item.data(forType: ClipboardProvenance.sourceAppType),
                   let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty {
                    return str
                }
            }
        }

        // Fall back to frontmost application
        if let frontmostId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           !frontmostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return frontmostId.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func extractRawCapture(sourceBundleId: String?) -> RawCapture? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return nil
        }

        var rawRepresentations: [RawRepresentation] = []
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000.0)

        for (groupIndex, item) in items.enumerated() {
            var seenCanonicalUtis = Set<String>()
            var groupReps: [RawRepresentation] = []

            for type in item.types {
                guard let canonicalUti = Self.supportedUtiMappings[type.rawValue] else {
                    continue
                }

                // Enforce user format enablement settings (F-013, F-015)
                guard typeConfiguration.isUtiEnabled(canonicalUti) else {
                    continue
                }

                // Avoid duplicate entries for the same canonical UTI in the same group
                if seenCanonicalUtis.contains(canonicalUti) {
                    continue
                }

                // Extract data payload safely
                guard let data = item.data(forType: type), !data.isEmpty else {
                    continue
                }

                // Enforce max payload size limit (F-015: 10 MB limit)
                guard data.count <= Self.maxPayloadSizeBytes else {
                    logger.warning("Dropped representation \(canonicalUti, privacy: .public) exceeding \(Self.maxPayloadSizeBytes, privacy: .public) bytes.")
                    continue
                }

                seenCanonicalUtis.insert(canonicalUti)
                groupReps.append(
                    RawRepresentation(
                        groupIndex: UInt32(groupIndex),
                        uti: canonicalUti,
                        payload: data
                    )
                )
            }

            // If group contains NSFilenamesPboardType but lacks public.file-url (legacy file copies)
            if typeConfiguration.isUtiEnabled("public.file-url"),
               !seenCanonicalUtis.contains("public.file-url"),
               let filenamesData = item.data(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")),
               let paths = try? PropertyListSerialization.propertyList(from: filenamesData, format: nil) as? [String] {
                for path in paths {
                    let fileUrl = URL(fileURLWithPath: path).absoluteString
                    if let urlData = fileUrl.data(using: .utf8) {
                        seenCanonicalUtis.insert("public.file-url")
                        groupReps.append(
                            RawRepresentation(groupIndex: UInt32(groupIndex), uti: "public.file-url", payload: urlData)
                        )
                    }
                }
            }

            // Synthesize plain text representation if rich text, file URLs, or web URLs are present but plain text is missing (P3-01, P3-03, P3-04)
            // ONLY synthesize if plain text is enabled by user configuration (F-013)
            let hasPlainText = seenCanonicalUtis.contains("public.utf8-plain-text")
            let hasRichText = seenCanonicalUtis.contains("public.rtf") ||
                              seenCanonicalUtis.contains("com.apple.flat-rtfd") ||
                              seenCanonicalUtis.contains("public.html")
            let hasFileUrl = seenCanonicalUtis.contains("public.file-url")
            let hasWebUrl = seenCanonicalUtis.contains("public.url")

            if typeConfiguration.isUtiEnabled("public.utf8-plain-text"),
               !hasPlainText && (hasRichText || hasFileUrl || hasWebUrl) {
                if let extractedText = PasteCoordinator.extractPlainText(from: groupReps),
                   !extractedText.isEmpty,
                   let textData = extractedText.data(using: .utf8) {
                    groupReps.append(
                        RawRepresentation(
                            groupIndex: UInt32(groupIndex),
                            uti: "public.utf8-plain-text",
                            payload: textData
                        )
                    )
                }
            }

            rawRepresentations.append(contentsOf: groupReps)
        }

        guard !rawRepresentations.isEmpty else {
            return nil
        }

        return RawCapture(
            timestampMs: timestampMs,
            sourceBundleId: sourceBundleId,
            representations: rawRepresentations
        )
    }
}

// Swift Array append helper matching Rust terminology if needed
private extension Array {
    mutating func push(_ newElement: Element) {
        append(newElement)
    }
}
