// ==============================================================================
// Mimra Core — Library Entrypoint & UniFFI Exports
// ==============================================================================

pub mod domain;
pub mod error;
pub mod storage;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

pub use domain::dto::{
    DatabaseRecoveryReportDTO, HistoryItemSummaryDTO, IngestResultDTO, RawCapture,
    RawRepresentation, StorageStatsDTO,
};
pub use domain::{
    fuzzy_match, score_item, uti, CanonicalUrl, CleanupReport, CleanupReportDTO, ContentKind,
    DatabaseRecoveryReport, HexColor, HighlightRangeDTO, HistoryItem, HistorySortMode,
    PinArrangement, Representation, RetentionPolicy, RetentionPolicyDTO, SearchMode,
};
pub use error::CoreError;
pub use storage::{
    attempt_salvage_corrupted_database, backup_database, clear_all_history, clear_unpinned_history,
    delete_item_by_id, edit_pinned_item_text, enforce_retention_limit, enforce_retention_policy,
    fetch_payload, find_by_content_hash, find_by_id, get_storage_stats, ingest_clipboard_item,
    ingest_clipboard_item_with_policy, insert_item, list_history_page,
    list_history_page_with_options, load_representations, open_database, open_database_resilient,
    open_in_memory, quarantine_corrupted_database, query_available_utis, rebuild_search_index,
    reorder_pins, restore_database_from_backup, run_migrations, sanitize_fts5_query,
    search_history_page, search_history_page_with_options, set_pin_status, toggle_pin_status,
    update_recopy, validate_pin_key, verify_database_integrity, verify_search_index_integrity,
    DatabaseConfig, HistoryItemSummary, IngestOutcome, StorageStats,
};

// Setup UniFFI scaffolding for procedural macro bindings
uniffi::setup_scaffolding!();

/// Core handle managing database state and exposed to Swift via UniFFI.
#[derive(uniffi::Object)]
pub struct MimraCoreHandle {
    db_path: Option<PathBuf>,
    conn: Mutex<rusqlite::Connection>,
    retention_policy: Mutex<RetentionPolicy>,
    recovery_report: Mutex<Option<DatabaseRecoveryReportDTO>>,
}

#[uniffi::export]
impl MimraCoreHandle {
    #[uniffi::constructor]
    pub fn open(db_path: String) -> Result<Arc<Self>, CoreError> {
        let path = PathBuf::from(db_path);
        let (conn, recovery_report) = open_database_resilient(&path, &DatabaseConfig::default())?;

        Ok(Arc::new(Self {
            db_path: Some(path),
            conn: Mutex::new(conn),
            retention_policy: Mutex::new(RetentionPolicy {
                max_count: Some(200),
                max_age_days: None,
                max_size_bytes: None,
            }),
            recovery_report: Mutex::new(Some(recovery_report.into())),
        }))
    }

    #[uniffi::constructor]
    pub fn open_resilient(db_path: String) -> Result<Arc<Self>, CoreError> {
        Self::open(db_path)
    }

    #[uniffi::constructor]
    pub fn open_in_memory() -> Result<Arc<Self>, CoreError> {
        let mut conn = open_in_memory(&DatabaseConfig::default())?;
        run_migrations(&mut conn)?;
        verify_database_integrity(&conn)?;

        Ok(Arc::new(Self {
            db_path: None,
            conn: Mutex::new(conn),
            retention_policy: Mutex::new(RetentionPolicy {
                max_count: Some(200),
                max_age_days: None,
                max_size_bytes: None,
            }),
            recovery_report: Mutex::new(None),
        }))
    }

    pub fn set_max_unpinned(&self, limit: u32) {
        if let Ok(mut lock) = self.retention_policy.lock() {
            lock.max_count = Some(limit as usize);
        }
    }

    pub fn set_retention_policy(&self, policy: RetentionPolicyDTO) {
        if let Ok(mut lock) = self.retention_policy.lock() {
            *lock = policy.into();
        }
    }

    pub fn get_retention_policy(&self) -> RetentionPolicyDTO {
        self.retention_policy
            .lock()
            .map(|p| (*p).into())
            .unwrap_or(RetentionPolicyDTO {
                max_count: Some(200),
                max_age_days: None,
                max_size_bytes: None,
            })
    }

    pub fn enforce_retention(
        &self,
        policy: Option<RetentionPolicyDTO>,
    ) -> Result<CleanupReportDTO, CoreError> {
        let effective_policy: RetentionPolicy = match policy {
            Some(p) => p.into(),
            None => self
                .retention_policy
                .lock()
                .map(|p| *p)
                .unwrap_or(RetentionPolicy {
                    max_count: Some(200),
                    max_age_days: None,
                    max_size_bytes: None,
                }),
        };

        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        let mut conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        let tx = conn.transaction()?;
        let report = enforce_retention_policy(&tx, &effective_policy, now_ms)?;
        tx.commit()?;

        Ok(report.into())
    }

    pub fn checkpoint_wal(&self) -> Result<u32, CoreError> {
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        let pages: u32 =
            conn.query_row("PRAGMA wal_checkpoint(TRUNCATE);", [], |row| row.get(2))?;
        Ok(pages)
    }

    pub fn vacuum_database(&self) -> Result<(), CoreError> {
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        conn.execute_batch("VACUUM;")?;
        Ok(())
    }

    pub fn ingest(&self, capture: RawCapture) -> Result<IngestResultDTO, CoreError> {
        let mut representations = Vec::new();
        for raw in capture.representations {
            representations.push(Representation::new(raw.group_index, raw.uti, raw.payload)?);
        }

        let item = HistoryItem::new(
            representations,
            capture.source_bundle_id,
            capture.timestamp_ms,
        )?;

        let policy = self
            .retention_policy
            .lock()
            .map(|p| *p)
            .unwrap_or(RetentionPolicy {
                max_count: Some(200),
                max_age_days: None,
                max_size_bytes: None,
            });

        let mut conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        let outcome = ingest_clipboard_item_with_policy(&mut conn, item, &policy)?;
        match outcome {
            IngestOutcome::NewItem(new_item) => Ok(IngestResultDTO {
                item_id: new_item.id.to_string(),
                is_duplicate: false,
                title: new_item.title,
                copy_count: new_item.copy_count,
                content_kind: new_item.content_kind.to_string(),
            }),
            IngestOutcome::DuplicateUpdated(updated_item) => Ok(IngestResultDTO {
                item_id: updated_item.id.to_string(),
                is_duplicate: true,
                title: updated_item.title,
                copy_count: updated_item.copy_count,
                content_kind: updated_item.content_kind.to_string(),
            }),
        }
    }

    pub fn list_page(
        &self,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<HistoryItemSummaryDTO>, CoreError> {
        self.list_page_with_sort(HistorySortMode::Recency, PinArrangement::Top, limit, offset)
    }

    pub fn list_page_with_sort(
        &self,
        sort_mode: HistorySortMode,
        pin_arrangement: PinArrangement,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<HistoryItemSummaryDTO>, CoreError> {
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        let summaries = list_history_page_with_options(
            &conn,
            sort_mode,
            pin_arrangement,
            limit as usize,
            offset as usize,
        )?;
        Ok(summaries
            .into_iter()
            .map(HistoryItemSummaryDTO::from)
            .collect())
    }

    pub fn search_page(
        &self,
        query: String,
        mode: SearchMode,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<HistoryItemSummaryDTO>, CoreError> {
        self.search_page_with_options(query, mode, true, PinArrangement::Top, limit, offset)
    }

    pub fn search_page_with_options(
        &self,
        query: String,
        mode: SearchMode,
        sort_by_relevance: bool,
        pin_arrangement: PinArrangement,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<HistoryItemSummaryDTO>, CoreError> {
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        let summaries = search_history_page_with_options(
            &conn,
            &query,
            mode,
            sort_by_relevance,
            pin_arrangement,
            limit as usize,
            offset as usize,
        )?;
        Ok(summaries
            .into_iter()
            .map(HistoryItemSummaryDTO::from)
            .collect())
    }

    pub fn rebuild_search_index(&self) -> Result<(), CoreError> {
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        rebuild_search_index(&conn)
    }

    pub fn check_search_index_integrity(&self) -> Result<bool, CoreError> {
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        verify_search_index_integrity(&conn)?;
        Ok(true)
    }

    pub fn fetch_payload(
        &self,
        item_id: String,
        uti: String,
    ) -> Result<Option<Vec<u8>>, CoreError> {
        let id = Uuid::parse_str(&item_id).map_err(|e| CoreError::InvalidInput {
            details: format!("Invalid UUID '{item_id}': {e}"),
        })?;

        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        fetch_payload(&conn, &id, &uti)
    }

    pub fn get_item_representations(
        &self,
        item_id: String,
    ) -> Result<Vec<RawRepresentation>, CoreError> {
        let id = Uuid::parse_str(&item_id).map_err(|e| CoreError::InvalidInput {
            details: format!("Invalid UUID '{item_id}': {e}"),
        })?;

        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        if find_by_id(&conn, &id)?.is_none() {
            return Err(CoreError::ItemNotFound { id: item_id });
        }

        let reps = load_representations(&conn, &id)?;
        Ok(reps.iter().map(RawRepresentation::from).collect())
    }

    pub fn delete_item(&self, item_id: String) -> Result<bool, CoreError> {
        let id = Uuid::parse_str(&item_id).map_err(|e| CoreError::InvalidInput {
            details: format!("Invalid UUID '{item_id}': {e}"),
        })?;

        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        delete_item_by_id(&conn, &id)
    }

    pub fn clear_unpinned(&self) -> Result<u64, CoreError> {
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        let cleared = clear_unpinned_history(&conn)?;
        Ok(cleared as u64)
    }

    pub fn clear_all(&self) -> Result<u64, CoreError> {
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        let cleared = clear_all_history(&conn)?;
        Ok(cleared as u64)
    }

    pub fn set_pin(
        &self,
        item_id: String,
        is_pinned: bool,
        pin_key: Option<String>,
        pin_order: Option<u32>,
    ) -> Result<(), CoreError> {
        let id = Uuid::parse_str(&item_id).map_err(|e| CoreError::InvalidInput {
            details: format!("Invalid UUID '{item_id}': {e}"),
        })?;

        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        set_pin_status(&conn, &id, is_pinned, pin_key, pin_order)
    }

    pub fn toggle_pin(&self, item_id: String) -> Result<bool, CoreError> {
        let id = Uuid::parse_str(&item_id).map_err(|e| CoreError::InvalidInput {
            details: format!("Invalid UUID '{item_id}': {e}"),
        })?;

        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        toggle_pin_status(&conn, &id)
    }

    pub fn validate_pin_key(&self, key: String) -> Result<String, CoreError> {
        validate_pin_key(&key)
    }

    pub fn reorder_pins(&self, ordered_ids: Vec<String>) -> Result<(), CoreError> {
        let mut parsed_ids = Vec::with_capacity(ordered_ids.len());
        for id_str in ordered_ids {
            let id = Uuid::parse_str(&id_str).map_err(|e| CoreError::InvalidInput {
                details: format!("Invalid UUID '{id_str}': {e}"),
            })?;
            parsed_ids.push(id);
        }

        let mut conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        reorder_pins(&mut conn, &parsed_ids)
    }

    pub fn edit_pinned_item_text(
        &self,
        item_id: String,
        new_text: String,
    ) -> Result<HistoryItemSummaryDTO, CoreError> {
        let id = Uuid::parse_str(&item_id).map_err(|e| CoreError::InvalidInput {
            details: format!("Invalid UUID '{item_id}': {e}"),
        })?;

        let mut conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        let summary = edit_pinned_item_text(&mut conn, &id, &new_text)?;
        Ok(HistoryItemSummaryDTO::from(summary))
    }

    pub fn get_stats(&self) -> Result<StorageStatsDTO, CoreError> {
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        let stats = get_storage_stats(&conn, self.db_path.as_deref())?;
        Ok(StorageStatsDTO::from(stats))
    }

    /// Queries the recovery diagnosis report if database recovery occurred during startup.
    pub fn get_recovery_report(&self) -> Option<DatabaseRecoveryReportDTO> {
        self.recovery_report.lock().ok().and_then(|r| r.clone())
    }

    /// Performs an atomic offline backup snapshot into the designated file path using SQLite VACUUM INTO.
    pub fn backup_database(&self, destination_path: String) -> Result<(), CoreError> {
        let dest = PathBuf::from(destination_path);
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;
        backup_database(&conn, &dest)
    }

    /// Verifies both B-Tree table integrity, foreign keys, and FTS5 search index synchronization.
    pub fn verify_integrity(&self) -> Result<(), CoreError> {
        let conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;
        verify_database_integrity(&conn)?;
        verify_search_index_integrity(&conn)?;
        Ok(())
    }

    /// Restores the active handle's database in-place from a verified backup file using SQLite Online Backup API.
    pub fn restore_from_backup(&self, backup_path: String) -> Result<(), CoreError> {
        let backup = PathBuf::from(backup_path);
        if !backup.exists() {
            return Err(CoreError::InvalidInput {
                details: format!("Backup file '{}' does not exist.", backup.display()),
            });
        }

        let backup_conn = rusqlite::Connection::open(&backup)?;
        crate::storage::db::configure_pragmas(&backup_conn, &DatabaseConfig::default())?;
        verify_database_integrity(&backup_conn)?;

        let mut conn = self.conn.lock().map_err(|e| CoreError::Internal {
            message: format!("Failed to acquire database lock: {e}"),
        })?;

        {
            let backup_runner = rusqlite::backup::Backup::new(&backup_conn, &mut conn)?;
            backup_runner.run_to_completion(100, std::time::Duration::from_millis(10), None)?;
        }

        run_migrations(&mut conn)?;
        verify_database_integrity(&conn)?;
        let _ = rebuild_search_index(&conn);

        Ok(())
    }
}

/// Restores a target SQLite database file from a verified backup file.
#[uniffi::export]
pub fn restore_database_backup(backup_path: String, target_path: String) -> Result<(), CoreError> {
    let backup = PathBuf::from(backup_path);
    let target = PathBuf::from(target_path);
    restore_database_from_backup(&backup, &target, &DatabaseConfig::default())
}

/// Maximum allowed payload size for a single clipboard item representation (10 MB).
pub const MAX_PAYLOAD_SIZE_BYTES: u64 = 10 * 1024 * 1024;

/// Returns the compiled version of the Mimra Core engine.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Computes a deterministic BLAKE3 cryptographic hex fingerprint for the given byte payload.
///
/// # Errors
/// Returns `CoreError::EmptyPayload` if the payload is empty.
/// Returns `CoreError::PayloadTooLarge` if the payload exceeds 10 MB.
#[uniffi::export]
pub fn fingerprint(payload: Vec<u8>) -> Result<String, CoreError> {
    if payload.is_empty() {
        return Err(CoreError::EmptyPayload);
    }

    let actual_size = payload.len() as u64;
    if actual_size > MAX_PAYLOAD_SIZE_BYTES {
        return Err(CoreError::PayloadTooLarge {
            max_bytes: MAX_PAYLOAD_SIZE_BYTES,
            actual_bytes: actual_size,
        });
    }

    let hash = blake3::hash(&payload);
    Ok(hash.to_hex().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_core_version_is_valid_semver() {
        let version = core_version();
        assert!(!version.is_empty(), "Version must not be empty");
        assert_eq!(version, "0.1.0");
    }

    #[test]
    fn test_fingerprint_deterministic_output() {
        let payload1 = b"Hello Mimra Clipboard".to_vec();
        let payload2 = b"Hello Mimra Clipboard".to_vec();
        let payload3 = b"Different text".to_vec();

        let hash1 = fingerprint(payload1).expect("Hashing payload1 must succeed");
        let hash2 = fingerprint(payload2).expect("Hashing payload2 must succeed");
        let hash3 = fingerprint(payload3).expect("Hashing payload3 must succeed");

        assert_eq!(
            hash1, hash2,
            "Identical payloads must yield identical fingerprints"
        );
        assert_ne!(
            hash1, hash3,
            "Different payloads must yield distinct fingerprints"
        );
        assert_eq!(
            hash1.len(),
            64,
            "BLAKE3 hex hash must be 64 characters long"
        );
    }

    #[test]
    fn test_fingerprint_empty_payload_fails() {
        let empty_payload = Vec::new();
        let result = fingerprint(empty_payload);

        assert_eq!(
            result,
            Err(CoreError::EmptyPayload),
            "Empty payload must return CoreError::EmptyPayload"
        );
    }

    #[test]
    fn test_fingerprint_oversized_payload_fails() {
        // Create an oversized payload: 10 MB + 1 byte
        let oversized = vec![0u8; (MAX_PAYLOAD_SIZE_BYTES + 1) as usize];
        let result = fingerprint(oversized);

        match result {
            Err(CoreError::PayloadTooLarge {
                max_bytes,
                actual_bytes,
            }) => {
                assert_eq!(max_bytes, MAX_PAYLOAD_SIZE_BYTES);
                assert_eq!(actual_bytes, MAX_PAYLOAD_SIZE_BYTES + 1);
            }
            other => panic!("Expected PayloadTooLarge error, got: {:?}", other),
        }
    }

    #[test]
    fn test_get_item_representations_success_and_not_found() {
        let handle = MimraCoreHandle::open_in_memory().expect("In-memory handle must open");
        let capture = RawCapture {
            timestamp_ms: 1000,
            source_bundle_id: Some("com.apple.dt.Xcode".to_string()),
            representations: vec![
                RawRepresentation {
                    group_index: 0,
                    uti: "public.utf8-plain-text".to_string(),
                    payload: b"let x = 42;".to_vec(),
                },
                RawRepresentation {
                    group_index: 0,
                    uti: "public.html".to_string(),
                    payload: b"<code>let x = 42;</code>".to_vec(),
                },
            ],
        };

        let ingest_res = handle.ingest(capture).expect("Ingestion must succeed");
        let reps = handle
            .get_item_representations(ingest_res.item_id.clone())
            .expect("Fetching representations must succeed");

        assert_eq!(reps.len(), 2);
        assert_eq!(reps[0].uti, "public.utf8-plain-text");
        assert_eq!(reps[0].payload, b"let x = 42;");
        assert_eq!(reps[1].uti, "public.html");
        assert_eq!(reps[1].payload, b"<code>let x = 42;</code>");

        // Non-existent item should return CoreError::ItemNotFound
        let fake_id = Uuid::new_v4().to_string();
        let not_found_res = handle.get_item_representations(fake_id.clone());
        assert_eq!(not_found_res, Err(CoreError::ItemNotFound { id: fake_id }));
    }
}
