#!/usr/bin/env bash
# ==============================================================================
# Mimra — Sparkle Appcast Generation Script (P9-05 / F-062, T-REL-01)
# Signs distribution DMG with Ed25519 key and updates appcast.xml RSS feed.
# Enforces collision protection (isolates scan targets to prevent duplicate items).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DMG_PATH="${1:-}"
VERSION="${2:-}"
BUILD="${3:-}"
KEY_INPUT="${4:-}"
NOTES_FILE="${5:-}"

if [ -z "$DMG_PATH" ] || [ -z "$VERSION" ] || [ -z "$BUILD" ] || [ -z "$KEY_INPUT" ]; then
    echo "Usage: $0 <path-to-dmg> <version> <build> <key-file-or-seed> [notes-file]"
    echo "Example: $0 dist/Mimra.dmg 0.1.0 1 /tmp/sparkle.key notes.txt"
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "Error: DMG file not found at: $DMG_PATH"
    exit 1
fi

SIGN_UPDATE="${PROJECT_ROOT}/bin/sparkle/sign_update"
if [ ! -f "$SIGN_UPDATE" ]; then
    echo "Error: sign_update tool not found at $SIGN_UPDATE. Running setup-sparkle.sh..."
    "$PROJECT_ROOT/scripts/setup-sparkle.sh"
fi

TMP_KEY_FILE=""
if [ -f "$KEY_INPUT" ]; then
    KEY_FILE="$KEY_INPUT"
else
    # Treat as raw seed string
    TMP_KEY_FILE="$(mktemp /tmp/mimra-sparkle-key.XXXXXX)"
    echo "$KEY_INPUT" > "$TMP_KEY_FILE"
    KEY_FILE="$TMP_KEY_FILE"
fi

cleanup() {
    if [ -n "$TMP_KEY_FILE" ] && [ -f "$TMP_KEY_FILE" ]; then
        rm -f "$TMP_KEY_FILE"
    fi
}
trap cleanup EXIT

echo "=== Computing Sparkle Ed25519 Signature for $(basename "$DMG_PATH") ==="
SIGNATURE="$("$SIGN_UPDATE" -p --ed-key-file "$KEY_FILE" "$DMG_PATH")"
FILE_SIZE="$(stat -f%z "$DMG_PATH")"

echo "Signature: $SIGNATURE"
echo "File size: $FILE_SIZE bytes"

RELEASE_NOTES="Bug fixes and performance improvements."
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    RELEASE_NOTES="$(cat "$NOTES_FILE")"
fi

APPCAST_FILE="${PROJECT_ROOT}/appcast.xml"
DOWNLOAD_URL="https://github.com/ahmetaltun/Mimra/releases/download/v${VERSION}/Mimra.dmg"

/usr/bin/python3 - <<PY
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
import os

appcast_path = "$APPCAST_FILE"
version = "$VERSION"
build = "$BUILD"
download_url = "$DOWNLOAD_URL"
file_size = "$FILE_SIZE"
signature = "$SIGNATURE"
notes = """$RELEASE_NOTES"""

ET.register_namespace('sparkle', 'https://sparkle-project.org/xml-namespaces/sparkle')

if os.path.exists(appcast_path):
    tree = ET.parse(appcast_path)
    root = tree.getroot()
else:
    root = ET.Element('rss', {
        'version': '2.0',
        '{https://sparkle-project.org/xml-namespaces/sparkle}': 'https://sparkle-project.org/xml-namespaces/sparkle'
    })
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'Mimra Updates'
    ET.SubElement(channel, 'link').text = 'https://raw.githubusercontent.com/ahmetaltun/Mimra/master/appcast.xml'
    ET.SubElement(channel, 'description').text = 'Most recent changes with links to updates for Mimra Clipboard Manager.'
    ET.SubElement(channel, 'language').text = 'en'

channel = root.find('channel')
if channel is None:
    channel = ET.SubElement(root, 'channel')

# Collision Protection: Remove any existing item with the same version or build
for item in list(channel.findall('item')):
    enclosure = item.find('enclosure')
    if enclosure is not None:
        enc_version = enclosure.attrib.get('{https://sparkle-project.org/xml-namespaces/sparkle}shortVersionString') or enclosure.attrib.get('sparkle:shortVersionString')
        enc_build = enclosure.attrib.get('{https://sparkle-project.org/xml-namespaces/sparkle}version') or enclosure.attrib.get('sparkle:version')
        if enc_version == version or enc_build == build:
            channel.remove(item)

# Create new update item
pub_date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
item = ET.Element('item')
ET.SubElement(item, 'title').text = f"Mimra {version}"
ET.SubElement(item, 'pubDate').text = pub_date

min_sys = ET.SubElement(item, '{https://sparkle-project.org/xml-namespaces/sparkle}minimumSystemVersion')
min_sys.text = "15.0"

desc = ET.SubElement(item, 'description')
desc.text = notes

enclosure = ET.SubElement(item, 'enclosure', {
    'url': download_url,
    '{https://sparkle-project.org/xml-namespaces/sparkle}version': str(build),
    '{https://sparkle-project.org/xml-namespaces/sparkle}shortVersionString': str(version),
    'length': str(file_size),
    'type': 'application/octet-stream',
    '{https://sparkle-project.org/xml-namespaces/sparkle}edSignature': signature
})

# Insert new item at the top of channel (index after channel metadata)
insert_idx = 0
for idx, child in enumerate(channel):
    if child.tag == 'item':
        insert_idx = idx
        break
    insert_idx = idx + 1

channel.insert(insert_idx, item)

# Pretty print XML
ET.indent(root, space="  ", level=0)
with open(appcast_path, "wb") as f:
    f.write(ET.tostring(root, encoding='utf-8', xml_declaration=True))

print(f"✓ Successfully updated {appcast_path} with Mimra v{version} (Build {build})")
PY

echo "Validating XML syntax..."
/usr/bin/python3 -c "import xml.etree.ElementTree as ET; ET.parse('$APPCAST_FILE'); print('✓ appcast.xml syntax valid.')"
