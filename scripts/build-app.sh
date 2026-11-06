#!/usr/bin/env bash
# ==============================================================================
# Mimra — Application Build & Packaging Script
# Compiles RustCore, generates Swift bindings, and builds Mimra.app via xcodebuild.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_MODE="${1:-debug}"
CONFIGURATION="Debug"
if [ "$BUILD_MODE" = "release" ]; then
    CONFIGURATION="Release"
fi

echo "=== 1. Building RustCore Static Library ($BUILD_MODE) ==="
"$PROJECT_ROOT/scripts/build-rust.sh" "$BUILD_MODE"

echo -e "\n=== 2. Generating UniFFI Bindings ==="
"$PROJECT_ROOT/scripts/generate-bindings.sh"

if [ ! -d "$PROJECT_ROOT/Frameworks/Sparkle.framework" ]; then
    echo -e "\n=== Setting up Sparkle Framework ==="
    "$PROJECT_ROOT/scripts/setup-sparkle.sh"
fi

echo -e "\n=== 3. Building Mimra.app via Xcode ($CONFIGURATION) ==="
cd "$PROJECT_ROOT"
xcodebuild -project Mimra.xcodeproj \
    -scheme Mimra \
    -configuration "$CONFIGURATION" \
    -derivedDataPath /tmp/MimraDerivedData \
    -destination 'platform=macOS,arch=arm64' \
    build

echo -e "\n=== 4. Staging Mimra.app to build/ ==="
mkdir -p "$PROJECT_ROOT/build"
rm -rf "$PROJECT_ROOT/build/Mimra.app"
cp -R "/tmp/MimraDerivedData/Build/Products/$CONFIGURATION/Mimra.app" "$PROJECT_ROOT/build/"

echo -e "\n=== 5. Verifying Static Linkage (Zero Dynamic Rust Dependencies) ==="
DYLIB_DEPS=$(otool -L "$PROJECT_ROOT/build/Mimra.app/Contents/MacOS/Mimra" | grep "mimra_core" || true)
if [ -n "$DYLIB_DEPS" ]; then
    echo "ERROR: Mimra binary has dynamic dependency on libmimra_core: $DYLIB_DEPS" >&2
    echo "Expected pure static linkage via libmimra_core.a." >&2
    exit 1
fi
echo "✓ Verified: Mimra binary is 100% statically linked with libmimra_core.a"

if [ "${2:-}" = "--install" ] || [ "${1:-}" = "--install" ]; then
    echo -e "\n=== Installing Mimra.app to /Applications ==="
    pkill -x Mimra 2>/dev/null || true
    rm -rf /Applications/Mimra.app
    cp -R "$PROJECT_ROOT/build/Mimra.app" /Applications/
    echo "✓ Installed freshly built Mimra.app to /Applications/Mimra.app"
fi

echo -e "\n✓ Mimra.app successfully built at: $PROJECT_ROOT/build/Mimra.app"
