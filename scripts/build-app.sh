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

echo -e "\n✓ Mimra.app successfully built at: $PROJECT_ROOT/build/Mimra.app"
