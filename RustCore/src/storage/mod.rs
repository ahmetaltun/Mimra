// ==============================================================================
// Mimra Core — Storage Module
// ==============================================================================

pub mod db;
pub mod migrations;
pub mod repository;

pub use db::{open_database, open_in_memory, DatabaseConfig};
pub use migrations::{run_migrations, verify_database_integrity, ALL_MIGRATIONS};
pub use repository::{
    clear_all_history, clear_unpinned_history, delete_item_by_id, enforce_retention_limit,
    fetch_payload, find_by_content_hash, find_by_id, get_storage_stats, ingest_clipboard_item,
    insert_item, list_history_page, load_representations, query_available_utis, set_pin_status,
    update_recopy, HistoryItemSummary, IngestOutcome, StorageStats,
};

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;

    #[test]
    fn test_migrations_fresh_database_applies_v1() {
        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        let applied = run_migrations(&mut conn).unwrap();

        assert_eq!(applied, vec![1], "Must apply migration version 1");

        // Verify table exists by querying sqlite_master
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('history_items', 'item_representations', 'schema_migrations');",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            count, 3,
            "Expected history_items, item_representations, and schema_migrations tables to exist"
        );

        // Verify integrity check passes
        verify_database_integrity(&conn).expect("Integrity check must pass");
    }

    #[test]
    fn test_migrations_idempotency() {
        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        let first_run = run_migrations(&mut conn).unwrap();
        assert_eq!(first_run, vec![1]);

        let second_run = run_migrations(&mut conn).unwrap();
        assert!(second_run.is_empty(), "Second run must apply no migrations");
    }

    #[test]
    fn test_foreign_key_enforcement_and_cascading_delete() {
        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        let item_id = "11111111-2222-3333-4444-555555555555";

        // 1. Attempting to insert representation with nonexistent item_id must fail
        let orphan_insert = conn.execute(
            "INSERT INTO item_representations (item_id, group_index, uti, payload) VALUES (?1, 0, 'public.plain-text', X'DEADBEEF');",
            params![item_id],
        );
        assert!(
            orphan_insert.is_err(),
            "Inserting orphaned representation without parent must fail FK check"
        );

        // 2. Insert valid parent item
        conn.execute(
            "INSERT INTO history_items (id, first_copied_at_ms, last_copied_at_ms, copy_count, content_kind, title, search_text, content_hash, created_at_ms)
             VALUES (?1, 1000, 1000, 1, 'text', 'Test Item', 'Test Item search', X'000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F', 1000);",
            params![item_id],
        ).unwrap();

        // 3. Insert representations for parent
        conn.execute(
            "INSERT INTO item_representations (item_id, group_index, uti, payload) VALUES (?1, 0, 'public.plain-text', X'48656C6C6F');",
            params![item_id],
        ).unwrap();
        conn.execute(
            "INSERT INTO item_representations (item_id, group_index, uti, payload) VALUES (?1, 0, 'public.rtf', X'7B5C727466317D');",
            params![item_id],
        ).unwrap();

        let rep_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM item_representations WHERE item_id = ?1;",
                params![item_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(rep_count, 2, "Expected 2 representations inserted");

        // 4. Delete parent history item
        conn.execute("DELETE FROM history_items WHERE id = ?1;", params![item_id])
            .unwrap();

        // 5. Verify cascading delete wiped associated representations
        let remaining_reps: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM item_representations WHERE item_id = ?1;",
                params![item_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            remaining_reps, 0,
            "All representations must be deleted on parent deletion (CASCADE)"
        );

        verify_database_integrity(&conn).expect("Integrity check must pass after deletion");
    }

    #[test]
    fn test_fts5_virtual_table_sync_triggers() {
        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        let item_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

        // 1. Insert item into history_items
        conn.execute(
            "INSERT INTO history_items (id, first_copied_at_ms, last_copied_at_ms, copy_count, content_kind, title, search_text, content_hash, created_at_ms)
             VALUES (?1, 1000, 1000, 1, 'text', 'Banana Split Recipe', 'Delicious dessert with bananas and chocolate', X'000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F', 1000);",
            params![item_id],
        ).unwrap();

        // 2. Query FTS5 table
        let fts_matches: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH 'banana';",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            fts_matches, 1,
            "FTS5 index must find matching keyword 'banana'"
        );

        // 3. Update title/content
        conn.execute(
            "UPDATE history_items SET title = 'Strawberry Tart Recipe', search_text = 'Delicious dessert with fresh strawberries' WHERE id = ?1;",
            params![item_id],
        ).unwrap();

        // 4. Old term should not match, new term should match
        let old_matches: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH 'banana';",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            old_matches, 0,
            "Old keyword 'banana' must not match after update"
        );

        let new_matches: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH 'strawberries';",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            new_matches, 1,
            "New keyword 'strawberries' must match after update"
        );

        // 5. Delete row
        conn.execute("DELETE FROM history_items WHERE id = ?1;", params![item_id])
            .unwrap();

        // 6. Verify FTS5 table is empty
        let count_after_delete: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH 'strawberries';",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            count_after_delete, 0,
            "FTS5 table must have no matches after delete"
        );
    }
}

#[test]
fn test_ingest_new_item_and_duplicate_handling() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::item::HistoryItem;

    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    let rep =
        Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Unique Clip Payload".to_vec()).unwrap();
    let item = HistoryItem::new(vec![rep], Some("com.apple.Safari".to_string()), 1000).unwrap();
    let original_id = item.id;

    // 1. Ingest new item
    let outcome = ingest_clipboard_item(&mut conn, item, 200).unwrap();
    assert!(matches!(outcome, IngestOutcome::NewItem(_)));

    // 2. Ingest duplicate item with updated timestamp and different source
    let rep_dup =
        Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Unique Clip Payload".to_vec()).unwrap();
    let item_dup =
        HistoryItem::new(vec![rep_dup], Some("com.google.Chrome".to_string()), 2000).unwrap();

    let outcome_dup = ingest_clipboard_item(&mut conn, item_dup, 200).unwrap();
    match outcome_dup {
        IngestOutcome::DuplicateUpdated(updated) => {
            assert_eq!(updated.id, original_id, "Duplicate must retain original ID");
            assert_eq!(updated.first_copied_at_ms, 1000);
            assert_eq!(updated.last_copied_at_ms, 2000);
            assert_eq!(updated.copy_count, 2);
            assert_eq!(
                updated.source_bundle_id,
                Some("com.google.Chrome".to_string())
            );
        }
        IngestOutcome::NewItem(_) => panic!("Expected DuplicateUpdated outcome"),
    }

    verify_database_integrity(&conn).expect("Database integrity check must pass");
}

#[test]
fn test_ingest_duplicate_merges_rich_representations_and_upgrades_kind() {
    use crate::domain::content::{uti, ContentKind, Representation};
    use crate::domain::item::HistoryItem;

    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    // 1. Ingest plain text item (ContentKind::Text)
    let rep_plain =
        Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Meeting Summary".to_vec()).unwrap();
    let item1 = HistoryItem::new(
        vec![rep_plain],
        Some("com.apple.Terminal".to_string()),
        1000,
    )
    .unwrap();
    let original_id = item1.id;

    let outcome1 = ingest_clipboard_item(&mut conn, item1, 100).unwrap();
    assert!(matches!(outcome1, IngestOutcome::NewItem(_)));

    // 2. Recopy identical text with rich representations (HTML + RTF) from Notes/Safari
    let rep_plain2 =
        Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Meeting Summary".to_vec()).unwrap();
    let rep_html = Representation::new(0, uti::HTML, b"<b>Meeting Summary</b>".to_vec()).unwrap();
    let rep_rtf = Representation::new(0, uti::RTF, b"{\\rtf1 Meeting Summary}".to_vec()).unwrap();
    let item2 = HistoryItem::new(
        vec![rep_plain2, rep_html, rep_rtf],
        Some("com.apple.Notes".to_string()),
        2000,
    )
    .unwrap();

    let outcome2 = ingest_clipboard_item(&mut conn, item2, 100).unwrap();
    match outcome2 {
        IngestOutcome::DuplicateUpdated(updated) => {
            assert_eq!(updated.id, original_id);
            assert_eq!(updated.copy_count, 2);
            assert_eq!(
                updated.content_kind,
                ContentKind::RichText,
                "Kind must upgrade from Text to RichText"
            );
            assert_eq!(
                updated.representations.len(),
                3,
                "Merged item must contain all 3 representations"
            );
            assert_eq!(
                updated.source_bundle_id,
                Some("com.apple.Notes".to_string())
            );
        }
        IngestOutcome::NewItem(_) => panic!("Expected DuplicateUpdated"),
    }

    // 3. Recopy plain text only again (e.g. from Terminal) -> rich representations must NOT be lost
    let rep_plain3 =
        Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Meeting Summary".to_vec()).unwrap();
    let item3 = HistoryItem::new(
        vec![rep_plain3],
        Some("com.apple.Terminal".to_string()),
        3000,
    )
    .unwrap();

    let outcome3 = ingest_clipboard_item(&mut conn, item3, 100).unwrap();
    match outcome3 {
        IngestOutcome::DuplicateUpdated(updated) => {
            assert_eq!(updated.id, original_id);
            assert_eq!(updated.copy_count, 3);
            assert_eq!(
                updated.content_kind,
                ContentKind::RichText,
                "Kind must remain RichText"
            );
            assert_eq!(
                updated.representations.len(),
                3,
                "Rich representations must be preserved across plain recopy"
            );
        }
        IngestOutcome::NewItem(_) => panic!("Expected DuplicateUpdated"),
    }

    // 4. Verify in-database representations count
    let stored_reps = load_representations(&conn, &original_id).unwrap();
    assert_eq!(stored_reps.len(), 3);

    verify_database_integrity(&conn).expect("Database integrity check must pass");
}

#[test]
fn test_ingest_google_sheets_recopy_updates_html_representation() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::item::HistoryItem;

    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    let plain = b"Revenue\t$50,000".to_vec();
    let html_v1 = b"<google-sheets data-session=\"1\"><table><tr><td>$50,000</td></tr></table></google-sheets>".to_vec();
    let html_v2 = b"<google-sheets data-session=\"2\"><table><tr><td>$50,000</td></tr></table></google-sheets>".to_vec();

    let rep_p1 = Representation::new(0, uti::UTF8_PLAIN_TEXT, plain.clone()).unwrap();
    let rep_h1 = Representation::new(0, uti::HTML, html_v1).unwrap();
    let item1 = HistoryItem::new(
        vec![rep_p1, rep_h1],
        Some("com.google.Chrome".to_string()),
        1000,
    )
    .unwrap();
    let original_id = item1.id;

    let outcome1 = ingest_clipboard_item(&mut conn, item1, 100).unwrap();
    assert!(matches!(outcome1, IngestOutcome::NewItem(_)));

    let rep_p2 = Representation::new(0, uti::UTF8_PLAIN_TEXT, plain).unwrap();
    let rep_h2 = Representation::new(0, uti::HTML, html_v2.clone()).unwrap();
    let item2 = HistoryItem::new(
        vec![rep_p2, rep_h2],
        Some("com.google.Chrome".to_string()),
        2000,
    )
    .unwrap();

    let outcome2 = ingest_clipboard_item(&mut conn, item2, 100).unwrap();
    match outcome2 {
        IngestOutcome::DuplicateUpdated(updated) => {
            assert_eq!(updated.id, original_id);
            assert_eq!(updated.copy_count, 2);
            let html_rep = updated
                .representations
                .iter()
                .find(|r| r.uti == uti::HTML)
                .unwrap();
            assert_eq!(
                html_rep.payload, html_v2,
                "HTML payload must be updated to the latest copy"
            );
        }
        IngestOutcome::NewItem(_) => panic!("Expected DuplicateUpdated"),
    }

    verify_database_integrity(&conn).expect("Database integrity check must pass");
}

#[test]
fn test_retention_limit_and_pinned_protection() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::item::HistoryItem;

    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    // Capacity limit of 2 unpinned items
    let max_unpinned = 2;

    // Ingest item 1 (unpinned)
    let rep1 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Item 1".to_vec()).unwrap();
    let item1 = HistoryItem::new(vec![rep1], None, 1000).unwrap();
    let id1 = item1.id;
    ingest_clipboard_item(&mut conn, item1, max_unpinned).unwrap();

    // Ingest item 2 (pinned!)
    let rep2 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Item 2 (Pinned)".to_vec()).unwrap();
    let mut item2 = HistoryItem::new(vec![rep2], None, 2000).unwrap();
    item2.is_pinned = true;
    let id2 = item2.id;
    ingest_clipboard_item(&mut conn, item2, max_unpinned).unwrap();

    // Ingest item 3 (unpinned)
    let rep3 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Item 3".to_vec()).unwrap();
    let item3 = HistoryItem::new(vec![rep3], None, 3000).unwrap();
    let id3 = item3.id;
    ingest_clipboard_item(&mut conn, item3, max_unpinned).unwrap();

    // Ingest item 4 (unpinned) -> should evict item 1 (oldest unpinned)
    let rep4 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Item 4".to_vec()).unwrap();
    let item4 = HistoryItem::new(vec![rep4], None, 4000).unwrap();
    let id4 = item4.id;
    ingest_clipboard_item(&mut conn, item4, max_unpinned).unwrap();

    // Verification:
    // Item 1 was evicted
    assert!(
        find_by_id(&conn, &id1).unwrap().is_none(),
        "Oldest unpinned Item 1 must be evicted"
    );

    // Item 2 (pinned) was PRESERVED
    assert!(
        find_by_id(&conn, &id2).unwrap().is_some(),
        "Pinned Item 2 must never be evicted"
    );

    // Item 3 and Item 4 exist
    assert!(
        find_by_id(&conn, &id3).unwrap().is_some(),
        "Item 3 must exist"
    );
    assert!(
        find_by_id(&conn, &id4).unwrap().is_some(),
        "Item 4 must exist"
    );

    // Total count = 3 (1 pinned + 2 unpinned)
    let total_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM history_items;", [], |r| r.get(0))
        .unwrap();
    assert_eq!(total_count, 3);

    verify_database_integrity(&conn).expect("Database integrity check must pass");
}

#[test]
fn test_list_history_page_ordering_and_pins() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::item::HistoryItem;

    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    // 1. Insert unpinned item (older)
    let rep1 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Older Unpinned".to_vec()).unwrap();
    let item1 = HistoryItem::new(vec![rep1], None, 1000).unwrap();
    ingest_clipboard_item(&mut conn, item1, 200).unwrap();

    // 2. Insert unpinned item (newer)
    let rep2 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Newer Unpinned".to_vec()).unwrap();
    let item2 = HistoryItem::new(vec![rep2], None, 2000).unwrap();
    ingest_clipboard_item(&mut conn, item2, 200).unwrap();

    // 3. Insert pinned item (pin_order = 1)
    let rep3 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"First Pin".to_vec()).unwrap();
    let mut item3 = HistoryItem::new(vec![rep3], None, 1500).unwrap();
    item3.is_pinned = true;
    item3.pin_order = Some(1);
    item3.pin_key = Some("1".to_string());
    ingest_clipboard_item(&mut conn, item3, 200).unwrap();

    // 4. Query page
    let page = list_history_page(&conn, 10, 0).unwrap();
    assert_eq!(page.len(), 3);

    // Pinned item must come FIRST despite not having the latest timestamp
    assert_eq!(page[0].title, "First Pin");
    assert!(page[0].is_pinned);
    assert_eq!(page[0].pin_key, Some("1".to_string()));

    // Newer unpinned must come SECOND
    assert_eq!(page[1].title, "Newer Unpinned");
    assert!(!page[1].is_pinned);

    // Older unpinned must come THIRD
    assert_eq!(page[2].title, "Older Unpinned");
    assert!(!page[2].is_pinned);
}

#[test]
fn test_fetch_payload_and_available_utis() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::item::HistoryItem;

    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    let rep_text =
        Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Plain text payload".to_vec()).unwrap();
    let rep_rtf = Representation::new(0, uti::RTF, b"{\\rtf1 RTF payload}".to_vec()).unwrap();

    let item = HistoryItem::new(vec![rep_text, rep_rtf], None, 1000).unwrap();
    let item_id = item.id;
    ingest_clipboard_item(&mut conn, item, 200).unwrap();

    // Query available UTIs
    let utis = query_available_utis(&conn, &item_id).unwrap();
    assert_eq!(utis.len(), 2);
    assert!(utis.contains(&uti::UTF8_PLAIN_TEXT.to_string()));
    assert!(utis.contains(&uti::RTF.to_string()));

    // Fetch plain text payload
    let text_bytes = fetch_payload(&conn, &item_id, uti::UTF8_PLAIN_TEXT).unwrap();
    assert_eq!(text_bytes, Some(b"Plain text payload".to_vec()));

    // Fetch RTF payload
    let rtf_bytes = fetch_payload(&conn, &item_id, uti::RTF).unwrap();
    assert_eq!(rtf_bytes, Some(b"{\\rtf1 RTF payload}".to_vec()));

    // Fetch absent UTI returns None
    let png_bytes = fetch_payload(&conn, &item_id, uti::PNG).unwrap();
    assert_eq!(png_bytes, None);
}

#[test]
fn test_delete_and_clear_operations() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::item::HistoryItem;

    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    // Ingest 2 unpinned items and 1 pinned item
    let rep1 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Delete Me".to_vec()).unwrap();
    let item1 = HistoryItem::new(vec![rep1], None, 1000).unwrap();
    let id1 = item1.id;
    ingest_clipboard_item(&mut conn, item1, 200).unwrap();

    let rep2 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Unpinned 2".to_vec()).unwrap();
    let item2 = HistoryItem::new(vec![rep2], None, 2000).unwrap();
    ingest_clipboard_item(&mut conn, item2, 200).unwrap();

    let rep3 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Keep Pinned".to_vec()).unwrap();
    let mut item3 = HistoryItem::new(vec![rep3], None, 3000).unwrap();
    item3.is_pinned = true;
    let id3 = item3.id;
    ingest_clipboard_item(&mut conn, item3, 200).unwrap();

    // 1. Delete single item by ID
    let deleted = delete_item_by_id(&conn, &id1).unwrap();
    assert!(deleted, "Item 1 must be deleted");
    assert!(find_by_id(&conn, &id1).unwrap().is_none());

    // 2. Clear unpinned history
    let cleared = clear_unpinned_history(&conn).unwrap();
    assert_eq!(cleared, 1, "Expected 1 unpinned item cleared");

    // Pinned item remains intact
    assert!(
        find_by_id(&conn, &id3).unwrap().is_some(),
        "Pinned item must survive clear_unpinned"
    );

    // 3. Clear all history
    let cleared_all = clear_all_history(&conn).unwrap();
    assert_eq!(cleared_all, 1, "Expected pinned item cleared in clear_all");

    let stats = get_storage_stats(&conn, None).unwrap();
    assert_eq!(stats.total_items, 0);
    assert_eq!(stats.total_representations, 0);

    verify_database_integrity(&conn).expect("Integrity check must pass after clears");
}

#[test]
fn test_crash_safe_reopen_on_disk() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::item::HistoryItem;
    use tempfile::NamedTempFile;
    use uuid::Uuid;

    let temp_file = NamedTempFile::new().unwrap();
    let db_path = temp_file.path().to_path_buf();

    let item_id: Uuid;

    // Scope 1: Open, write items, pin an item, then close (drop connection)
    {
        let mut conn = open_database(&db_path, &DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        let rep = Representation::new(
            0,
            uti::UTF8_PLAIN_TEXT,
            b"Crash safe persistent data".to_vec(),
        )
        .unwrap();
        let mut item =
            HistoryItem::new(vec![rep], Some("com.apple.Terminal".to_string()), 1000).unwrap();
        item.is_pinned = true;
        item.pin_key = Some("p".to_string());
        item_id = item.id;

        ingest_clipboard_item(&mut conn, item, 200).unwrap();
        // Connection is cleanly dropped at the end of this block, closing DB
    }

    // Scope 2: Reopen the database from disk, verify persistence and schema
    {
        let mut conn = open_database(&db_path, &DatabaseConfig::default()).unwrap();
        let newly_applied = run_migrations(&mut conn).unwrap();
        assert!(
            newly_applied.is_empty(),
            "Migrations must be idempotent upon reopen"
        );

        // Verify integrity
        verify_database_integrity(&conn).expect("Database on disk must pass integrity check");

        // Verify item survived
        let item = find_by_id(&conn, &item_id)
            .unwrap()
            .expect("Item must exist after reopening database");
        assert_eq!(item.title, "Crash safe persistent data");
        assert!(item.is_pinned);
        assert_eq!(item.pin_key, Some("p".to_string()));
        assert_eq!(
            item.source_bundle_id,
            Some("com.apple.Terminal".to_string())
        );

        // Verify FTS5 query works across reopen
        let fts_matches: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH 'persistent';",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            fts_matches, 1,
            "FTS5 index must be fully searchable across restart"
        );

        let stats = get_storage_stats(&conn, Some(&db_path)).unwrap();
        assert_eq!(stats.total_items, 1);
        assert_eq!(stats.pinned_items, 1);
        assert!(
            stats.db_size_bytes > 0,
            "DB file size must be greater than 0"
        );
    }
}
