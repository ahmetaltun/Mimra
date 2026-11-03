// ==============================================================================
// Mimra Core — Domain Module
// ==============================================================================

pub mod color;
pub mod content;
pub mod dto;
pub mod item;
pub mod search;
pub mod url_utils;

pub use color::HexColor;
pub use content::{uti, ContentKind, Representation};
pub use dto::{
    HistoryItemSummaryDTO, IngestResultDTO, RawCapture, RawRepresentation, StorageStatsDTO,
};
pub use item::{HistoryItem, MAX_TITLE_CHARS};
pub use search::{fuzzy_match, score_item, HighlightRangeDTO, SearchMode};
pub use url_utils::CanonicalUrl;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::CoreError;
    use crate::MAX_PAYLOAD_SIZE_BYTES;

    #[test]
    fn test_content_kind_from_str_and_display() {
        assert_eq!(ContentKind::Text.to_string(), "text");
        assert_eq!(ContentKind::RichText.to_string(), "rich_text");
        assert_eq!(ContentKind::Image.to_string(), "image");
        assert_eq!(ContentKind::FileUrls.to_string(), "file_urls");
        assert_eq!(ContentKind::Mixed.to_string(), "mixed");

        assert_eq!("text".parse::<ContentKind>().unwrap(), ContentKind::Text);
        assert_eq!(
            "rich_text".parse::<ContentKind>().unwrap(),
            ContentKind::RichText
        );
        assert_eq!("image".parse::<ContentKind>().unwrap(), ContentKind::Image);
        assert_eq!(
            "file_urls".parse::<ContentKind>().unwrap(),
            ContentKind::FileUrls
        );
        assert_eq!("mixed".parse::<ContentKind>().unwrap(), ContentKind::Mixed);

        assert!("unknown".parse::<ContentKind>().is_err());
    }

    #[test]
    fn test_representation_validation() {
        // Valid representation
        let rep = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"valid text".to_vec());
        assert!(rep.is_ok());

        // Empty UTI fails
        let empty_uti = Representation::new(0, "   ", b"valid text".to_vec());
        assert_eq!(
            empty_uti,
            Err(CoreError::InvalidInput {
                details: "Representation UTI cannot be empty.".to_string()
            })
        );

        // Empty payload fails
        let empty_payload = Representation::new(0, uti::UTF8_PLAIN_TEXT, Vec::new());
        assert_eq!(empty_payload, Err(CoreError::EmptyPayload));

        // Oversized payload fails
        let oversized = vec![0u8; (MAX_PAYLOAD_SIZE_BYTES + 1) as usize];
        let oversized_rep = Representation::new(0, uti::PNG, oversized);
        assert!(matches!(
            oversized_rep,
            Err(CoreError::PayloadTooLarge {
                max_bytes: MAX_PAYLOAD_SIZE_BYTES,
                actual_bytes: _
            })
        ));
    }

    #[test]
    fn test_history_item_creation_and_fields() {
        let text_bytes = "First line title\nSecond line content\nThird line"
            .as_bytes()
            .to_vec();
        let rep = Representation::new(0, uti::UTF8_PLAIN_TEXT, text_bytes).unwrap();
        let item = HistoryItem::new(
            vec![rep],
            Some("com.apple.Safari".to_string()),
            1700000000000,
        )
        .unwrap();

        assert_eq!(item.content_kind, ContentKind::Text);
        assert_eq!(item.title, "First line title");
        assert!(item.search_text.contains("Second line content"));
        assert_eq!(item.source_bundle_id, Some("com.apple.Safari".to_string()));
        assert_eq!(item.copy_count, 1);
        assert!(!item.is_pinned);
        assert_eq!(item.first_copied_at_ms, 1700000000000);
        assert_eq!(item.last_copied_at_ms, 1700000000000);
        assert_eq!(item.content_hash_hex().len(), 64);
    }

    #[test]
    fn test_history_item_rejects_empty_representations() {
        let empty_reps: Vec<Representation> = Vec::new();
        let result = HistoryItem::new(empty_reps, None, 1000);

        assert_eq!(
            result,
            Err(CoreError::InvalidInput {
                details: "Cannot create a history item with zero representations.".to_string(),
            })
        );
    }

    #[test]
    fn test_deterministic_content_hash_independent_of_order() {
        let rep1 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Hello World".to_vec()).unwrap();
        let rep2 = Representation::new(0, uti::HTML, b"<p>Hello World</p>".to_vec()).unwrap();
        let rep3 = Representation::new(1, uti::FILE_URL, b"file:///tmp/doc.pdf".to_vec()).unwrap();

        // Calculate hash with order [1, 2, 3]
        let hash_a =
            HistoryItem::calculate_content_hash(&[rep1.clone(), rep2.clone(), rep3.clone()]);
        // Calculate hash with permuted order [3, 1, 2]
        let hash_b =
            HistoryItem::calculate_content_hash(&[rep3.clone(), rep1.clone(), rep2.clone()]);
        // Calculate hash with permuted order [2, 3, 1]
        let hash_c = HistoryItem::calculate_content_hash(&[rep2, rep3, rep1]);

        assert_eq!(
            hash_a, hash_b,
            "Hash must be identical regardless of insertion order"
        );
        assert_eq!(
            hash_b, hash_c,
            "Hash must be identical across all permutations"
        );
    }

    #[test]
    fn test_unicode_normalization_cjk_emoji() {
        // Decomposed Unicode vs Precomposed Unicode (e.g. e + combining acute vs é)
        let decomposed = "caf\u{0065}\u{0301}"; // e + accent
        let precomposed = "caf\u{00E9}"; // é

        let rep_decomposed =
            Representation::new(0, uti::UTF8_PLAIN_TEXT, decomposed.as_bytes().to_vec()).unwrap();
        let rep_precomposed =
            Representation::new(0, uti::UTF8_PLAIN_TEXT, precomposed.as_bytes().to_vec()).unwrap();

        let item_a = HistoryItem::new(vec![rep_decomposed], None, 1000).unwrap();
        let item_b = HistoryItem::new(vec![rep_precomposed], None, 1000).unwrap();

        // After NFC normalization, titles and search_text must match exactly
        assert_eq!(item_a.title, item_b.title);
        assert_eq!(item_a.search_text, item_b.search_text);

        // Test CJK & Emoji support
        let cjk_emoji = "こんにちは世界 🌍 한국어 테스트 🎉";
        let rep_cjk =
            Representation::new(0, uti::UTF8_PLAIN_TEXT, cjk_emoji.as_bytes().to_vec()).unwrap();
        let item_cjk = HistoryItem::new(vec![rep_cjk], None, 1000).unwrap();
        assert_eq!(item_cjk.title, cjk_emoji);
    }

    #[test]
    fn test_record_recopy_updates_metadata() {
        let rep =
            Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Persistent Snippet".to_vec()).unwrap();
        let mut item =
            HistoryItem::new(vec![rep], Some("com.apple.Terminal".to_string()), 1000).unwrap();
        let original_id = item.id;

        item.record_recopy(2500, Some("com.google.Chrome".to_string()));

        assert_eq!(item.id, original_id, "Item ID must never change on recopy");
        assert_eq!(item.first_copied_at_ms, 1000);
        assert_eq!(item.last_copied_at_ms, 2500);
        assert_eq!(item.copy_count, 2);
        assert_eq!(item.source_bundle_id, Some("com.google.Chrome".to_string()));
    }

    #[test]
    fn test_serde_json_roundtrip() {
        let rep =
            Representation::new(0, uti::UTF8_PLAIN_TEXT, b"JSON roundtrip test".to_vec()).unwrap();
        let item = HistoryItem::new(vec![rep], Some("com.mimra.test".to_string()), 5000).unwrap();

        let json = serde_json::to_string(&item).expect("Serialization must succeed");
        let deserialized: HistoryItem =
            serde_json::from_str(&json).expect("Deserialization must succeed");

        assert_eq!(item, deserialized);
    }

    #[test]
    fn test_html_and_rtf_text_extraction() {
        // 1. HTML extraction
        let html_raw = "<div><h1>Heading 1</h1><p>Hello &amp; welcome to <b>Mimra</b>!&nbsp;&lt;Gate G3&gt;</p></div>";
        let extracted_html = HistoryItem::extract_text_from_html(html_raw);
        assert_eq!(
            extracted_html,
            "Heading 1 Hello & welcome to Mimra! <Gate G3>"
        );

        // 2. RTF extraction with font table, color table, control words, and newlines
        let rtf_raw = r"{\rtf1\ansi\ansicpg1252\cocoartf2821{\fonttbl\f0\fswiss Helvetica;}{\colortbl;\red255\green0\blue0;}\pard\f0\fs24\cf1 Hello \b Rich \b0 World!\par This is line 2 with escaped \{braces\} and \\backslash.}";
        let extracted_rtf = HistoryItem::extract_text_from_rtf(rtf_raw);
        assert!(extracted_rtf.contains("Hello Rich World!"));
        assert!(extracted_rtf.contains("This is line 2 with escaped {braces} and \\backslash."));
    }

    #[test]
    fn test_rich_text_fallback_title_and_search_text() {
        // Item with ONLY HTML (no plain text supplied)
        let html_payload =
            b"<p><strong>Safari Article Title</strong><br>Detailed paragraph content</p>".to_vec();
        let html_rep = Representation::new(0, uti::HTML, html_payload).unwrap();
        let html_item =
            HistoryItem::new(vec![html_rep], Some("com.apple.Safari".to_string()), 1000).unwrap();

        assert_eq!(html_item.content_kind, ContentKind::RichText);
        assert_eq!(
            html_item.title,
            "Safari Article Title Detailed paragraph content"
        );
        assert_eq!(
            html_item.search_text,
            "Safari Article Title Detailed paragraph content"
        );

        // Item with ONLY RTF (no plain text supplied)
        let rtf_payload = br"{\rtf1\ansi{\fonttbl\f0\fswiss Arial;}\pard\f0\fs28 Key Notes Document\par Detailed bullet points}".to_vec();
        let rtf_rep = Representation::new(0, uti::RTF, rtf_payload).unwrap();
        let rtf_item =
            HistoryItem::new(vec![rtf_rep], Some("com.apple.Notes".to_string()), 1500).unwrap();

        assert_eq!(rtf_item.content_kind, ContentKind::RichText);
        assert_eq!(rtf_item.title, "Key Notes Document");
        assert!(rtf_item.search_text.contains("Detailed bullet points"));

        // Multi-representation item (Plain text + HTML + RTF)
        let plain_payload = b"Exact Plain Text".to_vec();
        let plain_rep = Representation::new(0, uti::UTF8_PLAIN_TEXT, plain_payload).unwrap();
        let html_rep2 =
            Representation::new(0, uti::HTML, b"<b>Exact Plain Text</b>".to_vec()).unwrap();
        let rtf_rep2 =
            Representation::new(0, uti::RTF, br"{\rtf1\ansi Exact Plain Text}".to_vec()).unwrap();

        let multi_item = HistoryItem::new(
            vec![plain_rep, html_rep2, rtf_rep2],
            Some("com.microsoft.Word".to_string()),
            2000,
        )
        .unwrap();
        assert_eq!(multi_item.content_kind, ContentKind::RichText);
        assert_eq!(multi_item.title, "Exact Plain Text");
        assert_eq!(multi_item.search_text, "Exact Plain Text");
        assert_eq!(multi_item.representations.len(), 3);
    }

    #[test]
    fn test_image_item_title_and_metadata() {
        // PNG image
        let png_bytes = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]; // Minimal signature
        let rep_png = Representation::new(0, uti::PNG, png_bytes).unwrap();
        let item_png = HistoryItem::new(
            vec![rep_png],
            Some("com.apple.screencaptureui".to_string()),
            3000,
        )
        .unwrap();

        assert_eq!(item_png.content_kind, ContentKind::Image);
        assert_eq!(item_png.title, "PNG Image (8 B)");
        assert_eq!(item_png.search_text, "PNG Image 8 B");

        // JPEG image with size > 1 KB
        let jpeg_bytes = vec![0xFF; 2048];
        let rep_jpeg = Representation::new(0, uti::JPEG, jpeg_bytes).unwrap();
        let item_jpeg = HistoryItem::new(vec![rep_jpeg], None, 3500).unwrap();

        assert_eq!(item_jpeg.content_kind, ContentKind::Image);
        assert_eq!(item_jpeg.title, "JPEG Image (2.0 KB)");
        assert_eq!(item_jpeg.search_text, "JPEG Image 2.0 KB");

        // HEIC image
        let heic_bytes = vec![0x00; 512];
        let rep_heic = Representation::new(0, uti::HEIC, heic_bytes).unwrap();
        let item_heic = HistoryItem::new(vec![rep_heic], None, 4000).unwrap();

        assert_eq!(item_heic.content_kind, ContentKind::Image);
        assert_eq!(item_heic.title, "HEIC Image (512 B)");
    }

    #[test]
    fn test_file_url_item_title_and_search_text() {
        // Single file URL with percent encoding
        let url_bytes = b"file:///Users/username/My%20Documents/Quarterly%20Report.pdf".to_vec();
        let rep_file = Representation::new(0, uti::FILE_URL, url_bytes).unwrap();
        let item_file =
            HistoryItem::new(vec![rep_file], Some("com.apple.finder".to_string()), 5000).unwrap();

        assert_eq!(item_file.content_kind, ContentKind::FileUrls);
        assert_eq!(item_file.title, "Quarterly Report.pdf");
        assert_eq!(
            item_file.search_text,
            "file:///Users/username/My%20Documents/Quarterly%20Report.pdf"
        );

        // Folder URL with trailing slash
        let folder_bytes = b"file:///Users/username/Desktop/Projects/".to_vec();
        let rep_folder = Representation::new(0, uti::FILE_URL, folder_bytes).unwrap();
        let item_folder = HistoryItem::new(vec![rep_folder], None, 5100).unwrap();
        assert_eq!(item_folder.title, "Projects");

        // Multiple file URLs (3 files across 3 groups)
        let rep1 = Representation::new(0, uti::FILE_URL, b"file:///tmp/doc1.txt".to_vec()).unwrap();
        let rep2 = Representation::new(1, uti::FILE_URL, b"file:///tmp/doc2.pdf".to_vec()).unwrap();
        let rep3 =
            Representation::new(2, uti::FILE_URL, b"file:///tmp/image3.png".to_vec()).unwrap();

        let multi_file_item = HistoryItem::new(
            vec![rep1, rep2, rep3],
            Some("com.apple.finder".to_string()),
            5200,
        )
        .unwrap();
        assert_eq!(multi_file_item.content_kind, ContentKind::FileUrls);
        assert_eq!(multi_file_item.title, "3 files");
        assert!(multi_file_item.search_text.contains("doc1.txt"));
        assert!(multi_file_item.search_text.contains("doc2.pdf"));
        assert!(multi_file_item.search_text.contains("image3.png"));
    }

    #[test]
    fn test_history_item_url_plain_text() {
        let rep = Representation::new(
            0,
            uti::UTF8_PLAIN_TEXT,
            b"https://www.apple.com/macos/sequoia".to_vec(),
        )
        .unwrap();
        let item = HistoryItem::new(vec![rep], Some("com.apple.Safari".to_string()), 6000).unwrap();

        assert_eq!(item.content_kind, ContentKind::Text);
        assert_eq!(item.title, "https://www.apple.com/macos/sequoia");
        assert!(item.search_text.contains("apple.com"));
        assert!(item.search_text.contains("www.apple.com"));
    }

    #[test]
    fn test_history_item_url_with_page_title() {
        let url_rep =
            Representation::new(0, uti::URL, b"https://github.com/rust-lang/rust".to_vec())
                .unwrap();
        let title_rep = Representation::new(
            0,
            uti::URL_NAME,
            b"GitHub - rust-lang/rust: Empowering everyone to build reliable and efficient software."
                .to_vec(),
        )
        .unwrap();
        let item = HistoryItem::new(
            vec![url_rep, title_rep],
            Some("com.apple.Safari".to_string()),
            6100,
        )
        .unwrap();

        assert_eq!(
            item.title,
            "GitHub - rust-lang/rust: Empowering everyone to build reliable and efficient software."
        );
        assert!(item.search_text.contains("github.com"));
        assert!(item
            .search_text
            .contains("https://github.com/rust-lang/rust"));
    }

    #[test]
    fn test_history_item_hex_color() {
        let rep = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"#FF5733".to_vec()).unwrap();
        let item = HistoryItem::new(vec![rep], None, 6200).unwrap();

        assert_eq!(item.content_kind, ContentKind::Text);
        assert_eq!(item.title, "#FF5733");
        assert!(item.search_text.contains("#FF5733"));
        assert!(item.search_text.contains("FF5733"));
    }

    #[test]
    fn test_deduplication_google_sheets_html_session_churn() {
        let plain_text = b"Revenue\t$10,000\nProfit\t$2,500".to_vec();
        let html_session_1 = b"<google-sheets-html-origin data-session=\"abc-123\"><table><tr><td>Revenue</td><td>$10,000</td></tr></table></google-sheets-html-origin>".to_vec();
        let html_session_2 = b"<google-sheets-html-origin data-session=\"xyz-789\"><table><tr><td>Revenue</td><td>$10,000</td></tr></table></google-sheets-html-origin>".to_vec();

        let rep_plain_1 = Representation::new(0, uti::UTF8_PLAIN_TEXT, plain_text.clone()).unwrap();
        let rep_html_1 = Representation::new(0, uti::HTML, html_session_1).unwrap();
        let item_1 = HistoryItem::new(
            vec![rep_plain_1, rep_html_1],
            Some("com.google.Chrome".to_string()),
            1000,
        )
        .unwrap();

        let rep_plain_2 = Representation::new(0, uti::UTF8_PLAIN_TEXT, plain_text).unwrap();
        let rep_html_2 = Representation::new(0, uti::HTML, html_session_2).unwrap();
        let item_2 = HistoryItem::new(
            vec![rep_plain_2, rep_html_2],
            Some("com.google.Chrome".to_string()),
            2000,
        )
        .unwrap();

        assert_eq!(
            item_1.content_hash, item_2.content_hash,
            "Google Sheets copies with identical plain text must produce identical content hash despite HTML session ID churn"
        );
    }

    #[test]
    fn test_deduplication_safari_url_variants() {
        let plain_url_slash = b"https://github.com/rust-lang/rust/".to_vec();
        let plain_url_clean = b"https://github.com/rust-lang/rust".to_vec();
        let plain_url_port = b"HTTPS://GITHUB.COM:443/rust-lang/rust/".to_vec();

        let rep1 = Representation::new(0, uti::UTF8_PLAIN_TEXT, plain_url_slash).unwrap();
        let rep2 = Representation::new(0, uti::UTF8_PLAIN_TEXT, plain_url_clean).unwrap();
        let rep3 = Representation::new(0, uti::UTF8_PLAIN_TEXT, plain_url_port).unwrap();

        let url_rep =
            Representation::new(0, uti::URL, b"https://github.com/rust-lang/rust".to_vec())
                .unwrap();
        let title_rep = Representation::new(0, uti::URL_NAME, b"rust-lang/rust".to_vec()).unwrap();
        let plain_rep4 = Representation::new(
            0,
            uti::UTF8_PLAIN_TEXT,
            b"https://github.com/rust-lang/rust".to_vec(),
        )
        .unwrap();

        let item1 =
            HistoryItem::new(vec![rep1], Some("com.apple.Safari".to_string()), 1000).unwrap();
        let item2 =
            HistoryItem::new(vec![rep2], Some("com.apple.Safari".to_string()), 1100).unwrap();
        let item3 =
            HistoryItem::new(vec![rep3], Some("com.apple.Safari".to_string()), 1200).unwrap();
        let item4 = HistoryItem::new(
            vec![url_rep, title_rep, plain_rep4],
            Some("com.apple.Safari".to_string()),
            1300,
        )
        .unwrap();

        assert_eq!(
            item1.content_hash, item2.content_hash,
            "Trailing slash on URL must deduplicate"
        );
        assert_eq!(
            item2.content_hash, item3.content_hash,
            "Default port and upper-case host must deduplicate"
        );
        assert_eq!(
            item1.content_hash, item4.content_hash,
            "Public.url with page title must deduplicate with plain text URL"
        );
    }

    #[test]
    fn test_deduplication_vs_code_trailing_whitespace_and_newlines() {
        let code_line_copy = b"fn process_data(value: i32) -> bool {\n    true\n}\n".to_vec();
        let code_selected = b"fn process_data(value: i32) -> bool {\n    true\n}".to_vec();
        let code_trailing_spaces =
            b"fn process_data(value: i32) -> bool {   \n    true   \n}\n".to_vec();

        let rep1 = Representation::new(0, uti::UTF8_PLAIN_TEXT, code_line_copy).unwrap();
        let rep2 = Representation::new(0, uti::UTF8_PLAIN_TEXT, code_selected).unwrap();
        let rep3 = Representation::new(0, uti::UTF8_PLAIN_TEXT, code_trailing_spaces).unwrap();

        let item1 =
            HistoryItem::new(vec![rep1], Some("com.microsoft.VSCode".to_string()), 2000).unwrap();
        let item2 =
            HistoryItem::new(vec![rep2], Some("com.microsoft.VSCode".to_string()), 2100).unwrap();
        let item3 =
            HistoryItem::new(vec![rep3], Some("com.microsoft.VSCode".to_string()), 2200).unwrap();

        assert_eq!(
            item1.content_hash, item2.content_hash,
            "Line copy with trailing newline must deduplicate with exact selection"
        );
        assert_eq!(
            item2.content_hash, item3.content_hash,
            "Trailing line spaces must be normalized for code deduplication"
        );
    }

    #[test]
    fn test_deduplication_apple_notes_rtf_variations() {
        let text = b"Weekly Sync Notes".to_vec();
        let rtf_v1 = b"{\\rtf1\\ansi\\ansicpg1252{\\fonttbl\\f0\\fswiss Helvetica;}\\pard Weekly Sync Notes}".to_vec();
        let rtf_v2 = b"{\\rtf1\\ansi\\ansicpg1252{\\fonttbl\\f0\\fnil Arial;\\f1\\fswiss Helvetica;}\\pard Weekly Sync Notes}".to_vec();

        let rep_t1 = Representation::new(0, uti::UTF8_PLAIN_TEXT, text.clone()).unwrap();
        let rep_r1 = Representation::new(0, uti::RTF, rtf_v1).unwrap();
        let item1 = HistoryItem::new(
            vec![rep_t1, rep_r1],
            Some("com.apple.Notes".to_string()),
            3000,
        )
        .unwrap();

        let rep_t2 = Representation::new(0, uti::UTF8_PLAIN_TEXT, text).unwrap();
        let rep_r2 = Representation::new(0, uti::RTF, rtf_v2).unwrap();
        let item2 = HistoryItem::new(
            vec![rep_t2, rep_r2],
            Some("com.apple.Notes".to_string()),
            3100,
        )
        .unwrap();

        assert_eq!(
            item1.content_hash, item2.content_hash,
            "Apple Notes copies with identical text must deduplicate despite RTF font table variations"
        );
    }

    #[test]
    fn test_deduplication_file_urls_permutation_and_canonicalization() {
        let rep_a1 =
            Representation::new(0, uti::FILE_URL, b"file:///tmp/doc_b.pdf".to_vec()).unwrap();
        let rep_a2 =
            Representation::new(1, uti::FILE_URL, b"file:///tmp/doc_a.pdf/".to_vec()).unwrap();

        let rep_b1 =
            Representation::new(0, uti::FILE_URL, b"file://localhost/tmp/doc_a.pdf".to_vec())
                .unwrap();
        let rep_b2 =
            Representation::new(1, uti::FILE_URL, b"file:///tmp/doc_b.pdf".to_vec()).unwrap();

        let item1 = HistoryItem::new(
            vec![rep_a1, rep_a2],
            Some("com.apple.finder".to_string()),
            4000,
        )
        .unwrap();
        let item2 = HistoryItem::new(
            vec![rep_b1, rep_b2],
            Some("com.apple.finder".to_string()),
            4100,
        )
        .unwrap();

        assert_eq!(
            item1.content_hash, item2.content_hash,
            "File URLs selection order and scheme variations must produce identical deduplication hash"
        );
    }
}
