// ==============================================================================
// Mimra — Color & URL Inspector Cards for Preview Window
// Provides rich visual inspection, WCAG contrast ratios, format conversion pills,
// and parsed URL query parameter inspection with one-click copy.
// ==============================================================================

import AppKit
import SwiftUI

// MARK: - HexColorInfo Format & Contrast Extensions

public extension HexColorInfo {
    var rgbString: String {
        let rInt = Int(round(red * 255))
        let gInt = Int(round(green * 255))
        let bInt = Int(round(blue * 255))
        if alpha < 0.999 {
            return String(format: "rgba(%d, %d, %d, %.2f)", rInt, gInt, bInt, alpha)
        }
        return "rgb(\(rInt), \(gInt), \(bInt))"
    }

    var hslString: String {
        let maxC = max(red, green, blue)
        let minC = min(red, green, blue)
        let l = (maxC + minC) / 2.0
        var h: Double = 0
        var s: Double = 0

        if maxC != minC {
            let d = maxC - minC
            s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC)
            if maxC == red {
                h = (green - blue) / d + (green < blue ? 6.0 : 0.0)
            } else if maxC == green {
                h = (blue - red) / d + 2.0
            } else {
                h = (red - green) / d + 4.0
            }
            h /= 6.0
        }

        let hDeg = Int(round(h * 360))
        let sPct = Int(round(s * 100))
        let lPct = Int(round(l * 100))
        if alpha < 0.999 {
            return String(format: "hsla(%d, %d%%, %d%%, %.2f)", hDeg, sPct, lPct, alpha)
        }
        return "hsl(\(hDeg), \(sPct)%, \(lPct)%)"
    }

    var swiftUICodeString: String {
        if alpha < 0.999 {
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f, opacity: %.2f)", red, green, blue, alpha)
        }
        return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", red, green, blue)
    }

    var nsColorCodeString: String {
        String(format: "NSColor(srgbRed: %.3f, green: %.3f, blue: %.3f, alpha: %.2f)", red, green, blue, alpha)
    }

    /// Relative luminance per WCAG 2.1.
    var relativeLuminance: Double {
        func linearize(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// Contrast ratio against white (1.0) and black (0.0).
    var contrastAgainstWhite: Double {
        (1.0 + 0.05) / (relativeLuminance + 0.05)
    }

    var contrastAgainstBlack: Double {
        (relativeLuminance + 0.05) / (0.0 + 0.05)
    }
}

// MARK: - Color Inspector Card

@MainActor
public struct ColorInspectorCard: View {
    public let colorInfo: HexColorInfo
    @State private var copiedLabel: String? = nil

    public init(colorInfo: HexColorInfo) {
        self.colorInfo = colorInfo
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Large Swatch Banner
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(colorInfo.color)
                    .frame(height: 68)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    Text(colorInfo.formattedHex)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(colorInfo.isDark ? .white : .black)

                    Spacer()

                    contrastBadge(label: "White", ratio: colorInfo.contrastAgainstWhite)
                    contrastBadge(label: "Black", ratio: colorInfo.contrastAgainstBlack)
                }
                .padding(8)
            }

            // Format Copy Pills
            FlowLayout(spacing: 6) {
                copyPill(title: "HEX", value: colorInfo.formattedHex)
                copyPill(title: "RGB", value: colorInfo.rgbString)
                copyPill(title: "HSL", value: colorInfo.hslString)
                copyPill(title: "SwiftUI", value: colorInfo.swiftUICodeString)
                copyPill(title: "NSColor", value: colorInfo.nsColorCodeString)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func contrastBadge(label: String, ratio: Double) -> some View {
        let grade = ratio >= 7.0 ? "AAA" : (ratio >= 4.5 ? "AA" : "Low")
        return Text("\(label): \(String(format: "%.1f", ratio)):1 \(grade)")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((colorInfo.isDark ? Color.black : Color.white).opacity(0.35))
            .foregroundColor(colorInfo.isDark ? .white : .black)
            .cornerRadius(4)
    }

    private func copyPill(title: String, value: String) -> some View {
        let isCopied = copiedLabel == title
        return Button(action: {
            copyToPasteboard(value, label: title)
        }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Text(isCopied ? "Copied!" : value)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(isCopied ? .green : .primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help("Copy \(title): \(value)")
    }

    private func copyToPasteboard(_ value: String, label: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setData(Data(), forType: ClipboardProvenance.provenanceType)
        item.setString(ClipboardProvenance.mimraBundleIdentifier, forType: ClipboardProvenance.sourceAppType)
        if pb.writeObjects([item]) {
            ClipboardProvenance.shared.recordSelfWrite(on: pb)
            copiedLabel = label
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if copiedLabel == label { copiedLabel = nil }
            }
        }
    }
}

// MARK: - URL Inspector Card

@MainActor
public struct UrlInspectorCard: View {
    public let urlInfo: UrlInfo
    @State private var copiedKey: String? = nil

    public init(urlInfo: UrlInfo) {
        self.urlInfo = urlInfo
    }

    private var components: URLComponents? {
        URLComponents(string: urlInfo.originalString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var cleanUrlWithoutQuery: String? {
        guard var comp = components, comp.queryItems != nil else { return nil }
        comp.query = nil
        comp.fragment = nil
        return comp.string
    }

    public var body: some View {
        let queryItems = components?.queryItems ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)

                Text(urlInfo.domain.isEmpty ? urlInfo.host : urlInfo.domain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)

                Text(urlInfo.scheme.uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .cornerRadius(3)

                Spacer()

                if let clean = cleanUrlWithoutQuery {
                    Button(action: { copyString(clean, key: "__clean__") }) {
                        HStack(spacing: 3) {
                            Image(systemName: copiedKey == "__clean__" ? "checkmark" : "scissors")
                                .font(.system(size: 9))
                            Text(copiedKey == "__clean__" ? "Copied Clean URL" : "Copy Without Query")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(copiedKey == "__clean__" ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy URL without query parameters or fragment")
                }
            }

            if !urlInfo.path.isEmpty && urlInfo.path != "/" {
                HStack(spacing: 4) {
                    Text("PATH")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text(urlInfo.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            if !queryItems.isEmpty {
                Divider().opacity(0.2)

                Text("QUERY PARAMETERS (\(queryItems.count))")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))

                VStack(spacing: 4) {
                    ForEach(Array(queryItems.enumerated()), id: \.offset) { idx, q in
                        let rowId = "\(idx)-\(q.name)"
                        HStack(spacing: 6) {
                            Text(q.name)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .lineLimit(1)

                            Text("=")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.5))

                            Text(q.value ?? "")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button(action: { copyString(q.value ?? "", key: rowId) }) {
                                Image(systemName: copiedKey == rowId ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9))
                                    .foregroundColor(copiedKey == rowId ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy parameter value")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.03))
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func copyString(_ str: String, key: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(str, forType: .string)
        item.setData(Data(), forType: ClipboardProvenance.provenanceType)
        item.setString(ClipboardProvenance.mimraBundleIdentifier, forType: ClipboardProvenance.sourceAppType)
        if pb.writeObjects([item]) {
            ClipboardProvenance.shared.recordSelfWrite(on: pb)
            copiedKey = key
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if copiedKey == key { copiedKey = nil }
            }
        }
    }
}
