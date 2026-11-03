// ==============================================================================
// Mimra Core — History Item Domain Model
// Represents a persistent, deduplicated clipboard entry with representations.
// ==============================================================================

use crate::domain::content::{ContentKind, Representation};
use crate::error::CoreError;
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

/// Maximum character length for an auto-derived item title.
pub const MAX_TITLE_CHARS: usize = 120;

/// Represents a single history item in the Mimra clipboard history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryItem {
    /// Unique, stable identifier for this item.
    pub id: Uuid,
    /// Classification of the item's primary payload.
    pub content_kind: ContentKind,
    /// Brief descriptive label shown in UI list rows.
    pub title: String,
    /// Normalized text indexed for full-text search.
    pub search_text: String,
    /// Optional OCR text extracted from images via on-device Vision.
    pub ocr_text: String,
    /// BLAKE3 256-bit cryptographic digest of normalized representations for deduplication.
    pub content_hash: [u8; 32],
    /// Bundle identifier of the source application where this item was copied (if known).
    pub source_bundle_id: Option<String>,
    /// Whether this item is pinned to the top of the history list.
    pub is_pinned: bool,
    /// Explicit ordering index for pinned items.
    pub pin_order: Option<u32>,
    /// Single-character shortcut key assigned to this pin (e.g. "a", "1", ";").
    pub pin_key: Option<String>,
    /// Milliseconds since UNIX epoch when this content was first copied.
    pub first_copied_at_ms: i64,
    /// Milliseconds since UNIX epoch when this content was most recently copied.
    pub last_copied_at_ms: i64,
    /// Number of times this identical content has been copied.
    pub copy_count: u32,
    /// Total aggregate size in bytes across all representations.
    pub byte_size: u64,
    /// Milliseconds since UNIX epoch when this record was created.
    pub created_at_ms: i64,
    /// Multi-representation payload data.
    pub representations: Vec<Representation>,
}

impl HistoryItem {
    /// Constructs a new `HistoryItem` from raw representations and metadata.
    ///
    /// # Invariants Enforced:
    /// - Rejects empty representations (`CoreError::InvalidInput`).
    /// - Computes deterministic BLAKE3 `content_hash` over sorted representations.
    /// - Normalizes text fields to Unicode Normalization Form C (NFC).
    /// - Automatically derives `content_kind`, `title`, and `search_text`.
    pub fn new(
        representations: Vec<Representation>,
        source_bundle_id: Option<String>,
        timestamp_ms: i64,
    ) -> Result<Self, CoreError> {
        if representations.is_empty() {
            return Err(CoreError::InvalidInput {
                details: "Cannot create a history item with zero representations.".to_string(),
            });
        }

        // Calculate total byte size and verify representations
        let byte_size: u64 = representations.iter().map(|r| r.payload.len() as u64).sum();

        // Calculate deterministic BLAKE3 content hash
        let content_hash = Self::calculate_content_hash(&representations);

        // Derive content kind, title, and search text
        let content_kind = Self::derive_content_kind(&representations);
        let (title, search_text) = Self::derive_text_fields(&representations, content_kind);

        Ok(Self {
            id: Uuid::new_v4(),
            content_kind,
            title,
            search_text,
            ocr_text: String::new(),
            content_hash,
            source_bundle_id: source_bundle_id.map(|s| s.trim().to_string()),
            is_pinned: false,
            pin_order: None,
            pin_key: None,
            first_copied_at_ms: timestamp_ms,
            last_copied_at_ms: timestamp_ms,
            copy_count: 1,
            byte_size,
            created_at_ms: timestamp_ms,
            representations,
        })
    }

    /// Computes a deterministic BLAKE3 digest from representations.
    /// Representations are sorted by `(group_index, uti)` so insertion order never alters the hash.
    pub fn calculate_content_hash(reps: &[Representation]) -> [u8; 32] {
        let mut sorted: Vec<&Representation> = reps.iter().collect();
        sorted.sort_by(|a, b| {
            a.group_index
                .cmp(&b.group_index)
                .then_with(|| a.uti.cmp(&b.uti))
        });

        let mut hasher = blake3::Hasher::new();
        for rep in sorted {
            hasher.update(&rep.group_index.to_be_bytes());
            hasher.update(&(rep.uti.len() as u32).to_be_bytes());
            hasher.update(rep.uti.as_bytes());
            hasher.update(&(rep.payload.len() as u64).to_be_bytes());
            hasher.update(&rep.payload);
        }

        *hasher.finalize().as_bytes()
    }

    /// Returns the hex string representation of the 32-byte content hash.
    pub fn content_hash_hex(&self) -> String {
        blake3::Hash::from(self.content_hash).to_hex().to_string()
    }

    /// Updates this item when an identical content copy is observed (recopy / deduplication).
    pub fn record_recopy(&mut self, timestamp_ms: i64, source_bundle_id: Option<String>) {
        self.last_copied_at_ms = timestamp_ms;
        self.copy_count = self.copy_count.saturating_add(1);
        if let Some(new_source) = source_bundle_id {
            let trimmed = new_source.trim().to_string();
            if !trimmed.is_empty() {
                self.source_bundle_id = Some(trimmed);
            }
        }
    }

    /// Helper to classify content kind from representations.
    fn derive_content_kind(reps: &[Representation]) -> ContentKind {
        let has_text = reps.iter().any(|r| r.is_plain_text());
        let has_rich = reps.iter().any(|r| r.is_rich_text());
        let has_image = reps.iter().any(|r| r.is_image());
        let has_file = reps.iter().any(|r| r.is_file_url());

        if has_file {
            if reps.iter().all(|r| r.is_file_url() || r.is_plain_text()) {
                ContentKind::FileUrls
            } else {
                ContentKind::Mixed
            }
        } else if has_image {
            if has_rich || (has_text && reps.len() > 2) {
                ContentKind::Mixed
            } else {
                ContentKind::Image
            }
        } else if has_rich {
            ContentKind::RichText
        } else {
            ContentKind::Text
        }
    }

    /// Helper to derive title and search text from representations.
    fn derive_text_fields(reps: &[Representation], kind: ContentKind) -> (String, String) {
        // 1. Check for plain text representation first
        if let Some(text_rep) = reps.iter().find(|r| r.is_plain_text()) {
            let raw_text = String::from_utf8_lossy(&text_rep.payload);
            let nfc_text: String = raw_text.nfc().collect();
            let trimmed = nfc_text.trim();

            if !trimmed.is_empty() {
                // Find first non-empty line for title
                let first_line = trimmed.lines().next().unwrap_or("").trim();
                let title: String = first_line.chars().take(MAX_TITLE_CHARS).collect();
                return (title, trimmed.to_string());
            }
        }

        // 2. Check for file URLs
        if kind == ContentKind::FileUrls {
            let file_urls: Vec<String> = reps
                .iter()
                .filter(|r| r.is_file_url())
                .map(|r| {
                    let raw = String::from_utf8_lossy(&r.payload).trim().to_string();
                    raw.nfc().collect()
                })
                .collect();

            if !file_urls.is_empty() {
                let title = if file_urls.len() == 1 {
                    // Extract basename if possible
                    file_urls[0]
                        .split('/')
                        .next_back()
                        .unwrap_or(&file_urls[0])
                        .to_string()
                } else {
                    format!("{} files", file_urls.len())
                };
                let search_text = file_urls.join("\n");
                return (title, search_text);
            }
        }

        // 3. Fallbacks for images or non-text content
        match kind {
            ContentKind::Image => ("Image".to_string(), String::new()),
            ContentKind::RichText => ("Rich Text Document".to_string(), String::new()),
            ContentKind::FileUrls => ("File Reference".to_string(), String::new()),
            ContentKind::Mixed => ("Clipboard Content".to_string(), String::new()),
            ContentKind::Text => ("Plain Text".to_string(), String::new()),
        }
    }
}
