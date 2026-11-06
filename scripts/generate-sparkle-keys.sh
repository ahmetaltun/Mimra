#!/usr/bin/env bash
# ==============================================================================
# Mimra — Sparkle Ed25519 Key Management Script
# Displays active Ed25519 keys matching Info.plist or regenerates a new key pair.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEY_FILE="${PROJECT_ROOT}/.sparkle_private_key"

ACTION="${1:-}"

if [ "$ACTION" = "--regenerate" ]; then
    echo "=== Generating New Ed25519 Key Pair ==="
    cat << 'EOF' > /tmp/gen_mimra_key.swift
import Foundation
import CryptoKit

let privateKey = Curve25519.Signing.PrivateKey()
let seedBase64 = privateKey.rawRepresentation.base64EncodedString()
let pubBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()

print("\(seedBase64)")
print("\(pubBase64)")
EOF
    swiftc -module-cache-path /tmp/swift-module-cache /tmp/gen_mimra_key.swift -o /tmp/gen_mimra_key
    OUTPUT="$(/tmp/gen_mimra_key)"
    SEED="$(echo "$OUTPUT" | head -n 1)"
    PUB="$(echo "$OUTPUT" | tail -n 1)"
    rm -f /tmp/gen_mimra_key.swift /tmp/gen_mimra_key

    echo "$SEED" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"

    echo "✓ New key pair generated and saved to: .sparkle_private_key"
    echo ""
    echo "Public Key (SUPublicEDKey in Mimra/Info.plist):"
    echo "  $PUB"
    echo ""
    echo "Private Key (SPARKLE_PRIVATE_KEY in GitHub Secrets):"
    echo "  $SEED"
    exit 0
fi

if [ -f "$KEY_FILE" ]; then
    SEED="$(cat "$KEY_FILE" | tr -d '\r\n ')"
    cat << EOF > /tmp/derive_pub_key.swift
import Foundation
import CryptoKit

let seedBase64 = "$SEED"
if let seedData = Data(base64Encoded: seedBase64),
   let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seedData) {
    let pubBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
    print(pubBase64)
} else {
    print("INVALID_SEED")
}
EOF
    swiftc -module-cache-path /tmp/swift-module-cache /tmp/derive_pub_key.swift -o /tmp/derive_pub_key
    PUB="$(/tmp/derive_pub_key)"
    rm -f /tmp/derive_pub_key.swift /tmp/derive_pub_key

    echo "=== Active Mimra Sparkle Ed25519 Keys ==="
    echo ""
    echo "Public Key (SUPublicEDKey in Mimra/Info.plist):"
    echo "  $PUB"
    echo ""
    echo "Private Key (SPARKLE_PRIVATE_KEY for GitHub Secrets):"
    echo "  $SEED"
    echo ""
    echo "Location: .sparkle_private_key (gitignored)"
else
    echo "No existing .sparkle_private_key found. Run with --regenerate to create one:"
    echo "  ./scripts/generate-sparkle-keys.sh --regenerate"
fi
