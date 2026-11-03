// ==============================================================================
// Mimra Core — Database Failure Recovery & Backup Engine
// Provides resilient database opening, corrupt database quarantine, partial data
// salvaging, atomic vacuum backups, and safe backup restoration.
// Linked Feature: F-052, F-055, P4-07
// Test ID: T-DB-01
// ==============================================================================

use crate::domain::dto::DatabaseRecoveryReport;
use crate::error::CoreError;
use crate::storage::db::{configure_pragmas, open_database, DatabaseConfig};
use crate::storage::migrations::{run_migrations, verify_database_integrity};
use crate::storage::search::rebuild_search_index;
use rusqlite::{Connection, OpenFlags};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Safely isolates corrupted SQLite database files by renaming the primary file,
/// WAL log, and shared memory file to timestamped quarantine backups.
/// Guarantees that user history is never unconditionally erased or overwritten.
pub fn quarantine_corrupted_database(db_path: &Path) -> Result<PathBuf, CoreError> {
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);

    let original_name = db_path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "mimra.sqlite".to_string());

    let quarantine_name = format!("{original_name}.corrupt.{now_ms}.bak");
    let quarantine_path = db_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(&quarantine_name);

    // 1. Move primary DB file if present
    if db_path.exists() {
        fs::rename(db_path, &quarantine_path).map_err(|e| CoreError::DiskFullOrIoError {
            details: format!(
                "Failed to quarantine corrupt database '{}' to '{}': {e}",
                db_path.display(),
                quarantine_path.display()
            ),
        })?;
    }

    // 2. Quarantine WAL file if present
    let wal_path = PathBuf::from(format!("{}-wal", db_path.to_string_lossy()));
    if wal_path.exists() {
        let wal_quarantine = PathBuf::from(format!("{}-wal", quarantine_path.to_string_lossy()));
        let _ = fs::rename(&wal_path, &wal_quarantine);
    }

    // 3. Quarantine SHM file if present
    let shm_path = PathBuf::from(format!("{}-shm", db_path.to_string_lossy()));
    if shm_path.exists() {
        let shm_quarantine = PathBuf::from(format!("{}-shm", quarantine_path.to_string_lossy()));
        let _ = fs::rename(&shm_path, &shm_quarantine);
    }

    Ok(quarantine_path)
}

/// Attempts to salvage readable items from a quarantined database file into a target connection.
/// Scans through `history_items` and `item_representations` row-by-row, gracefully skipping
/// unreadable or corrupt pages so that maximum valid user data is preserved.
pub fn attempt_salvage_corrupted_database(
    corrupt_db_path: &Path,
    target_conn: &mut Connection,
) -> u32 {
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI;
    let source_conn = match Connection::open_with_flags(corrupt_db_path, flags) {
        Ok(c) => c,
        Err(_) => return 0,
    };

    // Configure pragmatic read settings to tolerate partial corruption
    let _ = source_conn.execute_batch(
        "PRAGMA foreign_keys = OFF;
         PRAGMA read_uncommitted = ON;",
    );

    let mut item_stmt = match source_conn.prepare(
        "SELECT id, first_copied_at_ms, last_copied_at_ms, copy_count, source_bundle_id,
                content_kind, title, search_text, ocr_text, content_hash, is_pinned,
                pin_order, pin_key, byte_size, created_at_ms
         FROM history_items;",
    ) {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let mut rows = match item_stmt.query([]) {
        Ok(r) => r,
        Err(_) => return 0,
    };

    let mut salvaged_count: u32 = 0;

    while let Ok(Some(row)) = rows.next() {
        // Attempt to extract item fields
        let id: String = match row.get(0) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let first_copied: i64 = row.get(1).unwrap_or(0);
        let last_copied: i64 = row.get(2).unwrap_or(0);
        let copy_count: i64 = row.get(3).unwrap_or(1);
        let source_bundle: Option<String> = row.get(4).ok();
        let content_kind: String = row.get(5).unwrap_or_else(|_| "text".to_string());
        let title: String = row.get(6).unwrap_or_default();
        let search_text: String = row.get(7).unwrap_or_default();
        let ocr_text: String = row.get(8).unwrap_or_default();
        let content_hash: Vec<u8> = match row.get(9) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let is_pinned: i64 = row.get(10).unwrap_or(0);
        let pin_order: Option<i64> = row.get(11).ok();
        let pin_key: Option<String> = row.get(12).ok();
        let byte_size: i64 = row.get(13).unwrap_or(0);
        let created_at: i64 = row.get(14).unwrap_or(0);

        // Fetch representations for this item
        let mut rep_stmt = match source_conn.prepare(
            "SELECT group_index, uti, payload FROM item_representations WHERE item_id = ?1;",
        ) {
            Ok(s) => s,
            Err(_) => continue,
        };

        let mut rep_rows = match rep_stmt.query([&id]) {
            Ok(r) => r,
            Err(_) => continue,
        };

        let mut representations: Vec<(i64, String, Vec<u8>)> = Vec::new();
        while let Ok(Some(rep_row)) = rep_rows.next() {
            if let (Ok(g), Ok(u), Ok(p)) = (rep_row.get(0), rep_row.get(1), rep_row.get(2)) {
                representations.push((g, u, p));
            }
        }

        // Must have at least one valid representation to salvage item
        if representations.is_empty() {
            continue;
        }

        // Insert into target_conn inside a transaction/savepoint
        let insert_result: Result<(), rusqlite::Error> = (|| {
            let tx = target_conn.transaction()?;
            tx.execute(
                "INSERT OR REPLACE INTO history_items (
                    id, first_copied_at_ms, last_copied_at_ms, copy_count, source_bundle_id,
                    content_kind, title, search_text, ocr_text, content_hash, is_pinned,
                    pin_order, pin_key, byte_size, created_at_ms
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15);",
                rusqlite::params![
                    id,
                    first_copied,
                    last_copied,
                    copy_count,
                    source_bundle,
                    content_kind,
                    title,
                    search_text,
                    ocr_text,
                    content_hash,
                    is_pinned,
                    pin_order,
                    pin_key,
                    byte_size,
                    created_at
                ],
            )?;

            for (group_idx, uti, payload) in representations {
                tx.execute(
                    "INSERT OR REPLACE INTO item_representations (
                        item_id, group_index, uti, payload
                    ) VALUES (?1, ?2, ?3, ?4);",
                    rusqlite::params![id, group_idx, uti, payload],
                )?;
            }

            tx.commit()?;
            Ok(())
        })();

        if insert_result.is_ok() {
            salvaged_count += 1;
        }
    }

    salvaged_count
}

/// Opens a SQLite database at the given path with automated failure detection and recovery.
/// If corruption is detected during connection open, migrations, or integrity check:
/// 1. The corrupted file is quarantined to a safe timestamped backup (`.bak`).
/// 2. A clean database is initialized and migrated.
/// 3. Salvageable items from the quarantined file are restored into the new database.
/// 4. FTS5 index is rebuilt and database integrity is verified.
pub fn open_database_resilient(
    db_path: &Path,
    config: &DatabaseConfig,
) -> Result<(Connection, DatabaseRecoveryReport), CoreError> {
    // If the file does not exist yet, initialize fresh
    if !db_path.exists() {
        let mut conn = open_database(db_path, config)?;
        run_migrations(&mut conn)?;
        verify_database_integrity(&conn)?;
        return Ok((
            conn,
            DatabaseRecoveryReport {
                was_recovered: false,
                quarantined_backup_path: None,
                salvaged_items_count: 0,
                error_details: None,
            },
        ));
    }

    // Attempt standard connection, migration, and integrity verification
    let open_attempt = (|| -> Result<Connection, CoreError> {
        let mut conn = open_database(db_path, config)?;
        run_migrations(&mut conn)?;
        verify_database_integrity(&conn)?;
        Ok(conn)
    })();

    match open_attempt {
        Ok(conn) => Ok((
            conn,
            DatabaseRecoveryReport {
                was_recovered: false,
                quarantined_backup_path: None,
                salvaged_items_count: 0,
                error_details: None,
            },
        )),
        Err(err) => {
            // Check if failure is due to database corruption
            let is_corrupt = match &err {
                CoreError::DatabaseCorrupt { .. } => true,
                CoreError::DatabaseError { details } => {
                    let d = details.to_lowercase();
                    d.contains("corrupt")
                        || d.contains("malformed")
                        || d.contains("not a database")
                        || d.contains("disk image is malformed")
                        || d.contains("integrity check failed")
                }
                _ => false,
            };

            // Non-corruption errors (e.g. forward schema mismatch, permission denied) must be propagated directly
            if !is_corrupt {
                return Err(err);
            }

            // Perform safe quarantine and recovery
            let quarantine_path = quarantine_corrupted_database(db_path)?;

            // Initialize fresh target database
            let mut fresh_conn = open_database(db_path, config)?;
            run_migrations(&mut fresh_conn)?;
            verify_database_integrity(&fresh_conn)?;

            // Salvage readable content from the quarantined file
            let salvaged_count =
                attempt_salvage_corrupted_database(&quarantine_path, &mut fresh_conn);

            // Rebuild search index to ensure complete FTS5 synchronization
            if salvaged_count > 0 {
                let _ = rebuild_search_index(&fresh_conn);
            }

            Ok((
                fresh_conn,
                DatabaseRecoveryReport {
                    was_recovered: true,
                    quarantined_backup_path: Some(quarantine_path.to_string_lossy().to_string()),
                    salvaged_items_count: salvaged_count,
                    error_details: Some(err.to_string()),
                },
            ))
        }
    }
}

/// Creates a safe, consistent offline backup snapshot of the active database using SQLite's VACUUM INTO.
/// Verifies the integrity of the generated backup before returning.
pub fn backup_database(conn: &Connection, destination: &Path) -> Result<(), CoreError> {
    if destination.exists() {
        return Err(CoreError::InvalidInput {
            details: format!(
                "Backup destination file '{}' already exists. Choose a unique or non-existent destination.",
                destination.display()
            ),
        });
    }

    if let Some(parent) = destination.parent() {
        if !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| CoreError::DiskFullOrIoError {
                details: format!(
                    "Failed to create backup directory '{}': {e}",
                    parent.display()
                ),
            })?;
        }
    }

    let dest_str = destination
        .to_str()
        .ok_or_else(|| CoreError::InvalidInput {
            details: "Destination path contains invalid UTF-8 characters".to_string(),
        })?;

    // VACUUM INTO creates a transactionally consistent, defragmented backup copy
    conn.execute("VACUUM INTO ?1;", [dest_str])
        .map_err(|e| CoreError::DiskFullOrIoError {
            details: format!("SQLite VACUUM INTO backup failed: {e}"),
        })?;

    // Verify backup integrity
    let backup_conn = Connection::open(destination)?;
    configure_pragmas(&backup_conn, &DatabaseConfig::default())?;
    verify_database_integrity(&backup_conn)?;

    Ok(())
}

/// Restores the target database from a verified backup file using SQLite's native online backup API.
/// Performs pre-verification on the backup, streams pages safely into the target connection,
/// and verifies target database integrity and migrations.
pub fn restore_database_from_backup(
    backup_path: &Path,
    target_path: &Path,
    config: &DatabaseConfig,
) -> Result<(), CoreError> {
    if !backup_path.exists() {
        return Err(CoreError::InvalidInput {
            details: format!("Backup file '{}' does not exist.", backup_path.display()),
        });
    }

    // 1. Verify backup file integrity before applying
    let backup_conn = Connection::open(backup_path)?;
    configure_pragmas(&backup_conn, config)?;
    verify_database_integrity(&backup_conn)?;

    // 2. Open or create target database with standard pragmas
    let mut target_conn = open_database(target_path, config)?;

    // 3. Use SQLite Online Backup API to safely stream all pages from backup into target
    {
        let backup = rusqlite::backup::Backup::new(&backup_conn, &mut target_conn)?;
        backup.run_to_completion(100, std::time::Duration::from_millis(10), None)?;
    }

    // 4. Verify restored target database and ensure search index is in sync
    run_migrations(&mut target_conn)?;
    verify_database_integrity(&target_conn)?;
    let _ = rebuild_search_index(&target_conn);

    Ok(())
}
