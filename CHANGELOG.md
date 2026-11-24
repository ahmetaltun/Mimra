# Changelog

All notable user-facing and architectural changes to Mimra are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.3.0] - 2026-11-24

### Added
- **Enhanced Slideout Preview — Interactive Image Canvas, Native Formatters & Rich Inspectors (ADR-073)**:
  - Interactive image zoom and pan canvas (`InteractiveImageCanvasView`) with high-resolution 4K zoom clarity (`maxPixelSize: 3840`) and Save Image As action.
  - Automatic text format detection (`TextFormatDetector`) and native formatters (`TextFormatters`) for JSON, Markdown, code, HTML, and RTF previews.
  - Rich inspector cards (`PreviewInspectorCards`) for color swatches/formats and URL query parameter inspection.
  - Dedicated file preview (`FilePreviewView`) with Finder metadata, Reveal in Finder, and inline text/image preview.
  - Contextual preview footer actions (Paste, Paste Plain, Edit Pin, Save Image As).

### Fixed & Improved
- **Adaptive Preview Debounce & Decoded Payload Caching**:
  - Gated the 70 ms preview debounce on rapid key-repeat navigation (`< 150 ms`) so intentional opens and single-step moves load immediately while fast scrubbing stays smooth.
  - Added a bounded `NSCache`-backed `PreviewContentCache` for text, formatted, and file previews keyed by item ID, byte size, and snippet hash for instant revisits and automatic invalidation on edits.
  - Offloaded HTML rendering, `ColorDetector`, `UrlDetector`, text formatting, Vision OCR (with 300 ms debounce and cancellation), image decoding, and file metadata I/O from `@MainActor` to background tasks.
  - Added explicit `shadowPath` on the image canvas layer to avoid offscreen alpha shadow passes.
- **Preview & Search Navigation Fixes**:
  - Synchronized the slideout preview window when the currently selected item is deleted.
  - Reset selection to index 0 and scrolled to top whenever the search query changes so users can immediately commit the top match with Return, while preserving selection on same-query background refreshes.
- **Settings Window Z-Order & History Panel Performance (ADR-071, ADR-072)**:
  - Fixed an AppKit focus-restoration re-entrancy bug where opening Settings from the floating panel could push `Mimra Settings` behind other application windows.
  - Replaced forced `.center` animated scrolling with natural un-anchored viewport scrolling (`keyboardScrollGeneration`), conformed `PanelItemRow` to `Equatable`, cached filtered items and section divider indices, and served cached app icons/thumbnails synchronously on first render.

## [0.2.0] - 2026-11-13

### Added
- **Sparkle 2 Software Update Integration (P9-05 / ADR-068)**:
  - Native, seamless in-app software update flow powered by Sparkle 2.10.1.
  - Dedicated "Updates" category in Settings (`UpdatesSettingsTab`) with automatic check toggle, check frequency options (daily, weekly, monthly), and on-demand check button.
  - "Check for Updates..." item in the menu bar status context menu.
  - Automated Ed25519 cryptographic feed verification and release appcast generation (`scripts/generate-appcast.sh`).
  - Strict zero-telemetry enforcement with anonymous update queries, system profiling disabled (`SUEnableSystemProfiling = false`), and no background analytics (`SUSendProfileInfo = false`).
- **Complete Public Documentation Suite & MIT Licensing**:
  - MIT License established in `LICENSE` and crate manifests.
  - Audience-first `README.md` covering architecture, keybindings, build scripts, and system requirements.
  - Transparent `PRIVACY.md` detailing 100% on-device SQLite storage, zero telemetry, and password manager suppression.
  - Private vulnerability reporting policies in `SECURITY.md` backed by STRIDE threat modeling.
  - Contributor workflows and code style guidelines in `CONTRIBUTING.md`.

### Fixed & Improved
- **History Retention Limit 2,000 Items Synchronization (Fix 19 / ADR-069)**:
  - Resolved an issue where cold launches reverted the Rust storage engine to a 200-item cap, evicting items 201–2,000.
  - Added startup synchronization in `CoreClient` to restore persisted retention limits from `UserDefaults` on launch.
  - Unified application lifecycle around a single `CoreClient.shared` instance, eliminating desynchronized engine handles between `ClipboardMonitor` and Settings.
  - Injected `StorageSettingsViewModel` into `GeneralSettingsTab` as a single source of truth, preventing cross-tab state overwrites.
  - Dynamically expanded search candidate scan limits in `RustCore` to support full-corpus matching up to 2,000 items.
- **Pure Static Linkage & Sparkle Startup Sequencing**:
  - Enforced pure static linkage for `RustCore` via `libmimra_core.a`, eliminating dynamic library dependencies from the `Mimra.app` bundle.
  - Corrected Sparkle framework initialization sequence during application startup.
- **Premium DMG Packaging Layout & Retina Alignment (ADR-067 / P9-04)**:
  - Corrected Retina 2x scale blow-up, coordinate inversions, and Finder icon alignment in `scripts/render_dmg_background.swift`.
  - Enforced invisible staging for `.background` directory (`chflags hidden`, `SetFile -a V`) and eliminated accidental horizontal scrollbars.
- **Swift 6 Strict Concurrency Hardening**:
  - Resolved Swift 6 `@_nonSendable(_assumed)` warnings and errors for AppKit `NSImage` under Xcode 16.4 / macOS 15.
  - Refactored `ImageThumbnailService` and `AppIconService` to `@MainActor`, introducing a thread-safe `SendableImage` wrapper for concurrent decoding.
- **CI/CD Release Pipeline Hardening**:
  - Pinned GitHub Actions release runner to `macos-15` (Apple Silicon).
  - Hardened Apple Developer ID certificate decoding and introduced OpenSSL legacy PKCS#12 export fallback for reliable keychain imports.

## [0.1.0] - 2026-11-06

Initial public release of Mimra — a minimal, premium, privacy-first clipboard manager for macOS on Apple Silicon.

### Added
- **Native SwiftUI + AppKit User Interface**: Fast, lightweight menu bar application (`LSUIElement`) with a keyboard-driven floating search panel.
- **Privacy-First Ingestion Engine**:
  - Automatic filtering and immediate drop of sensitive copies from password managers (1Password, Bitwarden, KeePassXC, macOS Keychain).
  - Memory-level suppression of macOS confidential and auto-generated markers (`org.nspasteboard.ConcealedType`, `org.nspasteboard.AutoGeneratedType`).
  - Strict zero-telemetry guarantee and 100% on-device local storage.
- **Embedded Rust Storage & Search Core (`mimra-core`)**:
  - SQLite storage with WAL journaling and FTS5 full-text indexing.
  - BLAKE3 cryptographic content hashing for zero-duplicate storage.
  - Configurable search modes: Exact substring, Fuzzy with recency boosts, and bounded Regex.
- **Multi-Representation Clipboard Support**:
  - Full-fidelity capture and replay for plain text (NFC normalized), Rich Text (RTF), HTML, and file URLs.
  - Image capture (PNG, TIFF, JPEG, HEIC) with thumbnail generation and aspect-ratio preservation.
  - Color detection with interactive HEX color swatch indicators.
  - Source application attribution with bundle identifier and app icon caching.
- **Slideout Preview & On-Device OCR**:
  - Dynamic slideout preview window supporting large scrollable text documents and high-resolution images.
  - Local text recognition (OCR) via Apple's Vision framework with one-click copy and searchable image text.
- **Pin Management & Power Navigation**:
  - Pin items to top with eviction protection.
  - Custom pin shortcut keybindings (letters, digits, and punctuation).
  - Drag-and-drop pin reordering with accessible keyboard alternative.
  - Quick-pick numeric shortcuts (1–9) with modifier keys.
  - Sequential cycle mode summoning (`Command+Shift+C`).
- **Packaging & Delivery**:
  - Official multi-resolution macOS application icon.
  - Premium 720×460 Retina drag-to-Applications DMG installer.
  - Sparkle 2 software update integration with Ed25519 cryptographic feed verification.
  - GitHub Actions CI/CD release workflow with Hardened Runtime and Apple notarization support.

[0.3.0]: https://github.com/ahmetaltun/Mimra/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ahmetaltun/Mimra/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ahmetaltun/Mimra/releases/tag/v0.1.0
