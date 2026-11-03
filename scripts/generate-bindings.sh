#!/usr/bin/env bash
# ==============================================================================
# Mimra — UniFFI Swift Bindings Generator Script
# Generates Swift bindings from RustCore into Generated/
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUST_DIR="$PROJECT_ROOT/RustCore"
OUT_DIR="$PROJECT_ROOT/Generated"

mkdir -p "$OUT_DIR"

echo "Compiling dynamic library for UniFFI bindgen..."
cd "$RUST_DIR"
cargo build

DYLIB_PATH="$RUST_DIR/target/debug/libmimra_core.dylib"
if [ ! -f "$DYLIB_PATH" ]; then
    echo "Error: Dynamic library not found at: $DYLIB_PATH" >&2
    exit 1
fi

echo "Generating Swift bindings into $OUT_DIR..."
cargo run --bin uniffi-bindgen -- generate "$DYLIB_PATH" \
    --library \
    --language swift \
    --metadata-no-deps \
    --out-dir "$OUT_DIR"

# Post-process for Swift 6 strict concurrency:
# UniFFI generates `private var initializationResult`, but it is immutable after initialization.
# Converting to `private let` satisfies Swift 6 nonisolated global safety checks.
if [ -f "$OUT_DIR/mimra_core.swift" ]; then
    sed -i '' 's/private var initializationResult:/private let initializationResult:/g' "$OUT_DIR/mimra_core.swift"
fi

echo "✓ Swift bindings generated successfully in $OUT_DIR"
