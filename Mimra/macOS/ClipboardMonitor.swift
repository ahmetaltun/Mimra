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

    /// Canonical mapping of supported pasteboard UTIs to standardize representations.
    private static let supportedUtiMappings: [String: String] = [
        // Plain text variants
        "public.utf8-plain-text": "public.utf8-plain-text",
        "NSStringPboardType": "public.utf8-plain-text",
        "public.plain-text": "public.utf8-plain-text",
        "public.text": "public.utf8-plain-text",

        // Rich text variants
        "public.rtf": "public.rtf",
        "NSRTFPboardType": "public.rtf",

        // HTML
        "public.html": "public.html",

        // File URLs
        "public.file-url": "public.file-url",
        "NSURLPboardType": "public.file-url",

        // Images
        "public.png": "public.png",
        "public.tiff": "public.tiff",
        "NSTypedPasteboardItemPboardType": "public.tiff",
        "public.jpeg": "public.jpeg",
        "public.heic": "public.heic",
    ]

    public init(
        pasteboard: NSPasteboard = .general,
        privacyFilter: PrivacyFilter = PrivacyFilter(),
        provenanceGuard: ClipboardProvenance = ClipboardProvenance(),
        coreClient: CoreClient
    ) {
        self.pasteboard = pasteboard
        self.privacyFilter = privacyFilter
        self.provenanceGuard = provenanceGuard
        self.coreClient = coreClient
        self.lastChangeCount = pasteboard.changeCount
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
        // Try reading explicit source attribution marker if present
        if let items = pasteboard.pasteboardItems {
            for item in items {
                if let source = item.string(forType: ClipboardProvenance.sourceAppType), !source.isEmpty {
                    return source
                }
            }
        }

        // Fall back to frontmost application
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func extractRawCapture(sourceBundleId: String?) -> RawCapture? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return nil
        }

        var rawRepresentations: [RawRepresentation] = []
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000.0)

        for (groupIndex, item) in items.enumerated() {
            var seenCanonicalUtis = Set<String>()

            for type in item.types {
                guard let canonicalUti = Self.supportedUtiMappings[type.rawValue] else {
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
                rawRepresentations.push(
                    RawRepresentation(
                        groupIndex: UInt32(groupIndex),
                        uti: canonicalUti,
                        payload: data
                    )
                )
            }
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
