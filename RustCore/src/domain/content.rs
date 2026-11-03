// ==============================================================================
// Mimra Core — Domain Content Models
// Represents clipboard data formats, representations, and content classifications.
// ==============================================================================

use crate::error::CoreError;
use crate::MAX_PAYLOAD_SIZE_BYTES;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

/// Standard Uniform Type Identifiers (UTIs) frequently handled by macOS clipboard.
pub mod uti {
    pub const UTF8_PLAIN_TEXT: &str = "public.utf8-plain-text";
    pub const PLAIN_TEXT: &str = "public.plain-text";
    pub const RTF: &str = "public.rtf";
    pub const RTFD: &str = "com.apple.flat-rtfd";
    pub const HTML: &str = "public.html";
    pub const PNG: &str = "public.png";
    pub const TIFF: &str = "public.tiff";
    pub const JPEG: &str = "public.jpeg";
    pub const HEIC: &str = "public.heic";
    pub const FILE_URL: &str = "public.file-url";
    pub const URL: &str = "public.url";
    pub const URL_NAME: &str = "public.url-name";
    pub const MIMRA_PROVENANCE: &str = "com.mimra.provenance";
}

/// The high-level classification of content stored in a clipboard history item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContentKind {
    /// Plain text content only.
    Text,
    /// Rich text content (RTF, HTML, styled strings).
    RichText,
    /// Visual image content (PNG, TIFF, JPEG, HEIC).
    Image,
    /// One or more file references / URLs.
    FileUrls,
    /// Mixed multi-item or compound payload.
    Mixed,
}

impl fmt::Display for ContentKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Text => write!(f, "text"),
            Self::RichText => write!(f, "rich_text"),
            Self::Image => write!(f, "image"),
            Self::FileUrls => write!(f, "file_urls"),
            Self::Mixed => write!(f, "mixed"),
        }
    }
}

impl FromStr for ContentKind {
    type Err = CoreError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_ascii_lowercase().as_str() {
            "text" => Ok(Self::Text),
            "rich_text" | "richtext" | "rich" => Ok(Self::RichText),
            "image" => Ok(Self::Image),
            "file_urls" | "files" => Ok(Self::FileUrls),
            "mixed" => Ok(Self::Mixed),
            other => Err(CoreError::InvalidInput {
                details: format!("Unknown content kind '{other}'. Expected: text, rich_text, image, file_urls, or mixed."),
            }),
        }
    }
}

/// A single representation / flavor within a pasteboard item.
/// A logical copy event may have multiple representations (e.g. plain text + HTML + RTF)
/// or multiple grouped items (e.g. copying 3 separate files in Finder).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Representation {
    /// Zero-based group index identifying the logical item within a multi-item copy.
    pub group_index: u32,
    /// The Uniform Type Identifier (UTI) describing this payload format.
    pub uti: String,
    /// The raw payload bytes for this representation.
    pub payload: Vec<u8>,
}

impl Representation {
    /// Constructs and validates a new clipboard representation.
    ///
    /// # Errors
    /// Returns `CoreError::InvalidInput` if UTI is empty.
    /// Returns `CoreError::EmptyPayload` if payload is empty.
    /// Returns `CoreError::PayloadTooLarge` if payload exceeds `MAX_PAYLOAD_SIZE_BYTES` (10 MB).
    pub fn new(
        group_index: u32,
        uti: impl Into<String>,
        payload: Vec<u8>,
    ) -> Result<Self, CoreError> {
        let uti_str = uti.into().trim().to_string();
        if uti_str.is_empty() {
            return Err(CoreError::InvalidInput {
                details: "Representation UTI cannot be empty.".to_string(),
            });
        }

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

        Ok(Self {
            group_index,
            uti: uti_str,
            payload,
        })
    }

    /// Returns true if this representation is a plain-text format.
    pub fn is_plain_text(&self) -> bool {
        self.uti == uti::UTF8_PLAIN_TEXT || self.uti == uti::PLAIN_TEXT
    }

    /// Returns true if this representation is an image format.
    pub fn is_image(&self) -> bool {
        matches!(
            self.uti.as_str(),
            uti::PNG | uti::TIFF | uti::JPEG | uti::HEIC
        )
    }

    /// Returns true if this representation is a file URL format.
    pub fn is_file_url(&self) -> bool {
        self.uti == uti::FILE_URL
    }

    /// Returns true if this representation is a rich text format (RTF, RTFD, HTML).
    pub fn is_rich_text(&self) -> bool {
        matches!(self.uti.as_str(), uti::RTF | uti::RTFD | uti::HTML)
    }
}
