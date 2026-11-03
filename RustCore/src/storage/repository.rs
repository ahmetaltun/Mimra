// ==============================================================================
// Mimra Core — History Repository
// Handles transactional storage operations: insertions, duplicate detection,
// representation queries, and capacity eviction.
// ==============================================================================

use crate::domain::content::{ContentKind, Representation};
use crate::domain::item::HistoryItem;
use crate::error::CoreError;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use std::str::FromStr;
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

/// Evicts the oldest unpinned items if the total unpinned count exceeds `max_unpinned`.
/// Pinned items are NEVER evicted.
/// Returns the number of evicted items.
pub fn enforce_retention_limit(tx: &Transaction, max_unpinned: usize) -> Result<usize, CoreError> {
    let unpinned_count: usize = tx.query_row(
        "SELECT COUNT(*) FROM history_items WHERE is_pinned = 0;",
        [],
        |row| row.get(0),
    )?;

    if unpinned_count <= max_unpinned {
        return Ok(0);
    }

    let excess = unpinned_count - max_unpinned;

    // Delete the oldest unpinned items. Cascading delete removes representations and triggers remove FTS rows.
    let deleted = tx.execute(
        "DELETE FROM history_items
         WHERE id IN (
             SELECT id FROM history_items
             WHERE is_pinned = 0
             ORDER BY last_copied_at_ms ASC
             LIMIT ?1
         );",
        params![excess as i64],
    )?;

    Ok(deleted)
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
    enforce_retention_limit(&tx, max_unpinned)?;

    tx.commit()?;
    Ok(IngestOutcome::NewItem(item))
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
    let mut stmt = conn.prepare(
        "SELECT id, content_kind, title, search_text, is_pinned, pin_order, pin_key,
                source_bundle_id, first_copied_at_ms, last_copied_at_ms, copy_count, byte_size
         FROM history_items
         ORDER BY is_pinned DESC,
                  CASE WHEN is_pinned = 1 THEN pin_order END ASC,
                  last_copied_at_ms DESC
         LIMIT ?1 OFFSET ?2;",
    )?;

    let rows = stmt.query_map(params![limit as i64, offset as i64], |row| {
        let id_str: String = row.get(0)?;
        let kind_str: String = row.get(1)?;
        let title: String = row.get(2)?;
        let search_text: String = row.get(3)?;
        let is_pinned_int: i64 = row.get(4)?;

        // Snippet is first ~160 characters of search_text
        let snippet: String = search_text.chars().take(160).collect();

        Ok((
            id_str,
            kind_str,
            title,
            snippet,
            is_pinned_int != 0,
            row.get(5)?,
            row.get(6)?,
            row.get(7)?,
            row.get(8)?,
            row.get(9)?,
            row.get(10)?,
            row.get(11)?,
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

/// Sets or unsets the pinned status, ordering, and shortcut key for an item.
pub fn set_pin_status(
    conn: &Connection,
    item_id: &Uuid,
    is_pinned: bool,
    pin_key: Option<String>,
    pin_order: Option<u32>,
) -> Result<(), CoreError> {
    let affected = conn.execute(
        "UPDATE history_items
         SET is_pinned = ?1,
             pin_key = ?2,
             pin_order = ?3
         WHERE id = ?4;",
        params![
            if is_pinned { 1 } else { 0 },
            pin_key,
            pin_order,
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
