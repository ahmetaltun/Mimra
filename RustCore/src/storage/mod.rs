// ==============================================================================
// Mimra Core — Storage Module
// ==============================================================================

pub mod db;
pub mod migrations;

pub use db::{open_database, open_in_memory, DatabaseConfig};
pub use migrations::{run_migrations, verify_database_integrity, ALL_MIGRATIONS};

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
