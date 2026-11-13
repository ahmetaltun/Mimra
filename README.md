# Mimra

**Mimra** is a minimal, premium, privacy-first macOS clipboard manager built with **SwiftUI**, **AppKit**, and **Rust**.

Mimra remembers what you copy, finds it instantly with embedded full-text search, and restores it accurately—without becoming a distraction, sending data to the cloud, or leaking your secrets.

[![Platform: macOS 15.0+](https://img.shields.io/badge/platform-macOS%2015.0%2B-blue.svg?style=flat-square)](https://apple.com/macos)
[![Architecture: arm64](https://img.shields.io/badge/arch-Apple%20Silicon%20(arm64)-orange.svg?style=flat-square)](https://apple.com/mac)
[![Release: 0.2.0](https://img.shields.io/badge/release-v0.2.0-green.svg?style=flat-square)](https://github.com/ahmetaltun/Mimra/releases/tag/v0.2.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg?style=flat-square)](LICENSE)

---

## Why Mimra?

Most clipboard utilities either rely on heavy web wrappers (Electron), silently ship telemetry, or lack deep search and multi-representation fidelity. Mimra is engineered natively from the ground up:

- **100% On-Device & Privacy-Preserving**: Zero telemetry, zero analytics, and zero network calls. Password managers (1Password, Bitwarden, KeePassXC, macOS Keychain) and confidential markers (`org.nspasteboard.ConcealedType`) are rejected in memory before reaching storage or disk.
- **Native Apple Silicon Speed**: Built with SwiftUI and AppKit on the front end, bound directly to a statically linked Rust engine (`mimra-core`) via a zero-cost UniFFI C-ABI.
- **Embedded SQLite & FTS5 Search**: Instant full-text search, bounded regular expressions, and fuzzy matching with recency scoring—indexed locally in SQLite with WAL journaling.
- **Slideout Preview & On-Device OCR**: Inspect rich text, HTML, and high-resolution images side-by-side with full-screen preview. On-device text recognition via Apple's Vision framework enables searching and copying text directly from images without external APIs.
- **Keyboard-Centric Workflow**: Summon history instantly with `Command+Shift+C`, navigate with arrow keys or vim-style shortcuts, quick-pick items 1–9, cycle paste, and manage pinned items with custom shortcut triggers.

---

## System Requirements

- **Operating System**: macOS 15.0 (Sequoia) or later.
- **Hardware**: Apple Silicon Mac (M1, M2, M3, M4 or newer; `arm64`). Intel (`x86_64`) architecture is not supported.
- **Permissions**: macOS Accessibility permission is required for auto-paste into active applications (Mimra falls back to copy-to-clipboard if permission is not granted).

---

## Installation

### Pre-built DMG Installer

1. Download the latest **`Mimra.dmg`** from [GitHub Releases](https://github.com/ahmetaltun/Mimra/releases/latest).
2. Open the downloaded disk image and drag **`Mimra.app`** into your **`Applications`** folder.
3. Launch Mimra. On first launch, follow the onboarding prompt to grant Accessibility permissions for auto-paste support.

---

## Quick Start

- **Summon History**: Press <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>C</kbd> (or click the Mimra icon in your menu bar).
- **Search**: Type to search across text, rich content, and OCR-scanned image text.
- **Paste**: Press <kbd>Return</kbd> to paste into your active application, or press <kbd>⌘</kbd> <kbd>C</kbd> to copy to clipboard without pasting.
- **Plain Text Paste**: Press <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>Return</kbd> to paste stripped of formatting.
- **Toggle Preview**: Press <kbd>⌃</kbd> <kbd>Space</kbd> (or <kbd>Space</kbd> when search is empty) to expand the slideout preview pane.
- **Pin Items**: Press <kbd>⌥</kbd> <kbd>P</kbd> to pin or unpin an item. Pinned items are protected from history eviction.
- **Cycle Mode**: Repeatedly tap <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>C</kbd> while holding modifiers to traverse recent items; release to paste.

---

## Architecture

Mimra maintains strict architectural boundaries between its native UI shell and its data core:

```
┌────────────────────────────────────────────────────────┐
│              macOS Desktop / Active Apps               │
└───────────────────────────▲────────────────────────────┘
                            │ Paste / Focus Return
┌───────────────────────────┴────────────────────────────┐
│              SwiftUI / AppKit UI Layer                 │
│  - NSStatusItem (Menu Bar)    - FloatingPanel (NSPanel)│
│  - Slideout Preview Window    - Settings & Onboarding  │
│  - Privacy Filter (Pre-check) - Hotkey & Auto-Paste    │
└───────────────────────────▲────────────────────────────┘
                            │ Non-blocking Off-Main C-ABI
┌───────────────────────────▼────────────────────────────┐
│                UniFFI Bridge Interface                 │
└───────────────────────────▲────────────────────────────┘
                            │ Synchronous Calls
┌───────────────────────────▼────────────────────────────┐
│                RustCore (`mimra-core`)                 │
│  - BLAKE3 Deduplication       - NFC Normalization      │
│  - SQLite Embedded Engine     - FTS5 Full-Text Search  │
│  - Bounded Regex & Fuzzy Rank - WAL Retention Cleaner  │
└────────────────────────────────────────────────────────┘
```

1. **SwiftUI / AppKit**: Intercepts pasteboard change events, renders the floating window, manages status items, handles keyboard events, and simulates paste keystrokes via `CGEventPost`.
2. **UniFFI Layer**: Exposes strongly typed Rust functions to Swift without manual C header boilerplate. UniFFI functions are invoked exclusively from off-main background actors.
3. **RustCore**: Statically linked static library (`libmimra_core.a`). Manages SQLite with bundled FTS5, BLAKE3 deduplication hashes, and retention pruning.

---

## Building from Source

### Prerequisites

Ensure your development environment meets the requirements:
- Xcode 16.0+ with Command Line Tools
- Rust 1.80+ with `aarch64-apple-darwin` target:
  ```sh
  rustup target add aarch64-apple-darwin
  ```

Validate your host environment:
```sh
./scripts/check-env.sh
```

### Build Commands

Mimra provides verified shell scripts to automate compilation:

```sh
# 1. Compile Rust static library (libmimra_core.a)
./scripts/build-rust.sh debug

# 2. Generate Swift UniFFI bindings
./scripts/generate-bindings.sh

# 3. Build Mimra.app with Xcode
./scripts/build-app.sh debug

# 4. (Optional) Build Drag-to-Applications DMG installer
./scripts/build-dmg.sh
```

The compiled application bundle will be staged at `build/Mimra.app`.

---

## Testing & Quality Assurance

To execute the complete automated test suite (Rust unit tests, clippy, formatting, Swift UniFFI integration, privacy filters, and regression suites):

```sh
./scripts/test-all.sh
```

---

## Documentation Index

- [Architecture & Master Plan](MIMRA_MASTER_PLAN.md): Complete engineering specification and design roadmap.
- [Architectural Decisions](docs/DECISIONS.md): Comprehensive log of 68 ADRs documenting key technical choices.
- [Project Status & Roadmap](docs/STATUS.md): Task trackers across all development milestones (Phases 0–9).
- [Threat Model](docs/THREAT_MODEL.md): STRIDE threat assessment, boundary definitions, and privacy mitigations.
- [Paste Regression Matrix](docs/PASTE_REGRESSION_MATRIX.md): Cross-application compatibility testing records.
- [Contributing Guide](CONTRIBUTING.md): Setup, coding standards, quality gates, and PR guidelines.
- [Security Policy](SECURITY.md): Private vulnerability reporting route.
- [Privacy Policy](PRIVACY.md): On-device storage details and data handling principles.
- [Changelog](CHANGELOG.md): Version history and release notes.

---

## License

Mimra is licensed under the [MIT License](LICENSE).
Copyright &copy; 2026 Mimra Contributors.
