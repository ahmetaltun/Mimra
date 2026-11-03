# Mimra — Project Status & Roadmap Tracker

> **Active Milestone:** Gate G2 — Reliable Copy / Paste (Phase 2)  
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
| **G2** | Reliable Copy / Paste | **IN PROGRESS** | NSPanel popup, focus restoration, global shortcut, accessibility fallback |
| **G3** | Complete Data Types | PENDING | RTF, HTML, PNG/JPEG/HEIC, file URLs with full round-trip fidelity |
| **G4** | History Power Features | PENDING | Fuzzy/regex search, pinning, retention cleanup, settings UI |
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
| **P2-01** | Panel: Resizable native `NSPanel` with SwiftUI list, text input, empty state | Planned | `Mimra/UI/Panel/FloatingPanel.swift` |
| **P2-02** | Hotkey: Carbon `RegisterEventHotKey` global summon without keylogger permissions | Planned | `Mimra/macOS/HotkeyManager.swift` |
| **P2-03** | Status item menu: Actions, pause toggle, ignore next copy, clear, settings | In Progress | `Mimra/macOS/StatusBarCoordinator.swift` |
| **P2-04** | Search interaction: Keyboard arrows, Return, Escape, selection state | Planned | `Mimra/UI/Panel/` |
| **P2-05** | Replay codec: Reconstruct valid NSPasteboard items from typed payloads with provenance | Planned | `Mimra/macOS/PasteCoordinator.swift` |
| **P2-06** | Auto-paste: Focus tracking and `CGEventPost` Command-V paste | Planned | `Mimra/macOS/PasteCoordinator.swift` |
| **P2-07** | Copy-only fallback: Graceful degradation when Accessibility permission is denied | Planned | `Mimra/macOS/AccessibilityManager.swift` |
| **P2-08** | Plain paste: Option-Shift-Return strip formatting shortcut | Planned | `Mimra/macOS/PasteCoordinator.swift` |
| **P2-09** | Paste error handling: App exited, secure input, password field guards | Planned | `Mimra/macOS/PasteCoordinator.swift` |

---

## 6. Current Blockers & Risks

* **None.** Gate G1 successfully verified and completed across all 8 tasks.
* **Next Task:** P2-01 (Panel: Resizable native `NSPanel` with SwiftUI list, text input, empty state, and non-activating panel behavior).
