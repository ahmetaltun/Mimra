// ==============================================================================
// Mimra Core — History Repository
// Handles transactional storage operations: insertions, duplicate detection,
// representation queries, and capacity eviction.
// ==============================================================================

use crate::domain::content::{ContentKind, Representation};
use crate::domain::dto::{CleanupReport, RetentionPolicy};
use crate::domain::item::HistoryItem;
use crate::error::CoreError;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use std::str::FromStr;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

/// Result of an ingestion operation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IngestOutcome {
    /// Content was unique and newly inserted into history.
    NewItem(HistoryItem),
    /// Content matched an existing item hash; recopy timestamp and count were updated.
    DuplicateUpdated(HistoryItem),
}

/// Inserts a new history item and all its representations into the database.
pub fn insert_item(tx: &Transaction, item: &HistoryItem) -> Result<(), CoreError> {
    // 1. Insert history_items row
    tx.execute(
        "INSERT INTO history_items (
            id, first_copied_at_ms, last_copied_at_ms, copy_count,
            source_bundle_id, content_kind, title, search_text, ocr_text,
            content_hash, is_pinned, pin_order, pin_key, byte_size, created_at_ms
        ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15
        );",
        params![
            item.id.to_string(),
            item.first_copied_at_ms,
            item.last_copied_at_ms,
            item.copy_count,
            item.source_bundle_id,
            item.content_kind.to_string(),
            item.title,
            item.search_text,
            item.ocr_text,
            item.content_hash.as_slice(),
            if item.is_pinned { 1 } else { 0 },
            item.pin_order,
            item.pin_key,
            item.byte_size,
            item.created_at_ms,
        ],
    )?;

    // 2. Insert item_representations rows
    let mut stmt = tx.prepare(
        "INSERT INTO item_representations (item_id, group_index, uti, payload)
         VALUES (?1, ?2, ?3, ?4);",
    )?;

    let id_str = item.id.to_string();
    for rep in &item.representations {
        stmt.execute(params![
            id_str,
            rep.group_index,
            rep.uti,
            rep.payload.as_slice(),
        ])?;
    }

    Ok(())
}

/// Finds an existing history item by its BLAKE3 content hash.
pub fn find_by_content_hash(
    conn: &Connection,
    hash: &[u8; 32],
) -> Result<Option<HistoryItem>, CoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, first_copied_at_ms, last_copied_at_ms, copy_count,
                source_bundle_id, content_kind, title, search_text, ocr_text,
                content_hash, is_pinned, pin_order, pin_key, byte_size, created_at_ms
         FROM history_items
         WHERE content_hash = ?1
         LIMIT 1;",
    )?;

    let row = stmt
        .query_row(params![hash.as_slice()], |row| {
            let id_str: String = row.get(0)?;
            let content_kind_str: String = row.get(5)?;
            let content_hash_raw: Vec<u8> = row.get(9)?;
            let is_pinned_int: i64 = row.get(10)?;

            let mut hash_arr = [0u8; 32];
            if content_hash_raw.len() == 32 {
                hash_arr.copy_from_slice(&content_hash_raw);
            }

            Ok((
                id_str,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                content_kind_str,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
                hash_arr,
                is_pinned_int != 0,
                row.get(11)?,
                row.get(12)?,
                row.get(13)?,
                row.get(14)?,
            ))
        })
        .optional()?;

    let Some((
        id_str,
        first_copied_at_ms,
        last_copied_at_ms,
        copy_count,
        source_bundle_id,
        content_kind_str,
        title,
        search_text,
        ocr_text,
        content_hash,
        is_pinned,
        pin_order,
        pin_key,
        byte_size,
        created_at_ms,
    )) = row
    else {
        return Ok(None);
    };

    let id = Uuid::parse_str(&id_str).map_err(|e| CoreError::DatabaseError {
        details: format!("Corrupted UUID in database: {e}"),
    })?;

    let content_kind = ContentKind::from_str(&content_kind_str)?;
    let representations = load_representations(conn, &id)?;

    Ok(Some(HistoryItem {
        id,
        content_kind,
        title,
        search_text,
        ocr_text,
        content_hash,
        source_bundle_id,
        is_pinned,
        pin_order,
        pin_key,
        first_copied_at_ms,
        last_copied_at_ms,
        copy_count,
        byte_size,
        created_at_ms,
        representations,
    }))
}

/// Finds a history item by its primary UUID.
pub fn find_by_id(conn: &Connection, id: &Uuid) -> Result<Option<HistoryItem>, CoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, first_copied_at_ms, last_copied_at_ms, copy_count,
                source_bundle_id, content_kind, title, search_text, ocr_text,
                content_hash, is_pinned, pin_order, pin_key, byte_size, created_at_ms
         FROM history_items
         WHERE id = ?1
         LIMIT 1;",
    )?;

    let id_str = id.to_string();
    let row = stmt
        .query_row(params![id_str], |row| {
            let id_str: String = row.get(0)?;
            let content_kind_str: String = row.get(5)?;
            let content_hash_raw: Vec<u8> = row.get(9)?;
            let is_pinned_int: i64 = row.get(10)?;

            let mut hash_arr = [0u8; 32];
            if content_hash_raw.len() == 32 {
                hash_arr.copy_from_slice(&content_hash_raw);
            }

            Ok((
                id_str,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                content_kind_str,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
                hash_arr,
                is_pinned_int != 0,
                row.get(11)?,
                row.get(12)?,
                row.get(13)?,
                row.get(14)?,
            ))
        })
        .optional()?;

    let Some((
        id_str,
        first_copied_at_ms,
        last_copied_at_ms,
        copy_count,
        source_bundle_id,
        content_kind_str,
        title,
        search_text,
        ocr_text,
        content_hash,
        is_pinned,
        pin_order,
        pin_key,
        byte_size,
        created_at_ms,
    )) = row
    else {
        return Ok(None);
    };

    let id = Uuid::parse_str(&id_str).map_err(|e| CoreError::DatabaseError {
        details: format!("Corrupted UUID in database: {e}"),
    })?;

    let content_kind = ContentKind::from_str(&content_kind_str)?;
    let representations = load_representations(conn, &id)?;

    Ok(Some(HistoryItem {
        id,
        content_kind,
        title,
        search_text,
        ocr_text,
        content_hash,
        source_bundle_id,
        is_pinned,
        pin_order,
        pin_key,
        first_copied_at_ms,
        last_copied_at_ms,
        copy_count,
        byte_size,
        created_at_ms,
        representations,
    }))
}

/// Loads all representations belonging to a specific history item.
pub fn load_representations(
    conn: &Connection,
    item_id: &Uuid,
) -> Result<Vec<Representation>, CoreError> {
    let mut stmt = conn.prepare(
        "SELECT group_index, uti, payload
         FROM item_representations
         WHERE item_id = ?1
         ORDER BY group_index ASC, id ASC;",
    )?;

    let id_str = item_id.to_string();
    let rows = stmt.query_map(params![id_str], |row| {
        let group_index: u32 = row.get(0)?;
        let uti: String = row.get(1)?;
        let payload: Vec<u8> = row.get(2)?;
        Ok(Representation {
            group_index,
            uti,
            payload,
        })
    })?;

    let mut reps = Vec::new();
    for row in rows {
        reps.push(row?);
    }

    Ok(reps)
}

/// Updates recopy timestamps, count, and optionally source application for an existing item.
pub fn update_recopy(
    tx: &Transaction,
    item_id: &Uuid,
    timestamp_ms: i64,
    source_bundle_id: Option<&str>,
) -> Result<(), CoreError> {
    tx.execute(
        "UPDATE history_items
         SET last_copied_at_ms = ?1,
             copy_count = copy_count + 1,
             source_bundle_id = COALESCE(?2, source_bundle_id)
         WHERE id = ?3;",
        params![timestamp_ms, source_bundle_id, item_id.to_string()],
    )?;

    Ok(())
}

/// Updates the last_copied_at_ms timestamp and increments copy_count for an existing item,
/// moving it to the top of the history list under recency-based sorting.
pub fn touch_item(conn: &Connection, item_id: &Uuid, timestamp_ms: i64) -> Result<bool, CoreError> {
    let now_ms = if timestamp_ms > 0 {
        timestamp_ms
    } else {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    };

    let rows_affected = conn.execute(
        "UPDATE history_items
         SET last_copied_at_ms = ?1,
             copy_count = copy_count + 1
         WHERE id = ?2;",
        params![now_ms, item_id.to_string()],
    )?;

    Ok(rows_affected > 0)
}

/// Updates recopy timestamps, count, source application, and merges representations for an existing item (F-012, T-CAP-05).
pub fn update_recopy_and_merge(
    tx: &Transaction,
    existing: &mut HistoryItem,
    incoming: &HistoryItem,
) -> Result<(), CoreError> {
    existing.record_recopy(
        incoming.last_copied_at_ms,
        incoming.source_bundle_id.clone(),
    );

    // 1. Upsert incoming representations into item_representations
    for rep in &incoming.representations {
        tx.execute(
            "INSERT INTO item_representations (item_id, group_index, uti, payload)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(item_id, group_index, uti) DO UPDATE SET payload = excluded.payload;",
            params![
                existing.id.to_string(),
                rep.group_index,
                rep.uti,
                rep.payload.as_slice(),
            ],
        )?;
    }

    // 2. Check if content kind or title should be upgraded (e.g. text -> rich_text or url page title)
    let should_upgrade_kind =
        existing.content_kind == ContentKind::Text && incoming.content_kind != ContentKind::Text;

    let existing_is_bare_url = existing.title.starts_with("http://")
        || existing.title.starts_with("https://")
        || existing.title.starts_with("file://")
        || existing.title.is_empty();
    let incoming_has_rich_title = !incoming.title.is_empty()
        && !incoming.title.starts_with("http://")
        && !incoming.title.starts_with("https://")
        && !incoming.title.starts_with("file://");
    let should_upgrade_title = incoming_has_rich_title && existing_is_bare_url;

    if should_upgrade_kind {
        existing.content_kind = incoming.content_kind;
    }
    if should_upgrade_title || (should_upgrade_kind && !incoming.title.is_empty()) {
        existing.title = incoming.title.clone();
        existing.search_text = incoming.search_text.clone();
    }

    // 3. Update history_items record
    tx.execute(
        "UPDATE history_items
         SET last_copied_at_ms = ?1,
             copy_count = copy_count + 1,
             source_bundle_id = COALESCE(?2, source_bundle_id),
             content_kind = ?3,
             title = ?4,
             search_text = ?5,
             byte_size = (SELECT COALESCE(SUM(LENGTH(payload)), 0) FROM item_representations WHERE item_id = ?6)
         WHERE id = ?6;",
        params![
            incoming.last_copied_at_ms,
            incoming.source_bundle_id.as_deref(),
            existing.content_kind.to_string(),
            existing.title,
            existing.search_text,
            existing.id.to_string(),
        ],
    )?;

    // 4. Reload merged representations into in-memory struct
    existing.representations = load_representations(tx, &existing.id)?;
    existing.byte_size = existing
        .representations
        .iter()
        .map(|r| r.payload.len() as u64)
        .sum();

    Ok(())
}

/// Evicts unpinned items based on age, count, and byte size policies within an atomic transaction.
/// Pinned items are NEVER evicted under any retention policy.
pub fn enforce_retention_policy(
    tx: &Transaction,
    policy: &RetentionPolicy,
    now_ms: i64,
) -> Result<CleanupReport, CoreError> {
    let initial_bytes: u64 = tx.query_row(
        "SELECT COALESCE(SUM(byte_size), 0) FROM history_items WHERE is_pinned = 0;",
        [],
        |row| row.get::<_, i64>(0).map(|b| b as u64),
    )?;

    let mut evicted_by_age = 0;
    let mut evicted_by_count = 0;
    let mut evicted_by_size = 0;

    // 1. Age-based eviction (cutoff by days)
    if let Some(days) = policy.max_age_days {
        if days > 0 {
            let cutoff_ms = now_ms - (days as i64 * 86_400_000);
            evicted_by_age = tx.execute(
                "DELETE FROM history_items
                 WHERE is_pinned = 0 AND last_copied_at_ms < ?1;",
                params![cutoff_ms],
            )?;
        }
    }

    // 2. Count-based eviction
    if let Some(max_count) = policy.max_count {
        let unpinned_count: usize = tx.query_row(
            "SELECT COUNT(*) FROM history_items WHERE is_pinned = 0;",
            [],
            |row| row.get(0),
        )?;

        if unpinned_count > max_count {
            let excess = unpinned_count - max_count;
            evicted_by_count = tx.execute(
                "DELETE FROM history_items
                 WHERE id IN (
                     SELECT id FROM history_items
                     WHERE is_pinned = 0
                     ORDER BY last_copied_at_ms ASC
                     LIMIT ?1
                 );",
                params![excess as i64],
            )?;
        }
    }

    // 3. Payload size-based eviction
    if let Some(max_bytes) = policy.max_size_bytes {
        let current_bytes: u64 = tx.query_row(
            "SELECT COALESCE(SUM(byte_size), 0) FROM history_items WHERE is_pinned = 0;",
            [],
            |row| row.get::<_, i64>(0).map(|b| b as u64),
        )?;

        if current_bytes > max_bytes {
            let mut stmt = tx.prepare(
                "SELECT id, byte_size FROM history_items
                 WHERE is_pinned = 0
                 ORDER BY last_copied_at_ms ASC;",
            )?;

            let rows = stmt.query_map([], |row| {
                let id_str: String = row.get(0)?;
                let b_size: i64 = row.get(1)?;
                Ok((id_str, b_size as u64))
            })?;

            let mut to_delete = Vec::new();
            let mut running_size = current_bytes;
            for r in rows {
                let (id, b_size) = r?;
                to_delete.push(id);
                running_size = running_size.saturating_sub(b_size);
                if running_size <= max_bytes {
                    break;
                }
            }

            drop(stmt);

            for id in to_delete {
                evicted_by_size +=
                    tx.execute("DELETE FROM history_items WHERE id = ?1;", params![id])?;
            }
        }
    }

    let final_bytes: u64 = tx.query_row(
        "SELECT COALESCE(SUM(byte_size), 0) FROM history_items WHERE is_pinned = 0;",
        [],
        |row| row.get::<_, i64>(0).map(|b| b as u64),
    )?;

    let remaining_unpinned: usize = tx.query_row(
        "SELECT COUNT(*) FROM history_items WHERE is_pinned = 0;",
        [],
        |row| row.get(0),
    )?;

    let remaining_pinned: usize = tx.query_row(
        "SELECT COUNT(*) FROM history_items WHERE is_pinned = 1;",
        [],
        |row| row.get(0),
    )?;

    let total_evicted = evicted_by_age + evicted_by_count + evicted_by_size;
    let freed_bytes = initial_bytes.saturating_sub(final_bytes);

    Ok(CleanupReport {
        evicted_by_count,
        evicted_by_age,
        evicted_by_size,
        total_evicted,
        remaining_unpinned,
        remaining_pinned,
        freed_bytes,
    })
}

/// Evicts the oldest unpinned items if the total unpinned count exceeds `max_unpinned`.
/// Pinned items are NEVER evicted.
/// Returns the number of evicted items.
pub fn enforce_retention_limit(tx: &Transaction, max_unpinned: usize) -> Result<usize, CoreError> {
    let report = enforce_retention_policy(
        tx,
        &RetentionPolicy {
            max_count: Some(max_unpinned),
            max_age_days: None,
            max_size_bytes: None,
        },
        0,
    )?;
    Ok(report.total_evicted)
}

/// Ingests a new or duplicate item atomically within a single transaction using the provided retention policy.
pub fn ingest_clipboard_item_with_policy(
    conn: &mut Connection,
    item: HistoryItem,
    policy: &RetentionPolicy,
) -> Result<IngestOutcome, CoreError> {
    let now_ms = item.last_copied_at_ms;
    let tx = conn.transaction()?;

    // 1. Check if identical content hash exists
    if let Some(mut existing) = find_by_content_hash(&tx, &item.content_hash)? {
        update_recopy_and_merge(&tx, &mut existing, &item)?;
        tx.commit()?;
        return Ok(IngestOutcome::DuplicateUpdated(existing));
    }

    // 2. Insert new item
    insert_item(&tx, &item)?;

    // 3. Enforce capacity limit on unpinned items
    enforce_retention_policy(&tx, policy, now_ms)?;

    tx.commit()?;
    Ok(IngestOutcome::NewItem(item))
}

/// Ingests a new or duplicate item atomically within a single transaction:
/// - If exact content exists: updates recopy timestamp/count and preserves pins.
/// - If new content: inserts item and representations.
/// - Enforces unpinned capacity limit (evicts oldest unpinned).
pub fn ingest_clipboard_item(
    conn: &mut Connection,
    item: HistoryItem,
    max_unpinned: usize,
) -> Result<IngestOutcome, CoreError> {
    ingest_clipboard_item_with_policy(
        conn,
        item,
        &RetentionPolicy {
            max_count: Some(max_unpinned),
            max_age_days: None,
            max_size_bytes: None,
        },
    )
}

/// Summary DTO for displaying an item in UI list rows without loading large binary payloads into memory.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct HistoryItemSummary {
    pub id: Uuid,
    pub content_kind: ContentKind,
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
    pub title_highlights: Vec<crate::domain::search::HighlightRangeDTO>,
    pub snippet_highlights: Vec<crate::domain::search::HighlightRangeDTO>,
}

/// Disk and item metrics for the storage layer.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct StorageStats {
    pub total_items: usize,
    pub pinned_items: usize,
    pub unpinned_items: usize,
    pub total_representations: usize,
    pub db_size_bytes: u64,
}

/// Retrieves a paginated list of history item summaries.
/// Pinned items appear first (ordered by `pin_order ASC, last_copied_at_ms DESC`),
/// followed by unpinned items (`last_copied_at_ms DESC`).
pub fn list_history_page(
    conn: &Connection,
    limit: usize,
    offset: usize,
) -> Result<Vec<HistoryItemSummary>, CoreError> {
    list_history_page_with_options(
        conn,
        crate::domain::dto::HistorySortMode::Recency,
        crate::domain::dto::PinArrangement::Top,
        limit,
        offset,
    )
}

/// Retrieves a paginated list of history item summaries with configurable sorting and pinned arrangement.
pub fn list_history_page_with_options(
    conn: &Connection,
    sort_mode: crate::domain::dto::HistorySortMode,
    pin_arrangement: crate::domain::dto::PinArrangement,
    limit: usize,
    offset: usize,
) -> Result<Vec<HistoryItemSummary>, CoreError> {
    use crate::domain::dto::{HistorySortMode, PinArrangement};

    let order_clause = match pin_arrangement {
        PinArrangement::Top => match sort_mode {
            HistorySortMode::Recency => {
                "is_pinned DESC, CASE WHEN is_pinned = 1 THEN pin_order END ASC, last_copied_at_ms DESC"
            }
            HistorySortMode::CopyCount => {
                "is_pinned DESC, CASE WHEN is_pinned = 1 THEN pin_order END ASC, copy_count DESC, last_copied_at_ms DESC"
            }
            HistorySortMode::FirstCopied => {
                "is_pinned DESC, CASE WHEN is_pinned = 1 THEN pin_order END ASC, first_copied_at_ms DESC"
            }
        },
        PinArrangement::Bottom => match sort_mode {
            HistorySortMode::Recency => {
                "is_pinned ASC, CASE WHEN is_pinned = 1 THEN pin_order END ASC, last_copied_at_ms DESC"
            }
            HistorySortMode::CopyCount => {
                "is_pinned ASC, CASE WHEN is_pinned = 1 THEN pin_order END ASC, copy_count DESC, last_copied_at_ms DESC"
            }
            HistorySortMode::FirstCopied => {
                "is_pinned ASC, CASE WHEN is_pinned = 1 THEN pin_order END ASC, first_copied_at_ms DESC"
            }
        },
        PinArrangement::Inline => match sort_mode {
            HistorySortMode::Recency => "last_copied_at_ms DESC",
            HistorySortMode::CopyCount => "copy_count DESC, last_copied_at_ms DESC",
            HistorySortMode::FirstCopied => "first_copied_at_ms DESC",
        },
    };

    let sql = format!(
        "SELECT id, content_kind, title, search_text, ocr_text, is_pinned, pin_order, pin_key,
                source_bundle_id, first_copied_at_ms, last_copied_at_ms, copy_count, byte_size
         FROM history_items
         ORDER BY {}
         LIMIT ?1 OFFSET ?2;",
        order_clause
    );

    let mut stmt = conn.prepare(&sql)?;

    let rows = stmt.query_map(params![limit as i64, offset as i64], |row| {
        let id_str: String = row.get(0)?;
        let kind_str: String = row.get(1)?;
        let title: String = row.get(2)?;
        let search_text: String = row.get(3)?;
        let ocr_text: String = row.get(4)?;
        let is_pinned_int: i64 = row.get(5)?;

        // For images with recognized OCR text, display OCR snippet; otherwise use search_text
        let snippet: String = if kind_str == "image" && !ocr_text.trim().is_empty() {
            ocr_text.chars().take(160).collect()
        } else {
            search_text.chars().take(160).collect()
        };

        Ok((
            id_str,
            kind_str,
            title,
            snippet,
            is_pinned_int != 0,
            row.get(6)?,
            row.get(7)?,
            row.get(8)?,
            row.get(9)?,
            row.get(10)?,
            row.get(11)?,
            row.get(12)?,
        ))
    })?;

    let mut summaries = Vec::new();
    for row in rows {
        let (
            id_str,
            kind_str,
            title,
            snippet,
            is_pinned,
            pin_order,
            pin_key,
            source_bundle_id,
            first_copied_at_ms,
            last_copied_at_ms,
            copy_count,
            byte_size,
        ) = row?;

        let id = Uuid::parse_str(&id_str).map_err(|e| CoreError::DatabaseError {
            details: format!("Corrupted UUID in history_items: {e}"),
        })?;

        let content_kind = ContentKind::from_str(&kind_str)?;
        let available_utis = query_available_utis(conn, &id)?;

        summaries.push(HistoryItemSummary {
            id,
            content_kind,
            title,
            snippet,
            is_pinned,
            pin_order,
            pin_key,
            source_bundle_id,
            first_copied_at_ms,
            last_copied_at_ms,
            copy_count,
            byte_size,
            available_utis,
            title_highlights: Vec::new(),
            snippet_highlights: Vec::new(),
        });
    }

    Ok(summaries)
}

/// Helper to query available UTIs for an item without loading byte payloads.
pub fn query_available_utis(conn: &Connection, item_id: &Uuid) -> Result<Vec<String>, CoreError> {
    let mut stmt = conn.prepare(
        "SELECT DISTINCT uti FROM item_representations WHERE item_id = ?1 ORDER BY group_index ASC, id ASC;",
    )?;

    let rows = stmt.query_map(params![item_id.to_string()], |row| row.get(0))?;
    let mut utis = Vec::new();
    for row in rows {
        utis.push(row?);
    }
    Ok(utis)
}

/// Fetches the raw payload bytes for a specific item and UTI (e.g. for paste or preview).
pub fn fetch_payload(
    conn: &Connection,
    item_id: &Uuid,
    uti: &str,
) -> Result<Option<Vec<u8>>, CoreError> {
    let mut stmt = conn.prepare(
        "SELECT payload FROM item_representations WHERE item_id = ?1 AND uti = ?2 LIMIT 1;",
    )?;

    let payload: Option<Vec<u8>> = stmt
        .query_row(params![item_id.to_string(), uti], |row| row.get(0))
        .optional()?;

    Ok(payload)
}

/// Deletes a single item by its ID.
/// Foreign-key cascading automatically removes representation rows and triggers update FTS5.
/// Returns true if an item was deleted, false if not found.
pub fn delete_item_by_id(conn: &Connection, item_id: &Uuid) -> Result<bool, CoreError> {
    let deleted = conn.execute(
        "DELETE FROM history_items WHERE id = ?1;",
        params![item_id.to_string()],
    )?;
    Ok(deleted > 0)
}

/// Clears all unpinned history items.
/// Pinned items are strictly protected and remain intact.
/// Returns the number of cleared items.
pub fn clear_unpinned_history(conn: &Connection) -> Result<usize, CoreError> {
    let deleted = conn.execute("DELETE FROM history_items WHERE is_pinned = 0;", [])?;
    Ok(deleted)
}

/// Clears all history items, including pinned items.
/// Used when the user explicitly confirms a full reset.
/// Returns the number of cleared items.
pub fn clear_all_history(conn: &Connection) -> Result<usize, CoreError> {
    let deleted = conn.execute("DELETE FROM history_items;", [])?;
    Ok(deleted)
}

/// Validates and normalizes a requested pin shortcut key (P5-02 / F-024, T-PIN-01).
/// Permitted: ASCII letters, digits, punctuation/symbols (`[];'./-=\` corpus), and non-US Unicode symbols.
/// Rejected: Empty, multi-character, control characters, and reserved key 'p' (Option-P).
pub fn validate_pin_key(key: &str) -> Result<String, CoreError> {
    let trimmed = key.trim();
    if trimmed.is_empty() {
        return Err(CoreError::InvalidInput {
            details: "Pin shortcut key cannot be empty or whitespace".to_string(),
        });
    }

    let chars: Vec<char> = trimmed.chars().collect();
    if chars.len() != 1 {
        return Err(CoreError::InvalidInput {
            details: format!(
                "Pin shortcut key must be a single character, got {} characters ('{}')",
                chars.len(),
                key
            ),
        });
    }

    let c = chars[0];

    // Check reserved keys
    if c == 'p' || c == 'P' {
        return Err(CoreError::PinKeyConflict {
            key: key.to_string(),
            details: "Key 'P' is reserved for toggling Pin/Unpin (Option-P)".to_string(),
        });
    }

    if c.is_control() {
        return Err(CoreError::InvalidInput {
            details: "Control characters cannot be used as pin shortcut keys".to_string(),
        });
    }

    // Normalize to lowercase for case-insensitive keyboard matching
    Ok(c.to_lowercase().to_string())
}

/// Sets or unsets the pinned status, ordering, and shortcut key for an item.
pub fn set_pin_status(
    conn: &Connection,
    item_id: &Uuid,
    is_pinned: bool,
    pin_key: Option<String>,
    pin_order: Option<u32>,
) -> Result<(), CoreError> {
    let (key_param, order_param) = if is_pinned {
        if let Some(ref raw_key) = pin_key {
            let normalized_key = validate_pin_key(raw_key)?;

            // Case-insensitive duplicate check across other items
            let existing_title: Option<String> = conn
                .query_row(
                    "SELECT title FROM history_items WHERE LOWER(pin_key) = LOWER(?1) AND id != ?2;",
                    params![normalized_key, item_id.to_string()],
                    |r| r.get(0),
                )
                .optional()?;

            if let Some(title) = existing_title {
                return Err(CoreError::PinKeyConflict {
                    key: normalized_key,
                    details: format!("Key is already assigned to item '{title}'"),
                });
            }

            (Some(normalized_key), pin_order)
        } else {
            (None, pin_order)
        }
    } else {
        (None, None)
    };

    let affected = conn.execute(
        "UPDATE history_items
         SET is_pinned = ?1,
             pin_key = ?2,
             pin_order = ?3
         WHERE id = ?4;",
        params![
            if is_pinned { 1 } else { 0 },
            key_param,
            order_param,
            item_id.to_string(),
        ],
    )?;

    if affected == 0 {
        return Err(CoreError::ItemNotFound {
            id: item_id.to_string(),
        });
    }

    Ok(())
}

/// Toggles the pinned status of an item.
/// If unpinned, pins the item and assigns it the next pin_order.
/// If pinned, unpins the item and clears pin_key and pin_order.
/// Returns the new is_pinned boolean status.
pub fn toggle_pin_status(conn: &Connection, item_id: &Uuid) -> Result<bool, CoreError> {
    let is_pinned: i64 = conn
        .query_row(
            "SELECT is_pinned FROM history_items WHERE id = ?1;",
            params![item_id.to_string()],
            |r| r.get(0),
        )
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => CoreError::ItemNotFound {
                id: item_id.to_string(),
            },
            other => CoreError::from(other),
        })?;

    let currently_pinned = is_pinned != 0;
    let next_pinned = !currently_pinned;

    if next_pinned {
        let max_order: Option<u32> = conn
            .query_row(
                "SELECT MAX(pin_order) FROM history_items WHERE is_pinned = 1;",
                [],
                |r| r.get(0),
            )
            .unwrap_or(None);
        let next_order = max_order.map(|o| o + 1).unwrap_or(0);
        set_pin_status(conn, item_id, true, None, Some(next_order))?;
    } else {
        set_pin_status(conn, item_id, false, None, None)?;
    }

    Ok(next_pinned)
}

/// Atomically reorders pinned items according to the provided list of item UUIDs (P5-03 / F-046, T-PIN-03).
/// Updates `pin_order` sequentially from 0 to N-1 for each item in `ordered_item_ids`.
/// Preserves each item's existing `pin_key` and other representations.
/// Fails if any ID does not exist or is not pinned.
pub fn reorder_pins(conn: &mut Connection, ordered_item_ids: &[Uuid]) -> Result<(), CoreError> {
    if ordered_item_ids.is_empty() {
        return Ok(());
    }

    // Check for duplicate IDs in the request
    let mut seen = std::collections::HashSet::new();
    for id in ordered_item_ids {
        if !seen.insert(id) {
            return Err(CoreError::InvalidInput {
                details: format!("Cannot reorder pins: duplicate item id '{id}' provided"),
            });
        }
    }

    let tx = conn.transaction()?;

    for (index, id) in ordered_item_ids.iter().enumerate() {
        let is_pinned: Option<i64> = tx
            .query_row(
                "SELECT is_pinned FROM history_items WHERE id = ?1;",
                params![id.to_string()],
                |r| r.get(0),
            )
            .optional()?;

        match is_pinned {
            Some(p) if p != 0 => {
                tx.execute(
                    "UPDATE history_items SET pin_order = ?1 WHERE id = ?2;",
                    params![index as u32, id.to_string()],
                )?;
            }
            Some(_) => {
                return Err(CoreError::InvalidInput {
                    details: format!("Item '{id}' cannot be reordered because it is not pinned"),
                });
            }
            None => {
                return Err(CoreError::ItemNotFound { id: id.to_string() });
            }
        }
    }

    tx.commit()?;
    Ok(())
}

/// Edits the text content of an existing pinned item (P5-04 / F-045, T-PIN-02).
///
/// Updates the item's plain text (and compatible HTML) representations,
/// recalculates content hash, title, and search text, triggers an atomic FTS5 index update,
/// and preserves the item's stable UUID, pinned state, pin_order, pin_key, and any unrelated representations.
///
/// Fails if the item does not exist (`CoreError::ItemNotFound`), if the item is not pinned (`CoreError::InvalidInput`),
/// or if `new_text` is empty (`CoreError::InvalidInput`).
pub fn edit_pinned_item_text(
    conn: &mut Connection,
    item_id: &Uuid,
    new_text: &str,
) -> Result<HistoryItemSummary, CoreError> {
    let nfc_text: String = new_text.nfc().collect();
    let trimmed = nfc_text.trim();
    if trimmed.is_empty() {
        return Err(CoreError::InvalidInput {
            details: "Pinned item text cannot be empty.".to_string(),
        });
    }

    let tx = conn.transaction()?;

    type PinnedItemMetadataRow = (
        i64,
        Option<u32>,
        Option<String>,
        Option<String>,
        i64,
        i64,
        u32,
        i64,
    );

    // 1. Verify item exists and is pinned
    let row: Option<PinnedItemMetadataRow> = tx
        .query_row(
            "SELECT is_pinned, pin_order, pin_key, source_bundle_id, first_copied_at_ms, last_copied_at_ms, copy_count, created_at_ms
             FROM history_items WHERE id = ?1;",
            params![item_id.to_string()],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                    r.get(7)?,
                ))
            },
        )
        .optional()?;

    let (
        is_pinned,
        pin_order,
        pin_key,
        source_bundle_id,
        first_copied_at_ms,
        last_copied_at_ms,
        copy_count,
        _created_at_ms,
    ) = match row {
        Some(r) => r,
        None => {
            return Err(CoreError::ItemNotFound {
                id: item_id.to_string(),
            })
        }
    };

    if is_pinned == 0 {
        return Err(CoreError::InvalidInput {
            details: format!("Item '{item_id}' cannot be edited because it is not pinned."),
        });
    }

    // 2. Fetch existing representations
    let existing_reps: Vec<Representation> = {
        let mut stmt = tx.prepare(
            "SELECT group_index, uti, payload FROM item_representations WHERE item_id = ?1 ORDER BY group_index ASC, id ASC;",
        )?;
        let reps = stmt
            .query_map(params![item_id.to_string()], |r| {
                let group_index: u32 = r.get(0)?;
                let uti: String = r.get(1)?;
                let payload: Vec<u8> = r.get(2)?;
                Ok(Representation {
                    group_index,
                    uti,
                    payload,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        reps
    };

    // 3. Mutate text representations while preserving unrelated representations
    let mut updated_reps = Vec::with_capacity(existing_reps.len().max(1));
    let mut found_plain_text = false;

    let escaped_html = trimmed
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;");
    let synthetic_html = format!("<meta charset='utf-8'><p>{}</p>", escaped_html).into_bytes();

    for rep in existing_reps {
        if rep.group_index == 0 {
            if rep.uti == crate::domain::content::uti::UTF8_PLAIN_TEXT
                || rep.uti == "public.plain-text"
                || rep.uti == "NSStringPboardType"
                || rep.uti == "public.text"
            {
                found_plain_text = true;
                updated_reps.push(Representation {
                    group_index: 0,
                    uti: rep.uti,
                    payload: trimmed.as_bytes().to_vec(),
                });
            } else if rep.uti == crate::domain::content::uti::HTML {
                // Update HTML representation to match the new text content
                updated_reps.push(Representation {
                    group_index: 0,
                    uti: rep.uti,
                    payload: synthetic_html.clone(),
                });
            } else if rep.uti == crate::domain::content::uti::RTF
                || rep.uti == crate::domain::content::uti::RTFD
            {
                // Drop stale RTF so pasteboard consumers fall back to clean updated plain text / HTML
                continue;
            } else {
                // Unrelated metadata representation in group 0 (e.g. org.nspasteboard.source, public.url-name, etc.)
                updated_reps.push(rep);
            }
        } else {
            // Unrelated representation in another group (e.g. attached file URLs or secondary pasteboard items)
            updated_reps.push(rep);
        }
    }

    if !found_plain_text {
        updated_reps.insert(
            0,
            Representation {
                group_index: 0,
                uti: crate::domain::content::uti::UTF8_PLAIN_TEXT.to_string(),
                payload: trimmed.as_bytes().to_vec(),
            },
        );
    }

    // 4. Overwrite item_representations for this item
    tx.execute(
        "DELETE FROM item_representations WHERE item_id = ?1;",
        params![item_id.to_string()],
    )?;
    for rep in &updated_reps {
        tx.execute(
            "INSERT INTO item_representations (item_id, group_index, uti, payload) VALUES (?1, ?2, ?3, ?4);",
            params![item_id.to_string(), rep.group_index, rep.uti, rep.payload],
        )?;
    }

    // 5. Recompute content hash, kind, title, search text, and total byte size
    let byte_size: u64 = updated_reps.iter().map(|r| r.payload.len() as u64).sum();
    let content_hash = HistoryItem::calculate_content_hash(&updated_reps);
    let content_kind = HistoryItem::derive_content_kind(&updated_reps);
    let (title, search_text) = HistoryItem::derive_text_fields(&updated_reps, content_kind);

    // 6. Update history_items row (FTS5 trigger automatically reindexes title and search_text)
    tx.execute(
        "UPDATE history_items
         SET content_kind = ?1,
             title = ?2,
             search_text = ?3,
             content_hash = ?4,
             byte_size = ?5
         WHERE id = ?6;",
        params![
            content_kind.to_string(),
            title,
            search_text,
            content_hash.as_slice(),
            byte_size as i64,
            item_id.to_string(),
        ],
    )?;

    tx.commit()?;

    let available_utis = query_available_utis(conn, item_id)?;
    let snippet = if search_text.len() > 120 {
        format!("{}...", &search_text[..120])
    } else {
        search_text.clone()
    };

    Ok(HistoryItemSummary {
        id: *item_id,
        content_kind,
        title,
        snippet,
        is_pinned: true,
        pin_order,
        pin_key,
        source_bundle_id,
        first_copied_at_ms,
        last_copied_at_ms,
        copy_count,
        byte_size,
        available_utis,
        title_highlights: Vec::new(),
        snippet_highlights: Vec::new(),
    })
}

/// Updates the OCR text for an existing history item (P6-05 / F-043, T-OCR-01).
///
/// If the item exists, updates `ocr_text` in `history_items`.
/// SQLite triggers automatically update the `search_fts` virtual table.
/// Returns Ok(true) if the item was found and updated, or Ok(false) if the item does not exist.
pub fn update_ocr_text(
    conn: &Connection,
    item_id: &Uuid,
    ocr_text: &str,
) -> Result<bool, CoreError> {
    let rows_affected = conn.execute(
        "UPDATE history_items SET ocr_text = ?1 WHERE id = ?2;",
        params![ocr_text, item_id.to_string()],
    )?;
    Ok(rows_affected > 0)
}

/// Retrieves the OCR text for an item if it exists (P6-05 / F-043, T-OCR-01).
pub fn get_ocr_text(conn: &Connection, item_id: &Uuid) -> Result<Option<String>, CoreError> {
    let mut stmt = conn.prepare("SELECT ocr_text FROM history_items WHERE id = ?1;")?;
    let mut rows = stmt.query(params![item_id.to_string()])?;
    if let Some(row) = rows.next()? {
        let text: String = row.get(0)?;
        Ok(Some(text))
    } else {
        Ok(None)
    }
}

/// Computes current storage metrics: item counts, representation counts, and database size.
pub fn get_storage_stats(
    conn: &Connection,
    db_file_path: Option<&std::path::Path>,
) -> Result<StorageStats, CoreError> {
    let total_items: usize =
        conn.query_row("SELECT COUNT(*) FROM history_items;", [], |r| r.get(0))?;

    let pinned_items: usize = conn.query_row(
        "SELECT COUNT(*) FROM history_items WHERE is_pinned = 1;",
        [],
        |r| r.get(0),
    )?;

    let unpinned_items = total_items.saturating_sub(pinned_items);

    let total_representations: usize =
        conn.query_row("SELECT COUNT(*) FROM item_representations;", [], |r| {
            r.get(0)
        })?;

    let db_size_bytes = if let Some(path) = db_file_path {
        std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
    } else {
        // For in-memory database, compute approximate page size * page count
        let page_size: i64 = conn
            .query_row("PRAGMA page_size;", [], |r| r.get(0))
            .unwrap_or(4096);
        let page_count: i64 = conn
            .query_row("PRAGMA page_count;", [], |r| r.get(0))
            .unwrap_or(0);
        (page_size * page_count) as u64
    };

    Ok(StorageStats {
        total_items,
        pinned_items,
        unpinned_items,
        total_representations,
        db_size_bytes,
    })
}
