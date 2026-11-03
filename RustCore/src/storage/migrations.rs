// ==============================================================================
// Mimra Core — Database Migrations Runner
// Atomically applies versioned migrations and tracks schema version.
// ==============================================================================

use crate::error::CoreError;
use rusqlite::Connection;
use std::time::{SystemTime, UNIX_EPOCH};

/// Represents a single versioned migration.
pub struct Migration {
    pub version: i64,
    pub description: &'static str,
    pub sql: &'static str,
}

/// Initial V1 Schema Migration
pub const V1_INITIAL_SCHEMA: &str = r#"
CREATE TABLE history_items (
    id TEXT PRIMARY KEY,
    first_copied_at_ms INTEGER NOT NULL,
    last_copied_at_ms INTEGER NOT NULL,
    copy_count INTEGER NOT NULL DEFAULT 1,
    source_bundle_id TEXT,
    content_kind TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    search_text TEXT NOT NULL DEFAULT '',
    ocr_text TEXT NOT NULL DEFAULT '',
    content_hash BLOB NOT NULL,
    is_pinned INTEGER NOT NULL DEFAULT 0,
    pin_order INTEGER,
    pin_key TEXT,
    byte_size INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL
);

CREATE TABLE item_representations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id TEXT NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
    group_index INTEGER NOT NULL,
    uti TEXT NOT NULL,
    payload BLOB NOT NULL,
    UNIQUE(item_id, group_index, uti)
);

-- Fast lookups for recency ordering and deduplication
CREATE INDEX idx_history_recent ON history_items(is_pinned, last_copied_at_ms DESC);
CREATE INDEX idx_history_hash ON history_items(content_hash);
CREATE UNIQUE INDEX idx_history_pin_key ON history_items(pin_key) WHERE pin_key IS NOT NULL;
CREATE INDEX idx_item_rep_parent ON item_representations(item_id);

-- FTS5 Full-Text Search virtual table backed by history_items
CREATE VIRTUAL TABLE search_fts USING fts5(
    title,
    search_text,
    ocr_text,
    content='history_items',
    content_rowid='rowid',
    tokenize='unicode61'
);

-- Synchronize search_fts with history_items via triggers
CREATE TRIGGER history_items_ai AFTER INSERT ON history_items BEGIN
    INSERT INTO search_fts(rowid, title, search_text, ocr_text)
    VALUES (new.rowid, new.title, new.search_text, new.ocr_text);
END;

CREATE TRIGGER history_items_ad AFTER DELETE ON history_items BEGIN
    INSERT INTO search_fts(search_fts, rowid, title, search_text, ocr_text)
    VALUES('delete', old.rowid, old.title, old.search_text, old.ocr_text);
END;

CREATE TRIGGER history_items_au AFTER UPDATE ON history_items BEGIN
    INSERT INTO search_fts(search_fts, rowid, title, search_text, ocr_text)
    VALUES('delete', old.rowid, old.title, old.search_text, old.ocr_text);
    INSERT INTO search_fts(rowid, title, search_text, ocr_text)
    VALUES (new.rowid, new.title, new.search_text, new.ocr_text);
END;
"#;

pub const ALL_MIGRATIONS: &[Migration] = &[Migration {
    version: 1,
    description: "Initial schema with normalized tables, cascading deletes, and FTS5 triggers",
    sql: V1_INITIAL_SCHEMA,
}];

/// Runs all pending migrations against the database within a transaction.
/// Returns the list of newly applied migration versions.
pub fn run_migrations(conn: &mut Connection) -> Result<Vec<i64>, CoreError> {
    // 1. Ensure migrations tracking table exists
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at_ms INTEGER NOT NULL
        );",
    )?;

    // 2. Query applied versions
    let applied_versions: Vec<i64> = {
        let mut stmt =
            conn.prepare("SELECT version FROM schema_migrations ORDER BY version ASC;")?;
        let rows = stmt.query_map([], |row| row.get(0))?;
        let mut versions = Vec::new();
        for row in rows {
            versions.push(row?);
        }
        versions
    };

    let mut newly_applied = Vec::new();

    // 3. Apply unapplied migrations in sequential order
    for migration in ALL_MIGRATIONS {
        if !applied_versions.contains(&migration.version) {
            let tx = conn.transaction()?;

            // Execute migration SQL batch
            tx.execute_batch(migration.sql)?;

            let now_ms = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);

            tx.execute(
                "INSERT INTO schema_migrations (version, applied_at_ms) VALUES (?1, ?2);",
                (migration.version, now_ms),
            )?;

            tx.commit()?;
            newly_applied.push(migration.version);
        }
    }

    Ok(newly_applied)
}

/// Runs SQLite integrity checks (foreign keys and DB file integrity).
pub fn verify_database_integrity(conn: &Connection) -> Result<(), CoreError> {
    // 1. Verify foreign key consistency
    let fk_violations: i64 = conn
        .query_row("PRAGMA foreign_key_check;", [], |_| Ok(1))
        .unwrap_or(0);
    if fk_violations > 0 {
        return Err(CoreError::DatabaseError {
            details: "Foreign key integrity check failed: orphaned references detected."
                .to_string(),
        });
    }

    // 2. Verify overall database B-tree and page integrity
    let integrity_result: String =
        conn.query_row("PRAGMA integrity_check;", [], |row| row.get(0))?;
    if integrity_result.to_lowercase() != "ok" {
        return Err(CoreError::DatabaseError {
            details: format!("SQLite integrity check failed: {integrity_result}"),
        });
    }

    Ok(())
}
