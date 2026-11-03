#!/usr/bin/env bash
# ==============================================================================
# Mimra — Comprehensive Verification Test Script
# Runs environment check, Rust formatting, clippy, unit tests, static library build,
# binding generation, Swift FFI integration verification, and Xcode app build.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== 1. Validating Environment ==="
"$PROJECT_ROOT/scripts/check-env.sh"

echo -e "\n=== 2. Running Rust Quality Gates (fmt, clippy, test) ==="
cd "$PROJECT_ROOT/RustCore"
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo test --all --locked

echo -e "\n=== 3. Building Rust Static Library ==="
"$PROJECT_ROOT/scripts/build-rust.sh" debug

echo -e "\n=== 4. Generating Swift UniFFI Bindings ==="
"$PROJECT_ROOT/scripts/generate-bindings.sh"

echo -e "\n=== 5. Running Swift <-> Rust FFI Integration Spike ==="
cd "$PROJECT_ROOT"
mkdir -p /tmp/swift-module-cache
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/tests/ffi_spike.swift" \
    -o /tmp/mimra_ffi_spike_runner

/tmp/mimra_ffi_spike_runner
rm -f /tmp/mimra_ffi_spike_runner

echo -e "\n=== 6. Building Native macOS App (Mimra.app) via Xcode ==="
cd "$PROJECT_ROOT"
xcodebuild -project Mimra.xcodeproj \
    -scheme Mimra \
    -configuration Debug \
    -derivedDataPath /tmp/MimraDerivedData \
    -destination 'platform=macOS,arch=arm64' \
    build

echo -e "\n✓ ALL QUALITY GATES, FFI INTEGRATION, AND NATIVE XCODE BUILDS PASSED!"
