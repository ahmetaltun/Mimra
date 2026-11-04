// ==============================================================================
// Mimra Core — History Item Domain Model
// Represents a persistent, deduplicated clipboard entry with representations.
// ==============================================================================

use crate::domain::color::HexColor;
use crate::domain::content::{ContentKind, Representation};
use crate::domain::url_utils::CanonicalUrl;
use crate::error::CoreError;
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

/// Maximum character length for an auto-derived item title.
pub const MAX_TITLE_CHARS: usize = 120;

/// Represents a single history item in the Mimra clipboard history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryItem {
    /// Unique, stable identifier for this item.
    pub id: Uuid,
    /// Classification of the item's primary payload.
    pub content_kind: ContentKind,
    /// Brief descriptive label shown in UI list rows.
    pub title: String,
    /// Normalized text indexed for full-text search.
    pub search_text: String,
    /// Optional OCR text extracted from images via on-device Vision.
    pub ocr_text: String,
    /// BLAKE3 256-bit cryptographic digest of normalized representations for deduplication.
    pub content_hash: [u8; 32],
    /// Bundle identifier of the source application where this item was copied (if known).
    pub source_bundle_id: Option<String>,
    /// Whether this item is pinned to the top of the history list.
    pub is_pinned: bool,
    /// Explicit ordering index for pinned items.
    pub pin_order: Option<u32>,
    /// Single-character shortcut key assigned to this pin (e.g. "a", "1", ";").
    pub pin_key: Option<String>,
    /// Milliseconds since UNIX epoch when this content was first copied.
    pub first_copied_at_ms: i64,
    /// Milliseconds since UNIX epoch when this content was most recently copied.
    pub last_copied_at_ms: i64,
    /// Number of times this identical content has been copied.
    pub copy_count: u32,
    /// Total aggregate size in bytes across all representations.
    pub byte_size: u64,
    /// Milliseconds since UNIX epoch when this record was created.
    pub created_at_ms: i64,
    /// Multi-representation payload data.
    pub representations: Vec<Representation>,
}

impl HistoryItem {
    /// Constructs a new `HistoryItem` from raw representations and metadata.
    ///
    /// # Invariants Enforced:
    /// - Rejects empty representations (`CoreError::InvalidInput`).
    /// - Computes deterministic BLAKE3 `content_hash` over sorted representations.
    /// - Normalizes text fields to Unicode Normalization Form C (NFC).
    /// - Automatically derives `content_kind`, `title`, and `search_text`.
    pub fn new(
        representations: Vec<Representation>,
        source_bundle_id: Option<String>,
        timestamp_ms: i64,
    ) -> Result<Self, CoreError> {
        if representations.is_empty() {
            return Err(CoreError::InvalidInput {
                details: "Cannot create a history item with zero representations.".to_string(),
            });
        }

        // Calculate total byte size and verify representations
        let byte_size: u64 = representations.iter().map(|r| r.payload.len() as u64).sum();

        // Calculate deterministic BLAKE3 content hash
        let content_hash = Self::calculate_content_hash(&representations);

        // Derive content kind, title, and search text
        let content_kind = Self::derive_content_kind(&representations);
        let (title, search_text) = Self::derive_text_fields(&representations, content_kind);

        Ok(Self {
            id: Uuid::new_v4(),
            content_kind,
            title,
            search_text,
            ocr_text: String::new(),
            content_hash,
            source_bundle_id: source_bundle_id.map(|s| s.trim().to_string()),
            is_pinned: false,
            pin_order: None,
            pin_key: None,
            first_copied_at_ms: timestamp_ms,
            last_copied_at_ms: timestamp_ms,
            copy_count: 1,
            byte_size,
            created_at_ms: timestamp_ms,
            representations,
        })
    }

    /// Computes a deterministic BLAKE3 digest for deduplication across complex applications.
    ///
    /// Deduplication Strategy (F-012, T-CAP-05):
    /// - For file references (`public.file-url`):
    ///   - Strips scheme, percent-decodes paths, trims trailing slashes, NFC-normalizes,
    ///     and sorts canonical paths lexicographically. This ensures file selection order
    ///     does not produce duplicate entries.
    /// - For items with `public.url`:
    ///   - Canonicalizes the URL (scheme/host lowercased, default ports 80/443 removed,
    ///     slashes collapsed) and hashes the canonical URL string.
    /// - For items with plain text:
    ///   - If content is a web URL, hashes the canonical URL.
    ///   - If content is a hex color code, hashes the normalized `#RRGGBB(AA)`.
    ///   - Otherwise, normalizes line breaks (\r\n -> \n), trims trailing whitespace per line
    ///     and outer whitespace, NFC-normalizes, and hashes the canonical text.
    ///     This prevents ephemeral HTML session IDs (Sheets/Excel), RTF fonttbl variations (Notes),
    ///     and editor trailing newline differences (VS Code) from creating duplicate entries.
    /// - For rich text without plain text (HTML or RTF):
    ///   - Extracts plain text from HTML/RTF and hashes the canonical extracted text if non-empty.
    /// - For images (PNG, TIFF, JPEG, HEIC):
    ///   - Hashes the primary image representation payload.
    /// - Fallback:
    ///   - Hashes sorted representations.
    pub fn calculate_content_hash(reps: &[Representation]) -> [u8; 32] {
        let mut hasher = blake3::Hasher::new();

        // 1. File references
        let file_reps: Vec<&Representation> = reps.iter().filter(|r| r.is_file_url()).collect();
        if !file_reps.is_empty() {
            let mut canonical_paths: Vec<String> = file_reps
                .iter()
                .map(|r| {
                    let raw = String::from_utf8_lossy(&r.payload);
                    Self::canonicalize_file_url(&raw)
                })
                .collect();
            canonical_paths.sort();
            canonical_paths.dedup();

            hasher.update(b"FILES:\n");
            for path in &canonical_paths {
                hasher.update(&(path.len() as u32).to_be_bytes());
                hasher.update(path.as_bytes());
                hasher.update(b"\n");
            }
            return *hasher.finalize().as_bytes();
        }

        // 2. Check for public.url representation (Safari / Chrome links)
        if let Some(url_rep) = reps
            .iter()
            .find(|r| r.uti == crate::domain::content::uti::URL)
        {
            let raw_url = String::from_utf8_lossy(&url_rep.payload);
            let trimmed = raw_url.trim();
            if let Ok(canonical) = CanonicalUrl::parse(trimmed) {
                let clean_url = canonical.normalized_url.trim_end_matches('/');
                hasher.update(b"URL:\n");
                hasher.update(clean_url.as_bytes());
                return *hasher.finalize().as_bytes();
            }
        }

        // 3. Plain text representation
        if let Some(text_rep) = reps.iter().find(|r| r.is_plain_text()) {
            let raw_text = String::from_utf8_lossy(&text_rep.payload);
            let canonical_text = Self::canonicalize_text(&raw_text);

            if !canonical_text.is_empty() {
                // 3a. Check if text is a web URL
                if let Ok(canonical) = CanonicalUrl::parse(&canonical_text) {
                    let clean_url = canonical.normalized_url.trim_end_matches('/');
                    hasher.update(b"URL:\n");
                    hasher.update(clean_url.as_bytes());
                    return *hasher.finalize().as_bytes();
                }

                // 3b. Check if text is a Hex color code
                if let Some(hex_color) = HexColor::parse(&canonical_text) {
                    hasher.update(b"COLOR:\n");
                    hasher.update(hex_color.to_hex_string().as_bytes());
                    return *hasher.finalize().as_bytes();
                }

                // 3c. Canonical plain text
                hasher.update(b"TEXT:\n");
                hasher.update(canonical_text.as_bytes());
                return *hasher.finalize().as_bytes();
            }
        }

        // 4. Rich text fallback when plain text is absent (HTML or RTF)
        if let Some(html_rep) = reps
            .iter()
            .find(|r| r.uti == crate::domain::content::uti::HTML)
        {
            let raw_html = String::from_utf8_lossy(&html_rep.payload);
            let extracted = Self::extract_text_from_html(&raw_html);
            let canonical_extracted = Self::canonicalize_text(&extracted);
            if !canonical_extracted.is_empty() {
                hasher.update(b"TEXT:\n");
                hasher.update(canonical_extracted.as_bytes());
                return *hasher.finalize().as_bytes();
            }
        }

        if let Some(rtf_rep) = reps.iter().find(|r| {
            r.uti == crate::domain::content::uti::RTF || r.uti == crate::domain::content::uti::RTFD
        }) {
            let raw_rtf = String::from_utf8_lossy(&rtf_rep.payload);
            let extracted = Self::extract_text_from_rtf(&raw_rtf);
            let canonical_extracted = Self::canonicalize_text(&extracted);
            if !canonical_extracted.is_empty() {
                hasher.update(b"TEXT:\n");
                hasher.update(canonical_extracted.as_bytes());
                return *hasher.finalize().as_bytes();
            }
        }

        // 5. Images (PNG, TIFF, JPEG, HEIC)
        if let Some(img_rep) = reps.iter().find(|r| r.is_image()) {
            hasher.update(b"IMAGE:\n");
            hasher.update(&(img_rep.uti.len() as u32).to_be_bytes());
            hasher.update(img_rep.uti.as_bytes());
            hasher.update(&(img_rep.payload.len() as u64).to_be_bytes());
            hasher.update(&img_rep.payload);
            return *hasher.finalize().as_bytes();
        }

        // 6. Generic fallback: sorted representations
        let mut sorted: Vec<&Representation> = reps.iter().collect();
        sorted.sort_by(|a, b| {
            a.group_index
                .cmp(&b.group_index)
                .then_with(|| a.uti.cmp(&b.uti))
        });

        hasher.update(b"GENERIC:\n");
        for rep in sorted {
            hasher.update(&rep.group_index.to_be_bytes());
            hasher.update(&(rep.uti.len() as u32).to_be_bytes());
            hasher.update(rep.uti.as_bytes());
            hasher.update(&(rep.payload.len() as u64).to_be_bytes());
            hasher.update(&rep.payload);
        }

        *hasher.finalize().as_bytes()
    }

    /// Returns the hex string representation of the 32-byte content hash.
    pub fn content_hash_hex(&self) -> String {
        blake3::Hash::from(self.content_hash).to_hex().to_string()
    }

    /// Updates this item when an identical content copy is observed (recopy / deduplication).
    pub fn record_recopy(&mut self, timestamp_ms: i64, source_bundle_id: Option<String>) {
        self.last_copied_at_ms = timestamp_ms;
        self.copy_count = self.copy_count.saturating_add(1);
        if let Some(new_source) = source_bundle_id {
            let trimmed = new_source.trim().to_string();
            if !trimmed.is_empty() {
                self.source_bundle_id = Some(trimmed);
            }
        }
    }

    /// Helper to classify content kind from representations.
    pub(crate) fn derive_content_kind(reps: &[Representation]) -> ContentKind {
        let _has_text = reps.iter().any(|r| r.is_plain_text());
        let has_rich = reps.iter().any(|r| r.is_rich_text());
        let has_image = reps.iter().any(|r| r.is_image());
        let has_file = reps.iter().any(|r| r.is_file_url());

        if has_file {
            if reps.iter().all(|r| r.is_file_url() || r.is_plain_text()) {
                ContentKind::FileUrls
            } else {
                ContentKind::Mixed
            }
        } else if has_image {
            // Check if this copy consists of multiple separate pasteboard items across distinct groups.
            let mut groups: Vec<u32> = reps.iter().map(|r| r.group_index).collect();
            groups.sort_unstable();
            groups.dedup();

            if groups.len() > 1 {
                ContentKind::Mixed
            } else {
                // Single-item copy containing an image (e.g. from browser "Copy Image", Screenshot, Preview, Figma).
                // Browsers commonly attach helper flavors such as HTML (<img src="...">) or URL/plain-text.
                // The primary payload is the image.
                ContentKind::Image
            }
        } else if has_rich {
            ContentKind::RichText
        } else {
            ContentKind::Text
        }
    }

    /// Helper to derive title and search text from representations.
    pub(crate) fn derive_text_fields(
        reps: &[Representation],
        kind: ContentKind,
    ) -> (String, String) {
        // 1. Check for file URLs first if classified as FileUrls (P3-03)
        if kind == ContentKind::FileUrls {
            let file_urls: Vec<String> = reps
                .iter()
                .filter(|r| r.is_file_url())
                .map(|r| {
                    let raw = String::from_utf8_lossy(&r.payload).trim().to_string();
                    raw.nfc().collect()
                })
                .collect();

            if !file_urls.is_empty() {
                let title = if file_urls.len() == 1 {
                    let cleaned = file_urls[0].trim_end_matches('/');
                    let decoded = Self::percent_decode_str(cleaned);
                    let basename = decoded
                        .split('/')
                        .next_back()
                        .unwrap_or(&file_urls[0])
                        .to_string();
                    if basename.is_empty() {
                        "File Reference".to_string()
                    } else {
                        basename
                    }
                } else {
                    format!("{} files", file_urls.len())
                };
                let search_text = file_urls.join("\n");
                return (title, search_text);
            }
        }

        // 2. Check for images if classified as Image (P3-02)
        if kind == ContentKind::Image {
            if let Some(img_rep) = reps.iter().find(|r| r.is_image()) {
                let format_name = match img_rep.uti.as_str() {
                    crate::domain::content::uti::PNG => "PNG Image",
                    crate::domain::content::uti::TIFF => "TIFF Image",
                    crate::domain::content::uti::JPEG => "JPEG Image",
                    crate::domain::content::uti::HEIC => "HEIC Image",
                    _ => "Image",
                };
                let size_str = Self::format_byte_size(img_rep.payload.len() as u64);
                let title = format!("{format_name} ({size_str})");

                let mut search_tokens = vec![format_name.to_string(), size_str];
                if let Some(url_rep) = reps
                    .iter()
                    .find(|r| r.uti == crate::domain::content::uti::URL)
                {
                    let raw_url = String::from_utf8_lossy(&url_rep.payload).trim().to_string();
                    if !raw_url.is_empty() {
                        search_tokens.push(raw_url);
                    }
                }
                let search_text = search_tokens.join(" ");
                return (title, search_text);
            }
            return ("Image".to_string(), String::new());
        }

        // 3. Check for public.url representation (P3-04)
        if let Some(url_rep) = reps
            .iter()
            .find(|r| r.uti == crate::domain::content::uti::URL)
        {
            let raw_url = String::from_utf8_lossy(&url_rep.payload).trim().to_string();
            if let Ok(canonical) = CanonicalUrl::parse(&raw_url) {
                let page_title = reps
                    .iter()
                    .find(|r| {
                        r.uti == crate::domain::content::uti::URL_NAME || r.uti == "public.url-name"
                    })
                    .and_then(|r| {
                        let t = String::from_utf8_lossy(&r.payload).trim().to_string();
                        if t.is_empty() {
                            None
                        } else {
                            Some(t)
                        }
                    });
                let title = page_title.unwrap_or_else(|| canonical.normalized_url.clone());
                let search_text = format!(
                    "{}\n{}\n{}",
                    canonical.normalized_url, canonical.domain, canonical.host
                );
                return (title, search_text);
            }
        }

        // 3. Check for plain text representation
        if let Some(text_rep) = reps.iter().find(|r| r.is_plain_text()) {
            let raw_text = String::from_utf8_lossy(&text_rep.payload);
            let nfc_text: String = raw_text.nfc().collect();
            let trimmed = nfc_text.trim();

            if !trimmed.is_empty() {
                // 3a. Check if plain text is a valid web URL (F-006, T-TYPE-04)
                if let Ok(canonical) = CanonicalUrl::parse(trimmed) {
                    let page_title = reps
                        .iter()
                        .find(|r| {
                            r.uti == crate::domain::content::uti::URL_NAME
                                || r.uti == "public.url-name"
                        })
                        .and_then(|r| {
                            let t = String::from_utf8_lossy(&r.payload).trim().to_string();
                            if t.is_empty() {
                                None
                            } else {
                                Some(t)
                            }
                        });
                    let title = page_title.unwrap_or_else(|| canonical.normalized_url.clone());
                    let search_text = format!(
                        "{}\n{}\n{}",
                        canonical.normalized_url, canonical.domain, canonical.host
                    );
                    return (title, search_text);
                }

                // 3b. Check if plain text is a valid Hex color code (F-037, T-TYPE-06)
                if let Some(hex_color) = HexColor::parse(trimmed) {
                    let hex_clean = hex_color.to_hex_string();
                    let raw_stripped = trimmed
                        .trim_start_matches('#')
                        .trim_start_matches("0x")
                        .trim_start_matches("0X");
                    let search_text = format!("{trimmed}\n{hex_clean}\n{raw_stripped}");
                    return (trimmed.to_string(), search_text);
                }

                // 3c. Regular plain text
                let first_line = trimmed.lines().next().unwrap_or("").trim();
                let title: String = first_line.chars().take(MAX_TITLE_CHARS).collect();
                return (title, trimmed.to_string());
            }
        }

        // 3. Check for rich text representations (HTML or RTF) if plain text was absent
        if kind == ContentKind::RichText {
            if let Some(html_rep) = reps
                .iter()
                .find(|r| r.uti == crate::domain::content::uti::HTML)
            {
                let raw_html = String::from_utf8_lossy(&html_rep.payload);
                let extracted = Self::extract_text_from_html(&raw_html);
                let trimmed = extracted.trim();
                if !trimmed.is_empty() {
                    let first_line = trimmed.lines().next().unwrap_or("").trim();
                    let title: String = first_line.chars().take(MAX_TITLE_CHARS).collect();
                    return (title, trimmed.to_string());
                }
            }

            if let Some(rtf_rep) = reps.iter().find(|r| {
                r.uti == crate::domain::content::uti::RTF
                    || r.uti == crate::domain::content::uti::RTFD
            }) {
                let raw_rtf = String::from_utf8_lossy(&rtf_rep.payload);
                let extracted = Self::extract_text_from_rtf(&raw_rtf);
                let trimmed = extracted.trim();
                if !trimmed.is_empty() {
                    let first_line = trimmed.lines().next().unwrap_or("").trim();
                    let title: String = first_line.chars().take(MAX_TITLE_CHARS).collect();
                    return (title, trimmed.to_string());
                }
            }
        }

        // 5. Fallbacks for non-text content
        match kind {
            ContentKind::Image => ("Image".to_string(), String::new()),
            ContentKind::RichText => ("Rich Text Document".to_string(), String::new()),
            ContentKind::FileUrls => ("File Reference".to_string(), String::new()),
            ContentKind::Mixed => ("Clipboard Content".to_string(), String::new()),
            ContentKind::Text => ("Plain Text".to_string(), String::new()),
        }
    }

    /// Normalizes text for deduplication across complex applications (F-012):
    /// - Strips object replacement / attachment characters (\u{fffc}, \u{fffd}).
    /// - Normalizes newlines (\r\n and \r -> \n).
    /// - Normalizes Unicode to NFC.
    /// - Trims outer whitespace and newlines.
    /// - For multiline text (code snippets, tables), trims trailing whitespace per line.
    pub fn canonicalize_text(raw: &str) -> String {
        let stripped_obj = raw.replace(['\u{fffc}', '\u{fffd}'], "");
        let normalized = stripped_obj.replace("\r\n", "\n").replace('\r', "\n");
        let nfc: String = normalized.nfc().collect();
        let trimmed_outer = nfc.trim();
        if trimmed_outer.is_empty() {
            return String::new();
        }

        if !trimmed_outer.contains('\n') {
            return trimmed_outer.to_string();
        }

        let mut lines: Vec<&str> = trimmed_outer.lines().map(|l| l.trim_end()).collect();
        while let Some(first) = lines.first() {
            if first.is_empty() {
                lines.remove(0);
            } else {
                break;
            }
        }
        while let Some(last) = lines.last() {
            if last.is_empty() {
                lines.pop();
            } else {
                break;
            }
        }
        lines.join("\n")
    }

    /// Canonicalizes a file URL or path for deduplication (F-012, T-CAP-05):
    /// - Trims whitespace and newlines.
    /// - Strips "file://localhost" or "file://" scheme prefix.
    /// - Percent-decodes escaped sequences (e.g. "%20" -> " ").
    /// - Trims trailing slashes.
    /// - NFC-normalizes the path.
    pub fn canonicalize_file_url(raw: &str) -> String {
        let trimmed = raw.trim();
        let stripped = trimmed
            .strip_prefix("file://localhost")
            .or_else(|| trimmed.strip_prefix("file://"))
            .unwrap_or(trimmed);
        let decoded = Self::percent_decode_str(stripped);
        let cleaned = decoded.trim_end_matches('/');
        let nfc: String = cleaned.nfc().collect();
        if nfc.is_empty() {
            "/".to_string()
        } else {
            nfc
        }
    }

    /// Formats a raw byte count into a human-readable string (B, KB, MB).
    pub fn format_byte_size(bytes: u64) -> String {
        if bytes < 1024 {
            format!("{bytes} B")
        } else if bytes < 1024 * 1024 {
            let kb = bytes as f64 / 1024.0;
            format!("{kb:.1} KB")
        } else {
            let mb = bytes as f64 / (1024.0 * 1024.0);
            format!("{mb:.1} MB")
        }
    }

    /// Lightweight helper to decode percent-encoded sequences in URLs (e.g. %20 -> ' ').
    pub fn percent_decode_str(input: &str) -> String {
        let mut bytes = Vec::with_capacity(input.len());
        let mut chars = input.bytes().peekable();

        while let Some(b) = chars.next() {
            if b == b'%' {
                let h1 = chars.next();
                let h2 = chars.next();
                if let (Some(c1), Some(c2)) = (h1, h2) {
                    let hex_slice = [c1, c2];
                    if let Ok(byte_val) =
                        u8::from_str_radix(std::str::from_utf8(&hex_slice).unwrap_or(""), 16)
                    {
                        bytes.push(byte_val);
                        continue;
                    } else {
                        bytes.push(b'%');
                        bytes.push(c1);
                        bytes.push(c2);
                        continue;
                    }
                } else {
                    bytes.push(b'%');
                    if let Some(c1) = h1 {
                        bytes.push(c1);
                    }
                    continue;
                }
            }
            bytes.push(b);
        }

        String::from_utf8_lossy(&bytes).to_string()
    }

    /// Extracts plain text from an HTML snippet by stripping tags and decoding common entities.
    pub fn extract_text_from_html(html: &str) -> String {
        let mut result = String::with_capacity(html.len());
        let mut in_tag = false;
        let mut current_tag = String::new();

        for ch in html.chars() {
            match ch {
                '<' => {
                    in_tag = true;
                    current_tag.clear();
                }
                '>' => {
                    in_tag = false;
                    let tag_name = current_tag
                        .trim()
                        .trim_start_matches('/')
                        .to_ascii_lowercase();
                    let tag_base = tag_name.split_whitespace().next().unwrap_or("");
                    if matches!(
                        tag_base,
                        "p" | "div"
                            | "br"
                            | "h1"
                            | "h2"
                            | "h3"
                            | "h4"
                            | "h5"
                            | "h6"
                            | "li"
                            | "tr"
                            | "table"
                    ) && !result.ends_with(' ')
                        && !result.is_empty()
                    {
                        result.push(' ');
                    }
                }
                _ if in_tag => {
                    current_tag.push(ch);
                }
                _ => result.push(ch),
            }
        }

        let decoded = result
            .replace("&nbsp;", " ")
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&apos;", "'");

        let cleaned: String = decoded.split_whitespace().collect::<Vec<_>>().join(" ");
        cleaned.nfc().collect()
    }

    /// Extracts plain text from an RTF payload by skipping control groups and words.
    pub fn extract_text_from_rtf(rtf: &str) -> String {
        let mut result = String::with_capacity(rtf.len());
        let mut chars = rtf.chars().peekable();
        let mut group_depth: usize = 0;
        let mut skip_group_depth: Option<usize> = None;

        while let Some(ch) = chars.next() {
            match ch {
                '{' => {
                    group_depth += 1;
                    if chars.peek() == Some(&'\\') {
                        let mut lookahead = String::new();
                        let mut temp = chars.clone();
                        temp.next(); // skip '\\'
                        while let Some(&c) = temp.peek() {
                            if c.is_ascii_alphabetic() || c == '*' {
                                lookahead.push(c);
                                temp.next();
                            } else {
                                break;
                            }
                        }
                        if matches!(
                            lookahead.as_str(),
                            "fonttbl" | "colortbl" | "stylesheet" | "info" | "*"
                        ) && skip_group_depth.is_none()
                        {
                            skip_group_depth = Some(group_depth);
                        }
                    }
                }
                '}' => {
                    if let Some(skip_depth) = skip_group_depth {
                        if group_depth <= skip_depth {
                            skip_group_depth = None;
                        }
                    }
                    group_depth = group_depth.saturating_sub(1);
                }
                '\\' => {
                    if skip_group_depth.is_some() {
                        continue;
                    }
                    // Handle escaped characters: \{, \}, \\
                    if let Some(&next_ch) = chars.peek() {
                        if next_ch == '{' || next_ch == '}' || next_ch == '\\' {
                            result.push(next_ch);
                            chars.next();
                            continue;
                        }
                    }
                    // Read control word
                    let mut word = String::new();
                    while let Some(&c) = chars.peek() {
                        if c.is_ascii_alphabetic() {
                            word.push(c);
                            chars.next();
                        } else {
                            break;
                        }
                    }
                    // Read optional numeric argument
                    while let Some(&c) = chars.peek() {
                        if c.is_ascii_digit() || c == '-' {
                            chars.next();
                        } else {
                            break;
                        }
                    }
                    // Optional delimiter space after control word
                    if chars.peek() == Some(&' ') {
                        chars.next();
                    }

                    // Check for paragraph or line breaks
                    if word == "par" || word == "line" {
                        result.push('\n');
                    }
                }
                '\r' | '\n' => {
                    // RTF raw newlines are ignored formatting
                }
                _ => {
                    if skip_group_depth.is_none() {
                        result.push(ch);
                    }
                }
            }
        }

        let cleaned = result.trim();
        cleaned.nfc().collect()
    }
}
