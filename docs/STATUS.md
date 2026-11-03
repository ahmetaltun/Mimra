# Mimra — Project Status & Roadmap Tracker

> **Active Milestone:** Gate G3 — Complete Data Types (Phase 3)  
> **Last Updated:** 2026-11-03  
> **Target Environment:** macOS 15.0+ (`aarch64-apple-darwin`), Apple Silicon only

---

## 1. Verified Toolchain Environment

| Component | Pinned Version / Value | Verification Command | Verified Date |
|---|---|---|---|
| Architecture | `arm64` | `uname -m` | 2026-11-03 |
| OS Version | macOS 15.8.2 (Build 24H232) | `sw_vers` | 2026-11-03 |
| Rust Toolchain | `rustc 1.99.1 (58cf8f9c3 2026-10-13)` | `rustc -V` | 2026-11-03 |
| Cargo | `cargo 1.99.1 (5f94df478 2026-08-27)` | `cargo -V` | 2026-11-03 |
| Xcode | Xcode 26.3 (Build 17C529) | `xcodebuild -version` | 2026-11-03 |
| Swift | Swift 6.2.4 (`arm64-apple-macosx15.0`) | `swift --version` | 2026-11-03 |
| Rustup Target | `aarch64-apple-darwin` | `rustup target list --installed` | 2026-11-03 |

---

## 2. Phase 0 Task Tracker (Gate G0)

| Task ID | Description | Status | Verification / Artifact |
|---|---|---|---|
| **P0-01** | Reference audit: Create `MIMRA_MASTER_PLAN.md` and classify matrix | Completed | `MIMRA_MASTER_PLAN.md` |
| **P0-02** | Developer environment: Create `scripts/check-env.sh` with explanatory diagnostics | Completed | [scripts/check-env.sh](../scripts/check-env.sh) |
| **P0-03** | Xcode shell: Create `Mimra` menubar app (`LSUIElement=true`, AppKit delegate, SwiftUI Settings) | Completed | [Mimra.xcodeproj](../Mimra.xcodeproj) |
| **P0-04** | Rust crate: Initialize `RustCore` as staticlib with dependencies | Completed | [RustCore/Cargo.toml](../RustCore/Cargo.toml) |
| **P0-05** | UniFFI spike: Expose `core_version()` and `fingerprint()`, test Swift↔Rust bridge | Completed | [tests/ffi_spike.swift](../tests/ffi_spike.swift) |
| **P0-06** | Docs/automation: Add `AGENTS.md`, status/ADRs, CI scripts, third-party notices | Completed | Repository root |
| **P0-07** | Policy/permissions spike: Audit macOS 15/26 Accessibility & Hotkey requirements | Completed | [docs/DECISIONS.md](DECISIONS.md) (ADR-008) |

---

## 3. Milestones & Gates Overview

| Gate | Name | Status | Exit Condition |
|---|---|---|---|
| **G0** | Clean Native + Rust Build | **COMPLETED** | arm64 app launches, Rust static library invoked from Swift, all ADRs recorded |
| **G1** | Safe Capture Engine | **COMPLETED** | Privacy filters, text capture, persistence, zero secret-marker leaks |
| **G2** | Reliable Copy / Paste | **COMPLETED** | NSPanel popup, focus restoration, global shortcut, accessibility fallback |
| **G3** | Complete Data Types | **COMPLETED** | RTF, HTML, PNG/JPEG/HEIC, file URLs, URLs/colors, attribution, dedupe hardening, type settings |
| **G4** | History Power Features | IN PROGRESS | Fuzzy/regex search, pinning, retention cleanup, settings UI |
| **G5** | Core Feature Parity | PENDING | Slideout preview, OCR, cycle summon, VoiceOver, localization |
| **G6** | Release Hardening | PENDING | Leaks, benchmarks, fuzzing, notarized arm64 distribution |
| **G7** | Mimra Differentiators | PENDING | Privacy profiles, secret heuristics, encrypted vault (SQLCipher) |

---

## 4. Phase 1 Task Tracker (Gate G1)

| Task ID | Description | Status | Verification / Artifact |
|---|---|---|---|
| **P1-01** | Rust domain models: Representations, UUIDs, timestamps, size limits, NFC normalization | Completed | [RustCore/src/domain/](../RustCore/src/domain/) (12 passing tests) |
| **P1-02** | SQLite migrations: Normalized tables, content representations, indexes and FTS5 | Completed | [RustCore/src/storage/](../RustCore/src/storage/) (16 passing tests) |
| **P1-03** | Core ingestion: Transactional insert, dedupe, recopy timestamps, pin preservation | Completed | [RustCore/src/storage/repository.rs](../RustCore/src/storage/repository.rs) (18 passing tests) |
| **P1-04** | Rust repository API: list-page, fetch, delete, clear, stats, retention with error codes | Completed | [RustCore/src/storage/repository.rs](../RustCore/src/storage/repository.rs) (22 passing tests) |
| **P1-05** | Clipboard reader: `changeCount` polling, lifecycle, snapshots, allowlist supported UTIs | Completed | `Mimra/macOS/ClipboardMonitor.swift`, `Mimra/Bridge/CoreClient.swift` (`tests/capture_pipeline_tests.swift`) |
| **P1-06** | Privacy prefilter: Mandatory deny markers, user UTI deny, ignored apps, pause/ignore-next | Completed | `Mimra/macOS/PrivacyFilter.swift` (`tests/privacy_filter_tests.swift`) |
| **P1-07** | Self-recapture protection: Provenance marker, sync `changeCount`, loop guard | Completed | `Mimra/macOS/ClipboardProvenance.swift` (`tests/provenance_tests.swift`) |
| **P1-08** | Persistence UI stub: Display recent text entries and survive relaunch | Completed | `Mimra/UI/History/HistoryView.swift` (`tests/persistence_relaunch_tests.swift`) |

---

## 5. Phase 2 Task Tracker (Gate G2)

| Task ID | Description | Status | Verification / Artifact |
|---|---|---|---|
| **P2-01** | Panel: Resizable native `NSPanel` with SwiftUI list, text input, empty state | Completed | `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Panel/FloatingPanelView.swift` (`tests/panel_tests.swift`, `T-UI-02`) |
| **P2-02** | Hotkey: Carbon `RegisterEventHotKey` global summon without keylogger permissions | Completed | `Mimra/macOS/HotkeyManager.swift` (`tests/hotkey_tests.swift`, `T-UI-01`, `T-KEY-02`) |
| **P2-03** | Status item menu: Actions, pause toggle, ignore next copy, clear, settings | Completed | `Mimra/macOS/StatusBarCoordinator.swift` (`tests/status_bar_tests.swift`, `T-UI-01`, `T-HIST-01`, `T-PRIV-06`) |
| **P2-04** | Search interaction: Keyboard arrows, Return, Escape, selection state | Completed | `Mimra/UI/Panel/` (`tests/search_interaction_tests.swift`, `T-UI-03`) |
| **P2-05** | Replay codec: Reconstruct valid NSPasteboard items from typed payloads with provenance | Completed | `Mimra/macOS/PasteCoordinator.swift` (`tests/paste_replay_tests.swift`, `T-PASTE-01`, `T-PASTE-02`, `T-CAP-05`) |
| **P2-06** | Auto-paste: Focus tracking and `CGEventPost` Command-V paste | Completed | `Mimra/macOS/PasteCoordinator.swift` (`tests/auto_paste_tests.swift`, `T-PASTE-01`, `T-PASTE-02`) |
| **P2-07** | Copy-only fallback: Graceful degradation when Accessibility permission is denied | Completed | `Mimra/macOS/AccessibilityService.swift` (`tests/accessibility_tests.swift`, `T-PASTE-01`, `T-UI-04`) |
| **P2-08** | Plain paste: Option-Shift-Return & Shift-Return strip formatting shortcut | Completed | `Mimra/macOS/PasteCoordinator.swift` (`tests/plain_paste_tests.swift`, `T-PASTE-03`) |
| **P2-09** | Paste error handling: App exited, secure input, password field guards | Completed | `Mimra/macOS/PasteCoordinator.swift` (`tests/paste_error_tests.swift`, `T-PASTE-04`) |

---

## 6. Phase 3 Task Tracker (Gate G3)

| Task ID | Description | Status | Verification / Artifact |
|---|---|---|---|
| **P3-01** | HTML/RTF: multi-representation capture & replay fidelity | Completed | `Mimra/macOS/ClipboardMonitor.swift`, `Mimra/macOS/PasteCoordinator.swift`, `RustCore/src/domain/item.rs` (`tests/rich_text_tests.swift`, `T-TYPE-01`, `F-003`, `F-007`, `F-021`) |
| **P3-02** | Images: allowlisted PNG/TIFF/JPEG/HEIC; lazy decode and thumbnail cache with memory limits | Completed | `Mimra/macOS/ImageThumbnailService.swift`, `Mimra/UI/Panel/FloatingPanelView.swift`, `RustCore/src/domain/item.rs` (`tests/image_type_tests.swift`, `T-TYPE-02`, `F-004`) |
| **P3-03** | File references: capture one/multiple file URLs; preserve identity and order; define vanished-file UX | Completed | `Mimra/macOS/ClipboardMonitor.swift`, `Mimra/macOS/PasteCoordinator.swift`, `Mimra/UI/Panel/FloatingPanelView.swift`, `RustCore/src/domain/item.rs` (`tests/file_url_tests.swift`, `T-TYPE-03`, `F-005`, `F-021`) |
| **P3-04** | URLs/colors: detection, click-safe preview, HEX swatch toggle; text remains primary | Completed | `Mimra/UI/Panel/ColorAndUrlPreview.swift`, `Mimra/UI/Panel/FloatingPanelView.swift`, `RustCore/src/domain/color.rs`, `RustCore/src/domain/url_utils.rs` (`tests/url_color_tests.swift`, `T-TYPE-04`, `T-TYPE-06`, `F-006`, `F-037`) |
| **P3-05** | Source attribution: bundle ID/icon via Workspace and `org.nspasteboard.source` marker | Completed | `Mimra/macOS/AppIconService.swift`, `Mimra/macOS/ClipboardMonitor.swift`, `Mimra/UI/Panel/FloatingPanelView.swift`, `Mimra/UI/Settings/SettingsView.swift` (`tests/source_attribution_tests.swift`, `T-CAP-04`, `F-011`, `F-016`) |
| **P3-06** | Dedupe hardening: Safari, Sheets, VS Code, Notes, MS Office, multi-representation copies | Completed | `RustCore/src/domain/item.rs`, `RustCore/src/storage/repository.rs`, `Mimra/macOS/ClipboardMonitor.swift` (`tests/dedupe_hardening_tests.swift`, `T-CAP-05`, `F-012`) |
| **P3-07** | Type settings: types enabled/disabled without storing unknown private payloads | Completed | `Mimra/macOS/ClipboardTypeConfiguration.swift`, `Mimra/macOS/PrivacyFilter.swift`, `Mimra/macOS/ClipboardMonitor.swift`, `Mimra/UI/Settings/SettingsView.swift` (`tests/type_settings_tests.swift`, `T-TYPE-05`, `F-013`, `F-015`) |

---

## 7. Phase 4 Task Tracker (Gate G4)

| Task ID | Description | Status | Verification / Artifact |
|---|---|---|---|
| **P4-01** | Search index: maintain Rust FTS5 and transactional index triggers; paginate | Completed | `RustCore/src/storage/search.rs`, `RustCore/src/lib.rs`, `Mimra/Bridge/CoreClient.swift`, `Mimra/UI/Panel/PanelViewModel.swift` (`tests/search_index_tests.swift`, `T-SRCH-01`, `F-019`, `F-048`) |
| **P4-02** | Fuzzy/mixed mode: deterministic ranker plus recency boosts, Unicode-aware highlight ranges | Completed | `RustCore/src/domain/search.rs`, `RustCore/src/storage/search.rs`, `Mimra/Bridge/CoreClient.swift`, `Mimra/UI/Panel/FloatingPanelView.swift` (`tests/fuzzy_search_tests.swift`, `T-SRCH-01`, `F-019`, `F-048`) |
| **P4-03** | Exact/regex modes: configurable modes, Rust bounded regex and error feedback; cancel stale search | Completed | `RustCore/src/domain/search.rs`, `RustCore/src/storage/search.rs`, `RustCore/src/error.rs`, `Mimra/Bridge/CoreClient.swift`, `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/UI/Panel/FloatingPanelView.swift` (`tests/regex_search_tests.swift`, `T-SRCH-02`, `F-048`) |
| **P4-04** | Sorting/highlights: pinned arrangement, recency, relevance and highlight styles | Completed | `RustCore/src/storage/repository.rs`, `RustCore/src/storage/search.rs`, `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/UI/Panel/FloatingPanelView.swift`, `Mimra/UI/Settings/SettingsView.swift` (`tests/sorting_highlight_tests.swift`, `T-UI-03`, `T-KEY-03`, `F-019`, `F-024`) |
| **P4-05** | History limit: count/age/size retention and clear, preserve pins | Completed | `RustCore/src/storage/repository.rs`, `RustCore/src/domain/dto.rs`, `RustCore/src/lib.rs`, `Mimra/Bridge/CoreClient.swift` (`tests/history_limit_tests.swift`, `T-HIST-01`, `T-HIST-03`, `T-HIST-05`, `F-025`, `F-052`, `F-053`) |
| **P4-06** | Storage UI: DB size/limits/types/clear-unpinned/clear-all and confirmation | Completed | `Mimra/UI/Settings/SettingsView.swift`, `Mimra/Bridge/CoreClient.swift`, `Mimra/macOS/StatusBarCoordinator.swift` (`tests/storage_ui_tests.swift`, `T-HIST-01`, `T-HIST-05`, `F-025`, `F-055`) |
| **P4-07** | Failure recovery: low disk, corrupt db, bad migration, full capacity, relaunch and backup recoverability | Pending | Scheduled next (`T-DB-01`) |

---

## 8. Current Blockers & Risks

* **None.** Gate G4 Tasks P4-01 through P4-06 are 100% complete and verified across Rust, Swift, and Xcode.
* **Next Task:** P4-07 (Failure recovery: low disk, corrupt db, bad migration, full capacity, relaunch and backup recoverability, `T-DB-01`).
