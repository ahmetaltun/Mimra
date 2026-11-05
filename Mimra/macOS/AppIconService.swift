// ==============================================================================
// Mimra — Source Application Icon Service
// Resolves, caches, and refreshes source application icons based on bundle ID.
// Linked Features: F-011, F-016
// Test IDs: T-CAP-04
// ==============================================================================

import AppKit
import Foundation
import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.mimra.app", category: "AppIconService")

/// Cache entry storing the rendered icon and bundle modification date for staleness checks.
private final class CachedIconEntry: @unchecked Sendable {
    let icon: NSImage
    let modificationDate: Date?

    init(icon: NSImage, modificationDate: Date?) {
        self.icon = icon
        self.modificationDate = modificationDate
    }
}

/// Thread-safe box wrapping NSCache for Swift 6 strict concurrency compliance.
private final class IconCacheBox: @unchecked Sendable {
    private let cache = NSCache<NSString, CachedIconEntry>()

    init(countLimit: Int = 100) {
        cache.countLimit = countLimit
    }

    func object(forKey key: String) -> CachedIconEntry? {
        cache.object(forKey: key as NSString)
    }

    func setObject(_ obj: CachedIconEntry, forKey key: String) {
        cache.setObject(obj, forKey: key as NSString)
    }

    func removeObject(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }
}

/// Service managing resolution and memory-bounded caching of source application icons.
@MainActor
public final class AppIconService {
    public static let shared = AppIconService()

    private let cache = IconCacheBox(countLimit: 120)
    private var inFlightResolutions: [String: Task<SendableImage, Never>] = [:]

    public init() {}

    // MARK: - Synchronous Fast Path

    /// Synchronously returns a previously cached icon if available, avoiding main-thread disk I/O.
    nonisolated public func cachedIcon(for bundleId: String) -> NSImage? {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return cache.object(forKey: trimmed)?.icon
    }

    // MARK: - Asynchronous Resolution

    /// Resolves an application icon asynchronously.
    /// Deduplicates concurrent requests for the same bundle identifier.
    public func icon(for bundleId: String) async -> NSImage? {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Check synchronous cache box
        if let cached = cache.object(forKey: trimmed) {
            // Verify if bundle was updated on disk since last cached
            if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed),
               let currentModDate = modificationDate(for: appUrl) {
                if let cachedDate = cached.modificationDate, currentModDate > cachedDate {
                    logger.debug("Source app '\(trimmed, privacy: .public)' updated on disk; refreshing icon.")
                    cache.removeObject(forKey: trimmed)
                } else {
                    return cached.icon
                }
            } else {
                return cached.icon
            }
        }

        // 2. Coalesce concurrent resolutions for the same bundleId
        if let inFlight = inFlightResolutions[trimmed] {
            return await inFlight.value.image
        }

        let task = Task<SendableImage, Never> { @MainActor in
            return SendableImage(self.resolveAppIcon(bundleId: trimmed))
        }
        inFlightResolutions[trimmed] = task
        defer { inFlightResolutions.removeValue(forKey: trimmed) }

        return await task.value.image
    }

    // MARK: - Cache Invalidation

    /// Purges a specific bundle ID from the icon cache.
    public func invalidate(bundleId: String) {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        cache.removeObject(forKey: trimmed)
    }

    /// Purges all cached application icons.
    public func invalidateAll() {
        cache.removeAllObjects()
    }

    // MARK: - Internal Resolution Logic

    private func resolveAppIcon(bundleId: String) -> NSImage? {
        guard let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            logger.debug("Could not resolve application URL for bundle ID '\(bundleId, privacy: .public)'")
            return nil
        }

        let modDate = modificationDate(for: appUrl)
        let rawIcon = NSWorkspace.shared.icon(forFile: appUrl.path)

        // Generate clean scaled representation
        let targetSize = NSSize(width: 32, height: 32)
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        rawIcon.draw(in: NSRect(origin: .zero, size: targetSize),
                     from: NSRect(origin: .zero, size: rawIcon.size),
                     operation: .copy,
                     fraction: 1.0)
        resized.unlockFocus()

        let entry = CachedIconEntry(icon: resized, modificationDate: modDate)
        cache.setObject(entry, forKey: bundleId)

        return resized
    }

    private func modificationDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}

// MARK: - SwiftUI Source App Icon Component

/// Renders a source application icon with asynchronous loading and caching.
public struct SourceAppIconView: View {
    public let bundleId: String
    public let size: CGFloat

    @State private var icon: NSImage?
    @State private var hasAttemptedLoad = false

    public init(bundleId: String, size: CGFloat = 14) {
        self.bundleId = bundleId
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = icon {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Color.clear
                    .frame(width: size, height: size)
            }
        }
        .task(id: bundleId) {
            // Check zero-latency synchronous cache first
            if let cached = AppIconService.shared.cachedIcon(for: bundleId) {
                self.icon = cached
                return
            }

            guard !hasAttemptedLoad else { return }
            hasAttemptedLoad = true

            let loaded = await AppIconService.shared.icon(for: bundleId)
            if let loaded = loaded {
                self.icon = loaded
            }
        }
    }
}
