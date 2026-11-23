// ==============================================================================
// Mimra — Native Text Formatters (Markdown, JSON, RTF, HTML)
// Zero-WebView, zero-network native NSAttributedString formatters for NSTextView.
// ==============================================================================

import AppKit
import Foundation

// MARK: - JSON Formatter & Syntax Highlighter

public enum JsonTextFormatter {
    /// Returns a pretty-printed JSON string if valid JSON, or nil otherwise.
    public static func prettyPrint(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let prettyStr = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return prettyStr
    }

    /// Single-pass O(N) JSON syntax highlighter returning an NSAttributedString.
    public static func attributedHighlight(_ json: String, fontSize: CGFloat = 12) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let result = NSMutableAttributedString(
            string: json,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )

        let ns = json as NSString
        let length = ns.length
        var i = 0

        let keyColor = NSColor.systemBlue
        let stringColor = NSColor.systemGreen
        let numberColor = NSColor.systemOrange
        let keywordColor = NSColor.systemPurple
        let punctColor = NSColor.secondaryLabelColor

        while i < length {
            let ch = ns.character(at: i)

            // String literal
            if ch == 34 { // '"'
                let start = i
                i += 1
                while i < length {
                    let c = ns.character(at: i)
                    if c == 92 { // '\'
                        i += 2
                        continue
                    }
                    if c == 34 {
                        i += 1
                        break
                    }
                    i += 1
                }
                let range = NSRange(location: start, length: i - start)
                // Look ahead past whitespace for ':' to distinguish object key vs string value
                var lookahead = i
                var isKey = false
                while lookahead < length {
                    let lc = ns.character(at: lookahead)
                    if lc == 32 || lc == 9 || lc == 10 || lc == 13 {
                        lookahead += 1
                        continue
                    }
                    if lc == 58 { // ':'
                        isKey = true
                    }
                    break
                }
                result.addAttribute(.foregroundColor, value: isKey ? keyColor : stringColor, range: range)
                continue
            }

            // Punctuation
            if ch == 123 || ch == 125 || ch == 91 || ch == 93 || ch == 58 || ch == 44 { // { } [ ] : ,
                result.addAttribute(.foregroundColor, value: punctColor, range: NSRange(location: i, length: 1))
                i += 1
                continue
            }

            // Numbers (including negative)
            if (ch >= 48 && ch <= 57) || ch == 45 {
                let start = i
                i += 1
                while i < length {
                    let c = ns.character(at: i)
                    if (c >= 48 && c <= 57) || c == 46 || c == 101 || c == 69 || c == 43 || c == 45 {
                        i += 1
                    } else {
                        break
                    }
                }
                result.addAttribute(.foregroundColor, value: numberColor, range: NSRange(location: start, length: i - start))
                continue
            }

            // Booleans & null
            if ch == 116 || ch == 102 || ch == 110 { // t, f, n
                let remaining = length - i
                if remaining >= 4 && ns.substring(with: NSRange(location: i, length: 4)) == "true" {
                    let r = NSRange(location: i, length: 4)
                    result.addAttributes([.foregroundColor: keywordColor, .font: boldFont], range: r)
                    i += 4
                    continue
                } else if remaining >= 5 && ns.substring(with: NSRange(location: i, length: 5)) == "false" {
                    let r = NSRange(location: i, length: 5)
                    result.addAttributes([.foregroundColor: keywordColor, .font: boldFont], range: r)
                    i += 5
                    continue
                } else if remaining >= 4 && ns.substring(with: NSRange(location: i, length: 4)) == "null" {
                    let r = NSRange(location: i, length: 4)
                    result.addAttributes([.foregroundColor: keywordColor, .font: boldFont], range: r)
                    i += 4
                    continue
                }
            }

            i += 1
        }

        return result
    }
}

// MARK: - Native Markdown -> NSAttributedString Renderer

public enum MarkdownAttributedRenderer {
    public static func render(_ markdown: String, baseFontSize: CGFloat = 12.5) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")

        let bodyFont = NSFont.systemFont(ofSize: baseFontSize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: max(11, baseFontSize - 1), weight: .regular)

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Fenced Code Block (``` or ~~~)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }

                if !lang.isEmpty {
                    let langStyle = NSMutableParagraphStyle()
                    langStyle.paragraphSpacingBefore = 6
                    langStyle.paragraphSpacing = 2
                    output.append(NSAttributedString(
                        string: "\(lang.uppercased())\n",
                        attributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold),
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .paragraphStyle: langStyle
                        ]
                    ))
                }

                let codeStyle = NSMutableParagraphStyle()
                codeStyle.headIndent = 10
                codeStyle.firstLineHeadIndent = 10
                codeStyle.tailIndent = -10
                codeStyle.paragraphSpacing = 8
                codeStyle.lineSpacing = 2

                let codeBlock = codeLines.joined(separator: "\n") + "\n"
                output.append(NSAttributedString(
                    string: codeBlock,
                    attributes: [
                        .font: monoFont,
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18),
                        .paragraphStyle: codeStyle
                    ]
                ))
                continue
            }

            // 2. Markdown Table Block
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                var tableRows: [[String]] = []
                while i < lines.count {
                    let rowTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if !rowTrimmed.contains("|") { break }
                    if !isTableSeparator(rowTrimmed) {
                        tableRows.append(parseTableCells(rowTrimmed))
                    }
                    i += 1
                }
                appendTable(tableRows, to: output, monoFont: monoFont)
                continue
            }

            // 3. Horizontal Rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                let hrStyle = NSMutableParagraphStyle()
                hrStyle.paragraphSpacingBefore = 6
                hrStyle.paragraphSpacing = 8
                output.append(NSAttributedString(
                    string: "────────────────────────────────────\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.separatorColor,
                        .paragraphStyle: hrStyle
                    ]
                ))
                i += 1
                continue
            }

            // 4. ATX Headings (# .. ######)
            if let (level, headingText) = parseHeading(trimmed) {
                let sizeDelta: CGFloat = switch level {
                case 1: 7.0
                case 2: 4.5
                case 3: 2.5
                case 4: 1.0
                default: 0.0
                }
                let headingFont = NSFont.systemFont(ofSize: baseFontSize + sizeDelta, weight: .bold)
                let hStyle = NSMutableParagraphStyle()
                hStyle.paragraphSpacingBefore = level <= 2 ? 10 : 6
                hStyle.paragraphSpacing = 4

                let inline = renderInline(headingText, baseFont: headingFont, baseColor: .labelColor)
                inline.addAttribute(.paragraphStyle, value: hStyle, range: NSRange(location: 0, length: inline.length))
                output.append(inline)
                output.append(NSAttributedString(string: "\n"))
                i += 1
                continue
            }

            // 5. Blockquote (> ...)
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                let quoteText = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : ""
                let qStyle = NSMutableParagraphStyle()
                qStyle.firstLineHeadIndent = 8
                qStyle.headIndent = 18
                qStyle.paragraphSpacing = 4

                let bar = NSAttributedString(
                    string: "▎ ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: baseFontSize, weight: .bold),
                        .foregroundColor: NSColor.controlAccentColor,
                        .paragraphStyle: qStyle
                    ]
                )
                let inline = renderInline(quoteText, baseFont: bodyFont, baseColor: .secondaryLabelColor)
                inline.addAttribute(.paragraphStyle, value: qStyle, range: NSRange(location: 0, length: inline.length))
                output.append(bar)
                output.append(inline)
                output.append(NSAttributedString(string: "\n"))
                i += 1
                continue
            }

            // 6. Task Lists & Unordered Lists
            if let (prefix, content, indentLevel) = parseListLine(line) {
                let lStyle = NSMutableParagraphStyle()
                let baseIndent = CGFloat(indentLevel) * 14.0
                lStyle.firstLineHeadIndent = baseIndent + 4
                lStyle.headIndent = baseIndent + 18
                lStyle.paragraphSpacing = 3

                let bulletAttr = NSAttributedString(
                    string: prefix,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: baseFontSize, weight: .semibold),
                        .foregroundColor: prefix.contains("☑") ? NSColor.systemGreen : NSColor.secondaryLabelColor,
                        .paragraphStyle: lStyle
                    ]
                )
                let inline = renderInline(content, baseFont: bodyFont, baseColor: .labelColor)
                inline.addAttribute(.paragraphStyle, value: lStyle, range: NSRange(location: 0, length: inline.length))
                output.append(bulletAttr)
                output.append(inline)
                output.append(NSAttributedString(string: "\n"))
                i += 1
                continue
            }

            // 7. Empty line
            if trimmed.isEmpty {
                output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
                i += 1
                continue
            }

            // 8. Standard paragraph line
            let pStyle = NSMutableParagraphStyle()
            pStyle.lineSpacing = 3
            pStyle.paragraphSpacing = 4
            let inline = renderInline(line, baseFont: bodyFont, baseColor: .labelColor)
            inline.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: inline.length))
            output.append(inline)
            output.append(NSAttributedString(string: "\n"))
            i += 1
        }

        // Trim trailing extra newline
        if output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    // MARK: - Inline Parser (Zero-KeyPath Swift 6 Strict Concurrency Safe)

    private static func renderInline(
        _ text: String,
        baseFont: NSFont,
        baseColor: NSColor
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let monoFont = NSFont.monospacedSystemFont(ofSize: max(10.5, baseFont.pointSize - 1), weight: .regular)
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)

        var idx = text.startIndex
        var plainBuffer = ""

        func flushPlain() {
            if !plainBuffer.isEmpty {
                result.append(NSAttributedString(
                    string: plainBuffer,
                    attributes: [.font: baseFont, .foregroundColor: baseColor]
                ))
                plainBuffer = ""
            }
        }

        while idx < text.endIndex {
            let rest = text[idx...]

            // 1. Inline code: `code`
            if rest.hasPrefix("`") {
                let afterOpen = text.index(after: idx)
                if afterOpen < text.endIndex, let closeRange = text[afterOpen...].range(of: "`") {
                    flushPlain()
                    let codeText = String(text[afterOpen..<closeRange.lowerBound])
                    result.append(NSAttributedString(
                        string: codeText,
                        attributes: [
                            .font: monoFont,
                            .foregroundColor: baseColor,
                            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.22)
                        ]
                    ))
                    idx = closeRange.upperBound
                    continue
                }
            }

            // 2. Markdown link: [label](url)
            if rest.hasPrefix("[") {
                let afterBracket = text.index(after: idx)
                if let closeBracket = text[afterBracket...].firstIndex(of: "]") {
                    let afterClose = text.index(after: closeBracket)
                    if afterClose < text.endIndex, text[afterClose] == "(" {
                        let urlStart = text.index(after: afterClose)
                        if let closeParen = text[urlStart...].firstIndex(of: ")") {
                            let label = String(text[afterBracket..<closeBracket])
                            let urlStr = String(text[urlStart..<closeParen])
                            flushPlain()
                            var attrs: [NSAttributedString.Key: Any] = [
                                .font: baseFont,
                                .foregroundColor: NSColor.linkColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                            if let url = URL(string: urlStr) {
                                attrs[.link] = url
                            }
                            result.append(NSAttributedString(string: label, attributes: attrs))
                            idx = text.index(after: closeParen)
                            continue
                        }
                    }
                }
            }

            // 3. Bold: **text** or __text__
            if rest.hasPrefix("**") || rest.hasPrefix("__") {
                let marker = String(rest.prefix(2))
                let afterOpen = text.index(idx, offsetBy: 2)
                if afterOpen < text.endIndex, let closeRange = text[afterOpen...].range(of: marker) {
                    flushPlain()
                    let inner = String(text[afterOpen..<closeRange.lowerBound])
                    result.append(NSAttributedString(
                        string: inner,
                        attributes: [.font: boldFont, .foregroundColor: baseColor]
                    ))
                    idx = closeRange.upperBound
                    continue
                }
            }

            // 4. Strikethrough: ~~text~~
            if rest.hasPrefix("~~") {
                let afterOpen = text.index(idx, offsetBy: 2)
                if afterOpen < text.endIndex, let closeRange = text[afterOpen...].range(of: "~~") {
                    flushPlain()
                    let inner = String(text[afterOpen..<closeRange.lowerBound])
                    result.append(NSAttributedString(
                        string: inner,
                        attributes: [
                            .font: baseFont,
                            .foregroundColor: baseColor,
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue
                        ]
                    ))
                    idx = closeRange.upperBound
                    continue
                }
            }

            // 5. Italic: *text* or _text_
            if rest.hasPrefix("*") || rest.hasPrefix("_") {
                let marker = String(rest.prefix(1))
                let afterOpen = text.index(after: idx)
                if afterOpen < text.endIndex,
                   text[afterOpen] != " ",
                   let closeRange = text[afterOpen...].range(of: marker) {
                    flushPlain()
                    let inner = String(text[afterOpen..<closeRange.lowerBound])
                    result.append(NSAttributedString(
                        string: inner,
                        attributes: [.font: italicFont, .foregroundColor: baseColor]
                    ))
                    idx = closeRange.upperBound
                    continue
                }
            }

            plainBuffer.append(text[idx])
            idx = text.index(after: idx)
        }

        flushPlain()
        return result
    }

    // MARK: - Block Helpers

    private static func parseHeading(_ trimmed: String) -> (Int, String)? {
        var level = 0
        for ch in trimmed {
            if ch == "#" {
                level += 1
                if level > 6 { return nil }
            } else if ch == " " {
                guard level >= 1 else { return nil }
                let content = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                return content.isEmpty ? nil : (level, content)
            } else {
                return nil
            }
        }
        return nil
    }

    private static func parseListLine(_ line: String) -> (prefix: String, content: String, indent: Int)? {
        let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let indentLevel = leadingSpaces / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("* [ ] ") {
            return ("☐ ", String(trimmed.dropFirst(6)), indentLevel)
        }
        if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") ||
           trimmed.hasPrefix("* [x] ") || trimmed.hasPrefix("* [X] ") {
            return ("☑ ", String(trimmed.dropFirst(6)), indentLevel)
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return ("• ", String(trimmed.dropFirst(2)), indentLevel)
        }

        // Ordered list: e.g. "1. Item"
        if let dotIdx = trimmed.firstIndex(of: ".") {
            let numPart = trimmed[..<dotIdx]
            let afterDot = trimmed.index(after: dotIdx)
            if !numPart.isEmpty && numPart.allSatisfy({ $0.isNumber }) &&
               afterDot < trimmed.endIndex && trimmed[afterDot] == " " {
                let content = String(trimmed[trimmed.index(after: afterDot)...])
                return ("\(numPart). ", content, indentLevel)
            }
        }

        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("---") else { return false }
        let allowed = CharacterSet(charactersIn: "|-: ")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func parseTableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func appendTable(_ rows: [[String]], to output: NSMutableAttributedString, monoFont: NSFont) {
        guard !rows.isEmpty else { return }
        let colCount = rows.map(\.count).max() ?? 0
        guard colCount > 0 else { return }

        var widths = Array(repeating: 3, count: colCount)
        for row in rows {
            for (idx, cell) in row.enumerated() where idx < colCount {
                widths[idx] = max(widths[idx], cell.count)
            }
        }

        let boldMono = NSFont.monospacedSystemFont(ofSize: monoFont.pointSize, weight: .bold)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 3
        style.lineSpacing = 2

        for (rowIdx, row) in rows.enumerated() {
            var formattedCells: [String] = []
            for c in 0..<colCount {
                let val = c < row.count ? row[c] : ""
                formattedCells.append(val.padding(toLength: widths[c], withPad: " ", startingAt: 0))
            }
            let line = formattedCells.joined(separator: " │ ") + "\n"
            output.append(NSAttributedString(
                string: line,
                attributes: [
                    .font: rowIdx == 0 ? boldMono : monoFont,
                    .foregroundColor: rowIdx == 0 ? NSColor.labelColor : NSColor.secondaryLabelColor,
                    .paragraphStyle: style
                ]
            ))
            if rowIdx == 0 {
                let sep = widths.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─") + "\n"
                output.append(NSAttributedString(
                    string: sep,
                    attributes: [
                        .font: monoFont,
                        .foregroundColor: NSColor.separatorColor,
                        .paragraphStyle: style
                    ]
                ))
            }
        }
    }
}

// MARK: - Native RTF & Safe Offline HTML Renderer

public enum RichTextAttributedRenderer {
    /// Decodes RTF bytes natively via AppKit and adapts contrast if needed.
    public static func renderRtf(_ data: Data) -> NSAttributedString? {
        guard let attr = NSAttributedString(rtf: data, documentAttributes: nil) else {
            return nil
        }
        return adaptContrastIfNeeded(attr)
    }

    /// Lightweight, zero-WebKit, zero-network HTML -> NSAttributedString renderer.
    public static func renderHtml(_ html: String, baseFontSize: CGFloat = 12.5) -> NSAttributedString {
        // Strip <style> and <script> blocks
        var cleaned = html
        cleaned = cleaned.replacingOccurrences(of: #"(?is)<style[^>]*>.*?</style>"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?is)<script[^>]*>.*?</script>"#, with: "", options: .regularExpression)

        // Convert block breaks to newlines
        cleaned = cleaned.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)</(p|div|h[1-6]|li|tr|blockquote)>"#, with: "\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)<li[^>]*>"#, with: "• ", options: .regularExpression)

        // Strip remaining tags
        cleaned = cleaned.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        cleaned = decodeHtmlEntities(cleaned)

        // Collapse excessive blank lines
        cleaned = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 4

        return NSAttributedString(
            string: cleaned,
            attributes: [
                .font: NSFont.systemFont(ofSize: baseFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
        )
    }

    private static func decodeHtmlEntities(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func adaptContrastIfNeeded(_ input: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: input)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            } else if let color = value as? NSColor,
                      let srgb = color.usingColorSpace(.sRGB),
                      srgb.redComponent < 0.12 && srgb.greenComponent < 0.12 && srgb.blueComponent < 0.12 {
                // Default black text from rich editors becomes adaptive labelColor
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        return mutable
    }
}
