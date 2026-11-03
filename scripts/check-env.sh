#!/usr/bin/env bash
# ==============================================================================
# Mimra — Environment Validation Script (P0-02)
# Validates the host machine satisfies all requirements for building Mimra:
# - macOS (Darwin) on Apple Silicon (arm64)
# - macOS 15.0+ deployment target SDK
# - Xcode and Command Line Tools
# - Rust toolchain with aarch64-apple-darwin target installed
# ==============================================================================

set -euo pipefail

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

ERRORS=0

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ERRORS=$((ERRORS + 1))
}

echo -e "${BOLD}Checking Mimra Development Environment...${NC}\n"

# 1. Check Operating System
OS_NAME="$(uname -s)"
if [ "$OS_NAME" != "Darwin" ]; then
    log_fail "Mimra requires macOS (Darwin). Current OS detected: '$OS_NAME'. Building on other platforms is not supported."
else
    log_pass "Operating System: macOS ($OS_NAME)"
fi

# 2. Check Architecture (Apple Silicon arm64 only)
ARCH_NAME="$(uname -m)"
if [ "$ARCH_NAME" != "arm64" ]; then
    log_fail "Mimra requires Apple Silicon (arm64/M1+). Current architecture: '$ARCH_NAME'. Rosetta 2 / Intel builds are intentionally excluded by architectural specification."
else
    log_pass "Architecture: Apple Silicon ($ARCH_NAME)"
fi

# 3. Check macOS Version (>= 15.0 required)
if command -v sw_vers >/dev/null 2>&1; then
    PRODUCT_VERSION="$(sw_vers -productVersion)"
    MAJOR_VERSION="$(echo "$PRODUCT_VERSION" | cut -d. -f1)"
    if [ "$MAJOR_VERSION" -lt 15 ]; then
        log_fail "Mimra requires macOS 15.0 or later. Detected version: '$PRODUCT_VERSION'. Please upgrade macOS or use an SDK with macOS 15+ support."
    else
        log_pass "macOS Version: $PRODUCT_VERSION (>= 15.0)"
    fi
else
    log_fail "'sw_vers' command not found. Unable to verify macOS product version."
fi

# 4. Check Xcode & Command Line Tools
if command -v xcodebuild >/dev/null 2>&1; then
    XCODE_INFO="$(xcodebuild -version | tr '\n' ' ')"
    log_pass "Xcode installed: $XCODE_INFO"
    
    # Check macOS SDK version
    MACOS_SDK_VERSION="$(xcrun --show-sdk-version --sdk macosx 2>/dev/null || echo "0")"
    SDK_MAJOR="$(echo "$MACOS_SDK_VERSION" | cut -d. -f1)"
    if [ "$SDK_MAJOR" -lt 15 ]; then
        log_fail "macOS SDK version must be >= 15.0. Found SDK version: '$MACOS_SDK_VERSION'. Install the latest Xcode or select it using 'sudo xcode-select -s'."
    else
        log_pass "macOS SDK Version: $MACOS_SDK_VERSION"
    fi
else
    log_fail "'xcodebuild' not found. Please install Xcode and run 'xcode-select --switch /Applications/Xcode.app/Contents/Developer'."
fi

# 5. Check Swift Compiler
if command -v swiftc >/dev/null 2>&1; then
    SWIFT_VERSION="$(swiftc --version 2>&1 | head -n 1)"
    log_pass "Swift compiler: $SWIFT_VERSION"
else
    log_fail "'swiftc' not found. Ensure Xcode or Apple Command Line Tools are correctly installed."
fi

# 6. Check Rust & Cargo
if command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
    RUST_VERSION="$(rustc --version)"
    CARGO_VERSION="$(cargo --version)"
    log_pass "Rust toolchain: $RUST_VERSION ($CARGO_VERSION)"
else
    log_fail "Rust toolchain ('rustc' or 'cargo') not found. Install Rust via https://rustup.rs."
fi

# 7. Check aarch64-apple-darwin target in rustup
if command -v rustup >/dev/null 2>&1; then
    if rustup target list --installed | grep -q "aarch64-apple-darwin"; then
        log_pass "Rust target installed: aarch64-apple-darwin"
    else
        log_fail "Required Rust target 'aarch64-apple-darwin' is missing. Fix this by running: 'rustup target add aarch64-apple-darwin'."
    fi
else
    log_warn "'rustup' not found in PATH; cannot verify if 'aarch64-apple-darwin' target is installed."
fi

# Summary
echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}✓ Environment check passed! All prerequisites for Mimra are satisfied.${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}✗ Environment check failed with $ERRORS error(s). Please resolve the issues above before building.${NC}"
    exit 1
fi
