// ==============================================================================
// Mimra Core — FTS5 Search Engine & Query Processor
// Safe query sanitization, token prefix expansion, BM25 ranking, and pagination.
// Linked Features: F-019, F-048
// Test IDs: T-SRCH-01, T-UI-03
// ==============================================================================

use crate::domain::search::{
    compile_bounded_regex, score_item_with_mode, HighlightRangeDTO, SearchMode,
};
use crate::error::CoreError;
use crate::storage::repository::{query_available_utis, HistoryItemSummary};
use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::str::FromStr;
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

/// Sanitizes user input into a safe SQLite FTS5 query string.
/// - Strips control characters and unsupported syntax punctuation.
/// - Escapes internal quotes by doubling them (`""`).
/// - Wraps each alphanumeric/word token in quotes with a prefix wildcard (`"token"*`).
/// - Returns `None` if the input contains no valid search tokens (e.g. empty or only punctuation).
pub fn sanitize_fts5_query(input: &str) -> Option<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }

    // Split input by whitespace and punctuation that should act as token delimiters,
    // while preserving alphanumeric characters and international Unicode letters/numbers.
    let mut tokens: Vec<String> = Vec::new();

    for raw_token in trimmed.split(|c: char| {
        c.is_whitespace()
            || matches!(
                c,
                '"' | '\''
                    | '*'
                    | '('
                    | ')'
                    | ':'
                    | '^'
                    | '{'
                    | '}'
                    | '['
                    | ']'
                    | '+'
                    | '-'
                    | '~'
                    | '/'
                    | '\\'
                    | '!'
                    | '?'
                    | ';'
                    | '<'
                    | '>'
                    | '='
                    | '|'
                    | '&'
            )
    }) {
        let cleaned: String = raw_token.chars().filter(|c| !c.is_control()).collect();
        if !cleaned.is_empty() {
            // Escape any existing quotes just in case
            let escaped = cleaned.replace('"', "\"\"");
            // Format as prefix token match: "escaped"*
            tokens.push(format!("\"{escaped}\"*"));
        }
    }

    if tokens.is_empty() {
        None
    } else {
        Some(tokens.join(" "))
    }
}

/// Maximum number of bytes scanned in content for regex and deep matching to prevent CPU stalls.
pub const MAX_CONTENT_SCAN_BYTES: usize = 64 * 1024; // 64 KB

/// Target character length for context preview snippets displayed in search results.
pub const SNIPPET_TARGET_CHARS: usize = 160;

/// Number of prefix context characters to show before a match in context preview snippets.
pub const SNIPPET_PREFIX_CHARS: usize = 35;

/// Extracts a context window of up to `target_chars` centered around `match_byte_offset` in `text`.
/// Safely avoids splitting UTF-8 characters and provides `prefix_chars` of preceding context.
pub fn extract_excerpt_around_byte(
    text: &str,
    match_byte_offset: usize,
    target_chars: usize,
    prefix_chars: usize,
) -> String {
    let char_count = text.chars().count();
    if char_count <= target_chars {
        return text.to_string();
    }

    let mut match_char_idx = 0;
    for (char_idx, (b_idx, _)) in text.char_indices().enumerate() {
        if b_idx <= match_byte_offset {
            match_char_idx = char_idx;
        } else {
            break;
        }
    }

    let start_char_idx = if match_char_idx + 20 <= target_chars {
        0
    } else {
        match_char_idx.saturating_sub(prefix_chars)
    };

    text.chars()
        .skip(start_char_idx)
        .take(target_chars)
        .collect()
}

/// Locates the byte offset of a match in `search_text` under the active `SearchMode`.
/// Bounds the scan to `MAX_CONTENT_SCAN_BYTES` to protect against pathological large payloads.
pub fn find_content_match_offset(
    search_text: &str,
    query: &str,
    mode: SearchMode,
    compiled_regex: Option<&regex::Regex>,
) -> Option<usize> {
    let trimmed_query = query.trim();
    if trimmed_query.is_empty() || search_text.is_empty() {
        return None;
    }

    // Take bounded scan slice up to a valid UTF-8 character boundary <= MAX_CONTENT_SCAN_BYTES
    let scan_slice = if search_text.len() > MAX_CONTENT_SCAN_BYTES {
        let mut end = MAX_CONTENT_SCAN_BYTES;
        while end > 0 && !search_text.is_char_boundary(end) {
            end -= 1;
        }
        &search_text[..end]
    } else {
        search_text
    };

    match mode {
        SearchMode::Regex => {
            if let Some(re) = compiled_regex {
                re.find(scan_slice).map(|m| m.start())
            } else {
                None
            }
        }
        SearchMode::Exact => {
            let query_lower = trimmed_query.to_lowercase();
            let scan_lower = scan_slice.to_lowercase();
            if let Some(pos) = scan_lower.find(&query_lower) {
                let mut byte_accum = 0;
                let mut original_byte_pos = 0;
                for (b_idx, c) in scan_slice.char_indices() {
                    if byte_accum >= pos {
                        original_byte_pos = b_idx;
                        break;
                    }
                    for lc in c.to_lowercase() {
                        byte_accum += lc.len_utf8();
                    }
                }
                Some(original_byte_pos)
            } else {
                None
            }
        }
        SearchMode::Fuzzy => {
            let query_lower = trimmed_query.to_lowercase();
            let scan_lower = scan_slice.to_lowercase();

            // 1. Literal substring match (highest priority in fuzzy match)
            if let Some(pos) = scan_lower.find(&query_lower) {
                let mut byte_accum = 0;
                let mut original_byte_pos = 0;
                for (b_idx, c) in scan_slice.char_indices() {
                    if byte_accum >= pos {
                        original_byte_pos = b_idx;
                        break;
                    }
                    for lc in c.to_lowercase() {
                        byte_accum += lc.len_utf8();
                    }
                }
                return Some(original_byte_pos);
            }

            // 2. Token-delimited substring match (matches individual tokens from FTS5 sanitization)
            for raw_token in trimmed_query.split(|c: char| {
                c.is_whitespace()
                    || matches!(
                        c,
                        '"' | '\''
                            | '*'
                            | '('
                            | ')'
                            | ':'
                            | '^'
                            | '{'
                            | '}'
                            | '['
                            | ']'
                            | '+'
                            | '-'
                            | '~'
                            | '/'
                            | '\\'
                            | '!'
                            | '?'
                            | ';'
                            | '<'
                            | '>'
                            | '='
                            | '|'
                            | '&'
                    )
            }) {
                let tok_cleaned: String = raw_token.chars().filter(|c| !c.is_control()).collect();
                if tok_cleaned.len() >= 2 {
                    let tok_lower = tok_cleaned.to_lowercase();
                    if let Some(pos) = scan_lower.find(&tok_lower) {
                        let mut byte_accum = 0;
                        let mut original_byte_pos = 0;
                        for (b_idx, c) in scan_slice.char_indices() {
                            if byte_accum >= pos {
                                original_byte_pos = b_idx;
                                break;
                            }
                            for lc in c.to_lowercase() {
                                byte_accum += lc.len_utf8();
                            }
                        }
                        return Some(original_byte_pos);
                    }
                }
            }

            None
        }
    }
}

/// Internal candidate structure retrieved from SQLite before fuzzy ranking and highlight extraction.
#[derive(Debug, Clone)]
struct RawCandidate {
    id_str: String,
    kind_str: String,
    title: String,
    search_text: String,
    snippet: String,
    ocr_text: String,
    is_pinned: bool,
    pin_order: Option<u32>,
    pin_key: Option<String>,
    source_bundle_id: Option<String>,
    first_copied_at_ms: i64,
    last_copied_at_ms: i64,
    copy_count: u32,
    byte_size: u64,
}

/// Executes a full-text & fuzzy hybrid search query across `history_items`.
/// - Leverages SQLite FTS5 index for fast candidate pre-filtering across large databases.
/// - Scans recent items to support non-prefix fuzzy acronyms (e.g. 'vsc' -> 'Visual Studio Code').
/// - Scores each candidate using the deterministic fuzzy ranker with word-boundary and recency boosts.
/// - Extracts exact UTF-16 highlight ranges for both `title` and `snippet`.
/// - Supports stable pagination via `limit` and `offset`.
pub fn search_history_page(
    conn: &Connection,
    query: &str,
    mode: SearchMode,
    limit: usize,
    offset: usize,
) -> Result<Vec<HistoryItemSummary>, CoreError> {
    search_history_page_with_options(
        conn,
        query,
        mode,
        true,
        crate::domain::dto::PinArrangement::Top,
        limit,
        offset,
    )
}

/// Paginated hybrid search with configurable relevance sorting and pinned item arrangement.
pub fn search_history_page_with_options(
    conn: &Connection,
    query: &str,
    mode: SearchMode,
    sort_by_relevance: bool,
    pin_arrangement: crate::domain::dto::PinArrangement,
    limit: usize,
    offset: usize,
) -> Result<Vec<HistoryItemSummary>, CoreError> {
    let trimmed_query = query.trim();
    if trimmed_query.is_empty() {
        return Ok(Vec::new());
    }

    // Precompile bounded regex if in Regex mode; returns typed CoreError::InvalidRegex on failure
    let compiled_regex = if mode == SearchMode::Regex {
        Some(compile_bounded_regex(trimmed_query)?)
    } else {
        None
    };

    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    let mut candidate_map: HashMap<String, RawCandidate> = HashMap::new();

    // 1. In Fuzzy or Exact mode, retrieve candidates via FTS5 index if sanitized tokens exist
    if mode != SearchMode::Regex {
        if let Some(sanitized_match) = sanitize_fts5_query(trimmed_query) {
            let mut stmt = conn.prepare(
                "SELECT h.id, h.content_kind, h.title, h.search_text, h.ocr_text, h.is_pinned, h.pin_order, h.pin_key,
                        h.source_bundle_id, h.first_copied_at_ms, h.last_copied_at_ms, h.copy_count, h.byte_size
                 FROM search_fts
                 JOIN history_items h ON h.rowid = search_fts.rowid
                 WHERE search_fts MATCH ?1
                 ORDER BY h.is_pinned DESC,
                          bm25(search_fts, 10.0, 1.0, 0.5) ASC,
                          h.last_copied_at_ms DESC
                 LIMIT 300;",
            )?;

            let rows = stmt.query_map(params![sanitized_match], |row| {
                let search_text: String = row.get(3)?;
                let ocr_text: String = row.get(4)?;
                let is_pinned_int: i64 = row.get(5)?;

                Ok(RawCandidate {
                    id_str: row.get(0)?,
                    kind_str: row.get(1)?,
                    title: row.get(2)?,
                    search_text,
                    snippet: String::new(),
                    ocr_text,
                    is_pinned: is_pinned_int != 0,
                    pin_order: row.get(6)?,
                    pin_key: row.get(7)?,
                    source_bundle_id: row.get(8)?,
                    first_copied_at_ms: row.get(9)?,
                    last_copied_at_ms: row.get(10)?,
                    copy_count: row.get(11)?,
                    byte_size: row.get(12)?,
                })
            })?;

            for r in rows {
                let cand = r?;
                candidate_map.insert(cand.id_str.clone(), cand);
            }
        }
    }

    // 2. Also retrieve recent history items to support acronyms, literal substrings, and regex scanning
    {
        let recent_limit = limit.max(if mode == SearchMode::Regex { 500 } else { 200 });
        let mut stmt = conn.prepare(
            "SELECT id, content_kind, title, search_text, ocr_text, is_pinned, pin_order, pin_key,
                    source_bundle_id, first_copied_at_ms, last_copied_at_ms, copy_count, byte_size
             FROM history_items
             ORDER BY is_pinned DESC, last_copied_at_ms DESC
             LIMIT ?1;",
        )?;

        let rows = stmt.query_map(params![recent_limit], |row| {
            let search_text: String = row.get(3)?;
            let ocr_text: String = row.get(4)?;
            let is_pinned_int: i64 = row.get(5)?;

            Ok(RawCandidate {
                id_str: row.get(0)?,
                kind_str: row.get(1)?,
                title: row.get(2)?,
                search_text,
                snippet: String::new(),
                ocr_text,
                is_pinned: is_pinned_int != 0,
                pin_order: row.get(6)?,
                pin_key: row.get(7)?,
                source_bundle_id: row.get(8)?,
                first_copied_at_ms: row.get(9)?,
                last_copied_at_ms: row.get(10)?,
                copy_count: row.get(11)?,
                byte_size: row.get(12)?,
            })
        })?;

        for r in rows {
            let cand = r?;
            candidate_map.entry(cand.id_str.clone()).or_insert(cand);
        }
    }

    // 3. Score every candidate with the configured search mode & extract highlights
    struct ScoredCandidate {
        candidate: RawCandidate,
        score: i64,
        title_highlights: Vec<HighlightRangeDTO>,
        snippet_highlights: Vec<HighlightRangeDTO>,
    }

    let mut scored_items: Vec<ScoredCandidate> = Vec::new();

    for (_, mut cand) in candidate_map {
        // 1. Evaluate match against title
        let title_scorable = crate::domain::search::ScorableItem {
            title: &cand.title,
            snippet: "",
            last_copied_at_ms: cand.last_copied_at_ms,
            is_pinned: cand.is_pinned,
            pin_order: cand.pin_order,
        };
        let title_match = score_item_with_mode(
            trimmed_query,
            &title_scorable,
            mode,
            compiled_regex.as_ref(),
            now_ms,
        );

        // 2. Evaluate match against search_text using context excerpt
        let content_match_offset = find_content_match_offset(
            &cand.search_text,
            trimmed_query,
            mode,
            compiled_regex.as_ref(),
        );

        let (content_snippet, content_match) = if let Some(offset) = content_match_offset {
            let excerpt = extract_excerpt_around_byte(
                &cand.search_text,
                offset,
                SNIPPET_TARGET_CHARS,
                SNIPPET_PREFIX_CHARS,
            );
            let excerpt_scorable = crate::domain::search::ScorableItem {
                title: "",
                snippet: &excerpt,
                last_copied_at_ms: cand.last_copied_at_ms,
                is_pinned: cand.is_pinned,
                pin_order: cand.pin_order,
            };
            let sc = score_item_with_mode(
                trimmed_query,
                &excerpt_scorable,
                mode,
                compiled_regex.as_ref(),
                now_ms,
            );
            (excerpt, sc)
        } else {
            let fallback_snippet = cand
                .search_text
                .chars()
                .take(SNIPPET_TARGET_CHARS)
                .collect();
            (fallback_snippet, None)
        };

        // 3. Evaluate match against OCR text (if present)
        let ocr_match_offset = if !cand.ocr_text.is_empty() {
            find_content_match_offset(&cand.ocr_text, trimmed_query, mode, compiled_regex.as_ref())
        } else {
            None
        };

        let (ocr_snippet, ocr_match) = if let Some(offset) = ocr_match_offset {
            let excerpt = extract_excerpt_around_byte(
                &cand.ocr_text,
                offset,
                SNIPPET_TARGET_CHARS,
                SNIPPET_PREFIX_CHARS,
            );
            let ocr_scorable = crate::domain::search::ScorableItem {
                title: "",
                snippet: &excerpt,
                last_copied_at_ms: cand.last_copied_at_ms,
                is_pinned: cand.is_pinned,
                pin_order: cand.pin_order,
            };
            let sc = score_item_with_mode(
                trimmed_query,
                &ocr_scorable,
                mode,
                compiled_regex.as_ref(),
                now_ms,
            );
            (excerpt, sc)
        } else if !cand.ocr_text.is_empty() {
            let fallback = cand.ocr_text.chars().take(SNIPPET_TARGET_CHARS).collect();
            (fallback, None)
        } else {
            (String::new(), None)
        };

        // If neither title, content, nor OCR text matched, discard candidate
        if title_match.is_none() && content_match.is_none() && ocr_match.is_none() {
            continue;
        }

        let mut final_score: i64 = 0;
        let mut final_title_hls = Vec::new();
        let mut final_snippet = content_snippet;
        let mut final_snippet_hls = Vec::new();

        if let Some((t_score, t_hls, _)) = title_match {
            final_score += t_score;
            final_title_hls = t_hls;
        }

        let has_content_match = content_match.is_some();
        if let Some((c_score, _, s_hls)) = content_match {
            final_score = final_score.max(c_score) + if final_score > 0 { 200 } else { 0 };
            final_snippet_hls = s_hls;
        }

        if let Some((o_score, _, o_hls)) = ocr_match {
            if !has_content_match || o_score > final_score {
                final_score = final_score.max(o_score);
                final_snippet = ocr_snippet;
                final_snippet_hls = o_hls;
            }
        }

        cand.snippet = final_snippet;

        scored_items.push(ScoredCandidate {
            candidate: cand,
            score: final_score,
            title_highlights: final_title_hls,
            snippet_highlights: final_snippet_hls,
        });
    }

    // 4. Sort by pinned priority (per pin_arrangement), then score/recency
    use crate::domain::dto::PinArrangement;

    scored_items.sort_by(|a, b| {
        let pin_cmp = match pin_arrangement {
            PinArrangement::Top => {
                b.candidate
                    .is_pinned
                    .cmp(&a.candidate.is_pinned)
                    .then_with(|| match (a.candidate.is_pinned, b.candidate.is_pinned) {
                        (true, true) => a
                            .candidate
                            .pin_order
                            .unwrap_or(999)
                            .cmp(&b.candidate.pin_order.unwrap_or(999)),
                        _ => std::cmp::Ordering::Equal,
                    })
            }
            PinArrangement::Bottom => {
                a.candidate
                    .is_pinned
                    .cmp(&b.candidate.is_pinned)
                    .then_with(|| match (a.candidate.is_pinned, b.candidate.is_pinned) {
                        (true, true) => a
                            .candidate
                            .pin_order
                            .unwrap_or(999)
                            .cmp(&b.candidate.pin_order.unwrap_or(999)),
                        _ => std::cmp::Ordering::Equal,
                    })
            }
            PinArrangement::Inline => std::cmp::Ordering::Equal,
        };

        pin_cmp.then_with(|| {
            if sort_by_relevance {
                b.score.cmp(&a.score).then_with(|| {
                    b.candidate
                        .last_copied_at_ms
                        .cmp(&a.candidate.last_copied_at_ms)
                })
            } else {
                b.candidate
                    .last_copied_at_ms
                    .cmp(&a.candidate.last_copied_at_ms)
                    .then_with(|| b.score.cmp(&a.score))
            }
        })
    });

    // 5. Apply pagination (offset & limit)
    let paginated_slice = scored_items.into_iter().skip(offset).take(limit);

    let mut summaries = Vec::new();
    for scored in paginated_slice {
        let cand = scored.candidate;
        let id = Uuid::parse_str(&cand.id_str).map_err(|e| CoreError::DatabaseError {
            details: format!("Corrupted UUID in history_items: {e}"),
        })?;

        let content_kind = crate::domain::content::ContentKind::from_str(&cand.kind_str)?;
        let available_utis = query_available_utis(conn, &id)?;

        summaries.push(HistoryItemSummary {
            id,
            content_kind,
            title: cand.title,
            snippet: cand.snippet,
            is_pinned: cand.is_pinned,
            pin_order: cand.pin_order,
            pin_key: cand.pin_key,
            source_bundle_id: cand.source_bundle_id,
            first_copied_at_ms: cand.first_copied_at_ms,
            last_copied_at_ms: cand.last_copied_at_ms,
            copy_count: cand.copy_count,
            byte_size: cand.byte_size,
            available_utis,
            title_highlights: scored.title_highlights,
            snippet_highlights: scored.snippet_highlights,
        });
    }

    Ok(summaries)
}

/// Validates that the FTS5 virtual index matches the underlying content table.
/// Executes the SQLite FTS5 integrity-check command.
pub fn verify_search_index_integrity(conn: &Connection) -> Result<(), CoreError> {
    // 1. Run FTS5 internal integrity check command
    conn.execute(
        "INSERT INTO search_fts(search_fts) VALUES('integrity-check');",
        [],
    )
    .map_err(|e| CoreError::DatabaseError {
        details: format!("FTS5 index integrity-check failed: {e}"),
    })?;

    // 2. Verify row counts match between history_items and search_fts
    let history_count: i64 =
        conn.query_row("SELECT COUNT(*) FROM history_items;", [], |r| r.get(0))?;
    let fts_count: i64 = conn.query_row("SELECT COUNT(*) FROM search_fts;", [], |r| r.get(0))?;

    if history_count != fts_count {
        return Err(CoreError::DatabaseError {
            details: format!(
                "FTS5 desync detected: history_items has {history_count} rows, search_fts has {fts_count} rows"
            ),
        });
    }

    Ok(())
}

/// Rebuilds the FTS5 virtual table index from the content table `history_items`.
pub fn rebuild_search_index(conn: &Connection) -> Result<(), CoreError> {
    conn.execute("INSERT INTO search_fts(search_fts) VALUES('rebuild');", [])
        .map_err(|e| CoreError::DatabaseError {
            details: format!("Failed to rebuild FTS5 index: {e}"),
        })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::content::Representation;
    use crate::domain::item::HistoryItem;
    use crate::storage::db::{open_in_memory, DatabaseConfig};
    use crate::storage::migrations::run_migrations;
    use crate::storage::repository::ingest_clipboard_item;
    use std::time::Instant;

    #[test]
    fn test_sanitize_fts5_query_cases() {
        // Normal words
        assert_eq!(
            sanitize_fts5_query("hello world"),
            Some("\"hello\"* \"world\"*".to_string())
        );

        // Punctuation and special FTS symbols
        assert_eq!(
            sanitize_fts5_query("foo:bar* (test) [baz]"),
            Some("\"foo\"* \"bar\"* \"test\"* \"baz\"*".to_string())
        );

        // Quotes and operators
        assert_eq!(
            sanitize_fts5_query("\"quoted text\" AND NOT"),
            Some("\"quoted\"* \"text\"* \"AND\"* \"NOT\"*".to_string())
        );

        // Unicode / CJK / Diacritics
        assert_eq!(
            sanitize_fts5_query("münchen 検索"),
            Some("\"münchen\"* \"検索\"*".to_string())
        );

        // Empty and punctuation only
        assert_eq!(sanitize_fts5_query(""), None);
        assert_eq!(sanitize_fts5_query("   "), None);
        assert_eq!(sanitize_fts5_query("***???:::"), None);
    }

    #[test]
    fn test_fts5_search_ranking_and_pinned_precedence() {
        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        // Item 1: match in snippet only, unpinned
        let item1 = HistoryItem::new(
            vec![Representation::new(
                0,
                "public.utf8-plain-text".to_string(),
                b"Some normal notes about rust programming language".to_vec(),
            )
            .unwrap()],
            Some("com.apple.Notes".to_string()),
            1000,
        )
        .unwrap();

        // Item 2: match in title (high BM25 weight), unpinned
        let item2 = HistoryItem::new(
            vec![Representation::new(
                0,
                "public.utf8-plain-text".to_string(),
                b"Rust Quickstart Guide".to_vec(),
            )
            .unwrap()],
            Some("com.apple.Safari".to_string()),
            2000,
        )
        .unwrap();

        ingest_clipboard_item(&mut conn, item1, 100).unwrap();
        ingest_clipboard_item(&mut conn, item2.clone(), 100).unwrap();

        // Search for 'Rust'
        let results = search_history_page(&conn, "Rust", SearchMode::Fuzzy, 10, 0).unwrap();
        assert_eq!(results.len(), 2, "Expected 2 matches for 'Rust'");
        // Title match (item 2) should rank higher than body match (item 1)
        assert_eq!(
            results[0].title, "Rust Quickstart Guide",
            "Title match should rank first due to higher BM25 weight"
        );

        // Pin item 1 and verify it jumps ahead of item 2 despite lower BM25 rank
        crate::storage::repository::set_pin_status(&conn, &results[1].id, true, None, Some(1))
            .unwrap();

        let pinned_results = search_history_page(&conn, "Rust", SearchMode::Fuzzy, 10, 0).unwrap();
        assert_eq!(pinned_results.len(), 2);
        assert!(pinned_results[0].is_pinned, "Pinned item must rank first");
        assert_eq!(pinned_results[0].id, results[1].id);

        // Exact mode test: "Rust Quick" matches item 2 only
        let exact_res = search_history_page(&conn, "Rust Quick", SearchMode::Exact, 10, 0).unwrap();
        assert_eq!(exact_res.len(), 1);
        assert_eq!(exact_res[0].id, item2.id);

        // Regex mode test: r"Rust\s+Quick.*" matches item 2
        let regex_res =
            search_history_page(&conn, r"Rust\s+Quick.*", SearchMode::Regex, 10, 0).unwrap();
        assert_eq!(regex_res.len(), 1);
        assert_eq!(regex_res[0].id, item2.id);

        // Regex mode with invalid syntax returns typed CoreError::InvalidRegex
        let regex_err =
            search_history_page(&conn, r"(unclosed", SearchMode::Regex, 10, 0).unwrap_err();
        match regex_err {
            CoreError::InvalidRegex { pattern, .. } => assert_eq!(pattern, "(unclosed"),
            _ => panic!("Expected InvalidRegex error"),
        }
    }

    #[test]
    fn test_search_10k_items_fixture_and_pagination() {
        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        println!("Populating 10,000 items fixture for T-SRCH-01...");
        let start_populate = Instant::now();

        // Insert 10k items inside a single transaction for speed
        {
            let tx = conn.transaction().unwrap();
            {
                let mut stmt = tx.prepare(
                    "INSERT INTO history_items (id, first_copied_at_ms, last_copied_at_ms, copy_count, content_kind, title, search_text, content_hash, is_pinned, byte_size, created_at_ms)
                     VALUES (?1, ?2, ?3, 1, 'text', ?4, ?5, ?6, 0, ?7, ?8);"
                ).unwrap();

                for i in 0..10_000 {
                    let id = Uuid::new_v4().to_string();
                    let title = if i == 42 {
                        "Target Special Alpha Item".to_string()
                    } else if i % 100 == 0 {
                        format!("Category Batch item number {i}")
                    } else {
                        format!("Standard item {i}")
                    };

                    let body = format!(
                        "Content payload snippet text for entry {i} containing data keyword"
                    );
                    let hash = blake3::hash(body.as_bytes()).as_bytes().to_vec();
                    let len = body.len() as i64;
                    let ts = 1_000_000 + i as i64;

                    stmt.execute(params![id, ts, ts, title, body, hash, len, ts])
                        .unwrap();
                }
            }
            tx.commit().unwrap();
        }

        let populate_duration = start_populate.elapsed();
        println!("Inserted 10,000 items in {:?}", populate_duration);

        // 1. Verify FTS5 index integrity across all 10k items
        verify_search_index_integrity(&conn)
            .expect("Search index integrity check must pass for 10k items");

        // 2. Query target item: must return in < 15ms
        let start_search = Instant::now();
        let target_matches =
            search_history_page(&conn, "Special Alpha", SearchMode::Fuzzy, 10, 0).unwrap();
        let search_duration = start_search.elapsed();

        println!("10k search query latency: {:?}", search_duration);
        assert_eq!(
            target_matches.len(),
            1,
            "Must match exactly the single target item"
        );
        assert_eq!(target_matches[0].title, "Target Special Alpha Item");
        // Allow reasonable margin in unoptimized debug profile during parallel multi-threaded test runs
        assert!(
            search_duration.as_millis() < 150,
            "Search query across 10k items must complete under 150ms in unoptimized debug test runner (actual: {:?})",
            search_duration
        );

        // 3. Test multi-match query and pagination stability
        // 'Batch' matches 100 items (i % 100 == 0)
        let page_0 = search_history_page(&conn, "Batch", SearchMode::Fuzzy, 20, 0).unwrap();
        let page_1 = search_history_page(&conn, "Batch", SearchMode::Fuzzy, 20, 20).unwrap();

        assert_eq!(page_0.len(), 20, "Page 0 should return 20 results");
        assert_eq!(page_1.len(), 20, "Page 1 should return 20 results");

        // Verify pages are disjoint (stable pagination)
        let page_0_ids: std::collections::HashSet<_> = page_0.iter().map(|item| item.id).collect();
        for item in &page_1 {
            assert!(
                !page_0_ids.contains(&item.id),
                "Page 1 item {} must not appear in Page 0",
                item.id
            );
        }

        // 4. Test rebuild_search_index
        rebuild_search_index(&conn).expect("Rebuild must succeed");
        verify_search_index_integrity(&conn).expect("Integrity check must pass after rebuild");

        let after_rebuild =
            search_history_page(&conn, "Special Alpha", SearchMode::Fuzzy, 10, 0).unwrap();
        assert_eq!(after_rebuild.len(), 1);
        assert_eq!(after_rebuild[0].title, "Target Special Alpha Item");
    }

    #[test]
    fn test_search_page_sorting_and_pin_arrangements() {
        use crate::domain::content::{uti, Representation};
        use crate::domain::dto::PinArrangement;
        use crate::domain::item::HistoryItem;
        use crate::storage::repository::ingest_clipboard_item;

        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        // 1. Item with exact title match but older timestamp (t=1000)
        let rep1 = Representation::new(
            0,
            uti::UTF8_PLAIN_TEXT,
            b"Terminal command reference".to_vec(),
        )
        .unwrap();
        let item1 = HistoryItem::new(vec![rep1], None, 1000).unwrap();
        ingest_clipboard_item(&mut conn, item1, 200).unwrap();

        // 2. Item with weaker match but newer timestamp (t=2000)
        let rep2 = Representation::new(
            0,
            uti::UTF8_PLAIN_TEXT,
            b"Setup guide with some Terminal tips".to_vec(),
        )
        .unwrap();
        let item2 = HistoryItem::new(vec![rep2], None, 2000).unwrap();
        ingest_clipboard_item(&mut conn, item2, 200).unwrap();

        // 3. Pinned item matching query (t=1500)
        let rep3 = Representation::new(
            0,
            uti::UTF8_PLAIN_TEXT,
            b"Pinned Terminal workflows".to_vec(),
        )
        .unwrap();
        let mut item3 = HistoryItem::new(vec![rep3], None, 1500).unwrap();
        item3.is_pinned = true;
        item3.pin_order = Some(1);
        ingest_clipboard_item(&mut conn, item3, 200).unwrap();

        // Query: "Terminal"

        // Case A: Top pin arrangement + Sort by relevance:
        // Pinned item first, then exact/stronger title match (rep1), then weaker match (rep2)
        let top_rel = search_history_page_with_options(
            &conn,
            "Terminal",
            SearchMode::Fuzzy,
            true,
            PinArrangement::Top,
            10,
            0,
        )
        .unwrap();
        assert_eq!(top_rel.len(), 3);
        assert_eq!(top_rel[0].title, "Pinned Terminal workflows");
        assert_eq!(top_rel[1].title, "Terminal command reference");
        assert_eq!(top_rel[2].title, "Setup guide with some Terminal tips");

        // Case B: Top pin arrangement + Sort by recency (sort_by_relevance = false):
        // Pinned item first, then newer item rep2 (t=2000), then older rep1 (t=1000)
        let top_rec = search_history_page_with_options(
            &conn,
            "Terminal",
            SearchMode::Fuzzy,
            false,
            PinArrangement::Top,
            10,
            0,
        )
        .unwrap();
        assert_eq!(top_rec.len(), 3);
        assert_eq!(top_rec[0].title, "Pinned Terminal workflows");
        assert_eq!(top_rec[1].title, "Setup guide with some Terminal tips");
        assert_eq!(top_rec[2].title, "Terminal command reference");

        // Case C: Bottom pin arrangement + Sort by relevance:
        // Unpinned ranked by relevance first (rep1, then rep2), Pinned item last
        let bottom_rel = search_history_page_with_options(
            &conn,
            "Terminal",
            SearchMode::Fuzzy,
            true,
            PinArrangement::Bottom,
            10,
            0,
        )
        .unwrap();
        assert_eq!(bottom_rel.len(), 3);
        assert_eq!(bottom_rel[0].title, "Terminal command reference");
        assert_eq!(bottom_rel[1].title, "Setup guide with some Terminal tips");
        assert_eq!(bottom_rel[2].title, "Pinned Terminal workflows");
    }

    #[test]
    fn test_ocr_text_update_and_search() {
        use crate::domain::content::{uti, Representation};
        use crate::domain::item::HistoryItem;
        use crate::storage::repository::{get_ocr_text, ingest_clipboard_item, update_ocr_text};

        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        // 1. Ingest an image item (PNG)
        let rep = Representation::new(
            0,
            uti::PNG,
            vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        )
        .unwrap();
        let item =
            HistoryItem::new(vec![rep], Some("com.apple.Preview".to_string()), 1000).unwrap();
        let item_id = item.id;
        ingest_clipboard_item(&mut conn, item, 100).unwrap();

        // Verify initial OCR text is empty
        let initial_ocr = get_ocr_text(&conn, &item_id).unwrap();
        assert_eq!(initial_ocr, Some("".to_string()));

        // Searching for multilingual terms before OCR returns empty
        let initial_search =
            search_history_page(&conn, "Bonjour", SearchMode::Fuzzy, 10, 0).unwrap();
        assert!(initial_search.is_empty());

        // 2. Update OCR text with bilingual content (English & French)
        let sample_ocr_text =
            "System Diagnostics: Error code 404\nBonjour le monde - Connexion réussie";
        let updated = update_ocr_text(&conn, &item_id, sample_ocr_text).unwrap();
        assert!(
            updated,
            "update_ocr_text must return true for existing item"
        );

        // Verify get_ocr_text reflects the updated text
        let fetched_ocr = get_ocr_text(&conn, &item_id).unwrap();
        assert_eq!(fetched_ocr, Some(sample_ocr_text.to_string()));

        // 3. Search for English term inside image
        let en_results =
            search_history_page(&conn, "Diagnostics", SearchMode::Fuzzy, 10, 0).unwrap();
        assert_eq!(en_results.len(), 1);
        assert_eq!(en_results[0].id, item_id);
        assert!(en_results[0].snippet.contains("System Diagnostics"));
        assert!(!en_results[0].snippet_highlights.is_empty());

        // 4. Search for French term inside image in Exact mode
        let fr_results = search_history_page(&conn, "Bonjour", SearchMode::Exact, 10, 0).unwrap();
        assert_eq!(fr_results.len(), 1);
        assert_eq!(fr_results[0].id, item_id);
        assert!(fr_results[0].snippet.contains("Bonjour"));

        // 5. Search using Regex mode
        let re_results =
            search_history_page(&conn, "Error.*404", SearchMode::Regex, 10, 0).unwrap();
        assert_eq!(re_results.len(), 1);
        assert_eq!(re_results[0].id, item_id);

        // 6. Update OCR text for non-existent UUID returns false
        let fake_id = uuid::Uuid::new_v4();
        let fake_updated = update_ocr_text(&conn, &fake_id, "Some text").unwrap();
        assert!(
            !fake_updated,
            "update_ocr_text must return false for non-existent item"
        );
        let fake_get = get_ocr_text(&conn, &fake_id).unwrap();
        assert_eq!(fake_get, None);

        // 7. Verify index integrity
        verify_search_index_integrity(&conn).expect("Index integrity must pass");
    }

    #[test]
    fn test_ocr_delete_and_clear_race_protection() {
        use crate::domain::content::{uti, Representation};
        use crate::domain::item::HistoryItem;
        use crate::storage::migrations::verify_database_integrity;
        use crate::storage::repository::{
            clear_all_history, clear_unpinned_history, delete_item_by_id, get_ocr_text,
            ingest_clipboard_item, set_pin_status, update_ocr_text,
        };

        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        // 1. Delete item while OCR pending (stale callback must never resurrect)
        let rep1 = Representation::new(0, uti::PNG, vec![0x89, 0x50, 0x4E, 0x47]).unwrap();
        let item1 =
            HistoryItem::new(vec![rep1], Some("com.apple.Preview".to_string()), 1000).unwrap();
        let item1_id = item1.id;
        ingest_clipboard_item(&mut conn, item1, 100).unwrap();

        // Delete item before OCR completes
        let deleted1 = delete_item_by_id(&conn, &item1_id).unwrap();
        assert!(deleted1, "Item must be successfully deleted");

        // Stale OCR callback arrives
        let updated1 = update_ocr_text(&conn, &item1_id, "Ghost Secret Text 12345").unwrap();
        assert!(
            !updated1,
            "update_ocr_text must return false for deleted item"
        );

        // Verify item was not resurrected in history_items or get_ocr_text
        let fetched_ocr1 = get_ocr_text(&conn, &item1_id).unwrap();
        assert_eq!(
            fetched_ocr1, None,
            "get_ocr_text must return None for deleted item"
        );

        // Verify FTS5 search cannot find ghost text
        let search_ghost = search_history_page(&conn, "Ghost", SearchMode::Fuzzy, 10, 0).unwrap();
        assert!(
            search_ghost.is_empty(),
            "Search must never find text from stale OCR callback on deleted item"
        );

        // 2. Clear unpinned history while OCR pending
        let rep2 = Representation::new(0, uti::PNG, vec![0x89, 0x50, 0x4E, 0x47]).unwrap();
        let item2 =
            HistoryItem::new(vec![rep2], Some("com.apple.Preview".to_string()), 2000).unwrap();
        let item2_id = item2.id;
        ingest_clipboard_item(&mut conn, item2, 100).unwrap();

        let cleared_count = clear_unpinned_history(&conn).unwrap();
        assert_eq!(cleared_count, 1, "Must clear 1 unpinned item");

        // Stale OCR callback arrives after clear_unpinned
        let updated2 = update_ocr_text(&conn, &item2_id, "Unpinned Cleared Text 67890").unwrap();
        assert!(
            !updated2,
            "update_ocr_text must return false after clear_unpinned"
        );

        let search_unpinned =
            search_history_page(&conn, "Cleared", SearchMode::Exact, 10, 0).unwrap();
        assert!(
            search_unpinned.is_empty(),
            "Search must never find text from cleared unpinned items"
        );

        // 3. Clear all history while OCR pending
        let rep3 = Representation::new(0, uti::PNG, vec![0x89, 0x50, 0x4E, 0x47]).unwrap();
        let item3 =
            HistoryItem::new(vec![rep3], Some("com.apple.Preview".to_string()), 3000).unwrap();
        let item3_id = item3.id;
        ingest_clipboard_item(&mut conn, item3, 100).unwrap();
        set_pin_status(&conn, &item3_id, true, Some("1".to_string()), None).unwrap();

        let cleared_all = clear_all_history(&conn).unwrap();
        assert_eq!(cleared_all, 1, "Must clear all history including pinned");

        let updated3 = update_ocr_text(&conn, &item3_id, "Pinned Cleared Text 11223").unwrap();
        assert!(
            !updated3,
            "update_ocr_text must return false after clear_all"
        );

        // 4. Stress test: 1,000 rapid changes, deletes, clears, and stale OCR callbacks
        let mut active_ids = Vec::new();
        let mut deleted_ids = Vec::new();

        for i in 0..1000 {
            match i % 5 {
                0 => {
                    // Ingest image item
                    let rep = Representation::new(
                        0,
                        uti::PNG,
                        vec![0x89, 0x50, 0x4E, 0x47, (i & 0xFF) as u8],
                    )
                    .unwrap();
                    let item = HistoryItem::new(
                        vec![rep],
                        Some("com.apple.Preview".to_string()),
                        1000 + i as i64,
                    )
                    .unwrap();
                    let id = item.id;
                    ingest_clipboard_item(&mut conn, item, 500).unwrap();
                    active_ids.push(id);
                }
                1 => {
                    // Delete an item if available
                    if let Some(id) = active_ids.pop() {
                        let ok = delete_item_by_id(&conn, &id).unwrap();
                        assert!(ok);
                        deleted_ids.push(id);
                    }
                }
                2 => {
                    // Stale OCR callback to a deleted item
                    if let Some(id) = deleted_ids.last() {
                        let res = update_ocr_text(&conn, id, "Stale OCR stress text").unwrap();
                        assert!(!res, "Stale OCR callback must not succeed on deleted ID");
                    }
                }
                3 => {
                    // Legitimate OCR callback to an active item
                    if let Some(id) = active_ids.last() {
                        let res = update_ocr_text(&conn, id, "Valid OCR stress text").unwrap();
                        assert!(res, "OCR callback must succeed on active ID");
                    }
                }
                4 => {
                    // Periodic clear_unpinned every 100 steps
                    if i % 100 == 4 {
                        let _ = clear_unpinned_history(&conn).unwrap();
                        active_ids.clear();
                    }
                }
                _ => unreachable!(),
            }
        }

        // 5. Final integrity assertions
        verify_database_integrity(&conn).expect("Database PRAGMA integrity check must pass");
        verify_search_index_integrity(&conn).expect("Search index integrity must pass");

        // Verify zero orphaned representations
        let orphaned_reps: usize = conn
            .query_row(
                "SELECT COUNT(*) FROM item_representations WHERE item_id NOT IN (SELECT id FROM history_items);",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            orphaned_reps, 0,
            "There must be zero orphaned representations"
        );
    }

    #[test]
    fn test_search_8000_chars_arm64() {
        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        let mut text = String::new();
        for i in 0..1000 {
            text.push_str("some words here ");
            if i == 500 {
                text.push_str("target keyword arm64 is located here ");
            }
        }
        let rep = Representation::new(
            0,
            crate::domain::uti::UTF8_PLAIN_TEXT.to_string(),
            text.as_bytes().to_vec(),
        )
        .unwrap();
        let item = HistoryItem::new(vec![rep], None, 1000).unwrap();
        ingest_clipboard_item(&mut conn, item, 100).unwrap();

        let res = search_history_page(&conn, "arm64", SearchMode::Fuzzy, 10, 0).unwrap();
        println!("Fuzzy res: {:?}", res.len());
        assert_eq!(res.len(), 1);

        let res_exact = search_history_page(&conn, "arm64", SearchMode::Exact, 10, 0).unwrap();
        println!("Exact res: {:?}", res_exact.len());
        assert_eq!(res_exact.len(), 1);

        let res_regex = search_history_page(&conn, "arm64", SearchMode::Regex, 10, 0).unwrap();
        println!("Regex res: {:?}", res_regex.len());
        assert_eq!(res_regex.len(), 1);
    }

    #[test]
    fn test_search_deep_json_content_across_all_modes() {
        let mut conn = open_in_memory(&DatabaseConfig::default()).unwrap();
        run_migrations(&mut conn).unwrap();

        // Multi-line JSON with target keyword at line 20 (character offset ~450, well past 160 chars)
        let json_body = r#"{
  "service": "authentication-gateway",
  "version": "2.4.1",
  "status": "operational",
  "config": {
    "rate_limiting": {
      "requests_per_minute": 600,
      "burst": 50
    },
    "security": {
      "tls_version": "1.3",
      "hsts": true,
      "jwt": {
        "issuer": "https://auth.mimra.internal",
        "algorithm": "ES256",
        "secret_token": "mimra_ultra_secure_pass_99",
        "rotation_days": 30
      }
    }
  }
}"#;

        let rep = Representation::new(
            0,
            crate::domain::uti::UTF8_PLAIN_TEXT.to_string(),
            json_body.as_bytes().to_vec(),
        )
        .unwrap();
        let item =
            HistoryItem::new(vec![rep], Some("com.apple.Terminal".to_string()), 5000).unwrap();
        let item_id = item.id;
        ingest_clipboard_item(&mut conn, item, 100).unwrap();

        // 1. Fuzzy mode test on deep keyword
        let fuzzy_res =
            search_history_page(&conn, "mimra_ultra", SearchMode::Fuzzy, 10, 0).unwrap();
        assert_eq!(fuzzy_res.len(), 1, "Fuzzy mode must find deep JSON keyword");
        assert_eq!(fuzzy_res[0].id, item_id);
        assert!(
            fuzzy_res[0].snippet.contains("mimra_ultra_secure_pass_99"),
            "Snippet must contain context excerpt with matching keyword, got: '{}'",
            fuzzy_res[0].snippet
        );
        assert!(
            !fuzzy_res[0].snippet_highlights.is_empty(),
            "Snippet highlights must not be empty for content match"
        );

        // 2. Exact mode test on deep keyword
        let exact_res =
            search_history_page(&conn, "secret_token", SearchMode::Exact, 10, 0).unwrap();
        assert_eq!(exact_res.len(), 1, "Exact mode must find deep JSON keyword");
        assert_eq!(exact_res[0].id, item_id);
        assert!(
            exact_res[0].snippet.contains("secret_token"),
            "Snippet must contain context excerpt with matching keyword, got: '{}'",
            exact_res[0].snippet
        );
        assert!(!exact_res[0].snippet_highlights.is_empty());

        // 3. Regex mode test on deep keyword
        let regex_res =
            search_history_page(&conn, r#"mimra_ultra_[a-z0-9_]+"#, SearchMode::Regex, 10, 0)
                .unwrap();
        assert_eq!(regex_res.len(), 1, "Regex mode must find deep JSON keyword");
        assert_eq!(regex_res[0].id, item_id);
        assert!(
            regex_res[0].snippet.contains("mimra_ultra_secure_pass_99"),
            "Snippet must contain context excerpt with matching regex pattern, got: '{}'",
            regex_res[0].snippet
        );
        assert!(!regex_res[0].snippet_highlights.is_empty());

        // 4. Negative test: non-existent keyword
        let not_found =
            search_history_page(&conn, "nonexistent_token_404", SearchMode::Fuzzy, 10, 0).unwrap();
        assert!(
            not_found.is_empty(),
            "Non-existent keyword must return 0 results"
        );

        let not_found_regex =
            search_history_page(&conn, r#"missing_[0-9]{5}"#, SearchMode::Regex, 10, 0).unwrap();
        assert!(not_found_regex.is_empty());
    }

    #[test]
    fn test_search_rejects_unrelated_items_in_fuzzy_mode() {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::storage::migrations::run_migrations(&mut conn).unwrap();

        // 1. Ingest pinned unrelated item
        let rep_pin = Representation::new(
            0,
            crate::domain::uti::UTF8_PLAIN_TEXT.to_string(),
            b"AWS production access key: AKIAIOSFODNN7EXAMPLE\nRegion: us-west-2".to_vec(),
        )
        .unwrap();
        let mut item_pin =
            HistoryItem::new(vec![rep_pin], Some("com.apple.Terminal".to_string()), 1000).unwrap();
        item_pin.is_pinned = true;
        item_pin.pin_order = Some(1);
        ingest_clipboard_item(&mut conn, item_pin, 100).unwrap();

        // 2. Ingest recent unrelated item (Git status)
        let rep_git = Representation::new(
            0,
            crate::domain::uti::UTF8_PLAIN_TEXT.to_string(),
            b"git status --porcelain\n M src/lib.rs\n?? tests/new_test.rs".to_vec(),
        )
        .unwrap();
        let item_git =
            HistoryItem::new(vec![rep_git], Some("com.apple.Terminal".to_string()), 2000).unwrap();
        ingest_clipboard_item(&mut conn, item_git, 100).unwrap();

        // 3. Ingest recent unrelated item (URL with numbers and letters)
        let rep_url = Representation::new(
            0,
            crate::domain::uti::UTF8_PLAIN_TEXT.to_string(),
            b"https://apple.com/macbook-pro-14-and-16-m3-max/specs/".to_vec(),
        )
        .unwrap();
        let item_url =
            HistoryItem::new(vec![rep_url], Some("com.apple.Safari".to_string()), 3000).unwrap();
        ingest_clipboard_item(&mut conn, item_url, 100).unwrap();

        // 4. Ingest target item with arm64
        let rep_target = Representation::new(
            0,
            crate::domain::uti::UTF8_PLAIN_TEXT.to_string(),
            b"Build artifact completed for target arm64-apple-darwin release binary.".to_vec(),
        )
        .unwrap();
        let item_target = HistoryItem::new(
            vec![rep_target],
            Some("com.apple.Terminal".to_string()),
            4000,
        )
        .unwrap();
        let target_id = item_target.id;
        ingest_clipboard_item(&mut conn, item_target, 100).unwrap();

        // Search for "arm" in Fuzzy mode
        let results = search_history_page(&conn, "arm", SearchMode::Fuzzy, 10, 0).unwrap();

        println!("Results for 'arm': {} items", results.len());
        for res in &results {
            println!(
                "  - id: {}, title: '{}', snippet: '{}'",
                res.id, res.title, res.snippet
            );
        }

        assert_eq!(
            results.len(),
            1,
            "Search for 'arm' must return ONLY the 1 matching item, but found {} items!",
            results.len()
        );
        assert_eq!(results[0].id, target_id);
    }
}
