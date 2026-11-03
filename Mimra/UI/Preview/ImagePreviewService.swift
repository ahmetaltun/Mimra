// ==============================================================================
// Mimra — Image Preview Service & Metadata Extractor
// Asynchronously decodes and caches high-fidelity downscaled preview images off the main thread.
// Extracts dimensions, format, byte size, aspect ratio, and color space via ImageIO.
// Supports PNG, JPEG, TIFF, and HEIC natively.
// Linked Feature: F-042
// Test ID: T-PREV-04
// ==============================================================================

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "ImagePreviewService")

/// Pure data model representing essential image attributes for inspection.
public struct ImageMetadata: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let format: String
    public let byteSize: Int64
    public let colorSpace: String?

    public init(
        width: Int,
        height: Int,
        format: String,
        byteSize: Int64,
        colorSpace: String? = nil
    ) {
        self.width = width
        self.height = height
        self.format = format
        self.byteSize = byteSize
        self.colorSpace = colorSpace
    }

    public var pixelDimensionsString: String {
        "\(width) × \(height)"
    }

    public var aspectRatioString: String {
        guard height > 0 else { return "1:1" }
        let gcdVal = Self.gcd(width, height)
        let simplifiedW = width / gcdVal
        let simplifiedH = height / gcdVal
        if simplifiedW <= 32 && simplifiedH <= 32 {
            return "\(simplifiedW):\(simplifiedH)"
        }
        let ratio = Double(width) / Double(height)
        return String(format: "%.2f:1", ratio)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let temp = y
            y = x % y
            x = temp
        }
        return x > 0 ? x : 1
    }
}

/// Decoded preview payload containing both the display NSImage and extracted metadata.
public struct ImagePreviewPayload: @unchecked Sendable {
    public let image: NSImage
    public let metadata: ImageMetadata

    public init(image: NSImage, metadata: ImageMetadata) {
        self.image = image
        self.metadata = metadata
    }
}

/// Internal cache item wrapper for NSCache storage.
private final class CacheEntry: @unchecked Sendable {
    let payload: ImagePreviewPayload
    init(payload: ImagePreviewPayload) {
        self.payload = payload
    }
}

/// Thread-safe storage box wrapping Foundation's NSCache under Swift 6 concurrency.
private final class PreviewCacheBox: @unchecked Sendable {
    let cache = NSCache<NSString, CacheEntry>()
}

/// Actor responsible for lazy, off-main-thread image preview decoding and high-resolution caching.
public actor ImagePreviewService {
    public static let shared = ImagePreviewService()

    /// Maximum preview dimension in pixels (e.g. 1600 px for Retina display clarity).
    public let maxPixelSize: Int

    /// In-memory bounded cache storing decoded image payloads.
    private let storage = PreviewCacheBox()

    /// Active in-flight decoding tasks to coalesce concurrent duplicate requests.
    private var inFlightTasks: [String: Task<ImagePreviewPayload?, Never>] = [:]

    public init(
        maxPixelSize: Int = 1600,
        countLimit: Int = 60,
        totalCostLimitBytes: Int = 128 * 1024 * 1024 // 128 MB
    ) {
        self.maxPixelSize = maxPixelSize
        self.storage.cache.countLimit = countLimit
        self.storage.cache.totalCostLimit = totalCostLimitBytes
    }

    /// Synchronously retrieves an existing cached preview payload if already decoded and available.
    nonisolated public func cachedPreview(for itemId: String) -> ImagePreviewPayload? {
        storage.cache.object(forKey: itemId as NSString)?.payload
    }

    /// Clears all entries from the preview cache.
    public func clearCache() {
        storage.cache.removeAllObjects()
    }

    /// Asynchronously fetches or decodes a downscaled preview for the given item.
    /// Coalesces concurrent in-flight requests for identical item IDs.
    public func preview(
        for itemId: String,
        utiHint: String? = nil,
        fetchPayload: @escaping @Sendable () async throws -> Data?
    ) async -> ImagePreviewPayload? {
        // 1. Check in-memory cache
        if let cached = storage.cache.object(forKey: itemId as NSString)?.payload {
            return cached
        }

        // 2. Coalesce concurrent in-flight requests for same itemId
        if let existingTask = inFlightTasks[itemId] {
            return await existingTask.value
        }

        // 3. Launch background decoding task
        let maxPixel = self.maxPixelSize
        let task = Task<ImagePreviewPayload?, Never> {
            guard let rawData = try? await fetchPayload(), !rawData.isEmpty else {
                return nil
            }
            return Self.decodePreview(from: rawData, maxPixelSize: maxPixel, utiHint: utiHint)
        }

        inFlightTasks[itemId] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: itemId)

        // 4. Cache valid previews with byte cost estimation
        if let previewPayload = result {
            let width = previewPayload.metadata.width
            let height = previewPayload.metadata.height
            let estimatedCost = max(width * height * 4, 1024)
            storage.cache.setObject(
                CacheEntry(payload: previewPayload),
                forKey: itemId as NSString,
                cost: estimatedCost
            )
        }

        return result
    }

    /// Fast metadata extraction without decompressing full image bitmap.
    nonisolated public static func extractMetadata(from data: Data, utiHint: String? = nil) -> ImageMetadata? {
        guard !data.isEmpty else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [CFString: Any] else {
            return nil
        }

        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ??
                    (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ??
                     (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

        guard width > 0, height > 0 else { return nil }

        var format = "Image"
        if let type = CGImageSourceGetType(source) as String? {
            let lowerType = type.lowercased()
            if lowerType.contains("png") { format = "PNG" }
            else if lowerType.contains("jpeg") || lowerType.contains("jpg") { format = "JPEG" }
            else if lowerType.contains("heic") || lowerType.contains("heif") { format = "HEIC" }
            else if lowerType.contains("tiff") || lowerType.contains("tif") { format = "TIFF" }
            else if lowerType.contains("gif") { format = "GIF" }
            else if lowerType.contains("webp") { format = "WebP" }
        } else if let uti = utiHint {
            let lowerUti = uti.lowercased()
            if lowerUti.contains("png") { format = "PNG" }
            else if lowerUti.contains("jpeg") { format = "JPEG" }
            else if lowerUti.contains("heic") { format = "HEIC" }
            else if lowerUti.contains("tiff") { format = "TIFF" }
        }

        let colorSpace = properties[kCGImagePropertyColorModel] as? String

        return ImageMetadata(
            width: width,
            height: height,
            format: format,
            byteSize: Int64(data.count),
            colorSpace: colorSpace
        )
    }

    /// Decodes raw image data into a downscaled NSImage and metadata.
    nonisolated public static func decodePreview(from data: Data, maxPixelSize: Int, utiHint: String? = nil) -> ImagePreviewPayload? {
        guard !data.isEmpty else { return nil }

        guard let metadata = extractMetadata(from: data, utiHint: utiHint) else {
            return nil
        }

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

        let image = NSImage(cgImage: cgThumbnail, size: size)
        return ImagePreviewPayload(image: image, metadata: metadata)
    }
}
