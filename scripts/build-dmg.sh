#!/usr/bin/env bash
# ==============================================================================
# Mimra — Premium macOS Drag-and-Drop DMG Packaging Script
# Follows the /premium-macos-dmg skill visual specification:
# - Window content-space: 720x460 points
# - App icon positioned at (202, 271), Applications link at (520, 271)
# - Multi-representation Retina TIFF background via tiffutil
# - Pre-stages .background with invisible & hidden flags
# - Preserves original code signatures and architecture
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH="${1:-$PROJECT_ROOT/build/Mimra.app}"
OUTPUT_DMG="${2:-$PROJECT_ROOT/dist/Mimra.dmg}"
BACKGROUND_DIR="$PROJECT_ROOT/packaging/dmg"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: DMG creation requires macOS." >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "ERROR: 'create-dmg' is not installed." >&2
    echo "Install it via Homebrew: brew install create-dmg" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" || ! -f "$APP_PATH/Contents/Info.plist" ]]; then
    echo "ERROR: Invalid macOS application bundle at: $APP_PATH" >&2
    exit 1
fi

APP_NAME="$(basename "$APP_PATH")"
VOL_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PATH/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "Mimra")"

echo "=== Packaging Premium macOS DMG ==="
echo "Application: $APP_PATH"
echo "Volume Name: $VOL_NAME"
echo "Output:      $OUTPUT_DMG"

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT_DMG")"
rm -f "$OUTPUT_DMG"

# Auto-regenerate background assets if missing
if [[ ! -f "$BACKGROUND_DIR/background.png" || ! -f "$BACKGROUND_DIR/background@2x.png" ]]; then
    echo "Rendering fresh background assets..."
    swift "$PROJECT_ROOT/scripts/render_dmg_background.swift" "$BACKGROUND_DIR"
fi

# Prepare staging directory
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp/}mimra-dmg-staging.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Staging application to $WORK_DIR..."
/usr/bin/ditto "$APP_PATH" "$WORK_DIR/$APP_NAME"

# Build high-DPI multi-representation TIFF background if @2x is present
BACKGROUND_PNG="$BACKGROUND_DIR/background.png"
BACKGROUND_2X="$BACKGROUND_DIR/background@2x.png"
BACKGROUND_TO_USE="$BACKGROUND_PNG"

if [[ -f "$BACKGROUND_PNG" && -f "$BACKGROUND_2X" ]] && command -v tiffutil >/dev/null 2>&1; then
    TIFF_PATH="$WORK_DIR/background.tiff"
    if tiffutil -cathidpicheck "$BACKGROUND_PNG" "$BACKGROUND_2X" -out "$TIFF_PATH" 2>/dev/null; then
        echo "✓ Created multi-representation Retina background TIFF"
        BACKGROUND_TO_USE="$TIFF_PATH"
    fi
fi

if [[ ! -f "$BACKGROUND_TO_USE" ]]; then
    echo "ERROR: Background image not found in $BACKGROUND_DIR" >&2
    exit 1
fi

# Pre-stage hidden .background directory in staging folder
mkdir -p "$WORK_DIR/.background"
cp "$BACKGROUND_TO_USE" "$WORK_DIR/.background/$(basename "$BACKGROUND_TO_USE")"
SetFile -a V "$WORK_DIR/.background" 2>/dev/null || true
chflags hidden "$WORK_DIR/.background" 2>/dev/null || true

echo "Invoking create-dmg..."
create-dmg \
    --volname "$VOL_NAME" \
    --background "$BACKGROUND_TO_USE" \
    --window-pos 200 120 \
    --window-size 720 460 \
    --icon-size 96 \
    --text-size 12 \
    --icon "$APP_NAME" 202 271 \
    --hide-extension "$APP_NAME" \
    --app-drop-link 520 271 \
    --no-internet-enable \
    "$OUTPUT_DMG" \
    "$WORK_DIR"

echo -e "\n✓ Successfully created premium DMG at: $OUTPUT_DMG"
