# Mimra — Project Status & Roadmap Tracker

> **Active Milestone:** Gate G6 Completed — Entering Phase 9 (Packaging & CI)  
> **Last Updated:** 2026-11-04  
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
| **G4** | History Power Features | **COMPLETED** | Fuzzy/regex search, pinning, retention cleanup, settings UI |
| **G5** | Core Feature Parity | **COMPLETED** | Slideout preview, OCR, cycle summon, VoiceOver, localization, full settings |
| **G6** | Release Hardening | **COMPLETED** | Leaks, benchmarks, fuzzing, recovery, and parity signed off |
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
| **P4-07** | Failure recovery: low disk, corrupt db, bad migration, full capacity, relaunch and backup recoverability | Completed | `RustCore/src/storage/recovery.rs`, `RustCore/src/lib.rs`, `RustCore/src/error.rs`, `Mimra/Bridge/CoreClient.swift`, `Mimra/UI/Settings/SettingsView.swift`, `Mimra/App/AppDelegate.swift` (`tests/failure_recovery_tests.swift`, `T-DB-01`, `F-052`, `F-055`) |

---

## 8. Phase 5 Task Tracker (Gate G4/G5)

| Task ID | Description | Status | Verification / Artifact |
|---|---|---|---|
| **P5-01** | Pins: pin/unpin, stable pinned section and shortcuts, eviction protection | Completed | `RustCore/src/storage/repository.rs`, `RustCore/src/lib.rs`, `Mimra/Bridge/CoreClient.swift`, `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Panel/FloatingPanelView.swift` (`tests/pin_tests.swift`, `T-PIN-01`, `T-HIST-03`, `T-KEY-01`, `F-020`, `F-024`, `F-036`, `F-053`) |
| **P5-02** | Pin shortcut assignment: enforce unique bindings and reserved key conflicts; permit punctuation keys in 2.8 | Completed | `RustCore/src/storage/repository.rs`, `RustCore/src/error.rs`, `RustCore/src/lib.rs`, `Mimra/Bridge/CoreClient.swift`, `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Panel/FloatingPanelView.swift` (`tests/pin_shortcut_assignment_tests.swift`, `T-PIN-01`, `F-024`) |
| **P5-03** | Pin reorder: drag-and-drop persistence, keyboard accessibility alternative | Completed | `RustCore/src/storage/repository.rs`, `RustCore/src/lib.rs`, `Mimra/Bridge/CoreClient.swift`, `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Panel/FloatingPanelView.swift` (`tests/pin_reorder_tests.swift`, `T-PIN-03`, `F-046`) |
| **P5-04** | Edit pin: editable text representation in preview; safe update of search index and retained pin ID | Completed | `RustCore/src/storage/repository.rs`, `RustCore/src/lib.rs`, `Mimra/Bridge/CoreClient.swift`, `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Panel/FloatingPanelView.swift` (`tests/pin_edit_tests.swift`, `T-PIN-02`, `F-045`) |
| **P5-05** | Quick pick: 1–9 with modifiers for copy/paste/plain; capacity/boundary cases | Completed | `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/UI/Panel/FloatingPanelView.swift` (`tests/quick_pick_tests.swift`, `T-KEY-01`, `F-022`) |
| **P5-06** | Cycle mode: repeat summon key while holding modifiers, release commits; cancel on Escape/focus loss | Completed | `Mimra/macOS/HotkeyManager.swift`, `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/App/AppDelegate.swift`, `Mimra/UI/Settings/SettingsView.swift` (`tests/cycle_mode_tests.swift`, `T-KEY-02`, `T-KEY-04`, `F-023`, `F-031`) |
| **P5-07** | Nav semantics: Page Up/Down, selection following delete, pinned-only row, separator consistency | Completed | `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/UI/Panel/FloatingPanelView.swift`, `Mimra/UI/Panel/FloatingPanel.swift` (`tests/nav_semantics_tests.swift`, `T-KEY-03`, `T-UI-10`, `F-030`, `F-036`) |

---

## 9. Phase 6 Task Tracker (Gate G5)

| Task ID | Description | Status | Verification / Artifact |
|---|---|---|---|
| **P6-01** | Slideout preview: text/image panel attached to history, width and bounds; close doesn't intercept mouse | Completed | `Mimra/UI/Preview/PreviewBoundsCalculator.swift`, `Mimra/UI/Preview/PreviewPanel.swift`, `Mimra/UI/Preview/PreviewContainerView.swift`, `Mimra/UI/Preview/PreviewCoordinator.swift`, `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Panel/PanelViewModel.swift` (`tests/preview_panel_tests.swift`, `T-PREV-01`, `F-039`) |
| **P6-02** | Preview shortcuts/settings: Control-Space toggle; auto-open/delay; only local shortcut, not global registration | Completed | `Mimra/UI/Preview/PreviewCoordinator.swift`, `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Settings/SettingsView.swift` (`tests/preview_settings_tests.swift`, `T-PREV-02`, `F-040`) |
| **P6-03** | Text preview: native efficient `NSTextView` for long content and accessibility selection | Completed | `Mimra/UI/Preview/NativeTextPreviewView.swift`, `Mimra/UI/Preview/PreviewContainerView.swift` (`tests/text_preview_tests.swift`, `T-PREV-03`, `F-041`) |
| **P6-04** | Image preview: aspect ratio, HEIC, dimensions and image-byte size; cached scaling | Completed | `Mimra/UI/Preview/ImagePreviewService.swift`, `Mimra/UI/Preview/ImagePreviewView.swift`, `Mimra/UI/Preview/PreviewContainerView.swift` (`tests/image_preview_tests.swift`, `T-PREV-04`, `F-042`) |
| **P6-05** | OCR service: Vision recognition on background queue, automatic language detection | Completed | `Mimra/macOS/OCRService.swift`, `RustCore/src/storage/repository.rs`, `RustCore/src/storage/search.rs`, `RustCore/src/lib.rs`, `Mimra/Bridge/CoreClient.swift`, `Mimra/macOS/ClipboardMonitor.swift` (`tests/ocr_service_tests.swift`, `T-OCR-01`, `F-043`) |
| **P6-06** | OCR results: searchable image text, copy OCR button, loading/failed states; no network call | Completed | `Mimra/UI/Preview/ImagePreviewView.swift`, `RustCore/src/storage/repository.rs`, `RustCore/src/storage/search.rs`, `Mimra/macOS/OCRService.swift`, `tests/ocr_results_tests.swift` (`T-OCR-02`, `F-044`) |
| **P6-07** | Race protection: delete/clear while OCR pending; stale callbacks must never resurrect deleted items | Completed | `RustCore/src/storage/search.rs`, `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/macOS/StatusBarCoordinator.swift`, `Mimra/UI/Settings/SettingsView.swift`, `tests/ocr_race_protection_tests.swift` (`T-PREV-02`, `T-SRCH-04`, `F-040`) |

---

## 10. Phase 7 Task Tracker (Gate G5)

| Task ID | Description | Status | Verification / Artifact |
|---|---|---|---|
| **P7-01** | General: paste mode, launch-at-login with `SMAppService.mainApp`, play sound on copy and paste, clear system clipboard if enabled | Completed | `Mimra/macOS/LaunchAtLoginService.swift`, `Mimra/macOS/SoundFeedbackService.swift`, `Mimra/UI/Settings/SettingsView.swift`, `Mimra/macOS/PasteCoordinator.swift`, `Mimra/macOS/StatusBarCoordinator.swift`, `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/macOS/ClipboardMonitor.swift`, `RustCore/src/domain/item.rs` (`tests/general_settings_tests.swift`, `tests/file_url_tests.swift`, `T-SET-01`, `T-REL-01`, `T-TYPE-03`, `F-005`, `F-020`, `F-035`, `F-056`, `F-062`, `F-064`, ADR-058) |
| **P7-02** | Appearance: title/search/footer/icon, source app icon, HEX swatches, sizing/position/screen, light/dark, panel chrome/traffic-light removal, one-line compact history option | Completed | `Mimra/macOS/AppearanceConfiguration.swift`, `Mimra/macOS/StatusBarCoordinator.swift`, `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Panel/FloatingPanelView.swift`, `Mimra/UI/Preview/PreviewCoordinator.swift`, `Mimra/UI/Settings/SettingsView.swift` (`tests/appearance_settings_tests.swift`, `T-SET-03`, `T-UI-05`, `T-UI-07`, `T-UI-08`, `T-UI-09`, `F-028`, `F-032`, `F-034`, `F-035`, `F-058`, ADR-059) |
| **P7-03** | Search/Storage: search modes/highlight; allowed formats and count/size options, DB stats | Completed | `Mimra/UI/Settings/SettingsView.swift`, `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/macOS/ClipboardTypeConfiguration.swift`, `Mimra/macOS/ClipboardMonitor.swift` (`tests/search_storage_settings_tests.swift`, `T-SRCH-02`, `T-HIST-05`, `F-013`, `F-049`, `F-050`, `F-055`) |
| **P7-04** | Ignore/Privacy: app picker outside `/Applications`, UTI editing, pause/ignore-next; validation/confirmation | Completed | `Mimra/macOS/PrivacyFilter.swift`, `Mimra/macOS/PrivacyConfiguration.swift`, `Mimra/UI/Settings/SettingsView.swift`, `Mimra/macOS/ClipboardMonitor.swift` (`tests/privacy_settings_tests.swift`, `T-PRIV-02`, `T-PRIV-03`, `T-SET-02`, `F-009`, `F-010`, `F-057`) |
| **P7-05** | Hotkeys: record/change/reset, collision handling, physical key layout and secure input fallback | Completed | `Mimra/macOS/HotkeyConfiguration.swift`, `Mimra/macOS/HotkeyManager.swift`, `Mimra/UI/Settings/SettingsView.swift`, `Mimra/UI/Panel/FloatingPanel.swift` (`tests/hotkey_settings_tests.swift`, `T-KEY-02`, `F-023`) |
| **P7-06** | English + localization: string catalog, layout expansion, CJK input, RTL visual QA, one non-English full flow | Completed | `Mimra/macOS/LocalizationService.swift`, `Mimra/Resources/Localizable.xcstrings`, `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Settings/SettingsView.swift` (`tests/localization_ime_tests.swift`, `T-I18N-01`, `T-I18N-02`, `F-033`, `F-059`) |
| **P7-07** | VoiceOver: selected row item content/type/source/pin status; preview, buttons, menu and keyboard drag alternative | Completed | `Mimra/UI/Panel/FloatingPanelView.swift`, `Mimra/UI/Preview/PreviewContainerView.swift`, `Mimra/UI/Preview/ImagePreviewView.swift`, `Mimra/UI/Panel/FloatingPanel.swift` (`tests/voiceover_accessibility_tests.swift`, `T-A11Y-01`, `F-060`) |
| **P7-08** | Permissions/onboarding: explain continuous clipboard history, accessibility auto-paste, sensitive exclusions, privacy controls | Completed | `Mimra/macOS/OnboardingService.swift`, `Mimra/UI/Onboarding/OnboardingView.swift`, `Mimra/macOS/PasteCoordinator.swift`, `Mimra/macOS/AccessibilityService.swift`, `Mimra/App/AppDelegate.swift` (`tests/onboarding_permissions_tests.swift`, `T-PASTE-03`, `F-061`) |
| **P7-09** | Appearance accessibility: Reduce Motion, VoiceOver focus restoration, high contrast, menu bar over fullscreen | Completed | `Mimra/UI/Panel/FloatingPanelView.swift`, `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/UI/Onboarding/OnboardingView.swift`, `Mimra/macOS/AppearanceConfiguration.swift` (`tests/appearance_accessibility_tests.swift`, `T-UI-06`, `T-UI-08`, `F-029`, `F-034`) |

---

## 11. Phase 8 Task Tracker (Gate G6)

| Task ID | Description | Status | Verification / Artifact |
|---|---|---|---|
| **P8-01** | Leak/retention stress: memory graph + synthetic 50k churn + 0 orphan FK/FTS checks | Completed | `tests/leak_retention_stress_tests.swift`, `RustCore/src/storage/mod.rs` (`T-HIST-05`, `F-025`, `F-052`, `F-053`) |
| **P8-02** | Paste regression lab: Finder, Safari, Chrome, Notes, Pages, Terminal, IDE, Spotlight, RDC, Fullscreen | Completed | `tests/paste_regression_lab_tests.swift`, `docs/PASTE_REGRESSION_MATRIX.md` (`T-PASTE-01` to `T-PASTE-04`, `T-UI-06`, `F-001`, `F-002`, `F-020`, `F-021`, `F-029`) |
| **P8-03** | Layout regression: multi-monitor, disconnection, scaled displays, Stage Manager, IME, safe preview | Completed | `tests/layout_regression_tests.swift`, `Mimra/UI/Preview/PreviewBoundsCalculator.swift`, `Mimra/UI/Panel/FloatingPanel.swift` (`T-UI-06`, `T-UI-07`, `T-PREV-01`, `T-PREV-02`, `F-018`, `F-028`, `F-032`, `F-039`, `F-040`) |
| **P8-04** | Privacy audit: denied markers, deleted items, logs, permissions, caches, zero network review | Completed | `tests/privacy_audit_tests.swift`, `docs/THREAT_MODEL.md` (`T-PRIV-01` to `T-PRIV-06`, `F-008`, `F-009`, `F-010`, `F-014`, `F-015`, `F-026`, `F-057`) |
| **P8-05** | FFI fuzz/property tests: malformed sizes, invalid UTF-8, pathological regex, SQL injection | Completed | `RustCore/src/fuzz_tests.rs`, `tests/ffi_fuzz_property_tests.swift` (`T-FFI-01`, `T-SRCH-02`, `F-018`, `F-048`, `F-051`) |
| **P8-06** | Performance benchmarks: idle CPU/wakeups, memory, history summon, search, paste, thumbnails | Completed | `tests/performance_benchmarks.swift` (§10 Budgets verified on Apple Silicon: Ingest 0.44ms, Search 14.4ms, Summon 3.36ms, Idle poll 0.0006ms) |
| **P8-07** | Database recovery: crash resilience, WAL replay, corruption quarantine & salvage, clean resume | Completed | `tests/database_recovery_lab_tests.swift`, `RustCore/src/storage/recovery.rs` (`T-DB-01`, `T-HIST-02`, `F-052`, `F-055`) |
| **P8-08** | Parity signoff: revisit feature inventory | Completed | `MIMRA_MASTER_PLAN.md` (all 64 feature IDs and Gate G6 exit criteria signed off) |

---

## 12. Post-G6 Usability & Runtime Fixes

| Item | Description | Status | Verification / Artifact |
|---|---|---|---|
| **Fix 1** | Browser image copy classification, thumbnail display, and ImagePreviewView routing | Completed | `RustCore/src/domain/item.rs`, `Mimra/macOS/PasteCoordinator.swift`, `FloatingPanelView.swift`, `PreviewContainerView.swift` (`tests/user_issues_fixes_tests.swift`) |
| **Fix 2** | Preview shortcut triggers (`Control+Space`, `Option+Space`, `Command+Y`, empty-search `Space`) | Completed | `Mimra/UI/Panel/FloatingPanel.swift` (`tests/user_issues_fixes_tests.swift`) |
| **Fix 3** | Settings button in history window footer wired to `onSettingsRequested` | Completed | `Mimra/UI/Panel/FloatingPanel.swift` (`tests/user_issues_fixes_tests.swift`) |
| **Fix 4** | Maximum history item limit (solid 2,000 limit, configurable picker in Settings and dynamic query limit) | Completed | `Mimra/UI/Panel/PanelViewModel.swift`, `Mimra/UI/Settings/SettingsView.swift` (`tests/user_issues_fixes_tests.swift`) |
| **Fix 5** | Deletion keybinding isolation: `Option+Backspace` deletes item, `Command+Backspace` reserved for text editing | Completed | `Mimra/UI/Panel/FloatingPanel.swift` (`tests/user_issues_fixes_tests.swift`) |
| **Fix 6** | Remove accessibility warning from history window | Completed | `Mimra/UI/Panel/FloatingPanelView.swift` (ADR-056) |
| **Fix 7** | Increase history window default height by 40% (540 pt -> 756 pt) | Completed | `Mimra/macOS/AppearanceConfiguration.swift`, `FloatingPanelView.swift`, `SettingsView.swift` (ADR-056) |
| **Fix 8** | Slideout preview height set to always match history window height | Completed | `Mimra/UI/Preview/PreviewCoordinator.swift` (`tests/preview_settings_tests.swift`, ADR-056) |
| **Fix 9** | Fix preview window vertical scrolling (NSTextView sizing, minSize/maxSize, Option-Up/Down keys) | Completed | `Mimra/UI/Preview/NativeTextPreviewView.swift`, `FloatingPanel.swift` (`tests/preview_settings_tests.swift`, ADR-056) |
| **Fix 10** | Configurable preview display modes (Manual default, Immediate, Delayed with delay picker) | Completed | `Mimra/UI/Preview/PreviewCoordinator.swift`, `SettingsView.swift`, `FloatingPanel.swift` (`tests/preview_settings_tests.swift`, ADR-056) |
| **Fix 11** | Settings window focus retention & standard .normal window level (opens in front, yields on app switch) | Completed | `Mimra/UI/Panel/FloatingPanel.swift`, `Mimra/macOS/StatusBarCoordinator.swift` (`tests/status_bar_tests.swift`, ADR-057) |
| **Fix 12** | Settings window navigation redesign: modern 190 pt left-rail sidebar (eliminating tab bar overflow and >> chevrons) | Completed | `Mimra/UI/Settings/SettingsView.swift`, `Mimra/macOS/StatusBarCoordinator.swift` (`tests/status_bar_tests.swift`, ADR-057) |
| **Fix 13** | Move history item to top on selection / paste with configurable setting toggle | Completed | Rust storage `touch_item`, `Generated/mimra_core.swift`, `CoreClient.swift`, `PasteCoordinator.swift`, `PanelViewModel.swift`, `SettingsView.swift` (`tests/move_to_top_tests.swift`, ADR-060) |
| **Fix 14** | Deep clipboard content search & contextual excerpt highlighting (multi-line JSON, code, logs past 160 chars) | Completed | `RustCore/src/storage/search.rs`, `tests/fuzzy_search_tests.swift` (`test_search_deep_json_content_across_all_modes`, ADR-061) |
| **Fix 15** | End-to-end runtime search pipeline: debounced search trigger, core engine bypass fix, and 8,000+ char verification | Completed | `Mimra/UI/Panel/PanelViewModel.swift`, `FloatingPanelView.swift`, `tests/fuzzy_search_tests.swift` (Step 8, ADR-062) |
| **Fix 16** | Precision search: word-boundary acronym matching in fuzzy mode and elimination of false-positive body content matches | Completed | `RustCore/src/domain/search.rs`, `RustCore/src/storage/search.rs`, `tests/fuzzy_search_tests.swift` (`test_search_rejects_unrelated_items_in_fuzzy_mode`, ADR-063) |
| **Fix 17** | Dimension sliders live value reactivity, reset to defaults action, dynamic window & preview frame resizing, and settings window quit action | Completed | `Mimra/macOS/AppearanceConfiguration.swift`, `SettingsView.swift`, `FloatingPanel.swift`, `FloatingPanelView.swift`, `PreviewCoordinator.swift` (`tests/appearance_settings_tests.swift`, `tests/panel_tests.swift`, ADR-064) |

---

## 13. Current Blockers & Risks

* **None.** Phase 8 hardening and all post-G6 runtime usability fixes are 100% COMPLETED and verified. All 81 Rust unit and property tests, 63 Swift integration test suites, and native arm64 builds pass cleanly.
* **Next Milestone:** Phase 9 (Packaging, CI, Release and Maintenance: Developer ID, Notarization, Signed DMG, GitHub Actions CI workflow).
