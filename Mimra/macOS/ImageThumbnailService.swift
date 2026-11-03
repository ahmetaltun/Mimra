// ==============================================================================
// Mimra — Image Thumbnail Service
// Asynchronously decodes and caches downscaled image thumbnails off the main thread.
// Enforces memory boundaries via NSCache with concurrent task deduplication.
// Linked Feature: F-004
// Test ID: T-TYPE-02
// ==============================================================================

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "ImageThumbnailService")

/// Thread-safe storage box wrapping Foundation's NSCache under Swift 6 concurrency.
private final class ThumbnailCacheBox: @unchecked Sendable {
    let cache = NSCache<NSString, NSImage>()
}

/// Actor responsible for lazy, off-main-thread image decoding and thumbnail caching.
public actor ImageThumbnailService {
    public static let shared = ImageThumbnailService()

    /// Maximum thumbnail dimension in pixels for list rows and preview thumbnails.
    public let maxPixelSize: Int

    /// In-memory bounded cache storing decoded NSImages.
    private let storage = ThumbnailCacheBox()

    /// Active in-flight decoding tasks to coalesce concurrent duplicate requests.
    private var inFlightTasks: [String: Task<NSImage?, Never>] = [:]

    public init(
        maxPixelSize: Int = 160,
        countLimit: Int = 250,
        totalCostLimitBytes: Int = 64 * 1024 * 1024 // 64 MB
    ) {
        self.maxPixelSize = maxPixelSize
        self.storage.cache.countLimit = countLimit
        self.storage.cache.totalCostLimit = totalCostLimitBytes
    }

    /// Synchronously retrieves an existing cached thumbnail if already decoded and available.
    nonisolated public func cachedThumbnail(for itemId: String) -> NSImage? {
        storage.cache.object(forKey: itemId as NSString)
    }

    /// Asynchronously fetches or decodes a downscaled thumbnail for the given item.
    /// Coalesces concurrent in-flight requests for identical item IDs.
    ///
    /// - Parameters:
    ///   - itemId: The UUID string identifying the history item.
    ///   - fetchPayload: Async closure retrieving raw image bytes if not cached.
    /// - Returns: A decoded, downscaled `NSImage`, or `nil` if decoding fails.
    public func thumbnail(
        for itemId: String,
        fetchPayload: @escaping @Sendable () async throws -> Data?
    ) async -> NSImage? {
        // 1. Check in-memory cache
        if let cached = storage.cache.object(forKey: itemId as NSString) {
            return cached
        }

        // 2. Coalesce concurrent in-flight requests for same itemId
        if let existingTask = inFlightTasks[itemId] {
            return await existingTask.value
        }

        // 3. Launch background decoding task
        let maxPixel = self.maxPixelSize
        let task = Task<NSImage?, Never> {
            guard let rawData = try? await fetchPayload(), !rawData.isEmpty else {
                return nil
            }
            return Self.decodeThumbnail(from: rawData, maxPixelSize: maxPixel)
        }

        inFlightTasks[itemId] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: itemId)

        // 4. Cache valid thumbnails with byte cost estimation
        if let image = result {
            let width = Int(image.size.width)
            let height = Int(image.size.height)
            let estimatedCost = max(width * height * 4, 1024)
            storage.cache.setObject(image, forKey: itemId as NSString, cost: estimatedCost)
        }

        return result
    }

    /// Decodes a raw image payload into a downscaled NSImage without full bitmap decompression.
    nonisolated public static func decodeThumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard !data.isEmpty else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let width = CGFloat(cgThumbnail.width)
        let height = CGFloat(cgThumbnail.height)
        let size = NSSize(width: width, height: height)

        return NSImage(cgImage: cgThumbnail, size: size)
    }

    /// Clears all entries from the thumbnail cache (e.g. on memory pressure or test teardown).
    public func clearCache() {
        storage.cache.removeAllObjects()
        inFlightTasks.removeAll()
    }
}
