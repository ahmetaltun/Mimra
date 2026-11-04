// ==============================================================================
// Mimra Core — Deterministic Fuzzy & Regex Search Engine
// Exact matching, bounded regex evaluation, word-boundary scoring, and highlights.
// Linked Features: F-019, F-048
// Test IDs: T-SRCH-01, T-SRCH-02, T-UI-03
// ==============================================================================

use crate::error::CoreError;

/// Maximum allowable pattern length for user regex queries to prevent pathological input.
pub const MAX_REGEX_PATTERN_LEN: usize = 256;

/// Search mode defining matching behavior across clipboard history.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum SearchMode {
    Fuzzy,
    Exact,
    Regex,
}

/// A contiguous slice of text to highlight in the UI.
/// Start and length are expressed in UTF-16 code units for direct AppKit/SwiftUI compatibility.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize, uniffi::Record,
)]
pub struct HighlightRangeDTO {
    pub start: u32,
    pub length: u32,
}

impl HighlightRangeDTO {
    pub fn new(start: u32, length: u32) -> Self {
        Self { start, length }
    }
}

/// Result of evaluating a match against a single string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FuzzyMatchResult {
    pub score: i64,
    pub highlights: Vec<HighlightRangeDTO>,
}

/// Internal representation of a target character with UTF-16 metrics, byte offsets, and boundary state.
#[derive(Debug, Clone, Copy)]
struct TargetChar {
    #[allow(dead_code)]
    c: char,
    lower: char,
    byte_offset: usize,
    byte_len: usize,
    utf16_offset: u32,
    utf16_len: u32,
    is_boundary: bool,
}

/// Preprocesses target text into characters annotated with UTF-16 and byte offsets, plus boundary markers.
fn prepare_target_chars(target: &str) -> Vec<TargetChar> {
    let mut chars = Vec::with_capacity(target.len());
    let mut current_utf16_offset: u32 = 0;
    let mut current_byte_offset: usize = 0;
    let mut prev_char: Option<char> = None;

    for c in target.chars() {
        let utf16_len = c.len_utf16() as u32;
        let byte_len = c.len_utf8();

        let is_boundary = match prev_char {
            None => true, // First character of string
            Some(p) => {
                p.is_whitespace()
                    || matches!(
                        p,
                        '_' | '-' | '/' | '\\' | '.' | ':' | '@' | '(' | '[' | '{' | '"' | '\''
                    )
                    || (p.is_lowercase() && c.is_uppercase()) // camelCase transition
            }
        };

        let lower = c.to_lowercase().next().unwrap_or(c);

        chars.push(TargetChar {
            c,
            lower,
            byte_offset: current_byte_offset,
            byte_len,
            utf16_offset: current_utf16_offset,
            utf16_len,
            is_boundary,
        });

        current_utf16_offset += utf16_len;
        current_byte_offset += byte_len;
        prev_char = Some(c);
    }

    chars
}

/// Converts a sorted set of matched character indices into compact contiguous highlight ranges.
fn consolidate_highlight_ranges(
    target_chars: &[TargetChar],
    matched_indices: &[usize],
) -> Vec<HighlightRangeDTO> {
    if matched_indices.is_empty() {
        return Vec::new();
    }

    let mut ranges: Vec<HighlightRangeDTO> = Vec::new();
    let mut current_start = target_chars[matched_indices[0]].utf16_offset;
    let mut current_length = target_chars[matched_indices[0]].utf16_len;
    let mut prev_index = matched_indices[0];

    for &idx in &matched_indices[1..] {
        if idx == prev_index + 1 {
            // Contiguous character match
            current_length += target_chars[idx].utf16_len;
        } else {
            // Break in continuity; flush current range
            ranges.push(HighlightRangeDTO::new(current_start, current_length));
            current_start = target_chars[idx].utf16_offset;
            current_length = target_chars[idx].utf16_len;
        }
        prev_index = idx;
    }

    ranges.push(HighlightRangeDTO::new(current_start, current_length));
    ranges
}

/// Evaluates fuzzy matching between `query` and `target`.
/// Returns `None` if the query cannot be matched.
pub fn fuzzy_match(query: &str, target: &str) -> Option<FuzzyMatchResult> {
    let trimmed_query = query.trim();
    if trimmed_query.is_empty() || target.is_empty() {
        return None;
    }

    let target_chars = prepare_target_chars(target);
    if target_chars.is_empty() {
        return None;
    }

    let query_chars: Vec<char> = trimmed_query
        .chars()
        .map(|c| c.to_lowercase().next().unwrap_or(c))
        .collect();

    // -------------------------------------------------------------------------
    // Phase 1: Check for Exact Substring Match (Highest priority)
    // -------------------------------------------------------------------------
    let target_lower: String = target_chars.iter().map(|tc| tc.lower).collect();
    let query_lower: String = query_chars.iter().collect();

    if let Some(pos) = target_lower.find(&query_lower) {
        let mut char_start_idx = 0;
        let mut byte_count = 0;
        for (i, tc) in target_chars.iter().enumerate() {
            if byte_count == pos {
                char_start_idx = i;
                break;
            }
            byte_count += tc.byte_len;
        }

        let match_char_count = query_chars.len();
        let matched_indices: Vec<usize> =
            (char_start_idx..char_start_idx + match_char_count).collect();

        let is_full_match = target_lower.len() == query_lower.len();
        let is_start = char_start_idx == 0;
        let is_boundary = target_chars[char_start_idx].is_boundary;

        let mut score: i64 = 2000;
        if is_full_match {
            score += 1500;
        } else if is_start {
            score += 800;
        } else if is_boundary {
            score += 500;
        }

        score += (match_char_count as i64) * 30;

        let highlights = consolidate_highlight_ranges(&target_chars, &matched_indices);
        return Some(FuzzyMatchResult { score, highlights });
    }

    // -------------------------------------------------------------------------
    // Phase 2: Ranked Subsequence Matching (Fuzzy / Acronyms)
    // -------------------------------------------------------------------------
    // Subsequence matching is strictly bounded to genuine word-boundary acronyms
    // or contiguous character runs. Accidental character gaps landing on internal
    // non-boundary letters are rejected to prevent false positives across unrelated text.
    let mut matched_indices: Vec<usize> = Vec::with_capacity(query_chars.len());
    let mut target_idx = 0;
    let mut score: i64 = 1000;
    let mut effective_q_idx = 0;

    for &qc in &query_chars {
        // Skip whitespace in query during acronym matching (e.g. 'v s c' -> 'vsc')
        if qc.is_whitespace() {
            continue;
        }

        let mut found = false;

        if effective_q_idx == 0 {
            // First character of the acronym/abbreviation MUST start on a word boundary
            while target_idx < target_chars.len() {
                if target_chars[target_idx].lower == qc && target_chars[target_idx].is_boundary {
                    matched_indices.push(target_idx);
                    score += 200;
                    target_idx += 1;
                    found = true;
                    break;
                }
                target_idx += 1;
            }
        } else {
            let prev_idx = matched_indices[effective_q_idx - 1];
            // Prefer contiguous continuation (e.g. 'co' in 'Code')
            if prev_idx + 1 < target_chars.len() && target_chars[prev_idx + 1].lower == qc {
                matched_indices.push(prev_idx + 1);
                score += 100;
                target_idx = prev_idx + 2;
                found = true;
            } else {
                // Non-contiguous jump: MUST land on a word boundary (e.g. 'S' in 'Studio')
                target_idx = prev_idx + 1;
                while target_idx < target_chars.len() {
                    if target_chars[target_idx].lower == qc && target_chars[target_idx].is_boundary
                    {
                        let gap = (target_idx - prev_idx - 1) as i64;
                        score += 150;
                        score -= (gap * 2).min(80);
                        matched_indices.push(target_idx);
                        target_idx += 1;
                        found = true;
                        break;
                    }
                    target_idx += 1;
                }
            }
        }

        if !found {
            return None;
        }
        effective_q_idx += 1;
    }

    if matched_indices.is_empty() {
        return None;
    }

    if let Some(&first_idx) = matched_indices.first() {
        let prefix_penalty = (first_idx as i64 * 5).min(200);
        score -= prefix_penalty;
    }

    let highlights = consolidate_highlight_ranges(&target_chars, &matched_indices);
    Some(FuzzyMatchResult { score, highlights })
}

/// Evaluates exact case-insensitive substring matching.
/// Rejects non-contiguous character matches (no subsequence skipping).
pub fn exact_match(query: &str, target: &str) -> Option<FuzzyMatchResult> {
    let trimmed = query.trim();
    if trimmed.is_empty() || target.is_empty() {
        return None;
    }

    let target_chars = prepare_target_chars(target);
    let target_lower: String = target_chars.iter().map(|tc| tc.lower).collect();
    let query_lower: String = trimmed
        .chars()
        .map(|c| c.to_lowercase().next().unwrap_or(c))
        .collect();

    let query_char_count = query_lower.chars().count();
    let mut matched_indices: Vec<usize> = Vec::new();
    let mut best_score: i64 = 0;

    let mut start_search_pos = 0;
    while let Some(pos) = target_lower[start_search_pos..].find(&query_lower) {
        let actual_byte_pos = start_search_pos + pos;
        let mut char_idx = 0;
        let mut byte_accum = 0;
        for (i, tc) in target_chars.iter().enumerate() {
            if byte_accum == actual_byte_pos {
                char_idx = i;
                break;
            }
            byte_accum += tc.byte_len;
        }

        for i in char_idx..char_idx + query_char_count {
            if i < target_chars.len() {
                matched_indices.push(i);
            }
        }

        let is_full = target_lower.len() == query_lower.len();
        let is_start = char_idx == 0;
        let is_boundary = target_chars[char_idx].is_boundary;

        let mut occurrence_score: i64 = 2500;
        if is_full {
            occurrence_score += 1500;
        } else if is_start {
            occurrence_score += 800;
        } else if is_boundary {
            occurrence_score += 500;
        }
        best_score = best_score.max(occurrence_score);

        start_search_pos = actual_byte_pos + query_lower.len();
        if start_search_pos >= target_lower.len() {
            break;
        }
    }

    if matched_indices.is_empty() {
        return None;
    }

    matched_indices.sort_unstable();
    matched_indices.dedup();

    let highlights = consolidate_highlight_ranges(&target_chars, &matched_indices);
    Some(FuzzyMatchResult {
        score: best_score,
        highlights,
    })
}

/// Compiles a regular expression with strict bounded resource limits.
/// Protects against runaway compilation and Denial-of-Service via linear-time DFA execution.
pub fn compile_bounded_regex(pattern: &str) -> Result<regex::Regex, CoreError> {
    let trimmed = pattern.trim();
    if trimmed.is_empty() {
        return Err(CoreError::InvalidRegex {
            pattern: pattern.to_string(),
            error_message: "Regular expression pattern cannot be empty".to_string(),
        });
    }

    if trimmed.chars().count() > MAX_REGEX_PATTERN_LEN {
        return Err(CoreError::InvalidRegex {
            pattern: pattern.to_string(),
            error_message: format!(
                "Pattern length exceeds maximum allowed limit of {MAX_REGEX_PATTERN_LEN} characters"
            ),
        });
    }

    regex::RegexBuilder::new(trimmed)
        .size_limit(64 * 1024)
        .dfa_size_limit(256 * 1024)
        .case_insensitive(true)
        .build()
        .map_err(|e| CoreError::InvalidRegex {
            pattern: pattern.to_string(),
            error_message: e.to_string(),
        })
}

/// Evaluates regular expression matching against target text.
/// Extracts UTF-16 highlight ranges safely aligned with matched character code units.
pub fn regex_match(re: &regex::Regex, target: &str) -> Option<FuzzyMatchResult> {
    if target.is_empty() {
        return None;
    }

    let target_chars = prepare_target_chars(target);
    let mut matched_indices: Vec<usize> = Vec::new();

    for m in re.find_iter(target) {
        let m_start = m.start();
        let m_end = m.end();
        for (idx, tc) in target_chars.iter().enumerate() {
            if tc.byte_offset >= m_start && tc.byte_offset < m_end {
                matched_indices.push(idx);
            }
        }
    }

    if matched_indices.is_empty() {
        return None;
    }

    matched_indices.sort_unstable();
    matched_indices.dedup();

    let mut score: i64 = 1500;
    if let Some(&first_idx) = matched_indices.first() {
        if first_idx == 0 {
            score += 800;
        } else if target_chars[first_idx].is_boundary {
            score += 400;
        }
    }
    score += (matched_indices.len() as i64) * 20;

    let highlights = consolidate_highlight_ranges(&target_chars, &matched_indices);
    Some(FuzzyMatchResult { score, highlights })
}

/// Calculates recency boost based on elapsed time since `last_copied_at_ms`.
pub fn calculate_recency_boost(last_copied_at_ms: i64, now_ms: i64) -> i64 {
    let elapsed_ms = (now_ms - last_copied_at_ms).max(0);
    let elapsed_mins = elapsed_ms / 60_000;

    if elapsed_mins < 5 {
        300
    } else if elapsed_mins < 60 {
        200
    } else if elapsed_mins < 1440 {
        100
    } else if elapsed_mins < 10080 {
        40
    } else {
        0
    }
}

/// Candidate metadata supplied for scoring.
#[derive(Debug, Clone, Copy)]
pub struct ScorableItem<'a> {
    pub title: &'a str,
    pub snippet: &'a str,
    pub last_copied_at_ms: i64,
    pub is_pinned: bool,
    pub pin_order: Option<u32>,
}

/// Evaluates an item across title and snippet under the requested SearchMode.
pub fn score_item_with_mode(
    query: &str,
    item: &ScorableItem<'_>,
    mode: SearchMode,
    compiled_regex: Option<&regex::Regex>,
    now_ms: i64,
) -> Option<(i64, Vec<HighlightRangeDTO>, Vec<HighlightRangeDTO>)> {
    let (title_match, snippet_match) = match mode {
        SearchMode::Fuzzy => (
            fuzzy_match(query, item.title),
            fuzzy_match(query, item.snippet),
        ),
        SearchMode::Exact => (
            exact_match(query, item.title),
            exact_match(query, item.snippet),
        ),
        SearchMode::Regex => match compiled_regex {
            Some(re) => (regex_match(re, item.title), regex_match(re, item.snippet)),
            None => (None, None),
        },
    };

    if title_match.is_none() && snippet_match.is_none() {
        return None;
    }

    let mut text_score: i64 = 0;
    let mut title_highlights = Vec::new();
    let mut snippet_highlights = Vec::new();

    if let Some(tm) = title_match {
        text_score += tm.score * 2;
        title_highlights = tm.highlights;
    }

    if let Some(sm) = snippet_match {
        text_score += sm.score;
        snippet_highlights = sm.highlights;
    }

    let recency_boost = calculate_recency_boost(item.last_copied_at_ms, now_ms);
    let mut total_score = text_score + recency_boost;

    if item.is_pinned {
        let pin_order_penalty = (item.pin_order.unwrap_or(999) as i64) * 10;
        total_score += 1_000_000 - pin_order_penalty;
    }

    Some((total_score, title_highlights, snippet_highlights))
}

/// Convenience wrapper evaluating an item under default Fuzzy mode.
pub fn score_item(
    query: &str,
    title: &str,
    snippet: &str,
    last_copied_at_ms: i64,
    now_ms: i64,
    is_pinned: bool,
    pin_order: Option<u32>,
) -> Option<(i64, Vec<HighlightRangeDTO>, Vec<HighlightRangeDTO>)> {
    let scorable = ScorableItem {
        title,
        snippet,
        last_copied_at_ms,
        is_pinned,
        pin_order,
    };
    score_item_with_mode(query, &scorable, SearchMode::Fuzzy, None, now_ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_exact_substring_match_and_boundary_bonus() {
        let res_exact = exact_match("rust", "rust").unwrap();
        assert!(res_exact.score > 3000);
        assert_eq!(res_exact.highlights, vec![HighlightRangeDTO::new(0, 4)]);

        let res_start = exact_match("rust", "rustacean").unwrap();
        assert_eq!(res_start.highlights, vec![HighlightRangeDTO::new(0, 4)]);

        let res_boundary = exact_match("code", "visual studio code").unwrap();
        assert_eq!(res_boundary.highlights, vec![HighlightRangeDTO::new(14, 4)]);

        // Exact match should reject subsequence matches
        assert_eq!(exact_match("vsc", "Visual Studio Code"), None);
    }

    #[test]
    fn test_regex_bounded_compilation_and_errors() {
        // Valid regex
        let re = compile_bounded_regex(r"^https?://[a-z.]+").expect("Valid regex should compile");
        let m = regex_match(&re, "https://mimra.app").expect("Should match url");
        assert_eq!(m.highlights, vec![HighlightRangeDTO::new(0, 17)]);

        // Invalid syntax: unclosed parenthesis
        let err = compile_bounded_regex(r"(unclosed").expect_err("Should fail on invalid syntax");
        match err {
            CoreError::InvalidRegex {
                pattern,
                error_message,
            } => {
                assert_eq!(pattern, "(unclosed");
                assert!(error_message.contains("unclosed"));
            }
            _ => panic!("Expected InvalidRegex error"),
        }

        // Giant regex exceeding length limit
        let giant_pattern = "a".repeat(300);
        let giant_err =
            compile_bounded_regex(&giant_pattern).expect_err("Should reject oversized regex");
        match giant_err {
            CoreError::InvalidRegex { error_message, .. } => {
                assert!(error_message.contains("Pattern length exceeds"));
            }
            _ => panic!("Expected InvalidRegex error"),
        }
    }

    #[test]
    fn test_regex_matching_and_utf16_ranges() {
        let re = compile_bounded_regex(r"\b[0-9]{3,4}\b").unwrap();
        let res = regex_match(&re, "Order #1234 was processed with pin 42 and port 8080").unwrap();
        // Should match 1234 and 8080 (not 42)
        assert_eq!(
            res.highlights,
            vec![
                HighlightRangeDTO::new(7, 4),  // 1234
                HighlightRangeDTO::new(47, 4), // 8080
            ]
        );
    }

    #[test]
    fn test_fuzzy_subsequence_acronym_matching() {
        let res = fuzzy_match("vsc", "Visual Studio Code").unwrap();
        assert_eq!(
            res.highlights,
            vec![
                HighlightRangeDTO::new(0, 1),
                HighlightRangeDTO::new(7, 1),
                HighlightRangeDTO::new(14, 1),
            ]
        );

        let res_gc = fuzzy_match("gc", "git commit").unwrap();
        assert_eq!(
            res_gc.highlights,
            vec![HighlightRangeDTO::new(0, 1), HighlightRangeDTO::new(4, 1)]
        );

        assert_eq!(fuzzy_match("xyz", "Visual Studio Code"), None);
    }

    #[test]
    fn test_recency_boost_tie_breaking() {
        let now_ms = 1_000_000;
        let copied_2_mins_ago = now_ms - (2 * 60 * 1000);
        let copied_2_days_ago = now_ms - (2 * 24 * 60 * 60 * 1000);

        let boost_recent = calculate_recency_boost(copied_2_mins_ago, now_ms);
        let boost_old = calculate_recency_boost(copied_2_days_ago, now_ms);

        assert_eq!(boost_recent, 300);
        assert_eq!(boost_old, 40);

        let score_recent = score_item(
            "clip",
            "My Clipboard Item",
            "",
            copied_2_mins_ago,
            now_ms,
            false,
            None,
        )
        .unwrap()
        .0;
        let score_old = score_item(
            "clip",
            "My Clipboard Item",
            "",
            copied_2_days_ago,
            now_ms,
            false,
            None,
        )
        .unwrap()
        .0;

        assert!(
            score_recent > score_old,
            "Item copied 2 minutes ago must rank higher than item copied 2 days ago"
        );
    }

    #[test]
    fn test_unicode_and_emoji_ranges() {
        let greek = fuzzy_match("αβγ", "Ελληνικά αβγ κείμενο").unwrap();
        assert_eq!(greek.highlights.len(), 1);
        assert_eq!(greek.highlights[0].length, 3);

        let cyrillic = fuzzy_match("привет", "Привет мир").unwrap();
        assert_eq!(cyrillic.highlights, vec![HighlightRangeDTO::new(0, 6)]);

        let cjk = fuzzy_match("検索", "日本語の検索テスト").unwrap();
        assert_eq!(cjk.highlights, vec![HighlightRangeDTO::new(4, 2)]);

        let text_with_emoji = "Launch 🚀 mission";
        let emoji_match = fuzzy_match("🚀", text_with_emoji).unwrap();
        assert_eq!(emoji_match.highlights, vec![HighlightRangeDTO::new(7, 2)]);
    }

    #[test]
    fn test_pinned_item_priority() {
        let now_ms = 1_000_000;
        let (pinned_score, _, _) =
            score_item("abc", "A big cat", "", 100, now_ms, true, Some(1)).unwrap();
        let (unpinned_score, _, _) =
            score_item("abc", "abc", "", now_ms, now_ms, false, None).unwrap();

        assert!(
            pinned_score > unpinned_score,
            "Pinned items must outrank unpinned items"
        );
    }
}
