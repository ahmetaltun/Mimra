// ==============================================================================
// Mimra Core — Storage Module
// ==============================================================================

pub mod db;
pub mod migrations;
pub mod recovery;
pub mod repository;
pub mod search;

pub use db::{open_database, open_in_memory, DatabaseConfig};
pub use migrations::{
    run_migrations, verify_database_integrity, ALL_MIGRATIONS, MAX_SUPPORTED_SCHEMA_VERSION,
};
pub use recovery::{
    attempt_salvage_corrupted_database, backup_database, open_database_resilient,
    quarantine_corrupted_database, restore_database_from_backup,
};
pub use repository::{
    clear_all_history, clear_unpinned_history, delete_item_by_id, enforce_retention_limit,
    enforce_retention_policy, fetch_payload, find_by_content_hash, find_by_id, get_storage_stats,
    ingest_clipboard_item, ingest_clipboard_item_with_policy, insert_item, list_history_page,
    list_history_page_with_options, load_representations, query_available_utis, set_pin_status,
    update_recopy, update_recopy_and_merge, HistoryItemSummary, IngestOutcome, StorageStats,
};
pub use search::{
    rebuild_search_index, sanitize_fts5_query, search_history_page,
    search_history_page_with_options, verify_search_index_integrity,
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
fn test_retention_policy_age_count_and_size_eviction() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::dto::RetentionPolicy;
    use crate::domain::item::HistoryItem;

    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    let now_ms = 1_700_000_000_000i64;
    let one_day_ms = 86_400_000i64;

    // 1. Pinned item (old, huge size: 10 KB)
    let rep_pin = Representation::new(0, uti::UTF8_PLAIN_TEXT, vec![b'P'; 10_000]).unwrap();
    let mut item_pin = HistoryItem::new(vec![rep_pin], None, now_ms - (40 * one_day_ms)).unwrap();
    item_pin.is_pinned = true;
    let pin_id = item_pin.id;
    ingest_clipboard_item(&mut conn, item_pin, 1000).unwrap();

    // 2. Unpinned item A: 45 days old (should be evicted by age when max_age_days = 30)
    let rep_a =
        Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Old unpinned item A".to_vec()).unwrap();
    let item_a = HistoryItem::new(vec![rep_a], None, now_ms - (45 * one_day_ms)).unwrap();
    let id_a = item_a.id;
    ingest_clipboard_item(&mut conn, item_a, 1000).unwrap();

    // 3. Unpinned item B: 10 days old, 5 KB payload
    let rep_b = Representation::new(0, uti::UTF8_PLAIN_TEXT, vec![b'B'; 5_000]).unwrap();
    let item_b = HistoryItem::new(vec![rep_b], None, now_ms - (10 * one_day_ms)).unwrap();
    let id_b = item_b.id;
    ingest_clipboard_item(&mut conn, item_b, 1000).unwrap();

    // 4. Unpinned item C: 5 days old, 5 KB payload
    let rep_c = Representation::new(0, uti::UTF8_PLAIN_TEXT, vec![b'C'; 5_000]).unwrap();
    let item_c = HistoryItem::new(vec![rep_c], None, now_ms - (5 * one_day_ms)).unwrap();
    let id_c = item_c.id;
    ingest_clipboard_item(&mut conn, item_c, 1000).unwrap();

    // 5. Unpinned item D: 1 day old, 5 KB payload
    let rep_d = Representation::new(0, uti::UTF8_PLAIN_TEXT, vec![b'D'; 5_000]).unwrap();
    let item_d = HistoryItem::new(vec![rep_d], None, now_ms - one_day_ms).unwrap();
    let id_d = item_d.id;
    ingest_clipboard_item(&mut conn, item_d, 1000).unwrap();

    // Currently: 1 pinned + 4 unpinned (A, B, C, D)
    let total_before: i64 = conn
        .query_row("SELECT COUNT(*) FROM history_items;", [], |r| r.get(0))
        .unwrap();
    assert_eq!(total_before, 5);

    // Apply policy: max_age_days = 30
    // Expected: Item A evicted (45 days old > 30 days). Pinned item (40 days old) PRESERVED!
    {
        let tx = conn.transaction().unwrap();
        let report = enforce_retention_policy(
            &tx,
            &RetentionPolicy {
                max_count: None,
                max_age_days: Some(30),
                max_size_bytes: None,
            },
            now_ms,
        )
        .unwrap();
        tx.commit().unwrap();

        assert_eq!(report.evicted_by_age, 1);
        assert_eq!(report.total_evicted, 1);
    }
    assert!(
        find_by_id(&conn, &id_a).unwrap().is_none(),
        "Item A must be evicted by age"
    );
    assert!(
        find_by_id(&conn, &pin_id).unwrap().is_some(),
        "Pinned item must survive age eviction"
    );

    // Apply policy: max_count = 2 (currently unpinned are B, C, D -> count is 3)
    // Expected: Oldest unpinned (B, 10 days old) evicted; C and D remain. Pinned item PRESERVED!
    {
        let tx = conn.transaction().unwrap();
        let report = enforce_retention_policy(
            &tx,
            &RetentionPolicy {
                max_count: Some(2),
                max_age_days: None,
                max_size_bytes: None,
            },
            now_ms,
        )
        .unwrap();
        tx.commit().unwrap();

        assert_eq!(report.evicted_by_count, 1);
        assert_eq!(report.total_evicted, 1);
    }
    assert!(
        find_by_id(&conn, &id_b).unwrap().is_none(),
        "Item B must be evicted by count"
    );
    assert!(
        find_by_id(&conn, &id_c).unwrap().is_some(),
        "Item C must remain"
    );
    assert!(
        find_by_id(&conn, &id_d).unwrap().is_some(),
        "Item D must remain"
    );
    assert!(
        find_by_id(&conn, &pin_id).unwrap().is_some(),
        "Pinned item must survive count eviction"
    );

    // Apply policy: max_size_bytes = 6_000 (currently unpinned are C (5KB) and D (5KB) -> total unpinned = 10KB)
    // Expected: Oldest unpinned (C) evicted to get unpinned total under 6KB; D remains. Pinned item (10KB) PRESERVED!
    {
        let tx = conn.transaction().unwrap();
        let report = enforce_retention_policy(
            &tx,
            &RetentionPolicy {
                max_count: None,
                max_age_days: None,
                max_size_bytes: Some(6_000),
            },
            now_ms,
        )
        .unwrap();
        tx.commit().unwrap();

        assert_eq!(report.evicted_by_size, 1);
        assert_eq!(report.total_evicted, 1);
    }
    assert!(
        find_by_id(&conn, &id_c).unwrap().is_none(),
        "Item C must be evicted by size budget"
    );
    assert!(
        find_by_id(&conn, &id_d).unwrap().is_some(),
        "Item D must remain"
    );
    assert!(
        find_by_id(&conn, &pin_id).unwrap().is_some(),
        "Pinned item must survive size eviction"
    );

    // Verify 100% foreign key and FTS integrity after evictions
    let fk_violations: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_foreign_key_check();",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(fk_violations, 0, "Zero foreign key violations allowed");
    crate::storage::search::verify_search_index_integrity(&conn)
        .expect("Search index integrity must pass");
}

#[test]
fn test_retention_50k_event_churn_and_zero_orphan_cleanup() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::dto::RetentionPolicy;
    use crate::domain::item::HistoryItem;
    use std::time::Instant;

    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    let start_time = Instant::now();
    let base_time_ms = 1_700_000_000_000i64;

    // 1. Pre-insert 10 pinned items that MUST survive all 50k churn cycles
    let mut pinned_ids = Vec::new();
    for p in 1..=10 {
        let payload = format!("Guaranteed Pinned Anchor Document #{p}").into_bytes();
        let rep = Representation::new(0, uti::UTF8_PLAIN_TEXT, payload).unwrap();
        let mut item = HistoryItem::new(
            vec![rep],
            Some("com.apple.Notes".to_string()),
            base_time_ms + p as i64,
        )
        .unwrap();
        item.is_pinned = true;
        item.pin_order = Some(p);
        item.pin_key = Some(p.to_string());
        pinned_ids.push(item.id);
        ingest_clipboard_item(&mut conn, item, 500).unwrap();
    }

    // Retention policy for churn: cap unpinned at 50 items and 80,000 bytes
    let churn_policy = RetentionPolicy {
        max_count: Some(50),
        max_age_days: Some(30),
        max_size_bytes: Some(80_000),
    };

    let total_events = 50_000;
    let batch_size = 500;
    let num_batches = total_events / batch_size;

    // Pre-create a pool of sample contents to induce recopy duplicates
    let sample_recopies = [
        "Common Recopy Alpha - Repeated Keystrokes"
            .as_bytes()
            .to_vec(),
        "Common Recopy Beta - Code Snippet Selection"
            .as_bytes()
            .to_vec(),
        "Common Recopy Gamma - StackOverflow Solution"
            .as_bytes()
            .to_vec(),
        "Common Recopy Delta - Terminal Shell One-liner"
            .as_bytes()
            .to_vec(),
    ];

    println!(
        "Starting 50k-event churn test across {num_batches} batches of {batch_size} events..."
    );

    for batch in 0..num_batches {
        let tx = conn.transaction().unwrap();

        for i in 0..batch_size {
            let event_index = batch * batch_size + i;
            let current_ts = base_time_ms + 10_000 + event_index as i64;

            if event_index % 5 == 0 {
                // 20% Recopy duplicates
                let sample_payload = &sample_recopies[event_index % sample_recopies.len()];
                let rep =
                    Representation::new(0, uti::UTF8_PLAIN_TEXT, sample_payload.clone()).unwrap();
                let item = HistoryItem::new(
                    vec![rep],
                    Some("com.apple.Terminal".to_string()),
                    current_ts,
                )
                .unwrap();

                // Duplicate update within transaction
                if let Some(mut existing) = find_by_content_hash(&tx, &item.content_hash).unwrap() {
                    update_recopy_and_merge(&tx, &mut existing, &item).unwrap();
                } else {
                    insert_item(&tx, &item).unwrap();
                }
            } else {
                // 80% Unique fresh items
                let payload =
                    format!("Unique item payload #{event_index} generated for 50k stress testing")
                        .into_bytes();
                let rep = Representation::new(0, uti::UTF8_PLAIN_TEXT, payload).unwrap();
                let item =
                    HistoryItem::new(vec![rep], Some("com.apple.Safari".to_string()), current_ts)
                        .unwrap();
                insert_item(&tx, &item).unwrap();
            }

            // Periodically enforce retention inside transaction (every 50 items)
            if i % 50 == 0 {
                enforce_retention_policy(&tx, &churn_policy, current_ts).unwrap();
            }
        }

        // Final retention sweep at end of batch
        let batch_end_ts = base_time_ms + 10_000 + ((batch + 1) * batch_size) as i64;
        enforce_retention_policy(&tx, &churn_policy, batch_end_ts).unwrap();

        tx.commit().unwrap();

        // Midway clear_unpinned test (at 25,000 events)
        if batch == num_batches / 2 {
            let cleared = clear_unpinned_history(&conn).unwrap();
            println!(
                "Midway clear_unpinned executed at event {}: cleared {} items",
                batch * batch_size,
                cleared
            );
        }
    }

    let elapsed = start_time.elapsed();
    println!("50k-event churn completed in {:?}", elapsed);

    // =========================================================================
    // Verification Phase (Definition of Done: P4-05)
    // =========================================================================

    // 1. Verify 100% of pinned items survived
    for pin_id in &pinned_ids {
        assert!(
            find_by_id(&conn, pin_id).unwrap().is_some(),
            "DoD VIOLATION: Pinned item {pin_id} was lost during 50k churn!"
        );
    }
    let pinned_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM history_items WHERE is_pinned = 1;",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(pinned_count, 10, "All 10 pinned items must exist");

    // 2. Verify unpinned count is bounded <= 50
    let unpinned_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM history_items WHERE is_pinned = 0;",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(
        unpinned_count <= 50,
        "Unpinned count ({unpinned_count}) must be bounded <= 50"
    );

    // 3. Verify unpinned byte size is bounded <= 80,000 bytes
    let unpinned_bytes: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(byte_size), 0) FROM history_items WHERE is_pinned = 0;",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(
        unpinned_bytes <= 80_000,
        "Unpinned bytes ({unpinned_bytes}) must be <= 80,000"
    );

    // 4. Verify 100% Foreign Key Integrity (Zero orphan representations)
    let fk_check_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_foreign_key_check();",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        fk_check_count, 0,
        "DoD VIOLATION: Foreign key violations detected!"
    );

    let orphan_reps: i64 = conn.query_row(
        "SELECT COUNT(*) FROM item_representations WHERE item_id NOT IN (SELECT id FROM history_items);",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(
        orphan_reps, 0,
        "DoD VIOLATION: Orphaned item_representations detected!"
    );

    // 5. Verify 100% FTS5 Index Integrity (Zero orphan FTS entries)
    crate::storage::search::verify_search_index_integrity(&conn)
        .expect("DoD VIOLATION: Search index integrity failed after 50k churn!");

    let orphan_fts: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM search_fts WHERE rowid NOT IN (SELECT rowid FROM history_items);",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        orphan_fts, 0,
        "DoD VIOLATION: Orphaned search_fts rows detected!"
    );

    // 6. Verify SQLite database integrity check
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
fn test_list_history_page_sorting_and_pin_arrangements() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::dto::{HistorySortMode, PinArrangement};
    use crate::domain::item::HistoryItem;

    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    // Item A: Copied at t=1000, 1 copy
    let rep_a = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Alpha item".to_vec()).unwrap();
    let item_a = HistoryItem::new(vec![rep_a], None, 1000).unwrap();
    ingest_clipboard_item(&mut conn, item_a, 200).unwrap();

    // Item B: Copied at t=2000, 5 copies
    let rep_b = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Beta item".to_vec()).unwrap();
    let mut item_b = HistoryItem::new(vec![rep_b], None, 2000).unwrap();
    item_b.copy_count = 5;
    ingest_clipboard_item(&mut conn, item_b, 200).unwrap();

    // Item C: Pinned item, copied at t=1500, 1 copy
    let rep_c = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Pinned item".to_vec()).unwrap();
    let mut item_c = HistoryItem::new(vec![rep_c], None, 1500).unwrap();
    item_c.is_pinned = true;
    item_c.pin_order = Some(1);
    ingest_clipboard_item(&mut conn, item_c, 200).unwrap();

    // 1. Top arrangement + Recency sort:
    // Pinned first, then Beta (2000), then Alpha (1000)
    let page_top =
        list_history_page_with_options(&conn, HistorySortMode::Recency, PinArrangement::Top, 10, 0)
            .unwrap();
    assert_eq!(page_top[0].title, "Pinned item");
    assert_eq!(page_top[1].title, "Beta item");
    assert_eq!(page_top[2].title, "Alpha item");

    // 2. Bottom arrangement + Recency sort:
    // Beta (2000) first, then Alpha (1000), then Pinned last
    let page_bottom = list_history_page_with_options(
        &conn,
        HistorySortMode::Recency,
        PinArrangement::Bottom,
        10,
        0,
    )
    .unwrap();
    assert_eq!(page_bottom[0].title, "Beta item");
    assert_eq!(page_bottom[1].title, "Alpha item");
    assert_eq!(page_bottom[2].title, "Pinned item");

    // 3. Inline arrangement + Recency sort:
    // Beta (2000) first, Pinned (1500) second, Alpha (1000) third
    let page_inline = list_history_page_with_options(
        &conn,
        HistorySortMode::Recency,
        PinArrangement::Inline,
        10,
        0,
    )
    .unwrap();
    assert_eq!(page_inline[0].title, "Beta item");
    assert_eq!(page_inline[1].title, "Pinned item");
    assert_eq!(page_inline[2].title, "Alpha item");

    // 4. CopyCount sort with Top arrangement:
    // Pinned first, then Beta (count=5), then Alpha (count=1)
    let page_count = list_history_page_with_options(
        &conn,
        HistorySortMode::CopyCount,
        PinArrangement::Top,
        10,
        0,
    )
    .unwrap();
    assert_eq!(page_count[0].title, "Pinned item");
    assert_eq!(page_count[1].title, "Beta item");
    assert_eq!(page_count[2].title, "Alpha item");
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

#[test]
fn test_corrupt_database_detection_and_quarantine_and_salvage() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::item::HistoryItem;
    use std::io::Write;

    let temp_dir = tempfile::tempdir().unwrap();
    let db_path = temp_dir.path().join("corrupt_test.sqlite");

    // 1. Create a valid database with items
    {
        let mut conn = open_database(&db_path, &DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        let rep = Representation::new(
            0,
            uti::UTF8_PLAIN_TEXT,
            b"Hello Salvageable Content".to_vec(),
        )
        .unwrap();
        let item = HistoryItem::new(
            vec![rep],
            Some("com.apple.Safari".to_string()),
            1_700_000_000_000,
        )
        .unwrap();

        ingest_clipboard_item(&mut conn, item, 200).unwrap();
        verify_database_integrity(&conn).unwrap();
    }

    // 2. Intentionally corrupt the database file
    {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .open(&db_path)
            .unwrap();
        // Corrupt page header at offset 16..48
        file.write_all(b"CORRUPTED_BYTES_HERE_1234567890").unwrap();
        file.sync_all().unwrap();
    }

    // 3. Open resiliently — must detect corruption, quarantine, and initialize fresh database
    let (mut conn, report) = open_database_resilient(&db_path, &DatabaseConfig::default()).unwrap();

    assert!(report.was_recovered, "Database must be marked as recovered");
    assert!(
        report.quarantined_backup_path.is_some(),
        "Quarantine backup path must be set"
    );

    let backup_path = report.quarantined_backup_path.unwrap();
    assert!(
        std::path::Path::new(&backup_path).exists(),
        "Quarantined backup file must exist on disk"
    );
    assert!(
        backup_path.contains(".corrupt."),
        "Backup path must contain '.corrupt.'"
    );

    // Fresh database must be valid and operational
    verify_database_integrity(&conn).expect("Recovered database must pass integrity check");

    // Insert new item into recovered database
    let rep2 =
        Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Post recovery payload".to_vec()).unwrap();
    let new_item = HistoryItem::new(
        vec![rep2],
        Some("com.apple.Terminal".to_string()),
        1_700_000_100_000,
    )
    .unwrap();
    ingest_clipboard_item(&mut conn, new_item, 200).unwrap();

    let page = list_history_page(&conn, 10, 0).unwrap();
    assert!(
        !page.is_empty(),
        "Recovered database must be fully writable and queryable"
    );
}

#[test]
fn test_completely_corrupted_file_quarantined_clean_init() {
    let temp_dir = tempfile::tempdir().unwrap();
    let db_path = temp_dir.path().join("garbage.sqlite");

    // Write completely invalid non-SQLite garbage
    std::fs::write(&db_path, b"THIS IS NOT A SQLITE DATABASE AT ALL").unwrap();

    let (conn, report) = open_database_resilient(&db_path, &DatabaseConfig::default()).unwrap();

    assert!(report.was_recovered);
    let backup_path = report.quarantined_backup_path.unwrap();
    let backup_contents = std::fs::read(&backup_path).unwrap();
    assert_eq!(
        backup_contents, b"THIS IS NOT A SQLITE DATABASE AT ALL",
        "Original bytes must be preserved in quarantine"
    );

    verify_database_integrity(&conn).unwrap();
}

#[test]
fn test_forward_schema_mismatch_fails_gracefully() {
    let temp_dir = tempfile::tempdir().unwrap();
    let db_path = temp_dir.path().join("future_schema.sqlite");

    {
        let mut conn = open_database(&db_path, &DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        // Insert simulated future schema version
        conn.execute(
            "INSERT INTO schema_migrations (version, applied_at_ms) VALUES (999, 12345);",
            [],
        )
        .unwrap();
    }

    // Opening resiliently must fail with SchemaMismatch, NOT quarantine
    let result = open_database_resilient(&db_path, &DatabaseConfig::default());
    match result {
        Err(crate::error::CoreError::SchemaMismatch { details }) => {
            assert!(
                details.contains("999"),
                "Error must mention future version 999: {details}"
            );
        }
        other => panic!("Expected SchemaMismatch error, got: {:?}", other),
    }

    // Ensure database was NOT quarantined
    assert!(
        db_path.exists(),
        "Target database must not be quarantined on schema mismatch"
    );
}

#[test]
fn test_backup_and_restore_cycle() {
    use crate::domain::content::{uti, Representation};
    use crate::domain::item::HistoryItem;

    let temp_dir = tempfile::tempdir().unwrap();
    let db_path = temp_dir.path().join("original.sqlite");
    let backup_path = temp_dir.path().join("backup.sqlite");

    let mut conn = open_database(&db_path, &DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    let rep1 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Item 1 payload".to_vec()).unwrap();
    let item1 = HistoryItem::new(
        vec![rep1],
        Some("com.apple.Safari".to_string()),
        1_700_000_000_000,
    )
    .unwrap();
    ingest_clipboard_item(&mut conn, item1, 200).unwrap();

    // 1. Create backup
    backup_database(&conn, &backup_path).expect("Backup must succeed");
    assert!(backup_path.exists(), "Backup file must exist on disk");

    // 2. Modify original database (insert another item)
    let rep2 = Representation::new(0, uti::UTF8_PLAIN_TEXT, b"Item 2 payload".to_vec()).unwrap();
    let item2 = HistoryItem::new(
        vec![rep2],
        Some("com.apple.Safari".to_string()),
        1_700_000_000_100,
    )
    .unwrap();
    ingest_clipboard_item(&mut conn, item2, 200).unwrap();
    assert_eq!(list_history_page(&conn, 10, 0).unwrap().len(), 2);
    drop(conn);

    // 3. Restore from backup to original path
    restore_database_from_backup(&backup_path, &db_path, &DatabaseConfig::default())
        .expect("Restore must succeed");

    // 4. Verify restored state matches backup (only item1 exists)
    let restored_conn = open_database(&db_path, &DatabaseConfig::default()).unwrap();
    verify_database_integrity(&restored_conn).unwrap();
    let items = list_history_page(&restored_conn, 10, 0).unwrap();
    assert_eq!(
        items.len(),
        1,
        "Restored database must only contain the items from backup"
    );
    assert_eq!(items[0].title, "Item 1 payload");
}

#[test]
fn test_transaction_kill_and_rollback_zero_orphan_records() {
    let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
    run_migrations(&mut conn).unwrap();

    // Simulate interrupted transaction
    {
        let tx = conn.transaction().unwrap();
        tx.execute(
            "INSERT INTO history_items (
                id, first_copied_at_ms, last_copied_at_ms, copy_count, source_bundle_id,
                content_kind, title, search_text, ocr_text, content_hash, is_pinned,
                pin_order, pin_key, byte_size, created_at_ms
            ) VALUES ('aborted-id', 1000, 1000, 1, 'com.apple.Finder', 'text', 'Aborted Title', 'Aborted Text', '', X'010203', 0, NULL, NULL, 50, 1000);",
            [],
        ).unwrap();
        // Transaction dropped without commit -> simulated process kill / failure
    }

    // Verify no orphan record remained
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM history_items WHERE id = 'aborted-id';",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 0, "Aborted transaction must leave zero rows");

    // Verify FTS5 and FK integrity pass
    verify_database_integrity(&conn).unwrap();
    verify_search_index_integrity(&conn).unwrap();
}
