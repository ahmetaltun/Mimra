// ==============================================================================
// Mimra Core — FFI Fuzz & Property Test Suite (P8-05)
// Linked Features: F-018, F-048, F-051
// Test IDs: T-FFI-01, T-SRCH-02
// Thoroughly exercises all public FFI boundary methods against malformed,
// pathological, oversized, and hostile inputs to guarantee zero panics and
// strictly typed error returns across the C-ABI boundary.
// ==============================================================================

#[cfg(test)]
mod tests {
    use crate::domain::content::uti;
    use crate::domain::dto::{RawCapture, RawRepresentation, RetentionPolicyDTO};
    use crate::domain::search::SearchMode;
    use crate::error::CoreError;
    use crate::{fingerprint, MimraCoreHandle, MAX_PAYLOAD_SIZE_BYTES};

    #[test]
    fn test_fuzz_ingest_malformed_representations() {
        let handle = MimraCoreHandle::open_in_memory().expect("In-memory handle must open");

        // 1. Zero representations in capture
        let empty_capture = RawCapture {
            timestamp_ms: 1000,
            source_bundle_id: Some("com.apple.Safari".to_string()),
            representations: vec![],
        };
        let err = handle
            .ingest(empty_capture)
            .expect_err("Must reject zero representations");
        assert!(matches!(err, CoreError::InvalidInput { .. }));

        // 2. Empty UTI string
        let empty_uti_capture = RawCapture {
            timestamp_ms: 1000,
            source_bundle_id: None,
            representations: vec![RawRepresentation {
                group_index: 0,
                uti: "   ".to_string(),
                payload: b"valid payload".to_vec(),
            }],
        };
        let err = handle
            .ingest(empty_uti_capture)
            .expect_err("Must reject whitespace UTI");
        assert!(matches!(err, CoreError::InvalidInput { .. }));

        // 3. Empty payload bytes
        let empty_payload_capture = RawCapture {
            timestamp_ms: 1000,
            source_bundle_id: None,
            representations: vec![RawRepresentation {
                group_index: 0,
                uti: uti::UTF8_PLAIN_TEXT.to_string(),
                payload: vec![],
            }],
        };
        let err = handle
            .ingest(empty_payload_capture)
            .expect_err("Must reject empty payload");
        assert_eq!(err, CoreError::EmptyPayload);

        // 4. Oversized payload (> 10 MB limit)
        let oversized_capture = RawCapture {
            timestamp_ms: 1000,
            source_bundle_id: None,
            representations: vec![RawRepresentation {
                group_index: 0,
                uti: uti::PNG.to_string(),
                payload: vec![0x42; (MAX_PAYLOAD_SIZE_BYTES + 1) as usize],
            }],
        };
        let err = handle
            .ingest(oversized_capture)
            .expect_err("Must reject payload exceeding 10 MB");
        assert!(matches!(err, CoreError::PayloadTooLarge { .. }));

        // 5. Invalid / Non-UTF8 byte sequences in UTF8 text format
        // Expected: Must NOT panic; gracefully decode losslessly
        let invalid_utf8_bytes = vec![0xFF, 0xFE, 0xFD, 0x80, 0x81, 0x90, 0xC0, 0xAF];
        let invalid_utf8_capture = RawCapture {
            timestamp_ms: 1000,
            source_bundle_id: Some("com.apple.Terminal".to_string()),
            representations: vec![RawRepresentation {
                group_index: 0,
                uti: uti::UTF8_PLAIN_TEXT.to_string(),
                payload: invalid_utf8_bytes,
            }],
        };
        let result = handle
            .ingest(invalid_utf8_capture)
            .expect("Invalid UTF-8 must be handled cleanly");
        assert!(!result.item_id.is_empty());

        // 6. Giant UTI string (10,000 characters)
        let giant_uti = "a.".repeat(5000);
        let giant_uti_capture = RawCapture {
            timestamp_ms: 1000,
            source_bundle_id: None,
            representations: vec![RawRepresentation {
                group_index: 0,
                uti: giant_uti,
                payload: b"some data".to_vec(),
            }],
        };
        let result = handle
            .ingest(giant_uti_capture)
            .expect("Giant UTI must be handled without crash");
        assert!(!result.item_id.is_empty());

        // 7. Embedded null bytes in text and file URLs
        let null_bytes_capture = RawCapture {
            timestamp_ms: 1000,
            source_bundle_id: None,
            representations: vec![RawRepresentation {
                group_index: 0,
                uti: uti::UTF8_PLAIN_TEXT.to_string(),
                payload: b"Hello\0World\0\0Trailing".to_vec(),
            }],
        };
        let result = handle
            .ingest(null_bytes_capture)
            .expect("Null bytes must be safely handled");
        assert!(!result.item_id.is_empty());
    }

    #[test]
    fn test_fuzz_fingerprint_boundary() {
        // 1. Empty payload
        let err = fingerprint(vec![]).expect_err("Empty fingerprint payload must fail");
        assert_eq!(err, CoreError::EmptyPayload);

        // 2. Oversized payload
        let oversized = vec![0xAA; (MAX_PAYLOAD_SIZE_BYTES + 50) as usize];
        let err = fingerprint(oversized).expect_err("Oversized fingerprint payload must fail");
        assert!(matches!(err, CoreError::PayloadTooLarge { .. }));

        // 3. Arbitrary pseudo-random byte fuzz
        for seed in 1..=50 {
            let mut pseudo_random = Vec::with_capacity(seed * 64);
            for i in 0..(seed * 64) {
                pseudo_random.push(((i * seed) % 256) as u8);
            }
            let fp = fingerprint(pseudo_random).expect("Valid payload must produce fingerprint");
            assert_eq!(
                fp.len(),
                64,
                "BLAKE3 hex string must be exactly 64 characters"
            );
            assert!(fp.chars().all(|c| c.is_ascii_hexdigit()));
        }
    }

    #[test]
    fn test_fuzz_search_queries_pathological_cases() {
        let handle = MimraCoreHandle::open_in_memory().expect("In-memory handle must open");

        // Seed sample item
        let capture = RawCapture {
            timestamp_ms: 2000,
            source_bundle_id: Some("com.apple.Notes".to_string()),
            representations: vec![RawRepresentation {
                group_index: 0,
                uti: uti::UTF8_PLAIN_TEXT.to_string(),
                payload: b"Fuzz target document containing Rust, Swift, and SQLite details."
                    .to_vec(),
            }],
        };
        handle.ingest(capture).unwrap();

        // 1. Pathological SQL injection strings in search queries
        let sql_injections = [
            "' OR '1'='1",
            "'; DROP TABLE history_items;--",
            "\" OR 1=1; VACUUM;--",
            "' UNION SELECT id, title, ocr_text FROM history_items;--",
            "admin'--",
            "\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"",
        ];
        for query in sql_injections {
            let res = handle.search_page(query.to_string(), SearchMode::Fuzzy, 10, 0);
            assert!(
                res.is_ok(),
                "SQL injection query must be safely escaped: {query}"
            );
            let exact_res = handle.search_page(query.to_string(), SearchMode::Exact, 10, 0);
            assert!(
                exact_res.is_ok(),
                "Exact SQL injection query must be safely escaped: {query}"
            );
        }

        // 2. Pathological FTS5 syntax triggers
        let fts5_triggers = [
            "*",
            "**",
            "***",
            "NEAR()",
            "NEAR(a, b, 10)",
            "NOT",
            "AND OR NOT",
            "^",
            "column:value",
            "{col1 col2}:value",
            "\"unclosed quote",
            "((((unclosed paren",
            "---",
            "___",
            "...",
        ];
        for trigger in fts5_triggers {
            let res = handle.search_page(trigger.to_string(), SearchMode::Fuzzy, 10, 0);
            assert!(
                res.is_ok(),
                "FTS5 syntax trigger must be safely sanitized: {trigger}"
            );
        }

        // 3a. Complex repetition patterns that would cause catastrophic backtracking in backtracking engines
        // In Rust's regex DFA engine, these are valid and guaranteed to execute in linear time O(m * n) without hanging
        let linear_dfa_regexes = [
            "(a+)+$",      // Nested repetition
            "(a|aa)+",     // Ambiguous branch repetition
            "(((a*)*)*)*", // Multi-level repetition
        ];
        for pattern in linear_dfa_regexes {
            let res = handle.search_page(pattern.to_string(), SearchMode::Regex, 10, 0);
            assert!(
                res.is_ok(),
                "Linear DFA regex must compile and execute safely without hang: {pattern}"
            );
        }

        // 3b. Syntactically invalid regexes (must fail safely with CoreError::InvalidRegex)
        let invalid_syntax_regexes = [
            "[a-z",      // Unclosed bracket
            "(unclosed", // Unclosed parenthesis
            "*start",    // Quantifier on nothing
            "+",         // Leading plus quantifier without operand
            "(?<",       // Incomplete group
            "\\c",       // Invalid escape
        ];
        for pattern in invalid_syntax_regexes {
            let err = handle
                .search_page(pattern.to_string(), SearchMode::Regex, 10, 0)
                .expect_err(&format!("Invalid regex must fail safely: {pattern}"));
            assert!(matches!(err, CoreError::InvalidRegex { .. }));
        }

        // 4. Regex exceeding maximum length limit (256 chars)
        let giant_regex = "a".repeat(300);
        let err = handle
            .search_page(giant_regex, SearchMode::Regex, 10, 0)
            .expect_err("Giant regex must fail safely");
        assert!(matches!(err, CoreError::InvalidRegex { .. }));

        // 5. Special Unicode characters (Object replacement U+FFFC, RTL, Emoji zwj sequences)
        let special_unicode = [
            "\u{FFFC}",
            "\u{200B}\u{200C}\u{200D}\u{FEFF}",
            "👨‍👩‍👧‍👦",
            "العربية / فارسی",
            "日本語テキスト入力",
        ];
        for text in special_unicode {
            let res = handle.search_page(text.to_string(), SearchMode::Fuzzy, 10, 0);
            assert!(
                res.is_ok(),
                "Special Unicode query must be safely handled: {text}"
            );
        }
    }

    #[test]
    fn test_fuzz_uuid_parameters() {
        let handle = MimraCoreHandle::open_in_memory().expect("In-memory handle must open");

        let malformed_ids = [
            "",
            "not-a-uuid",
            "12345",
            "g3b2a1c0-0000-0000-0000-000000000000", // Invalid hex characters
            "00000000-0000-0000-0000-000000000000-extra",
            "'; DROP TABLE history_items;--",
            "\0\0\0\0",
        ];

        for bad_id in malformed_ids {
            // delete_item
            let err = handle
                .delete_item(bad_id.to_string())
                .expect_err(&format!("Invalid UUID should return error: {bad_id}"));
            assert!(matches!(err, CoreError::InvalidInput { .. }));

            // get_ocr_text
            let err = handle
                .get_ocr_text(bad_id.to_string())
                .expect_err(&format!("Invalid UUID should return error: {bad_id}"));
            assert!(matches!(err, CoreError::InvalidInput { .. }));

            // update_ocr_text
            let err = handle
                .update_ocr_text(bad_id.to_string(), "some text".to_string())
                .expect_err(&format!("Invalid UUID should return error: {bad_id}"));
            assert!(matches!(err, CoreError::InvalidInput { .. }));

            // edit_pinned_item_text
            let err = handle
                .edit_pinned_item_text(bad_id.to_string(), "new text".to_string())
                .expect_err(&format!("Invalid UUID should return error: {bad_id}"));
            assert!(matches!(err, CoreError::InvalidInput { .. }));

            // set_pin
            let err = handle
                .set_pin(bad_id.to_string(), true, Some("1".to_string()), Some(1))
                .expect_err(&format!("Invalid UUID should return error: {bad_id}"));
            assert!(matches!(err, CoreError::InvalidInput { .. }));

            // toggle_pin
            let err = handle
                .toggle_pin(bad_id.to_string())
                .expect_err(&format!("Invalid UUID should return error: {bad_id}"));
            assert!(matches!(err, CoreError::InvalidInput { .. }));
        }
    }

    #[test]
    fn test_fuzz_pin_key_validation() {
        let handle = MimraCoreHandle::open_in_memory().expect("In-memory handle must open");

        // 1. Multi-character pin keys
        let err = handle
            .validate_pin_key("abc".to_string())
            .expect_err("Multi-char pin key must fail");
        assert!(matches!(err, CoreError::InvalidInput { .. }));

        // 2. Empty string
        let err = handle
            .validate_pin_key("".to_string())
            .expect_err("Empty pin key must fail");
        assert!(matches!(err, CoreError::InvalidInput { .. }));

        // 3. Reserved shortcuts (P/p reserved for pin toggle)
        let err_p = handle
            .validate_pin_key("p".to_string())
            .expect_err("Reserved 'p' must fail");
        assert!(matches!(err_p, CoreError::PinKeyConflict { .. }));
        let err_upper_p = handle
            .validate_pin_key("P".to_string())
            .expect_err("Reserved 'P' must fail");
        assert!(matches!(err_upper_p, CoreError::PinKeyConflict { .. }));

        // 4. Valid single characters (letters, numbers, punctuation)
        let valid_keys = ["1", "9", "a", "z", ";", "[", "]", "/", "-", "=", ".", ","];
        for key in valid_keys {
            let res = handle.validate_pin_key(key.to_string());
            assert!(res.is_ok(), "Valid pin key should be accepted: {key}");
        }
    }

    #[test]
    fn test_fuzz_retention_policy_and_limits() {
        let handle = MimraCoreHandle::open_in_memory().expect("In-memory handle must open");

        // Extreme edge cases for retention limits
        handle.set_max_unpinned(0); // Cap at 0 unpinned
        handle.set_max_unpinned(u32::MAX); // Maximum u32

        let extreme_policy = RetentionPolicyDTO {
            max_count: Some(0),
            max_age_days: Some(0),
            max_size_bytes: Some(0),
        };
        let report = handle
            .enforce_retention(Some(extreme_policy))
            .expect("Enforce extreme retention must not crash");
        assert_eq!(report.remaining_unpinned, 0);
    }
}
