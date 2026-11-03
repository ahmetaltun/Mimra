// ==============================================================================
// Mimra — Color Swatch and URL Recognition Previews
// Linked Features: F-006, F-037
// Test IDs: T-TYPE-04, T-TYPE-06
// ==============================================================================

import AppKit
import SwiftUI

// MARK: - Hex Color Detection & Info (F-037, T-TYPE-06)

/// Parsed RGBA color details extracted from clipboard hex text.
public struct HexColorInfo: Equatable, Sendable {
    public let hexString: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    public let isDark: Bool

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var formattedHex: String {
        let rInt = Int(round(red * 255))
        let gInt = Int(round(green * 255))
        let bInt = Int(round(blue * 255))
        if alpha < 0.999 {
            let aInt = Int(round(alpha * 255))
            return String(format: "#%02X%02X%02X%02X", rInt, gInt, bInt, aInt)
        }
        return String(format: "#%02X%02X%02X", rInt, gInt, bInt)
    }
}

/// Fast, safe detector for Hex color codes in copied strings.
public enum ColorDetector {
    /// Detects if a string is a valid HEX color code (#RGB, #RGBA, #RRGGBB, #RRGGBBAA, or 0x prefix).
    public static func detect(in string: String) -> HexColorInfo? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hexPart: Substring
        if trimmed.hasPrefix("#") {
            hexPart = trimmed.dropFirst()
        } else if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            hexPart = trimmed.dropFirst(2)
        } else {
            return nil
        }

        // Validate all characters are hexadecimal
        guard !hexPart.isEmpty && hexPart.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        let hexStr = String(hexPart)
        let r: Double, g: Double, b: Double, a: Double

        switch hexStr.count {
        case 3: // #RGB
            guard let rVal = parseHexNibble(hexStr, at: 0),
                  let gVal = parseHexNibble(hexStr, at: 1),
                  let bVal = parseHexNibble(hexStr, at: 2) else { return nil }
            r = Double((rVal << 4) | rVal) / 255.0
            g = Double((gVal << 4) | gVal) / 255.0
            b = Double((bVal << 4) | bVal) / 255.0
            a = 1.0

        case 4: // #RGBA
            guard let rVal = parseHexNibble(hexStr, at: 0),
                  let gVal = parseHexNibble(hexStr, at: 1),
                  let bVal = parseHexNibble(hexStr, at: 2),
                  let aVal = parseHexNibble(hexStr, at: 3) else { return nil }
            r = Double((rVal << 4) | rVal) / 255.0
            g = Double((gVal << 4) | gVal) / 255.0
            b = Double((bVal << 4) | bVal) / 255.0
            a = Double((aVal << 4) | aVal) / 255.0

        case 6: // #RRGGBB
            guard let rVal = parseHexByte(hexStr, at: 0),
                  let gVal = parseHexByte(hexStr, at: 2),
                  let bVal = parseHexByte(hexStr, at: 4) else { return nil }
            r = Double(rVal) / 255.0
            g = Double(gVal) / 255.0
            b = Double(bVal) / 255.0
            a = 1.0

        case 8: // #RRGGBBAA
            guard let rVal = parseHexByte(hexStr, at: 0),
                  let gVal = parseHexByte(hexStr, at: 2),
                  let bVal = parseHexByte(hexStr, at: 4),
                  let aVal = parseHexByte(hexStr, at: 6) else { return nil }
            r = Double(rVal) / 255.0
            g = Double(gVal) / 255.0
            b = Double(bVal) / 255.0
            a = Double(aVal) / 255.0

        default:
            return nil
        }

        // Perceptual luminance calculation (ITU-R BT.601)
        let luminance = 0.299 * (r * 255.0) + 0.587 * (g * 255.0) + 0.114 * (b * 255.0)
        let isDark = luminance < 128.0

        return HexColorInfo(
            hexString: trimmed,
            red: r,
            green: g,
            blue: b,
            alpha: a,
            isDark: isDark
        )
    }

    private static func parseHexNibble(_ str: String, at index: Int) -> UInt8? {
        guard index < str.count else { return nil }
        let charIndex = str.index(str.startIndex, offsetBy: index)
        return UInt8(String(str[charIndex]), radix: 16)
    }

    private static func parseHexByte(_ str: String, at index: Int) -> UInt8? {
        guard index + 2 <= str.count else { return nil }
        let start = str.index(str.startIndex, offsetBy: index)
        let end = str.index(start, offsetBy: 2)
        return UInt8(String(str[start..<end]), radix: 16)
    }
}

// MARK: - Color Swatch SwiftUI Component

/// Renders a color swatch with contrast border and alpha checkerboard.
public struct ColorSwatchView: View {
    public let colorInfo: HexColorInfo
    public let size: CGFloat
    public let cornerRadius: CGFloat

    public init(colorInfo: HexColorInfo, size: CGFloat = 16, cornerRadius: CGFloat = 3) {
        self.colorInfo = colorInfo
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        ZStack {
            // Subtle checkerboard background for translucent colors
            if colorInfo.alpha < 0.999 {
                CheckerboardPattern()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }

            // Color fill
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(colorInfo.color)
                .frame(width: size, height: size)

            // Outline stroke for contrast against light/dark themes
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    colorInfo.isDark ? Color.white.opacity(0.35) : Color.black.opacity(0.2),
                    lineWidth: 0.75
                )
                .frame(width: size, height: size)
        }
    }
}

/// Helper view for rendering a mini transparency grid.
private struct CheckerboardPattern: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 4
            let cols = Int(ceil(size.width / step))
            let rows = Int(ceil(size.height / step))

            for r in 0..<rows {
                for c in 0..<cols {
                    let isEven = (r + c) % 2 == 0
                    let rect = CGRect(x: CGFloat(c) * step, y: CGFloat(r) * step, width: step, height: step)
                    context.fill(Path(rect), with: .color(isEven ? Color.white : Color.gray.opacity(0.4)))
                }
            }
        }
    }
}

// MARK: - URL Detection & Canonicalization (F-006, T-TYPE-04)

/// Information extracted from a recognized web URL.
public struct UrlInfo: Equatable, Sendable {
    public let originalString: String
    public let scheme: String
    public let host: String
    public let domain: String
    public let normalizedUrlString: String
    public let path: String

    public var url: URL? {
        URL(string: normalizedUrlString)
    }
}

/// Fast detector and canonicalizer for web URLs in clipboard items.
public enum UrlDetector {
    /// Detects if a string represents an HTTP, HTTPS, or FTP URL.
    public static func detect(in string: String) -> UrlInfo? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Must start with a known web scheme
        guard let schemeRange = trimmed.range(of: "://") else { return nil }
        let scheme = String(trimmed[..<schemeRange.lowerBound]).lowercased()
        guard scheme == "http" || scheme == "https" || scheme == "ftp" else {
            return nil
        }

        // Validate host exists and does not contain spaces
        let rest = String(trimmed[schemeRange.upperBound...])
        guard !rest.isEmpty else { return nil }

        let hostEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let rawHostPort = String(rest[..<hostEnd])
        guard !rawHostPort.isEmpty && !rawHostPort.contains(" ") else { return nil }

        // Separate host and optional port
        let host: String
        let explicitPort: Int?
        if let colonIdx = rawHostPort.lastIndex(of: ":") {
            host = String(rawHostPort[..<colonIdx]).lowercased()
            let portStr = String(rawHostPort[rawHostPort.index(after: colonIdx)...])
            explicitPort = Int(portStr)
        } else {
            host = rawHostPort.lowercased()
            explicitPort = nil
        }

        guard !host.isEmpty else { return nil }

        // Strip default ports
        let normalizedPort: Int?
        switch (scheme, explicitPort) {
        case ("http", 80), ("https", 443), ("ftp", 21):
            normalizedPort = nil
        default:
            normalizedPort = explicitPort
        }

        // Clean domain name (strip leading www.)
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        let afterHost = String(rest[hostEnd...])
        let pathAndQuery: String
        if afterHost.isEmpty {
            pathAndQuery = "/"
        } else if !afterHost.hasPrefix("/") && !afterHost.hasPrefix("?") && !afterHost.hasPrefix("#") {
            pathAndQuery = "/" + afterHost
        } else {
            pathAndQuery = afterHost
        }

        var normalizedUrl = "\(scheme)://\(host)"
        if let port = normalizedPort {
            normalizedUrl += ":\(port)"
        }
        normalizedUrl += pathAndQuery

        return UrlInfo(
            originalString: trimmed,
            scheme: scheme,
            host: host,
            domain: domain,
            normalizedUrlString: normalizedUrl,
            path: pathAndQuery
        )
    }
}

// MARK: - URL Badge & Click-Safe View

/// Renders a domain badge for recognized URLs.
public struct UrlBadgeView: View {
    public let urlInfo: UrlInfo
    public let isSelected: Bool

    public init(urlInfo: UrlInfo, isSelected: Bool) {
        self.urlInfo = urlInfo
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "link")
                .font(.system(size: 9))
            Text(urlInfo.domain)
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            isSelected
                ? Color.white.opacity(0.2)
                : Color.accentColor.opacity(0.12)
        )
        .foregroundColor(isSelected ? .white : .accentColor)
        .cornerRadius(4)
    }
}
