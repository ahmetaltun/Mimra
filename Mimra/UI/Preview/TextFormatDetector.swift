// ==============================================================================
// Mimra — Text Format Detector
// Fast, deterministic, zero-network detection of Markdown, JSON, RTF, and HTML
// clipboard payloads for the Preview Window formatter switch.
// ==============================================================================

import Foundation

/// Supported structured/formatted text kinds in the Preview Window.
public enum DetectedTextFormat: String, Equatable, Sendable {
    case plain
    case markdown
    case json
    case rtf
    case html

    public var badgeLabel: String? {
        switch self {
        case .plain: return nil
        case .markdown: return "MARKDOWN"
        case .json: return "JSON"
        case .rtf: return "RTF"
        case .html: return "HTML"
        }
    }

    public var isFormattable: Bool {
        self != .plain
    }
}

/// Heuristic and structural detector for clipboard text formats.
public enum TextFormatDetector {
    /// Maximum payload size (512 KB) to run full structural/markdown heuristics on.
    private static let maxDetectionBytes = 512 * 1024

    public static func detect(
        text: String,
        availableUtis: [String] = [],
        hasRtfData: Bool = false,
        hasHtmlData: Bool = false
    ) -> DetectedTextFormat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. JSON detection (only if bounded and starts/ends with object/array delimiters)
        if !trimmed.isEmpty && trimmed.utf8.count <= maxDetectionBytes {
            if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
               (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
                if let data = trimmed.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data, options: [])) != nil {
                    return .json
                }
            }
        }

        // 2. Markdown detection (bounded line scan)
        if !trimmed.isEmpty && trimmed.utf8.count <= maxDetectionBytes {
            if looksLikeMarkdown(trimmed) {
                return .markdown
            }
        }

        // 3. RTF / HTML representations from pasteboard UTIs
        if hasRtfData || availableUtis.contains("public.rtf") {
            return .rtf
        }
        if hasHtmlData || availableUtis.contains("public.html") {
            return .html
        }

        return .plain
    }

    /// Fast bounded heuristic to distinguish Markdown from ordinary plain prose.
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        var strongSignals = 0
        var mediumSignals = 0
        var inCodeFence = false
        var lineCount = 0

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            lineCount += 1
            if lineCount > 250 { break }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Fenced code block
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if inCodeFence {
                    strongSignals += 1
                }
                inCodeFence.toggle()
                continue
            }
            if inCodeFence { continue }

            // ATX Heading: # Title .. ###### Title
            if isAtxHeading(line) {
                strongSignals += 1
            }

            // Task list: - [ ] or - [x]
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") ||
               line.hasPrefix("* [ ] ") || line.hasPrefix("* [x] ") || line.hasPrefix("* [X] ") {
                strongSignals += 1
            }

            // Markdown table separator: |---|---|
            if isTableSeparatorLine(line) {
                strongSignals += 1
            }

            // Blockquote: > text
            if line.hasPrefix("> ") {
                mediumSignals += 1
            }

            // Unordered list: - item / * item
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                mediumSignals += 1
            }

            // Ordered list: 1. item
            if isOrderedListItem(line) {
                mediumSignals += 1
            }

            // Horizontal rule: --- or *** or ___
            if line == "---" || line == "***" || line == "___" {
                mediumSignals += 1
            }

            // Inline Markdown links: [label](url)
            if containsMarkdownLink(line) {
                strongSignals += 1
            }

            // Inline bold **text** or inline code `code`
            if line.contains("**") && hasPairedMarker(line, marker: "**") {
                mediumSignals += 1
            }
            if line.contains("`") && hasPairedMarker(line, marker: "`") {
                mediumSignals += 1
            }

            if strongSignals >= 1 || mediumSignals >= 2 {
                return true
            }
        }

        return strongSignals >= 1 || mediumSignals >= 2
    }

    private static func isAtxHeading(_ line: String) -> Bool {
        var hashCount = 0
        for ch in line {
            if ch == "#" {
                hashCount += 1
                if hashCount > 6 { return false }
            } else if ch == " " {
                return hashCount >= 1 && line.count > hashCount + 1
            } else {
                return false
            }
        }
        return false
    }

    private static func isOrderedListItem(_ line: String) -> Bool {
        var digits = 0
        for ch in line {
            if ch.isNumber {
                digits += 1
                if digits > 4 { return false }
            } else if ch == "." {
                if digits == 0 { return false }
                let afterDotIdx = line.index(line.startIndex, offsetBy: digits + 1)
                return afterDotIdx < line.endIndex && line[afterDotIdx] == " "
            } else {
                return false
            }
        }
        return false
    }

    private static func isTableSeparatorLine(_ line: String) -> Bool {
        guard line.contains("|") && line.contains("---") else { return false }
        let allowed = CharacterSet(charactersIn: "|-: ")
        return line.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func containsMarkdownLink(_ line: String) -> Bool {
        guard let openBracket = line.firstIndex(of: "["),
              let closeBracket = line[openBracket...].firstIndex(of: "]"),
              closeBracket < line.endIndex else {
            return false
        }
        let afterBracket = line.index(after: closeBracket)
        guard afterBracket < line.endIndex, line[afterBracket] == "(" else {
            return false
        }
        return line[afterBracket...].contains(")")
    }

    private static func hasPairedMarker(_ line: String, marker: String) -> Bool {
        guard let first = line.range(of: marker) else { return false }
        return line[first.upperBound...].range(of: marker) != nil
    }
}
