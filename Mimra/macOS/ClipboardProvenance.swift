// ==============================================================================
// Mimra — Clipboard Provenance & Self-Recapture Protection
// Prevents feedback loops and spurious duplicates when Mimra itself writes
// to NSPasteboard.
// Linked Features: F-012, F-020
// Test IDs: T-CAP-05
// ==============================================================================

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "ClipboardProvenance")

/// Protects the clipboard pipeline against self-recapture loops.
public final class ClipboardProvenance: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSelfWrittenChangeCount: Int = -1

    /// Custom UTI attached to items written by Mimra.
    public static let provenanceType = NSPasteboard.PasteboardType("com.mimra.provenance")

    /// Standard macOS pasteboard source type.
    public static let sourceAppType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    /// Mimra's bundle identifier used for source attribution.
    public static let mimraBundleIdentifier = "com.mimra.app"

    public init() {}

    /// Records that Mimra just wrote to the given pasteboard and stores the changeCount.
    public func recordSelfWrite(on pasteboard: NSPasteboard) {
        lock.lock()
        defer { lock.unlock() }

        lastSelfWrittenChangeCount = pasteboard.changeCount
        logger.debug("Recorded self-write on pasteboard with changeCount: \(self.lastSelfWrittenChangeCount, privacy: .public)")
    }

    /// Explicitly sets the expected change count after writing.
    public func recordExpectedChangeCount(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }

        lastSelfWrittenChangeCount = count
    }

    /// Checks whether the given pasteboard state was originated by Mimra itself.
    public func isSelfGenerated(changeCount: Int, pasteboard: NSPasteboard) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // 1. Direct change count match
        if changeCount == lastSelfWrittenChangeCount && lastSelfWrittenChangeCount != -1 {
            logger.debug("Detected self-write by changeCount match (\(changeCount, privacy: .public)).")
            return true
        }

        // 2. Custom provenance UTI present
        if let types = pasteboard.types, types.contains(Self.provenanceType) {
            logger.debug("Detected self-write by provenance UTI marker.")
            return true
        }

        // 3. Check individual items for provenance UTI or Mimra source
        if let items = pasteboard.pasteboardItems {
            for item in items {
                if item.types.contains(Self.provenanceType) {
                    return true
                }
                if let source = item.string(forType: Self.sourceAppType),
                   source == Self.mimraBundleIdentifier {
                    return true
                }
            }
        }

        return false
    }

    /// Resets the recorded self-write state.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        lastSelfWrittenChangeCount = -1
    }
}
