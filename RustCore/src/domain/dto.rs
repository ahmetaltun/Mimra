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

/// Sorting order for history items.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum HistorySortMode {
    /// Ordered by most recently copied timestamp (default).
    Recency,
    /// Ordered by total number of times copied (most frequent first), tie-broken by recency.
    CopyCount,
    /// Ordered by first initial copy timestamp (chronological capture order).
    FirstCopied,
}

/// Placement of pinned items relative to unpinned items in list views.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum PinArrangement {
    /// Pinned items appear at the very top of the list (default).
    Top,
    /// Pinned items appear at the bottom of the list.
    Bottom,
    /// Pinned items are mixed inline with unpinned items based solely on the active sort order.
    Inline,
}

/// Configuration policy for historical data retention (P4-05).
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record,
)]
pub struct RetentionPolicyDTO {
    /// Maximum number of unpinned items retained in history (None = unlimited).
    pub max_count: Option<u32>,
    /// Maximum age in days for unpinned items (None = unlimited).
    pub max_age_days: Option<u32>,
    /// Maximum total byte size for unpinned item payloads (None = unlimited).
    pub max_size_bytes: Option<u64>,
}

/// Internal domain representation of retention policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RetentionPolicy {
    pub max_count: Option<usize>,
    pub max_age_days: Option<u32>,
    pub max_size_bytes: Option<u64>,
}

impl From<RetentionPolicyDTO> for RetentionPolicy {
    fn from(dto: RetentionPolicyDTO) -> Self {
        Self {
            max_count: dto.max_count.map(|c| c as usize),
            max_age_days: dto.max_age_days,
            max_size_bytes: dto.max_size_bytes,
        }
    }
}

impl From<RetentionPolicy> for RetentionPolicyDTO {
    fn from(p: RetentionPolicy) -> Self {
        Self {
            max_count: p.max_count.map(|c| c as u32),
            max_age_days: p.max_age_days,
            max_size_bytes: p.max_size_bytes,
        }
    }
}

/// Statistics detailing the outcome of a retention enforcement or cleanup cycle.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct CleanupReportDTO {
    pub evicted_by_count: u64,
    pub evicted_by_age: u64,
    pub evicted_by_size: u64,
    pub total_evicted: u64,
    pub remaining_unpinned: u64,
    pub remaining_pinned: u64,
    pub freed_bytes: u64,
}

/// Internal domain representation of cleanup report.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CleanupReport {
    pub evicted_by_count: usize,
    pub evicted_by_age: usize,
    pub evicted_by_size: usize,
    pub total_evicted: usize,
    pub remaining_unpinned: usize,
    pub remaining_pinned: usize,
    pub freed_bytes: u64,
}

impl From<CleanupReport> for CleanupReportDTO {
    fn from(r: CleanupReport) -> Self {
        Self {
            evicted_by_count: r.evicted_by_count as u64,
            evicted_by_age: r.evicted_by_age as u64,
            evicted_by_size: r.evicted_by_size as u64,
            total_evicted: r.total_evicted as u64,
            remaining_unpinned: r.remaining_unpinned as u64,
            remaining_pinned: r.remaining_pinned as u64,
            freed_bytes: r.freed_bytes,
        }
    }
}

/// Detailed diagnostic and recovery outcome when opening or recovering a database.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DatabaseRecoveryReportDTO {
    pub was_recovered: bool,
    pub quarantined_backup_path: Option<String>,
    pub salvaged_items_count: u32,
    pub error_details: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct DatabaseRecoveryReport {
    pub was_recovered: bool,
    pub quarantined_backup_path: Option<String>,
    pub salvaged_items_count: u32,
    pub error_details: Option<String>,
}

impl From<DatabaseRecoveryReport> for DatabaseRecoveryReportDTO {
    fn from(r: DatabaseRecoveryReport) -> Self {
        Self {
            was_recovered: r.was_recovered,
            quarantined_backup_path: r.quarantined_backup_path,
            salvaged_items_count: r.salvaged_items_count,
            error_details: r.error_details,
        }
    }
}
