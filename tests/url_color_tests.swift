// ==============================================================================
// Mimra — URL & HEX Color Recognition Automated Tests (T-TYPE-04, T-TYPE-06)
// Linked Features: F-006, F-037
// ==============================================================================

import AppKit
import Foundation

@main
struct UrlColorTests {
    static func main() async {
        print("----------------------------------------------------------------------")
        print("Starting URL & Color Recognition Tests (T-TYPE-04, T-TYPE-06)")
        print("----------------------------------------------------------------------")

        // =========================================================================
        // 1. URL Detection & Canonicalization Tests (T-TYPE-04, F-006)
        // =========================================================================
        print("1. Testing URL Detection & Canonicalization...")

        // 1a. Standard HTTPS URL
        let standardUrl = "HTTPS://WWW.EXAMPLE.COM/path/to/page"
        guard let urlInfo1 = UrlDetector.detect(in: standardUrl) else {
            fatalError("FAIL: Expected valid URL for '\(standardUrl)'")
        }
        assert(urlInfo1.scheme == "https", "FAIL: Scheme must be lowercased to 'https'")
        assert(urlInfo1.host == "www.example.com", "FAIL: Host must be lowercased")
        assert(urlInfo1.domain == "example.com", "FAIL: Domain must strip 'www.' prefix, got '\(urlInfo1.domain)'")
        assert(urlInfo1.normalizedUrlString == "https://www.example.com/path/to/page", "FAIL: Normalized URL mismatch")
        print("  ✓ Standard HTTPS URL normalized with clean domain extraction")

        // 1b. Default port removal (80 for http, 443 for https)
        guard let httpDefaultPort = UrlDetector.detect(in: "http://example.com:80/index.html") else {
            fatalError("FAIL: Expected valid URL for default http port")
        }
        assert(httpDefaultPort.normalizedUrlString == "http://example.com/index.html", "FAIL: Port 80 should be stripped")

        guard let httpsDefaultPort = UrlDetector.detect(in: "https://example.com:443/api") else {
            fatalError("FAIL: Expected valid URL for default https port")
        }
        assert(httpsDefaultPort.normalizedUrlString == "https://example.com/api", "FAIL: Port 443 should be stripped")

        // 1c. Custom port retention
        guard let customPort = UrlDetector.detect(in: "http://localhost:8080/dashboard") else {
            fatalError("FAIL: Expected valid URL for custom port")
        }
        assert(customPort.normalizedUrlString == "http://localhost:8080/dashboard", "FAIL: Custom port 8080 should be preserved")
        assert(customPort.domain == "localhost", "FAIL: Domain should be 'localhost'")
        print("  ✓ Default ports stripped, custom ports preserved")

        // 1d. Query parameters and fragments
        let complexUrl = "https://github.com/rust-lang/rust/pull/1234?tab=files#diff-1"
        guard let complexInfo = UrlDetector.detect(in: complexUrl) else {
            fatalError("FAIL: Expected valid URL for complex URL")
        }
        assert(complexInfo.domain == "github.com", "FAIL: Domain should be 'github.com'")
        assert(complexInfo.normalizedUrlString == complexUrl, "FAIL: Query and fragment should be preserved")
        print("  ✓ Query parameters and fragments preserved")

        // 1e. Invalid URLs rejected
        assert(UrlDetector.detect(in: "") == nil, "FAIL: Empty string should not be URL")
        assert(UrlDetector.detect(in: "not a url") == nil, "FAIL: Plain text should not be URL")
        assert(UrlDetector.detect(in: "http://") == nil, "FAIL: Incomplete URL should be rejected")
        assert(UrlDetector.detect(in: "http://has space.com") == nil, "FAIL: URL with spaces in host should be rejected")
        assert(UrlDetector.detect(in: "file:///Users/doc.txt") == nil, "FAIL: file:// should not be handled by UrlDetector (reserved for FileUrls)")
        print("  ✓ Invalid URLs rejected properly")

        // =========================================================================
        // 2. HEX Color Detection & Swatch Tests (T-TYPE-06, F-037)
        // =========================================================================
        print("2. Testing HEX Color Detection...")

        // 2a. 3-digit #RGB
        guard let colorRgb = ColorDetector.detect(in: "#f0a") else {
            fatalError("FAIL: Expected valid color for #f0a")
        }
        assert(abs(colorRgb.red - 1.0) < 0.001, "FAIL: Red should be 1.0 (0xFF)")
        assert(abs(colorRgb.green - 0.0) < 0.001, "FAIL: Green should be 0.0 (0x00)")
        assert(abs(colorRgb.blue - (Double(0xAA) / 255.0)) < 0.01, "FAIL: Blue should be ~0.667 (0xAA)")
        assert(abs(colorRgb.alpha - 1.0) < 0.001, "FAIL: Alpha should default to 1.0")
        assert(colorRgb.formattedHex == "#FF00AA", "FAIL: Formatted hex mismatch: \(colorRgb.formattedHex)")
        print("  ✓ 3-digit #RGB parsed and expanded to 8-bit per channel")

        // 2b. 4-digit #RGBA
        guard let colorRgba = ColorDetector.detect(in: "#1238") else {
            fatalError("FAIL: Expected valid color for #1238")
        }
        assert(abs(colorRgba.alpha - (Double(0x88) / 255.0)) < 0.001, "FAIL: Alpha parsed incorrectly")
        assert(colorRgba.formattedHex == "#11223388", "FAIL: Formatted hex mismatch: \(colorRgba.formattedHex)")
        print("  ✓ 4-digit #RGBA parsed with alpha")

        // 2c. 6-digit #RRGGBB
        guard let colorRrggeb = ColorDetector.detect(in: "#336699") else {
            fatalError("FAIL: Expected valid color for #336699")
        }
        assert(abs(colorRrggeb.red - (51.0 / 255.0)) < 0.001, "FAIL: Red channel mismatch")
        assert(abs(colorRrggeb.green - (102.0 / 255.0)) < 0.001, "FAIL: Green channel mismatch")
        assert(abs(colorRrggeb.blue - (153.0 / 255.0)) < 0.001, "FAIL: Blue channel mismatch")
        assert(abs(colorRrggeb.alpha - 1.0) < 0.001, "FAIL: Alpha should be 1.0")
        assert(colorRrggeb.formattedHex == "#336699", "FAIL: Formatted hex mismatch: \(colorRrggeb.formattedHex)")
        print("  ✓ 6-digit #RRGGBB parsed accurately")

        // 2d. 8-digit #RRGGBBAA
        guard let colorRrggebbaa = ColorDetector.detect(in: "#FF573380") else {
            fatalError("FAIL: Expected valid color for #FF573380")
        }
        assert(abs(colorRrggebbaa.red - 1.0) < 0.001, "FAIL: Red channel mismatch")
        assert(abs(colorRrggebbaa.alpha - (128.0 / 255.0)) < 0.001, "FAIL: Alpha channel mismatch")
        assert(colorRrggebbaa.formattedHex == "#FF573380", "FAIL: Formatted hex mismatch: \(colorRrggebbaa.formattedHex)")
        print("  ✓ 8-digit #RRGGBBAA parsed accurately")

        // 2e. 0x prefix
        guard let color0x = ColorDetector.detect(in: "0x00FF00") else {
            fatalError("FAIL: Expected valid color for 0x00FF00")
        }
        assert(abs(color0x.green - 1.0) < 0.001, "FAIL: Green should be 1.0")
        print("  ✓ 0x prefix parsed successfully")

        // 2f. Whitespace tolerance
        guard let colorWhitespace = ColorDetector.detect(in: "  #AABBCC  \n") else {
            fatalError("FAIL: Expected valid color with whitespace")
        }
        assert(colorWhitespace.formattedHex == "#AABBCC", "FAIL: Whitespace parsing mismatch")
        print("  ✓ Whitespace trimming verified")

        // 2g. Invalid HEX inputs rejected
        assert(ColorDetector.detect(in: "") == nil, "FAIL: Empty string rejected")
        assert(ColorDetector.detect(in: "#") == nil, "FAIL: Bare # rejected")
        assert(ColorDetector.detect(in: "#12") == nil, "FAIL: 2 digits rejected")
        assert(ColorDetector.detect(in: "#12345") == nil, "FAIL: 5 digits rejected")
        assert(ColorDetector.detect(in: "#1234567") == nil, "FAIL: 7 digits rejected")
        assert(ColorDetector.detect(in: "#123456789") == nil, "FAIL: 9 digits rejected")
        assert(ColorDetector.detect(in: "#GG0011") == nil, "FAIL: Non-hex chars rejected")
        assert(ColorDetector.detect(in: "Hello World") == nil, "FAIL: Random text rejected")
        print("  ✓ Invalid color hex inputs rejected")

        // 2h. Luminance / Dark contrast
        let blackColor = ColorDetector.detect(in: "#000000")!
        assert(blackColor.isDark, "FAIL: #000000 must be marked dark")

        let whiteColor = ColorDetector.detect(in: "#FFFFFF")!
        assert(!whiteColor.isDark, "FAIL: #FFFFFF must not be marked dark")
        print("  ✓ Luminance contrast calculation verified")

        // =========================================================================
        // 3. Ingestion & Replay Fidelity (Text Remains Primary)
        // =========================================================================
        print("3. Testing Ingestion, Search, and Replay...")

        let tempDbPath = "/tmp/mimra_url_color_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDbPath)
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-shm")
        }

        do {
            let client = try CoreClient(databasePath: tempDbPath)

            // 3a. Ingest a URL
            let urlString = "https://developer.apple.com/documentation/swiftui"
            let urlRep = RawRepresentation(groupIndex: 0, uti: "public.url", payload: urlString.data(using: .utf8)!)
            let titleRep = RawRepresentation(groupIndex: 0, uti: "public.url-name", payload: "SwiftUI | Apple Developer Documentation".data(using: .utf8)!)
            let plainRep = RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: urlString.data(using: .utf8)!)

            let captureUrl = RawCapture(timestampMs: 1000, sourceBundleId: "com.apple.Safari", representations: [urlRep, titleRep, plainRep])
            let outcomeUrl = try await client.ingest(capture: captureUrl)
            assert(outcomeUrl.title == "SwiftUI | Apple Developer Documentation", "FAIL: Page title should be used as item title when available")

            let items = try await client.listPage(limit: 10, offset: 0)
            assert(!items.isEmpty, "FAIL: Item list should not be empty")
            let firstItem = items[0]
            assert(firstItem.title == "SwiftUI | Apple Developer Documentation", "FAIL: Listed item title mismatch")
            assert(firstItem.availableUtis.contains("public.url"), "FAIL: Available UTIs must include public.url")
            assert(firstItem.availableUtis.contains("public.url-name"), "FAIL: Available UTIs must include public.url-name")
            print("  ✓ URL ingested and listed with full representation fidelity")

            // Replay URL: Text remains primary
            let replayedUrlItems = PasteCoordinator.encodePasteboardItems(representations: [urlRep, titleRep, plainRep], mode: .plainText)
            assert(replayedUrlItems.count == 1, "FAIL: Plain paste should yield 1 pasteboard item")
            assert(replayedUrlItems[0].string(forType: .string) == urlString, "FAIL: Plain text paste must yield exact URL string")
            print("  ✓ Replay preserves exact URL string on plain text paste")

            // 3b. Ingest a HEX color
            let hexString = "#FF5733"
            let hexData = hexString.data(using: .utf8)!
            let hexRep = RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: hexData)
            let captureHex = RawCapture(timestampMs: 2000, sourceBundleId: "com.apple.dt.Xcode", representations: [hexRep])
            let outcomeHex = try await client.ingest(capture: captureHex)
            assert(outcomeHex.title == "#FF5733", "FAIL: Hex string should be exact item title")

            let hexItems = try await client.listPage(limit: 10, offset: 0)
            assert(hexItems.first?.title == "#FF5733", "FAIL: Listed hex title mismatch")
            print("  ✓ HEX color ingested with exact string title")

            // Replay HEX color: exact text string preserved
            let replayedHexItems = PasteCoordinator.encodePasteboardItems(representations: [hexRep], mode: .original)
            assert(replayedHexItems.count == 1, "FAIL: Original mode should yield 1 item")
            assert(replayedHexItems[0].string(forType: .string) == "#FF5733", "FAIL: Original hex string must be preserved on replay")
            print("  ✓ Replay preserves exact HEX color string (text remains primary)")

            print("----------------------------------------------------------------------")
            print("✓ ALL URL & COLOR RECOGNITION TESTS PASSED (T-TYPE-04, T-TYPE-06)")
            print("----------------------------------------------------------------------")
        } catch {
            fatalError("FAIL: Encountered unexpected error: \(error)")
        }
    }
}
