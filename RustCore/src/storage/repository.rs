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
        // Record recopy on existing item
        existing.record_recopy(item.last_copied_at_ms, item.source_bundle_id.clone());
        update_recopy(
            &tx,
            &existing.id,
            item.last_copied_at_ms,
            item.source_bundle_id.as_deref(),
        )?;

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
