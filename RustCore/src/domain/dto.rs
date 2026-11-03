// ==============================================================================
// Mimra Core — UniFFI Data Transfer Objects (DTOs)
// Strongly-typed records crossing the FFI boundary between Swift and Rust.
// ==============================================================================

use crate::domain::content::Representation;
use crate::domain::search::HighlightRangeDTO;
use crate::storage::repository::{HistoryItemSummary, StorageStats};

/// Raw representation data received from macOS pasteboard.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RawRepresentation {
    pub group_index: u32,
    pub uti: String,
    pub payload: Vec<u8>,
}

impl From<RawRepresentation> for Representation {
    fn from(raw: RawRepresentation) -> Self {
        Self {
            group_index: raw.group_index,
            uti: raw.uti,
            payload: raw.payload,
        }
    }
}

impl From<&Representation> for RawRepresentation {
    fn from(rep: &Representation) -> Self {
        Self {
            group_index: rep.group_index,
            uti: rep.uti.clone(),
            payload: rep.payload.clone(),
        }
    }
}

/// Raw clipboard capture payload submitted by Swift ClipboardMonitor.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RawCapture {
    pub timestamp_ms: i64,
    pub source_bundle_id: Option<String>,
    pub representations: Vec<RawRepresentation>,
}

/// Outcome of an ingestion operation returned to Swift.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct IngestResultDTO {
    pub item_id: String,
    pub is_duplicate: bool,
    pub title: String,
    pub copy_count: u32,
    pub content_kind: String,
}

/// Lightweight item summary for UI list rendering without loading payloads into memory.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryItemSummaryDTO {
    pub id: String,
    pub content_kind: String,
    pub title: String,
    pub snippet: String,
    pub is_pinned: bool,
    pub pin_order: Option<u32>,
    pub pin_key: Option<String>,
    pub source_bundle_id: Option<String>,
    pub first_copied_at_ms: i64,
    pub last_copied_at_ms: i64,
    pub copy_count: u32,
    pub byte_size: u64,
    pub available_utis: Vec<String>,
    pub title_highlights: Vec<HighlightRangeDTO>,
    pub snippet_highlights: Vec<HighlightRangeDTO>,
}

impl From<HistoryItemSummary> for HistoryItemSummaryDTO {
    fn from(s: HistoryItemSummary) -> Self {
        Self {
            id: s.id.to_string(),
            content_kind: s.content_kind.to_string(),
            title: s.title,
            snippet: s.snippet,
            is_pinned: s.is_pinned,
            pin_order: s.pin_order,
            pin_key: s.pin_key,
            source_bundle_id: s.source_bundle_id,
            first_copied_at_ms: s.first_copied_at_ms,
            last_copied_at_ms: s.last_copied_at_ms,
            copy_count: s.copy_count,
            byte_size: s.byte_size,
            available_utis: s.available_utis,
            title_highlights: s.title_highlights,
            snippet_highlights: s.snippet_highlights,
        }
    }
}

/// High-level metrics describing database utilization.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StorageStatsDTO {
    pub total_items: u64,
    pub pinned_items: u64,
    pub unpinned_items: u64,
    pub total_representations: u64,
    pub db_size_bytes: u64,
}

impl From<StorageStats> for StorageStatsDTO {
    fn from(s: StorageStats) -> Self {
        Self {
            total_items: s.total_items as u64,
            pinned_items: s.pinned_items as u64,
            unpinned_items: s.unpinned_items as u64,
            total_representations: s.total_representations as u64,
            db_size_bytes: s.db_size_bytes,
        }
    }
}
