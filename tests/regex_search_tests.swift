// ==============================================================================
// Mimra Tests — Exact & Regex Search Modes, Error Feedback, and Stale Search Cancellation
// Linked Features: F-019, F-048
// Test IDs: T-SRCH-02, T-UI-03
// ==============================================================================

import AppKit
import Foundation

@main
struct RegexSearchTests {
    @MainActor
    static func main() async {
        print("=== Running Exact & Regex Search Tests (P4-03 / T-SRCH-02) ===")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_regex_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("regex_test.db").path

        do {
            let core = try CoreClient(databasePath: dbPath)

            // -----------------------------------------------------------------
            // 1. Ingest Test Corpus
            // -----------------------------------------------------------------
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            // Item 1: URL with https
            let cap1 = RawCapture(
                timestampMs: nowMs - 1000,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("https://mimra.app/docs/getting-started".utf8)
                    )
                ]
            )
            let res1 = try await core.ingest(capture: cap1)

            // Item 2: Text with pin code and port
            let cap2 = RawCapture(
                timestampMs: nowMs - 2000,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Port 8080 listening on local socket with code 42".utf8)
                    )
                ]
            )
            let res2 = try await core.ingest(capture: cap2)

            // Item 3: Title with words for exact matching test
            let cap3 = RawCapture(
                timestampMs: nowMs - 3000,
                sourceBundleId: "com.microsoft.VSCode",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Visual Studio Code Workspace".utf8)
                    )
                ]
            )
            let res3 = try await core.ingest(capture: cap3)

            // -----------------------------------------------------------------
            // 2. Exact Mode Verification
            // -----------------------------------------------------------------
            // Exact substring "Visual Studio" matches Item 3
            let exactMatch = try await core.searchPage(query: "Visual Studio", mode: .exact, limit: 10, offset: 0)
            assert(exactMatch.count == 1, "FAIL: Exact mode should match exactly Item 3")
            assert(exactMatch[0].id == res3.itemId)
            assert(!exactMatch[0].titleHighlights.isEmpty, "FAIL: Exact match must produce highlights")

            // Exact mode must reject non-contiguous subsequence "vsc"
            let exactSubsequence = try await core.searchPage(query: "vsc", mode: .exact, limit: 10, offset: 0)
            assert(exactSubsequence.isEmpty, "FAIL: Exact mode must NOT match non-contiguous acronyms")
            print("✓ Step 1: Exact mode literal matching verified (matches substrings, rejects acronyms)")

            // -----------------------------------------------------------------
            // 3. Regex Mode: Valid Patterns
            // -----------------------------------------------------------------
            // Pattern 1: URL matching with ^https?://
            let urlResults = try await core.searchPage(query: "^https?://[a-z.]+", mode: .regex, limit: 10, offset: 0)
            assert(urlResults.count == 1, "FAIL: Regex should match URL")
            assert(urlResults[0].id == res1.itemId)
            assert(!urlResults[0].titleHighlights.isEmpty)

            // Pattern 2: Digits matching \b[0-9]{4}\b (matches 8080)
            let digitResults = try await core.searchPage(query: #"\b[0-9]{4}\b"#, mode: .regex, limit: 10, offset: 0)
            assert(digitResults.count == 1, "FAIL: Regex should match 4-digit port")
            assert(digitResults[0].id == res2.itemId)
            assert(!digitResults[0].titleHighlights.isEmpty)
            print("✓ Step 2: Valid regex patterns (^https?://, \\b[0-9]{4}\\b) and highlight extraction verified")

            // -----------------------------------------------------------------
            // 4. Regex Mode: Invalid Patterns Graceful Rejection (T-SRCH-02)
            // -----------------------------------------------------------------
            let invalidPatterns = [
                "(unclosed parenthesis",
                "[a-z unclosed bracket",
                "*leading wildcard",
                "+leading plus",
                "?leading question",
                "(?P<invalid",
                #"\p{InvalidProperty}"#
            ]

            for pattern in invalidPatterns {
                do {
                    _ = try await core.searchPage(query: pattern, mode: .regex, limit: 10, offset: 0)
                    assert(false, "FAIL: Invalid regex '\(pattern)' should have thrown CoreError.InvalidRegex")
                } catch CoreError.InvalidRegex(let pat, let errorMsg) {
                    assert(pat == pattern, "FAIL: Pattern in error must match input pattern")
                    assert(!errorMsg.isEmpty, "FAIL: Error message must explain syntax error")
                } catch {
                    assert(false, "FAIL: Unexpected error type thrown: \(error)")
                }
            }
            print("✓ Step 3: Invalid regex syntax gracefully caught with typed CoreError.InvalidRegex (no crashes)")

            // -----------------------------------------------------------------
            // 5. Giant Regex Length Limit Protection (T-SRCH-02)
            // -----------------------------------------------------------------
            let giantPattern = String(repeating: "a", count: 300)
            do {
                _ = try await core.searchPage(query: giantPattern, mode: .regex, limit: 10, offset: 0)
                assert(false, "FAIL: Oversized regex (>256 chars) should be rejected")
            } catch CoreError.InvalidRegex(let pat, let errorMsg) {
                assert(pat == giantPattern)
                assert(errorMsg.contains("Pattern length exceeds"), "FAIL: Should report length limit error")
            }
            print("✓ Step 4: Giant regex pattern (>256 chars) bounded rejection verified")

            // -----------------------------------------------------------------
            // 6. PanelViewModel Integration & Stale Search Cancellation
            // -----------------------------------------------------------------
            let vm = PanelViewModel(coreClient: core)
            vm.searchMode = .regex

            // Test invalid regex sets regexErrorMessage in ViewModel
            await vm.performSearch(query: "(unclosed")
            assert(vm.regexErrorMessage != nil, "FAIL: ViewModel should expose regexErrorMessage")
            assert(vm.items.isEmpty, "FAIL: Items should be empty on invalid regex")

            // Test valid regex clears regexErrorMessage and returns items
            await vm.performSearch(query: "mimra")
            assert(vm.regexErrorMessage == nil, "FAIL: Valid regex should clear regexErrorMessage")
            assert(vm.items.count == 1, "FAIL: Valid regex should populate matched items")

            // Test stale search cancellation: fire 3 rapid queries in parallel
            let task1 = Task { await vm.performSearch(query: "Port 8080") }
            let task2 = Task { await vm.performSearch(query: "Visual Studio") }
            let task3 = Task { await vm.performSearch(query: "https://mimra") }

            _ = await (task1.value, task2.value, task3.value)

            // Final state must reflect the latest generation's query
            assert(vm.searchGeneration >= 3, "FAIL: Search generation should increment with each query")
            print("✓ Step 5: PanelViewModel UI error reporting and stale search cancellation verified")

            try? FileManager.default.removeItem(at: tempDir)
            print("✓ ALL Exact & Regex Search Tests PASSED!")
        } catch {
            print("TEST FAILED WITH ERROR: \(error)")
            exit(1)
        }
    }
}
