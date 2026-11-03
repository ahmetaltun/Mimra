// ==============================================================================
// Mimra Core — Typed Error Definitions
// Explanatory, type-safe error definitions exported across the UniFFI boundary.
// ==============================================================================

use thiserror::Error;

/// Core errors that can occur during Rust operations and are mapped across FFI to Swift.
#[derive(Error, Debug, PartialEq, Eq, uniffi::Error)]
pub enum CoreError {
    #[error("The provided clipboard payload is empty. Expected non-zero bytes.")]
    EmptyPayload,

    #[error(
        "The payload size ({actual_bytes} bytes) exceeds the allowed limit of {max_bytes} bytes."
    )]
    PayloadTooLarge { max_bytes: u64, actual_bytes: u64 },

    #[error("Database error occurred: {details}. Check SQLite integrity and permissions.")]
    DatabaseError { details: String },

    #[error("Requested item with ID '{id}' was not found in local history.")]
    ItemNotFound { id: String },

    #[error("Invalid input: {details}")]
    InvalidInput { details: String },

    #[error("Invalid regular expression '{pattern}': {error_message}")]
    InvalidRegex {
        pattern: String,
        error_message: String,
    },

    #[error("Internal engine failure: {message}")]
    Internal { message: String },
}

impl From<rusqlite::Error> for CoreError {
    fn from(err: rusqlite::Error) -> Self {
        CoreError::DatabaseError {
            details: err.to_string(),
        }
    }
}
