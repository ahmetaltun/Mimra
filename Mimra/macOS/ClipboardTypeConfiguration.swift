// ==============================================================================
// Mimra — Clipboard Type Configuration (F-013, F-015, T-TYPE-05)
// Controls format enablement and prevents storage of unselected/unsupported types.
// ==============================================================================

import Foundation

/// Defines which clipboard content categories are captured by Mimra.
/// Dropped types are rejected in Swift before payload bytes reach memory or disk.
public struct ClipboardTypeConfiguration: Equatable, Sendable {
    public static let storePlainTextKey = "storePlainText"
    public static let storeRichTextKey = "storeRichText"
    public static let storeImagesKey = "storeImages"
    public static let storeFilesKey = "storeFiles"

    /// Whether plain text and URLs are captured (default: true).
    public var storePlainText: Bool
    /// Whether rich text (HTML, RTF, RTFD) is captured (default: true).
    public var storeRichText: Bool
    /// Whether bitmap images (PNG, TIFF, JPEG, HEIC) are captured (default: true).
    public var storeImages: Bool
    /// Whether file URL references are captured (default: true).
    public var storeFiles: Bool

    public init(
        storePlainText: Bool = true,
        storeRichText: Bool = true,
        storeImages: Bool = true,
        storeFiles: Bool = true
    ) {
        self.storePlainText = storePlainText
        self.storeRichText = storeRichText
        self.storeImages = storeImages
        self.storeFiles = storeFiles
    }

    /// Loads configuration from UserDefaults, defaulting all formats to true.
    public static func load(from defaults: UserDefaults = .standard) -> ClipboardTypeConfiguration {
        let plain = defaults.object(forKey: storePlainTextKey) as? Bool ?? true
        let rich = defaults.object(forKey: storeRichTextKey) as? Bool ?? true
        let images = defaults.object(forKey: storeImagesKey) as? Bool ?? true
        let files = defaults.object(forKey: storeFilesKey) as? Bool ?? true
        return ClipboardTypeConfiguration(
            storePlainText: plain,
            storeRichText: rich,
            storeImages: images,
            storeFiles: files
        )
    }

    /// Saves the current configuration to UserDefaults.
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(storePlainText, forKey: Self.storePlainTextKey)
        defaults.set(storeRichText, forKey: Self.storeRichTextKey)
        defaults.set(storeImages, forKey: Self.storeImagesKey)
        defaults.set(storeFiles, forKey: Self.storeFilesKey)
    }

    /// Determines if a standardized canonical UTI is enabled by user preferences (F-013).
    /// Unknown/unsupported UTIs return false, enforcing strict payload allowlisting (F-015).
    public func isUtiEnabled(_ canonicalUti: String) -> Bool {
        switch canonicalUti {
        case "public.utf8-plain-text", "public.url", "public.url-name":
            return storePlainText
        case "public.rtf", "com.apple.flat-rtfd", "public.html":
            return storeRichText
        case "public.png", "public.tiff", "public.jpeg", "public.heic":
            return storeImages
        case "public.file-url":
            return storeFiles
        default:
            return false
        }
    }

    /// Canonical mapping of supported pasteboard UTIs to standardize representations (F-015).
    /// Types omitted from this mapping are never read or stored.
    public static let supportedUtiMappings: [String: String] = [
        // Plain text variants
        "public.utf8-plain-text": "public.utf8-plain-text",
        "NSStringPboardType": "public.utf8-plain-text",
        "public.plain-text": "public.utf8-plain-text",
        "public.text": "public.utf8-plain-text",

        // Rich text variants
        "public.rtf": "public.rtf",
        "NSRTFPboardType": "public.rtf",
        "com.apple.flat-rtfd": "com.apple.flat-rtfd",
        "public.rtfd": "com.apple.flat-rtfd",
        "NSRTFDPboardType": "com.apple.flat-rtfd",

        // HTML
        "public.html": "public.html",
        "NSHTMLPboardType": "public.html",
        "Apple HTML pasteboard type": "public.html",

        // File URLs
        "public.file-url": "public.file-url",
        "NSURLPboardType": "public.file-url",
        "NSFilenamesPboardType": "public.file-url",

        // Web URLs (P3-04)
        "public.url": "public.url",
        "public.url-name": "public.url-name",

        // Images
        "public.png": "public.png",
        "public.tiff": "public.tiff",
        "NSTypedPasteboardItemPboardType": "public.tiff",
        "public.jpeg": "public.jpeg",
        "public.heic": "public.heic",
    ]

    /// Determines if a raw pasteboard type string maps to an enabled format category.
    public func isRawTypeEnabled(_ rawType: String) -> Bool {
        guard let canonical = Self.supportedUtiMappings[rawType] else {
            return false
        }
        return isUtiEnabled(canonical)
    }

    /// Checks whether any raw pasteboard type corresponds to an enabled format.
    public func hasAnyEnabledType(in rawTypes: Set<String>) -> Bool {
        for rawType in rawTypes {
            if isRawTypeEnabled(rawType) {
                return true
            }
        }
        return false
    }
}
