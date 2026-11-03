// ==============================================================================
// Mimra Core — Library Entrypoint & UniFFI Exports
// ==============================================================================

pub mod domain;
pub mod error;

pub use domain::{uti, ContentKind, HistoryItem, Representation};
pub use error::CoreError;

// Setup UniFFI scaffolding for procedural macro bindings
uniffi::setup_scaffolding!();

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
}
