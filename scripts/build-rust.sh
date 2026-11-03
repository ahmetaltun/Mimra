#!/usr/bin/env bash
# ==============================================================================
# Mimra — Rust Static Library Build Script
# Compiles RustCore as a static library for aarch64-apple-darwin
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUST_DIR="$PROJECT_ROOT/RustCore"

BUILD_MODE="${1:-debug}"
TARGET="aarch64-apple-darwin"

echo "Building RustCore ($BUILD_MODE) for target $TARGET..."

cd "$RUST_DIR"

if [ "$BUILD_MODE" = "release" ]; then
    cargo build --release --target "$TARGET"
    LIB_PATH="$RUST_DIR/target/$TARGET/release/libmimra_core.a"
else
    cargo build --target "$TARGET"
    LIB_PATH="$RUST_DIR/target/$TARGET/debug/libmimra_core.a"
fi

if [ ! -f "$LIB_PATH" ]; then
    echo "Error: Expected static library not found at: $LIB_PATH" >&2
    exit 1
fi

echo "Verifying static library architecture..."
ARCH_INFO="$(lipo -info "$LIB_PATH")"
echo "$ARCH_INFO"

if [[ "$ARCH_INFO" != *"arm64"* ]]; then
    echo "Error: Built archive does not contain arm64 slice!" >&2
    exit 1
fi

echo "✓ RustCore static library built successfully at: $LIB_PATH"
