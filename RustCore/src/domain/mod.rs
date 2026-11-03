// ==============================================================================
// Mimra Core — Domain Module
// ==============================================================================

pub mod content;
pub mod dto;
pub mod item;

pub use content::{uti, ContentKind, Representation};
pub use dto::{
    HistoryItemSummaryDTO, IngestResultDTO, RawCapture, RawRepresentation, StorageStatsDTO,
};
pub use item::{HistoryItem, MAX_TITLE_CHARS};

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
}
