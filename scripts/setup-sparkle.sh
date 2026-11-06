#!/usr/bin/env bash
# ==============================================================================
# Mimra — Sparkle 2 Setup & Ingestion Script
# Downloads and stages the official Sparkle 2.10.x distribution (Framework + CLI tools).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SPARKLE_VERSION="${1:-2.10.1}"
DOWNLOAD_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
TMP_DIR="$(mktemp -d /tmp/mimra-sparkle-setup.XXXXXX)"

trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Setting up Sparkle ${SPARKLE_VERSION} ==="
echo "Downloading from: ${DOWNLOAD_URL}..."

curl -sSL -A "Mimra-Build-Agent" "${DOWNLOAD_URL}" -o "${TMP_DIR}/Sparkle.tar.xz"

echo "Extracting Sparkle archive..."
tar -xf "${TMP_DIR}/Sparkle.tar.xz" -C "${TMP_DIR}"

mkdir -p "${PROJECT_ROOT}/Frameworks"
mkdir -p "${PROJECT_ROOT}/bin/sparkle"

# Stage Framework / XCFramework
if [ -d "${TMP_DIR}/Sparkle.xcframework" ]; then
    echo "Staging Sparkle.xcframework to Frameworks/..."
    rm -rf "${PROJECT_ROOT}/Frameworks/Sparkle.xcframework"
    cp -R "${TMP_DIR}/Sparkle.xcframework" "${PROJECT_ROOT}/Frameworks/"
    
    # Also extract the direct macOS arm64/x86_64 Sparkle.framework for direct linkage
    if [ -d "${TMP_DIR}/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" ]; then
        rm -rf "${PROJECT_ROOT}/Frameworks/Sparkle.framework"
        cp -R "${TMP_DIR}/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "${PROJECT_ROOT}/Frameworks/"
    fi
elif [ -d "${TMP_DIR}/Sparkle.framework" ]; then
    echo "Staging Sparkle.framework to Frameworks/..."
    rm -rf "${PROJECT_ROOT}/Frameworks/Sparkle.framework"
    cp -R "${TMP_DIR}/Sparkle.framework" "${PROJECT_ROOT}/Frameworks/"
fi

# Stage CLI binaries
echo "Staging Sparkle CLI tools to bin/sparkle/..."
for tool in generate_appcast generate_keys sign_update; do
    if [ -f "${TMP_DIR}/bin/${tool}" ]; then
        cp "${TMP_DIR}/bin/${tool}" "${PROJECT_ROOT}/bin/sparkle/${tool}"
        chmod +x "${PROJECT_ROOT}/bin/sparkle/${tool}"
    fi
done

echo "✓ Sparkle ${SPARKLE_VERSION} successfully staged in:"
echo "  Frameworks: ${PROJECT_ROOT}/Frameworks/Sparkle.framework"
echo "  CLI tools:  ${PROJECT_ROOT}/bin/sparkle/"
