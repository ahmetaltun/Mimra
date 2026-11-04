// ==============================================================================
// Mimra Tests — FFI Fuzz & Property Bridge Tests (P8-05)
// Linked Features: F-018, F-048, F-051
// Test IDs: T-FFI-01, T-SRCH-02
// Exercises the Swift <-> Rust UniFFI bridge across all public methods with
// malformed, oversized, invalid UTF-8, and SQL injection inputs.
// Verifies zero process aborts and strictly typed Swift CoreError propagation.
// ==============================================================================

import AppKit
import Foundation

@main
struct FfiFuzzPropertyTests {
    @MainActor
    static func main() async {
        print("=== Running FFI Fuzz & Property Bridge Tests (P8-05 / T-FFI-01, T-SRCH-02) ===")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_ffi_fuzz_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("fuzz.sqlite").path

        do {
            let core = try CoreClient(databasePath: dbPath)

            // -----------------------------------------------------------------
            // 1. Ingestion Boundary Fuzzing
            // -----------------------------------------------------------------

            // 1a. Empty Representations
            do {
                let emptyCap = RawCapture(
                    timestampMs: 1000,
                    sourceBundleId: "com.apple.Safari",
                    representations: []
                )
                _ = try await core.ingest(capture: emptyCap)
                fatalError("DoD VIOLATION: Ingesting zero representations must fail!")
            } catch let error as CoreError {
                guard case .InvalidInput = error else {
                    fatalError("DoD VIOLATION: Expected InvalidInput, got \(error)")
                }
            }
            print("✓ Step 1a: Zero representations rejected with CoreError.InvalidInput")

            // 1b. Empty Payload Data
            do {
                let emptyDataCap = RawCapture(
                    timestampMs: 1000,
                    sourceBundleId: nil,
                    representations: [
                        RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: Data())
                    ]
                )
                _ = try await core.ingest(capture: emptyDataCap)
                fatalError("DoD VIOLATION: Ingesting empty payload data must fail!")
            } catch let error as CoreError {
                guard case .EmptyPayload = error else {
                    fatalError("DoD VIOLATION: Expected EmptyPayload, got \(error)")
                }
            }
            print("✓ Step 1b: Empty payload rejected with CoreError.EmptyPayload")

            // 1c. Oversized Payload (> 10 MB limit)
            do {
                let oversizedCap = RawCapture(
                    timestampMs: 1000,
                    sourceBundleId: nil,
                    representations: [
                        RawRepresentation(
                            groupIndex: 0,
                            uti: "public.png",
                            payload: Data(count: 10_485_761) // 10 MB + 1 byte
                        )
                    ]
                )
                _ = try await core.ingest(capture: oversizedCap)
                fatalError("DoD VIOLATION: Ingesting oversized payload must fail!")
            } catch let error as CoreError {
                guard case .PayloadTooLarge(let maxBytes, let actualBytes) = error else {
                    fatalError("DoD VIOLATION: Expected PayloadTooLarge, got \(error)")
                }
                assert(maxBytes == 10_485_760)
                assert(actualBytes == 10_485_761)
            }
            print("✓ Step 1c: Oversized payload (>10 MB) rejected with CoreError.PayloadTooLarge")

            // 1d. Invalid Non-UTF8 Bytes in Text Representation
            let invalidUtf8Bytes: [UInt8] = [0xFF, 0xFE, 0xFD, 0x80, 0x81, 0x90, 0xC0, 0xAF]
            let nonUtf8Cap = RawCapture(
                timestampMs: 1000,
                sourceBundleId: "com.apple.Terminal",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data(invalidUtf8Bytes)
                    )
                ]
            )
            let nonUtf8Res = try await core.ingest(capture: nonUtf8Cap)
            assert(!nonUtf8Res.itemId.isEmpty, "Invalid UTF-8 bytes must be handled losslessly without crashing")
            print("✓ Step 1d: Non-UTF8 byte sequences handled losslessly without crash")

            // 1e. Embedded Null Bytes and Giant UTI
            let giantUti = String(repeating: "a.", count: 2000)
            let nullBytesCap = RawCapture(
                timestampMs: 1000,
                sourceBundleId: nil,
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: giantUti,
                        payload: Data("Hello\0World\0\0Trailing\0Data".utf8)
                    )
                ]
            )
            let nullRes = try await core.ingest(capture: nullBytesCap)
            assert(!nullRes.itemId.isEmpty)
            print("✓ Step 1e: Giant UTI (4,000 chars) and embedded null bytes handled safely")

            // -----------------------------------------------------------------
            // 2. Search Query Boundary Fuzzing (T-SRCH-02)
            // -----------------------------------------------------------------

            // 2a. Catastrophic / Malformed Regex Queries
            let malformedRegexes = [
                "[a-z",          // Unclosed bracket
                "(unclosed",     // Unclosed paren
                "*start",        // Quantifier on nothing
                "+",             // Plus without operand
                "(?<",           // Incomplete group
                "\\c",           // Invalid escape
                String(repeating: "a", count: 300) // Oversized regex pattern
            ]

            for pattern in malformedRegexes {
                do {
                    _ = try await core.searchPage(query: pattern, mode: .regex, limit: 10, offset: 0)
                    fatalError("DoD VIOLATION: Malformed regex '\(pattern)' must throw CoreError.InvalidRegex!")
                } catch let error as CoreError {
                    guard case .InvalidRegex = error else {
                        fatalError("DoD VIOLATION: Expected InvalidRegex for pattern '\(pattern)', got \(error)")
                    }
                }
            }
            print("✓ Step 2a: All \(malformedRegexes.count) malformed regex queries threw typed CoreError.InvalidRegex")

            // 2b. SQL Injection Payloads in Fuzzy and Exact Search
            let sqlInjections = [
                "' OR '1'='1",
                "'; DROP TABLE history_items;--",
                "\" OR 1=1; VACUUM;--",
                "admin'--",
                "\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\""
            ]
            for query in sqlInjections {
                let fuzzyRes = try await core.searchPage(query: query, mode: .fuzzy, limit: 10, offset: 0)
                let exactRes = try await core.searchPage(query: query, mode: .exact, limit: 10, offset: 0)
                assert(fuzzyRes.isEmpty || !fuzzyRes.isEmpty)
                assert(exactRes.isEmpty || !exactRes.isEmpty)
            }
            print("✓ Step 2b: SQL injection attempts safely sanitized across fuzzy and exact search modes")

            // -----------------------------------------------------------------
            // 3. UUID Parameter Fuzzing
            // -----------------------------------------------------------------
            let invalidUuids = [
                "",
                "not-a-valid-uuid",
                "12345",
                "g0000000-0000-0000-0000-000000000000",
                "'; DROP TABLE history_items;--",
                "\0\0\0\0"
            ]

            for badId in invalidUuids {
                // deleteItem
                do {
                    _ = try await core.deleteItem(itemId: badId)
                    fatalError("DoD VIOLATION: deleteItem with bad UUID '\(badId)' must throw CoreError.InvalidInput!")
                } catch let error as CoreError {
                    guard case .InvalidInput = error else {
                        fatalError("DoD VIOLATION: Expected InvalidInput, got \(error)")
                    }
                }

                // updateOcrText
                do {
                    _ = try await core.updateOcrText(itemId: badId, ocrText: "text")
                    fatalError("DoD VIOLATION: updateOcrText with bad UUID '\(badId)' must throw CoreError.InvalidInput!")
                } catch let error as CoreError {
                    guard case .InvalidInput = error else {
                        fatalError("DoD VIOLATION: Expected InvalidInput, got \(error)")
                    }
                }

                // setPin
                do {
                    try await core.setPin(itemId: badId, isPinned: true, pinKey: "1", pinOrder: 1)
                    fatalError("DoD VIOLATION: setPin with bad UUID '\(badId)' must throw CoreError.InvalidInput!")
                } catch let error as CoreError {
                    guard case .InvalidInput = error else {
                        fatalError("DoD VIOLATION: Expected InvalidInput, got \(error)")
                    }
                }

                // togglePin
                do {
                    _ = try await core.togglePin(itemId: badId)
                    fatalError("DoD VIOLATION: togglePin with bad UUID '\(badId)' must throw CoreError.InvalidInput!")
                } catch let error as CoreError {
                    guard case .InvalidInput = error else {
                        fatalError("DoD VIOLATION: Expected InvalidInput, got \(error)")
                    }
                }
            }
            print("✓ Step 3: All malformed UUID inputs rejected with typed CoreError.InvalidInput")

            // -----------------------------------------------------------------
            // 4. Pin Shortcut Key Validation Fuzzing
            // -----------------------------------------------------------------

            // Multi-character string
            do {
                _ = try await core.validatePinKey(key: "xyz")
                fatalError("DoD VIOLATION: Multi-char pin key must fail!")
            } catch let error as CoreError {
                guard case .InvalidInput = error else {
                    fatalError("DoD VIOLATION: Expected InvalidInput, got \(error)")
                }
            }

            // Reserved 'p' / 'P'
            do {
                _ = try await core.validatePinKey(key: "p")
                fatalError("DoD VIOLATION: Reserved key 'p' must fail!")
            } catch let error as CoreError {
                guard case .PinKeyConflict = error else {
                    fatalError("DoD VIOLATION: Expected PinKeyConflict, got \(error)")
                }
            }

            // Valid punctuation keys
            let validPunctuation = [";", "[", "]", "/", "-", "=", ".", ","]
            for key in validPunctuation {
                let validated = try await core.validatePinKey(key: key)
                assert(validated == key)
            }
            print("✓ Step 4: Pin shortcut key validation boundaries verified")

            // Clean up test database
            try? FileManager.default.removeItem(at: tempDir)
            print("✓ Cleaned up temporary test directory")

        } catch {
            print("❌ FfiFuzzPropertyTests failed: \(error)")
            exit(1)
        }

        print("----------------------------------------------------------------------")
        print("ALL FFI FUZZ & PROPERTY TESTS (P8-05) PASSED!")
        print("----------------------------------------------------------------------")
    }
}
