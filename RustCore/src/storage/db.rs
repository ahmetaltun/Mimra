// ==============================================================================
// Mimra Core — Database Connection & Setup
// Manages SQLite connection initialization, WAL configuration, and PRAGMAs.
// ==============================================================================

use crate::error::CoreError;
use rusqlite::Connection;
use std::path::Path;
use std::time::Duration;

/// Configuration options for the local database connection.
#[derive(Debug, Clone)]
pub struct DatabaseConfig {
    pub busy_timeout: Duration,
}

impl Default for DatabaseConfig {
    fn default() -> Self {
        Self {
            busy_timeout: Duration::from_millis(5000),
        }
    }
}

/// Opens and configures a SQLite connection at the given path.
/// Sets `foreign_keys = ON`, `journal_mode = WAL`, and `busy_timeout`.
pub fn open_database(path: &Path, config: &DatabaseConfig) -> Result<Connection, CoreError> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            let _ = std::fs::create_dir_all(parent);
        }
    }

    let conn = Connection::open(path)?;

    // Configure SQLite pragmas for performance, concurrency, and integrity
    configure_pragmas(&conn, config)?;

    Ok(conn)
}

/// Opens an in-memory SQLite connection configured with the standard pragmas (useful for tests).
pub fn open_in_memory(config: &DatabaseConfig) -> Result<Connection, CoreError> {
    let conn = Connection::open_in_memory()?;
    configure_pragmas(&conn, config)?;
    Ok(conn)
}

/// Applies required PRAGMAs to an active SQLite connection.
pub fn configure_pragmas(conn: &Connection, config: &DatabaseConfig) -> Result<(), CoreError> {
    // 1. Enforce foreign keys (crucial for cascading deletes)
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;

    // 2. Set WAL mode for non-blocking concurrent reads and crash durability
    // Note: In-memory databases ignore WAL, so ignore any non-critical return value
    let _ = conn.query_row("PRAGMA journal_mode = WAL;", [], |_| Ok(()));

    // 3. Set busy timeout to prevent immediate lock errors under concurrent worker access
    conn.busy_timeout(config.busy_timeout)?;

    Ok(())
}
