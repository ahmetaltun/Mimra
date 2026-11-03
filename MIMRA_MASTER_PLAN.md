# MIMRA — Product Specification, Feature Parity & AI-Execution Roadmap

> **Status:** Implementation-ready master plan (not implemented software)  
> **Product:** Mimra — a minimal, premium, privacy-first macOS clipboard manager  
> **Research cutoff:** 2026-11-03  
> **Target:** macOS **15.0+**, **Apple silicon arm64 only** (M1 and newer)  
> **Non-negotiable stack:** **SwiftUI + AppKit + Rust**  
> **Scope:** Reach practical core feature parity, then add clearly marked Mimra improvements.

## 0. How agents must use this file

This is the project's **single product/architecture baseline**, not an instruction to generate the entire app in one response.

1. Read §§1–7 before working. Read the current phase (§8) and the relevant testing sections (§§9–11).
2. Check `docs/STATUS.md` (create in Phase 0) and choose **one small unblocked task** from §8.
3. Inspect the actual repository and installed versions. If this plan conflicts with a compiler, Apple API, official documentation,  **record an ADR and correct the plan**, not fake compatibility.
4. Implement the **smallest vertical slice** with concrete tests and no unrelated refactor.
5. Run all applicable quality gates; if unable to run on a Mac, label the result **NOT VERIFIED** and write reproducible macOS commands.
6. Commit logically isolated work; update task checkboxes, `docs/STATUS.md`, `docs/DECISIONS.md`, and traceability records.
7. Never report an incomplete feature as shipped. Never fabricate benchmark, UI test, notarization, or permission results.
8. Never duplicate proprietary names, artwork, copy, or third-party assets. If borrowing open-source logic, retain proper notices and track it.

**Priority:** security/privacy > data correctness > reliable paste > keyboard accessibility > performance > feature completeness > visual decoration.

**Symbols:** `[V]` = verified core clipboard behavior; `[R]` = suggested by documented settings/code, requires verification; `[+]` = **Mimra improvement**; `[?]` = requires hands-on version-specific verification. **P0/P1/P2** = critical / parity / polish. Every feature begins incomplete.

---

## 1. Product vision and hard constraints

### 1.1 One-sentence promise

**Mimra remembers what you copy, finds it instantly, and restores it accurately—without becoming a distraction or leaking your data.**

### 1.2 Success criteria

- Native, keyboard-first utility; no Electron, WebView-based UI, telemetry, network service, or persistent privileged daemon.
- Usable by mouse, keyboard-only, and VoiceOver users; robust with Korean/Japanese/Chinese IMEs and non-US keyboards.
- Preserve original supported payload variants, including rich text, images, URLs, and file references; distinguish **copy to clipboard** from **paste into previous app**.
- Explicitly support **macOS 15 and macOS 26** (and later only after verification). Do not pretend simulator/Intel testing validates arm64.
- Background history storage wholly on device. **No sync by default.** Optional sync is a proposed future feature.
- Explain Accessibility access and provide copy-only fallback if not granted.
- Favor graceful handling of unavailable/policy-blocked APIs over hacks or attempts to evade macOS protections.
- **No claims of release readiness until the matrix in §3 is fully verified and every P0/P1 verification is green.**

### 1.3 Milestones, in dependency order (not calendar promises)

| Gate | Deliverable | Exit condition |
|---|---|---|
| G0 | Clean native + Rust build | arm64 app launches; Rust static library can be invoked from Swift |
| G1 | Safe capture | Privacy filters, text capture, tests, persistent history |
| G2 | Reliable copy/paste | Popup, focus restoration, global shortcut, accessibility fallback |
| G3 | Complete data types | Rich text, images, file URLs, full-fidelity round trips |
| G4 | History power features | Search modes, pinning, retention, shortcuts, settings |
| G5 | Core Feature Parity | Preview/OCR/cycle/VoiceOver/localization/appearance/regression matrix |
| G6 | Release quality | Performance, privacy, data integrity, notarized arm64 build |
| G7 | Mimra differentiation | Optional features behind explicit flags and separate tests |

---

## 2. Source audit and confidence notes

### 2.1 Authoritative inputs (use these, not lookalike websites)
- UniFFI docs: https://mozilla.github.io/uniffi-rs/ and https://mozilla.github.io/uniffi-rs/latest/swift/overview.html
- Apple API references: https://developer.apple.com/documentation/appkit/nspasteboard ; https://developer.apple.com/documentation/servicemanagement/smappservice ; https://developer.apple.com/documentation/vision/vnrecognizetextrequest


### 2.2 What has been verified at research time

- Official GitHub releases list **2.8.0** as latest on 2026-11-03. 2.8.0 includes VoiceOver, drag-reordering of pins, editing pins from preview, special-symbol pin keys, image size, improved app exclusions and OCR language detection, and leak fixes.
- 2.7.0 adds slideout text/image preview, `Control-Space` preview toggle, copy OCR text, auto-open preview option, HEX swatch option, image dimensions and performance fixes.
- 2.4.0 adds image OCR search, `org.nspasteboard.source` attribution, Page Up/Down, cycling via repeat summon key, improved dedupe for Safari/Google Sheets, and supported screen-handling behavior.
- Official README documents copy versus paste modifiers; pin/unpin; clearing pinned/unpinned history; pause/ignore next copy; ignored pasteboard markers; adjustable polling interval; accessibility paste requirements.
- Mimra uses **SwiftUI + NSPanel** for UI and **Rust-owned SQLite** to satisfy the chosen technology constraints and control database integrity.

### 2.3 Mandatory hands-on parity-audit procedure [TASK AUDIT-01]

Before declaring **G5**, verify and inventory every pane, menu, and command against baseline expectations:

1. Record app version/build/hash, macOS version, language, and settings screenshots (local reference only).
2. Enumerate sections: General, Appearance, Search, Storage, Ignore, Hotkeys, Preview and any other present section. Pin editing is supported directly in preview.
3. Exercise: empty / full / mixed item history; pinned-only list; paste enabled/disabled; spotlight/fullscreen/multi-monitor; copied image/File URLs; source app icons; accessibility denied/granted.
4. Compare all visible defaults, keyboard combinations, click modifiers, help/status-bar interactions, and configuration migrations.
5. For each row in §3, store: expected result, Mimra behavior, difference, proof/test ID, and final disposition.
6. If any `[R]` item does not exist in 2.8, mark it **Mimra option**; if a new new behavior is found, add a new `F-` feature ID.
7. Preserve old behavior where configurable, but avoid forcing unsafe defaults merely for cosmetic parity.

---

## 3. Feature-parity matrix — authoritative implementation checklist

**Key:** Each `F` ID must have at least one automated test, or a named manual macOS test if UI/permission dependent. For `[R]` entries, agents must first verify exact v2.8 behavior rather than invent a spec. Default keyboard mappings may be affected by the **Paste automatically** preference—see §4.5.

### 3.1 Capture and types

| ID | Priority / evidence | Required Mimra behavior | Proof |
|---|---|---|---|
| F-001 | P0 [V] | Watch `NSPasteboard.general.changeCount`; configurable default ~500 ms; pause/restart cleanly | T-CAP-01 |
| F-002 | P0 [V] | Save ordinary plain text; handle empty/whitespace and Unicode deliberately | T-CAP-02 |
| F-003 | P0 [V] | Retain original HTML and RTF alongside plain-text variants | T-TYPE-01 |
| F-004 | P0 [V] | Capture PNG, TIFF, JPEG, HEIC where available; show thumbnails | T-TYPE-02 |
| F-005 | P0 [V] | Capture file references / file URLs, preserve type on replay | T-TYPE-03 |
| F-006 | P1 [V] | Recognize URLs and display appropriate link preview/title | T-TYPE-04 |
| F-007 | P0 [V] | Treat multi-item/multi-representation pasteboard changes as one logical copy when appropriate | T-CAP-03 |
| F-008 | P0 [V] | Ignore hidden/transient/autogenerated markers, including `org.nspasteboard.*` mandatory markers | T-PRIV-01 |
| F-009 | P0 [V] | Configurable ignored custom pasteboard UTIs; documented password manager hints | T-PRIV-02 |
| F-010 | P0 [V] | App ignore/block list by bundle identity, including apps outside `/Applications` | T-PRIV-03 |
| F-011 | P1 [V] | Detect/display source app icon and `org.nspasteboard.source` when available | T-CAP-04 |
| F-012 | P0 [V] | Dedupe consecutive/repeated copies reliably (Safari URLs, spreadsheet and transient types) | T-CAP-05 |
| F-013 | P1 [V] | Enable/disable supported pasteboard formats in Storage/preferences | T-TYPE-05 |
| F-014 | P1 [V] | Optional ignore Universal Clipboard type `com.apple.is-remote-clipboard` | T-PRIV-04 |
| F-015 | P1 [V] | Hide unsupported/unselected payload types instead of persisting WebArchives/arbitrary data | T-PRIV-05 |
| F-016 | P1 [R] | Track source application best-effort; refresh source icon after app update | T-CAP-04 |

### 3.2 Popup / input / menu bar

| ID | Priority / evidence | Required Mimra behavior | Proof |
|---|---|---|---|
| F-017 | P0 [V] | Menu bar-only normal operation with a summon hotkey (reference `Shift-Command-C`) | T-UI-01 |
| F-018 | P0 [V] | Responsive, scrollable, resizable native floating `NSPanel` containing SwiftUI | T-UI-02 |
| F-019 | P0 [V] | Search as you type; Up/Down, Return, Escape; mouse hover/click selection | T-UI-03 |
| F-020 | P0 [V] | Copy selected history item to clipboard vs auto-paste into previous app | T-PASTE-01 |
| F-021 | P0 [V] | Paste without formatting; preserve useful file URL semantics, don't silently downgrade files | T-PASTE-02 |
| F-022 | P1 [V] | Number quick picks 1–9 with modifier-dependent copy/paste/plain-text actions | T-KEY-01 |
| F-023 | P1 [V] | Configurable global summon, pin, delete and preview hotkeys | T-KEY-02 |
| F-024 | P1 [V] | Pin/unpin; pin shortcuts including `[];'./-=\\` and letters (subject to collision rules) | T-PIN-01 |
| F-025 | P1 [V] | Clear unpinned; separately clear all incl. pinned, with distinct confirmations | T-HIST-01 |
| F-026 | P1 [V] | Pause capture via menu and ignore only the next copy; clearly visible state | T-PRIV-06 |
| F-027 | P1 [V] | Preferences from menu + `Command-,`; quit/about/help paths | T-UI-04 |
| F-028 | P1 [V] | Optional title/search/footer presentation; footer remains discoverable when hidden | T-UI-05 |
| F-029 | P1 [V] | Popup usable on all screens, full-screen Spaces and above common overlays; constrain to visible screen | T-UI-06 |
| F-030 | P1 [V] | PageUp/PageDown; correct selection after deletes; keyboard wrap rules documented | T-KEY-03 |
| F-031 | P1 [V] | Summon-key cycle mode: hold summon modifiers, tap key, release to confirm | T-KEY-04 |
| F-032 | P1 [V] | App position/screen targeting and remembers size/position; graceful display disconnect | T-UI-07 |
| F-033 | P1 [V] | Correct IME composition, keyboard layouts (Dvorak, AZERTY), input focus | T-I18N-01 |
| F-034 | P1 [V] | Native light/dark/system appearances; clean native control and menu bar behavior | T-UI-08 |
| F-035 | P2 [R] | Optional menu bar icon choice, menu bar title/recent copy and sound feedback if verified | T-UI-09 |
| F-036 | P1 [V] | Stable list boundaries for pinned-only, zero results, minimum row count, separators | T-UI-10 |
| F-037 | P1 [V] | Text/URL/HEX color representations with optional color swatch | T-TYPE-06 |
| F-038 | P1 [V] | Undo/kill-to-end and text editing shortcuts only where relevant; don't intercept OS shortcuts | T-KEY-05 |

### 3.3 Preview, OCR and editing

| ID | Priority / evidence | Required Mimra behavior | Proof |
|---|---|---|---|
| F-039 | P1 [V] | Slideout text/image preview; `Control-Space` default toggle; adjustable width | T-PREV-01 |
| F-040 | P1 [V] | Optional automatic preview; sensible delay; preview closes/releases mouse input correctly | T-PREV-02 |
| F-041 | P1 [V] | Long text preview scroll and native text layout (`NSTextView` if useful) | T-PREV-03 |
| F-042 | P1 [V] | Image preview including size/dimensions and HEIC | T-PREV-04 |
| F-043 | P1 [V] | OCR-index image text; search it; on-device Vision with language auto-detection | T-OCR-01 |
| F-044 | P1 [V] | Copy OCR text from image preview toolbar | T-OCR-02 |
| F-045 | P1 [V] | Edit a pin in preview, persist revised content and update index | T-PIN-02 |
| F-046 | P1 [V] | Drag/drop reorder pinned items, keeping stable keyboard bindings | T-PIN-03 |
| F-047 | P2 [R] | Preview tooltip for truncated rows with optional hover delay | T-PREV-05 |

### 3.4 Search / history / settings

| ID | Priority / evidence | Required Mimra behavior | Proof |
|---|---|---|---|
| F-048 | P0 [V] | Extremely fast local search with selection stability and nonblocking typing | T-SRCH-01 |
| F-049 | P1 [R] | Search modes: mixed/fuzzy, exact/substring, regex; verify exact v2.8 labels/default | T-SRCH-02 |
| F-050 | P1 [V] | Highlight matched text; support the selectable highlight styles where available | T-SRCH-03 |
| F-051 | P1 [V] | Search text inside images via OCR and search metadata for usable content | T-SRCH-04 |
| F-052 | P0 [V] | Persistent local history survives quit/restart; bounded configurable item limit | T-HIST-02 |
| F-053 | P0 [V] | Pinning protects items from ordinary history eviction/clear-unpinned | T-HIST-03 |
| F-054 | P1 [R] | Sorting by copy time / recency and pin positioning if present in 2.8 | T-HIST-04 |
| F-055 | P1 [V] | Storage settings show DB size, retention, enable types, clear actions | T-HIST-05 |
| F-056 | P1 [R] | `clearSystemClipboard`, `pasteByDefault`, `playSounds` and related General toggles if still present | T-SET-01 |
| F-057 | P1 [V] | App exclusions + custom ignored type management; validation and test option | T-SET-02 |
| F-058 | P1 [R] | Configure appearance, popup size/position/screen, preview and search preferences | T-SET-03 |
| F-059 | P1 [V] | Localized UI; support current system language; at least English plus one non-English QA locale | T-I18N-02 |
| F-060 | P1 [V] | VoiceOver labels, focus order, item type/status announcements, keyboard accessibility | T-A11Y-01 |
| F-061 | P1 [V] | Accessibility permission onboarding; usable copy-only mode without access | T-PASTE-03 |
| F-062 | P1 [R] | Launch at login / application distribution / update controls; verify version behavior before copying UX | T-REL-01 |
| F-063 | P1 [R] | Adjustable polling interval, including advanced settings/`defaults` compatibility | T-CAP-06 |
| F-064 | P1 [R] | Optional indicator and retention options for system clipboard (if verified) | T-HIST-06 |

### 3.5 Explicit nonclaims and separations

- **Do not assume:** iCloud history sync; AI rewrite/summarization; snippet expansion; team accounts; remote APIs; a mobile companion; biometric unlock. They are **NOT verified requirements**.
- Native offline OCR and app icons are implemented independently on-device. Mimra should implement equivalents independently.
- Standard clipboard behaviors such as **Return = copy; Option-Return = paste; Option-Shift-Return = plain paste** describe mode configurations. Mimra **must support a `Paste automatically` preference** and test both behaviors.
- Version parity means **equivalent behavior**, not pixel-for-pixel imitation or copied branding.

---

## 4. Architecture decisions (ADRs to create in Phase 0)

### 4.1 Ownership map — strict

| Component | Language | Owns | Must **not** own |
|---|---|---|---|
| App shell + views | SwiftUI | List, search UI, previews, Settings, accessibility semantics | SQL, pasteboard polling |
| macOS adapter | AppKit | `NSPasteboard`, `NSPanel`, `NSStatusItem`, shortcut events, accessibility, app identity, CGEvent/AX paste | Domain search rules or SQL |
| `MimraCore` | Rust | Canonical history, normalization, dedupe, search/ranking/regex, pin ordering, retention, SQLite/FTS5 | AppKit, UI, process-global event taps |
| `MimraBridge` | UniFFI + Swift wrapper | Narrow typed requests/results, versioned error handling, off-main dispatch | App decision-making |
| OCR adapter | Swift Vision | Deferred on-device recognition from image bytes | Network OCR / SQL mutations |
| Preferences adapter | Swift `UserDefaults` / settings store | UI and platform preferences; source of truth for native permissions | Storing clipboard payloads |
| SQLite | Rust (`rusqlite`) | Atomic commits, queries, migrations, WAL, content and index deletion | Concurrent Swift database connections |

**Decisions:** Rust owns SQLite exclusively; Swift passes only chosen allowlisted bytes to Rust. UniFFI is a **build-time binding generator**, not a substitute for building, codesigning and packaging the native library. Start with a Rust `staticlib` for `aarch64-apple-darwin`, expose a compact UniFFI surface, embed/link into the arm64 app; no dylib search-path surprises, no helper process, no external service.

### 4.2 Data/control flow

```text
                 macOS (on user session)
                          |
           NSPasteboard.changeCount (AppKit)
                          |
              [ClipboardMonitor Swift]
                          |
         [Source-App & Privacy Filter Swift]
                   /              \
            ignored -> drop    allowlisted payload
                                     |
                           [Rust UniFFI Core]
                               |        |
                      dedupe/normalize  SQLite + FTS5
                               |        |
                               +--------+
                                     |
                        paged results / notifications
                                     |
                         [SwiftUI History UI]
                            /             \
                   [Preview + Vision]   [PasteCoordinator]
                                           |
                                NSPasteboard + focus restore
                                           |
                                    prior target app
```

**Boundary rule:** Swift/AppKit can inspect source-app identity and marker types prior to capturing payload bytes. For security, any marker-denied change **never enters Rust**, thumbnails, OCR, logs, or crash diagnostics.

### 4.3 Concurrency policy

- `ClipboardMonitor`, `PanelCoordinator`, `PasteCoordinator`, and `NSStatusItem` are `@MainActor` or explicitly interact on the appropriate AppKit thread.
- **Never block the main actor** on Rust SQLite queries, image decoding, hash computation, OCR, or retention cleanup. Generated UniFFI sync calls can block; wrap them in a **dedicated serial worker/queue or actor-compatible off-main executor**, then return immutable Swift DTOs to main actor. Document/sendability gaps; do not blindly annotate generated classes `@unchecked Sendable`.
- One DB writer/queue; read-only search may use a separate Rust-managed connection if safe. Time-bound/cancel stale searches by generation ID, don't let old results replace new.
- Never call UI callbacks while holding Rust locks. Avoid cyclic callbacks from Rust to Swift in v1. Use Swift-pulled results and lightweight notifications.
- Catch errors at boundaries; no Rust panics across FFI. Return typed `MimraError` variants (IO, badInput, schemaMismatch, unavailable, corrupt, permissionDenied).

### 4.4 UI and window behavior

- Set up an **agent/menubar-style app** (evaluate `LSUIElement=true` as baseline). Keep a settings window accessible via menu bar if main panel fails.
- Render SwiftUI history inside an AppKit-managed `NSPanel`/`NSHostingView` (or `NSHostingController`). Test `nonactivatingPanel`/become-key behavior rather than asserting a single style-mask always works. Input method editors need a real text-input responder.
- Track last non-Mimra foreground application and previous focus target **before panel open**. Dismiss panel, restore target, then conditionally deliver paste via supported accessibility/event APIs. Fail safely to copy-only if denied or target is no longer valid.
- Position panel within `NSScreen.visibleFrame` of user-selected/active screen; clamp after display changes. Test fullscreen Spaces, Stage Manager, Mission Control, external displays and scaling.
- Avoid global event taps unless a feature genuinely requires them; register a summon hotkey with well-tested native library/API and disclose any permission needs. Detect conflicting shortcuts and present remediation.
- `NSStatusItem` menus: open history, pause/resume, skip next copy, clear unpinned/all, preferences, launch at login, About, quit.
- Use SF Symbols and original Mimra design; support reduced motion, increased contrast, dynamic text/VoiceOver.

### 4.5 Clipboard and paste contracts

**Capture algorithm:**
1. Poll `changeCount` with user-defined interval (initial 500 ms; clamp and validate bounds).
2. If unchanged, return without allocations or SQL calls. On change, take a consistent pasteboard snapshot where feasible; re-check for changes/races.
3. If paused or `ignoreNext` set: consume **exactly one observed external change** and reset; don't accidentally skip multiple updates.
4. Inspect **pasteboard-level and item-level** types, marker types, and source bundle; reject concealed, transient, auto-generated, ignored app/UTI, or disallowed format.
5. Extract **only** supported types: UTF-8 plain text, RTF, HTML, PNG/TIFF/JPEG/HEIC where representable, `public.file-url`, optionally source marker metadata. Never store unselected Safari WebArchives or arbitrary custom UTI blobs.
6. Normalize a fingerprint over canonical chosen content (deterministic ordering, not preview/title alone); store representations as one logical history event. Recognize duplicates, update lastCopy and ranking while preserving pins.
7. Commit atomically to Rust-owned DB; schedule thumbnail/OCR indexing after persistence; publish immutable history result to UI.

**Replay algorithm:**
1. User selects a stable item ID and command: `copy`, `pasteOriginal`, or `pastePlain`.
2. Fetch all valid original representations from Rust with bounds and corruption checks. Verify no ambiguous/untrusted file path transformations.
3. Replace clipboard **once** with valid multi-representation pasteboard items. Stamp a proprietary Mimra-origin marker to prevent self-recapture; update monitor observed change count.
4. If copy-only, end. If auto-paste requested but Accessibility unavailable, show nonblocking explanation, keep content on clipboard, do not inject input.
5. If auto-paste permitted: close panel, resolve prior target, restore appropriate focus, and send `Command-V` through an explicitly tested allowed macOS path. No private APIs; do not bypass system security prompts.
6. Do not paste into Mimra itself or an unexpected app after focus changes; bail out to clipboard-only and explain.
7. **Plain-text paste** strips RTF/HTML for text; for files and images, show/execute a defined compatible fallback rather than destroying content. Test terminals and document editors.
8. Distinguish menu actions and key combinations under `pasteByDefault` mode. Baseline parity behavior to validate: Enter copies vs auto-pastes; Option+Enter pastes; Option+Shift+Enter pastes without formatting.

### 4.6 Threat model and security defaults

**Assets:** clipboard secrets, copied financial text, app attribution, local SQLite and backups, search index, preview caches, exported diagnostic data.

**Threats:** password manager marking errors, clipboard read without awareness, leaked rich-text payload, accidental paste into wrong window, sensitive debug logs, searchable plaintext sidecar, discarded data still recoverable from SQLite WAL/free pages, unbounded data retention, access to backup files, malicious malformed image/RTF, accidental network exfiltration, FFI memory bugs, supply-chain updates.

- Never log raw clipboard contents, OCR text, file paths, tokens, snippets, or URL query parameters. Redact diagnostic events by default.
- Fail closed for known secret markers; allow custom denylist additions; warn that unmarked secrets **can still be captured**. No misleading claim that all passwords are automatically detected.
- Display an understandable onboarding disclosure and per-app ignore rules. Never silently disable platform safeguards.
- Keep OCR and previews on-device; process potentially malformed image types using hardened platform decoders; impose per-item and total byte quotas.
- Add optional encrypted-at-rest mode as a **Mimra improvement**: SQLCipher or equivalent **after a prototype validates correct statically-linked arm64 build and FTS/WAL coverage**. Protect key in Keychain, document logged-in-user threat model and key-loss behavior. Do not describe baseline SQLite as encrypted; macOS FileVault is separate.
- Make clear-history semantics explicit: remove history/index/thumbnail references atomically; use SQLite secure_delete when enabled and eventual checkpoint/VACUUM where appropriate. Do **not promise forensic erasure** on APFS, snapshots or backups.
- Keep `Info.plist`, entitlements, accessibility requests, and sandbox policy documented. Direct distribution baseline; Mac App Store compatibility must be assessed separately—do not assume the same entitlement model works everywhere.

---

## 5. Concrete repository structure and build

```text
Mimra/
├── README.md
├── LICENSE                      # chosen project license; track 3rd-party notices
├── MIMRA_MASTER_PLAN.md        # this file (copy into repository)
├── AGENTS.md                    # agents' strict execution instructions
├── .gitignore
├── .github/workflows/           # rust unit checks; macOS Xcode CI if available
├── Makefile                     # or justfile, deterministic developer commands
├── scripts/
│   ├── check-env.sh
│   ├── build-rust.sh
│   ├── generate-bindings.sh
│   ├── package-xcframework.sh    # if needed; one arm64 macOS slice
│   ├── test-all.sh
│   └── notarize.sh               # non-secret placeholders + documented env vars
├── Mimra.xcodeproj/
├── Mimra/
│   ├── App/MimraApp.swift
│   ├── App/AppDelegate.swift
│   ├── UI/History/{HistoryView,HistoryRow,SearchField}.swift
│   ├── UI/Preview/{PreviewView,PreviewPanel}.swift
│   ├── UI/Settings/{General,Appearance,Search,Storage,Ignore,Hotkeys,Privacy}.swift
│   ├── macOS/{ClipboardMonitor,ClipboardCodec,PasteCoordinator}.swift
│   ├── macOS/{HotkeyCoordinator,PanelCoordinator,StatusBarCoordinator}.swift
│   ├── macOS/{AccessibilityService,SourceAppResolver,LoginItemService}.swift
│   ├── Services/{OCRService,ThumbnailService,PreferencesStore}.swift
│   ├── Bridge/{CoreClient,CoreDTO,CoreErrors}.swift
│   ├── Assets.xcassets/
│   └── Localizable.xcstrings
├── RustCore/
│   ├── Cargo.toml
│   ├── Cargo.lock
│   └── src/
│       ├── lib.rs               # public UniFFI entrypoints
│       ├── domain/{item,content,pin,settings}.rs
│       ├── storage/{db,migrations,repository,retention}.rs
│       ├── search/{fuzzy,exact,regex,ranking}.rs
│       ├── services/{dedupe,history,validation}.rs
│       └── error.rs
├── Generated/                   # deterministic generated FFI; policy in README
├── MimraTests/                  # Swift XCTest / Swift Testing
├── MimraUITests/                # native UI automation (human approvals may be needed)
├── fixtures/                    # synthetic non-sensitive text, RTF, HTML, PNG, HEIC, files
├── benchmarks/
└── docs/
    ├── STATUS.md
    ├── DECISIONS.md
    ├── 
    ├── ARCHITECTURE.md
    ├── SECURITY.md
    ├── QA_MATRIX.md
    ├── RELEASE.md
    └── THIRD_PARTY_NOTICES.md
```

### 5.1 Versions/tools

- Xcode with the macOS 15+ SDK, strict concurrency checks. **Pin actual tested Xcode and rustc versions in `docs/STATUS.md`** rather than hardcoding a version that may be unavailable on a developer's Mac.
- Rust stable, `rustup target add aarch64-apple-darwin`, Cargo.lock committed, reproducible `--locked` builds.
- UniFFI for typed Swift bindings; pin UniFFI crate and bindgen version **identically**. At research time its support has documented limitations, especially async `Sendable`; use a **sync UniFFI API called from Swift background worker** until tested otherwise.
- `rusqlite` with a verified SQLite+FTS5 setup. Pin SQLite compile options; don't assume bundled SQLite includes every extension.
- Rust crates only for clear needs: `thiserror`, `uuid`, `serde`, `blake3`, `regex`, `unicode-normalization`, `rusqlite`. Avoid unnecessary framework layers; use `cargo audit`/license review.
- A single native macOS arm64 static library inside the final app. Verify architecture with `lipo -info`, `file`, or `otool` as applicable and ensure generated bindings reflect the same build.
- Signing/notarization via Xcode and Apple Developer ID. App updates may use Sparkle **only after** signing/feed threat modeling; user can also update manually. Review Sparkle license/notarization guidance before integrating.

### 5.2 Commands to implement (the skeleton can vary)

```bash
# Mac developer setup after the project exists
rustup target add aarch64-apple-darwin
cd RustCore && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings
cd RustCore && cargo test --all --locked
./scripts/build-rust.sh
./scripts/generate-bindings.sh
xcodebuild -project Mimra.xcodeproj -scheme Mimra -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
xcodebuild -project Mimra.xcodeproj -scheme Mimra \
  -destination 'platform=macOS,arch=arm64' test
```

Do **not** run imaginary commands before Phase 0 creates the files/scheme. Avoid checking signing credentials or private user data into source control.

---

## 6. Rust database and core API contracts

### 6.1 SQLite schema proposal (evolve only with migrations)

```sql
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at_ms INTEGER NOT NULL
);

CREATE TABLE history_items (
  id TEXT PRIMARY KEY,                 -- UUID/ULID
  first_copied_at_ms INTEGER NOT NULL,
  last_copied_at_ms INTEGER NOT NULL,
  copy_count INTEGER NOT NULL DEFAULT 1,
  source_bundle_id TEXT,               -- best effort; null if unknown
  content_kind TEXT NOT NULL,          -- text, rich, image, files, mixed
  title TEXT NOT NULL DEFAULT '',
  search_text TEXT NOT NULL DEFAULT '',
  ocr_text TEXT NOT NULL DEFAULT '',
  content_hash BLOB NOT NULL,
  is_pinned INTEGER NOT NULL DEFAULT 0,
  pin_order INTEGER,
  pin_key TEXT,
  byte_size INTEGER NOT NULL DEFAULT 0,
  created_at_ms INTEGER NOT NULL
);

CREATE TABLE item_representations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id TEXT NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
  group_index INTEGER NOT NULL,        -- one logical copy can contain multiple pasteboard items
  uti TEXT NOT NULL,
  payload BLOB NOT NULL,               -- bounded, type-validated raw representation
  UNIQUE(item_id, group_index, uti)
);

CREATE INDEX idx_history_recent ON history_items(is_pinned, last_copied_at_ms DESC);
CREATE INDEX idx_history_hash ON history_items(content_hash);
CREATE UNIQUE INDEX idx_history_pin_key ON history_items(pin_key) WHERE pin_key IS NOT NULL;
CREATE INDEX idx_item_rep_parent ON item_representations(item_id);

CREATE VIRTUAL TABLE search_fts USING fts5(
  title, search_text, ocr_text,
  content='history_items', content_rowid='rowid', tokenize='unicode61'
);
-- Add correct insert/update/delete triggers or explicit synchronized updates,
-- and assert no stale index rows in integrity tests.
```

**Important:** The schema is a draft. External-content FTS5 with `history_items.rowid` is valid for SQLite rowid tables, but **IDs remain string primary keys**; ensure every search result joins correctly. Prefer storing large binary blobs in a separate bounded content store **only if** measured SQLite amplification merits it. If external blobs are used, require transactional manifest + crash-safe orphan cleanup. Keep `search_text`/OCR *only* on device. Old content deletion must delete representation rows and FTS postings; test with foreign-key assertions and `PRAGMA integrity_check`.

**Capacity policy (initial defaults, adjustable after profiling):** 200 unpinned items; 500 ms scan; 10 MB max individual media (make configurable and inform users), 100 MB total initially. Do not silently truncate rich text or images; mark “too large to save” with a privacy-safe UI state. Caps are **Mimra choices**.

### 6.2 Core interface design (pseudo-UniFFI contract)

The code below describes behavior, not a drop-in compilation-tested UDL:

```text
CoreHandle.open(database_path, configuration) -> Result<CoreHandle, CoreError>
CoreHandle.ingest(ClipboardCapture) -> Result<IngestResult, CoreError>
CoreHandle.list_page(HistoryQuery, cursor, limit) -> Result<HistoryPage, CoreError>
CoreHandle.search(SearchRequest, generation, limit) -> Result<SearchResultPage, CoreError>
CoreHandle.fetch_payload(item_id) -> Result<ClipboardPayload, CoreError>
CoreHandle.pin(item_id, desired_state, pin_key) -> Result<HistoryItemDTO, CoreError>
CoreHandle.reorder_pins(ordered_ids) -> Result<(), CoreError>
CoreHandle.edit_pinned_text(item_id, new_text) -> Result<HistoryItemDTO, CoreError>
CoreHandle.delete_item(item_id) -> Result<(), CoreError>
CoreHandle.clear_unpinned() -> Result<DeletedCounts, CoreError>
CoreHandle.clear_all() -> Result<DeletedCounts, CoreError>
CoreHandle.enforce_retention(policy) -> Result<CleanupReport, CoreError>
CoreHandle.update_ocr(item_id, recognized_text) -> Result<(), CoreError>
CoreHandle.storage_stats() -> Result<StorageStats, CoreError>
CoreHandle.health_check() -> Result<DatabaseHealth, CoreError>
CoreHandle.close() -> Result<(), CoreError>
```

**DTOs:** `ClipboardCapture { captured_at, source_bundle_id?, representations: [group_index, uti, bytes], display_hint? }`; `HistoryItemDTO { id, title, kind, pinned, pin_key?, app_bundle_id?, timestamps, dimensions?, snippet, availability }`; `SearchRequest { text, mode, include_ocr, max_results, sort }`; `CoreError { kind, safe_message }`.

**Rules:** no UIKit/AppKit objects over FFI; pass bytes/strings/simple numeric types only. No duplicate payload transfer on list/search; fetch full payload on explicit paste/preview only. All strings normalized for search and tested for invalid Unicode/zero-width characters. Serialize FFI access to stateful SQLite handle. Use limit + cursor, never giant lists into UI.

### 6.3 Search details

- **Mixed/fuzzy:** deterministic Unicode-aware substring first, ranked subsequence matching second (favor token boundaries, consecutive matches and recency). State trade-offs for non-Latin scripts and diacritics; test Greek, Japanese, Cyrillic and emoji.
- **Exact/substring:** case/diacritic options; stable recency tie-break. FTS5 can prefilter but may not implement substring/fuzzy on its own.
- **Regex:** Rust `regex` engine (bounded/linear-time patterns rather than arbitrary backtracking), limit length/result count and run off-main; never evaluate user regex via unsafe SQL.
- **OCR:** deferred on-device `Vision` text recognition in Swift; results update Rust `ocr_text`; reindex transactionally. Respect pause/clear races: an OCR result for a deleted item must never resurrect it.
- **Highlight:** Swift-owned ranges derived from Rust search matches using safe UTF-16 / grapheme conversions; never split Unicode grapheme clusters.
- **Ranking:** pinned separate pinned order if configured, otherwise copy recency and relevance; no flicker or selection jumping during live search.

### 6.4 Retention and database safety

- Configurable count limit applies to unpinned items. Never evict pinned items accidentally when full.
- Insert + duplicate resolution + eviction + index maintenance must be **one transaction**. Concurrent delete/duplicate/pin operations must be order-consistent.
- Row deletions cascade and leave no content/FTS orphans. Write tests for 50k insert/evict cycles, full-pinned capacity, and repeated image duplicates.
- DB migrations idempotent, atomic, versioned, tested from snapshots. No blocking full-DB cleanup on the main thread or during first-frame rendering. Require recoverable error path for corruption and low disk.
- Periodic WAL checkpoints on dedicated worker; manage freed space without unbounded startup work. Note APFS snapshots/backup persistence.

---

## 7. UI/UX specification: distinctly Mimra, not a reskin

### 7.1 Product visuals

- Premium, quiet aesthetic: monochrome or subdued accent, refined typography, original icon; restrained animation. Follow system light/dark, vibrancy, Reduce Motion and contrast preferences.
- A narrow, vertically resizable search-centric panel. Rows: content thumbnail/type icon + text preview + optional source app icon + pin indicator + position shortcut.
- Pins separated from recents without double separators. Minimum visible list height for three rows when feasible; empty-state guidance for newly installed users.
- Search results can show contextual matches and OCR badge; document when OCR indexing is pending without exposing captured text in diagnostics.
- Slideout preview attached to panel, clamped on either side within display visible frame. Toolbar actions: Copy, Paste, Paste Plain (where meaningful), Pin/Edit, Copy OCR Text, Delete; image dimensions and file details.
- Native Settings categories: **General, Appearance, Search, Storage, Ignore, Hotkeys, Privacy, About**. No separate Pins settings pane by default (pin edits are handled in preview).

### 7.2 Suggested settings model (validate reference defaults)

| Section | Controls |
|---|---|
| General | Launch at login; Paste automatically; play sound; restore focus; clear system clipboard preference; check interval (advanced) |
| Appearance | Icon/menu bar visibility; recent copy display; panel screen/position; show title/search/footer; show source app icon; HEX color swatch; theme/system; preview width/auto-open/delay |
| Search | Mode (mixed/fuzzy/substring/regex); matching highlight style; OCR inclusion; sort mode |
| Storage | Enable capture formats; max item count; retention days/bytes (+); DB size; clear unpinned; clear all; diagnostics / health |
| Ignore | Apps by bundle ID plus executable identity (outside Applications); ignored pasteboard types; Universal Clipboard toggle; pause / ignore-next behavior |
| Hotkeys | Open panel; pin; delete; preview; quick picks; cycle mode; collisions; restored defaults |
| Privacy | Disclosure; permissions help; password markers; export rules; encryption (future +); redacted diagnostics |
| About | App version, architecture arm64, license notices, updates, help, acknowledgments |

All settings changes persist atomically and update relevant components without requiring app restart unless technically necessary. Provide `Reset to Defaults` and clear warnings for destructive actions.

---

## 8. Detailed incremental roadmap — task cards for AI agents

**Implementation convention:** A task is marked `[x]` only after its code, tests, real device result (where required), and documentation pass. Identifiers are permanent; do not silently renumber.

### PHASE 0 — Repository, decisions and verified reference (G0 prerequisites)

- [ ] **P0-01 Reference audit:** Create `MIMRA_MASTER_PLAN.md`; transcribe settings and hotkeys from official 2.8.0; classify each §3 row. **DoD:** full reference inventory with observed/proposed labels; unknowns tracked.
- [ ] **P0-02 Developer environment:** Mac/Xcode/Rust validation, `xcodebuild -version`, `rustc -V`, SDK version, `uname -m` arm64. **DoD:** environment script fails clearly if target cannot build.
- [ ] **P0-03 Xcode shell:** Create `Mimra` menubar app with SwiftUI Settings scene, AppKit delegate, `MACOSX_DEPLOYMENT_TARGET=15.0`, arm64 only. **DoD:** runs on macOS 15 arm64; opens settings from status icon.
- [ ] **P0-04 Rust crate:** Create `RustCore` with `staticlib`, feature flags and pinned dependencies. **DoD:** `cargo fmt/clippy/test` pass.
- [ ] **P0-05 UniFFI spike:** Expose `core_version()` and a pure `fingerprint(bytes)` via staticlib; generate bindings; compile arm64; invoke from Swift. **DoD:** clean machine/rebuild and Swift integration test; verify architecture.
- [ ] **P0-06 Docs/automation:** Add `AGENTS.md`, status/ADRs, CI scripts, third-party notices, mock data fixtures and `.gitignore`. **DoD:** onboard a fresh Mac without tribal knowledge.
- [ ] **P0-07 Policy/permissions spike:** Determine signed direct-distribution sandbox/Accessibility/Hotkey behavior on both macOS 15 and 26; record tested choices. **DoD:** real-device matrix, no unsupported private API workaround.

**Phase 0 exit:** launchable signed-in-development arm64 shell, Swift↔Rust test, tested build script, all architecture ADRs recorded.

### PHASE 1 — Local history engine and safety (G1)

- [ ] **P1-01 Rust domain models:** Typed content representations, stable UUID IDs, source app, timestamps, hash and size limits. **DoD:** serialization/property tests with empty/invalid/multi-representation data.
- [ ] **P1-02 SQLite migrations:** Create normalized tables, content references, indexes and FTS5. **DoD:** migrate from empty and old fixture DB; FK/FTS integrity passes.
- [ ] **P1-03 Core ingestion:** Transactional insert, dedupe, recopy timestamps and stable order; preserve pins. **DoD:** duplicate fixtures + capacity edge cases pass.
- [ ] **P1-04 Rust repository API:** list-page, fetch, delete, clear, stats, retention with error codes. **DoD:** integration tests including crash-safe reopen.
- [ ] **P1-05 Clipboard reader:** `changeCount` polling, lifecycle, snapshots, allowlist supported UTIs, multi-item handling. **DoD:** plain text capture into Rust via FFI in running Mac app.
- [ ] **P1-06 Privacy prefilter:** mandatory deny markers, user UTI deny, ignored source apps, pause and ignore-next state machine. **DoD:** no excluded bytes passed to Rust in instrumented tests.
- [ ] **P1-07 Self-recapture protection:** provenance UTI/marker, sync `changeCount`, distinguish other app writes. **DoD:** repeated Mimra replay creates zero unintended duplicates.
- [ ] **P1-08 Persistence UI stub:** display 50 recent text entries and survive restart. **DoD:** 1,000 synthetic copies, stable ordering, no hang.

**Phase 1 exit:** a local text clipboard monitor with reliable persistence, explicit exclusions, and no secret-marker capture.

### PHASE 2 — Core user loop, popup and paste (G2)

- [ ] **P2-01 Panel:** Resizable native `NSPanel` with SwiftUI list, text input, empty state and hide/reopen behavior. **DoD:** no dock UI by default, focus works in regular/fullscreen apps.
- [ ] **P2-02 Hotkey:** Register/unregister global summon without global keylogger; shortcut collision handling; non-US keyboard tests. **DoD:** summon from Finder/Terminal/browser.
- [ ] **P2-03 Status item:** icon and menu commands open/pause/ignore-next/settings/clear/quit. **DoD:** Option- and Option-Shift-click functionality documented and tested.
- [ ] **P2-04 Search interaction:** keyboard arrows, Enter, Escape, `Command-,`, mouse click/hover, selection state. **DoD:** no accidental hover overrides immediately after keyboard navigation.
- [ ] **P2-05 Replay codec:** reconstruct valid NSPasteboard item(s) from typed payloads, own marker. **DoD:** text round-trip byte/content comparison.
- [ ] **P2-06 Auto-paste:** track previous app/focus, dismiss panel, paste via consented supported API. **DoD:** exact recipient app receives data in real devices.
- [ ] **P2-07 Copy-only fallback:** default configurable `Paste automatically`, permissions status, recovery when denied/revoked. **DoD:** user can always copy without Accessibility.
- [ ] **P2-08 Plain paste:** implement mode-specific key combinations and clipboard encoding behavior. **DoD:** formatted text becomes plain; file URL fallback explicitly tested.
- [ ] **P2-09 Paste error handling:** app exited/screen switched/password/secure input/remote desktop/Spotlight cases. **DoD:** never paste to an unintended target and never claim success without it.

**Phase 2 exit:** keyboard-only open→search→copy/paste in a normal target app; fallback without permissions.

### PHASE 3 — Full data fidelity and richer previews (G3)

- [ ] **P3-01 HTML/RTF:** capture/write multiple coherent representations. **DoD:** Word/Pages/Notes/browser round trips (formats that system supports).
- [ ] **P3-02 Images:** allowlisted PNG/TIFF/JPEG/HEIC; lazy decode and thumbnail cache with memory limits. **DoD:** screenshots/large images repeat correctly without main-thread decode.
- [ ] **P3-03 File references:** capture one/multiple file URLs; preserve identity and order; define vanished-file UX. **DoD:** paste as file in Finder where possible; no silent path-text degradation.
- [ ] **P3-04 URLs/colors:** detection, click-safe preview, HEX swatch toggle; text remains primary. **DoD:** #RGB/#RRGGBB parsing and URL canonicalization tests.
- [ ] **P3-05 Source attribution:** bundle ID/icon via Workspace and `org.nspasteboard.source` marker (best-effort). **DoD:** icons update when app changes, unknown source safe.
- [ ] **P3-06 Dedupe hardening:** Safari, Sheets, VS Code, Notes, MS Office, multi-representation copies and source-specific markers. **DoD:** no duplicate storms or content loss.
- [ ] **P3-07 Type settings:** types enabled/disabled without storing unknown private payloads. **DoD:** every toggle has capture test.

**Phase 3 exit:** normal text, rich text, images and file references round-trip as supported; graceful failure for unsupported formats.

### PHASE 4 — Search and storage power features (G4)

- [ ] **P4-01 Search index:** maintain Rust FTS5 and transactional index triggers; paginate. **DoD:** 10k results fixture, index integrity and stable pagination.
- [ ] **P4-02 Fuzzy/mixed mode:** deterministic ranker plus recency boosts, Unicode-aware highlight ranges. **DoD:** test corpus snapshots and no keyboard lag.
- [ ] **P4-03 Exact/regex modes:** configurable modes, Rust bounded regex and error feedback; cancel stale search. **DoD:** invalid regex doesn't crash UI.
- [ ] **P4-04 Sorting/highlights:** pinned arrangement, recency, relevance and highlight styles. **DoD:** selection remains on same ID on updates.
- [ ] **P4-05 History limit:** count/age/size retention and clear, preserve pins. **DoD:** 50k-event churn + 100% FK/FTS cleanup.
- [ ] **P4-06 Storage UI:** DB size/limits/types/clear-unpinned/clear-all and confirmation. **DoD:** disk metrics update after checkpoint and cleanup.
- [ ] **P4-07 Failure recovery:** low disk, corrupt db, bad migration, full capacity, relaunch and backup recoverability. **DoD:** user-facing safe error, no unconditional history wipe.

**Phase 4 exit:** indexed, bounded, correct local history, including text and metadata search, all core operations tested.

### PHASE 5 — Pins, cycling and advanced keyboard operations (G4/G5)

- [ ] **P5-01 Pins:** pin/unpin, stable pinned section and shortcuts, eviction protection. **DoD:** pin survives restart/full history/clear unpinned.
- [ ] **P5-02 Pin shortcut assignment:** enforce unique bindings and reserved key conflicts; permit punctuation keys in 2.8. **DoD:** non-US layout and `[];'./-=\\` test corpus.
- [ ] **P5-03 Pin reorder:** drag-and-drop persistence, keyboard accessibility alternative. **DoD:** deterministic order after relaunch.
- [ ] **P5-04 Edit pin:** editable text representation in preview; safe update of search index and retained pin ID. **DoD:** edited item copy/paste uses new content; no unrelated representation corruption.
- [ ] **P5-05 Quick pick:** 1–9 with modifiers for copy/paste/plain; capacity/boundary cases. **DoD:** matches selected visible order.
- [ ] **P5-06 Cycle mode:** repeat summon key while holding modifiers, release commits; cancel on Escape/focus loss. **DoD:** no conflict with pin key/IME/other apps.
- [ ] **P5-07 Nav semantics:** Page Up/Down, selection following delete, pinned-only row, separator consistency. **DoD:** snapshot and keyboard tests.

**Phase 5 exit:** all high-frequency keyboard/pin workflows are usable without touching the mouse.

### PHASE 6 — Preview + on-device OCR (G5)

- [ ] **P6-01 Slideout preview:** text/image panel attached to history, width and bounds; close doesn't intercept mouse. **DoD:** layout survives monitor changes and quick toggles.
- [ ] **P6-02 Preview shortcuts/settings:** Control-Space toggle; auto-open/delay; only local shortcut, not global registration. **DoD:** keyboard shortcut works inside panel only.
- [ ] **P6-03 Text preview:** native efficient `NSTextView` for long content and accessibility selection. **DoD:** 1 MB text scrollable without UI freeze.
- [ ] **P6-04 Image preview:** aspect ratio, HEIC, dimensions and image-byte size; cached scaling. **DoD:** no image decoded repeatedly on each row render.
- [ ] **P6-05 OCR service:** Vision recognition on background queue, automatic language detection where supported. **DoD:** synthetic test image in 2 languages indexed; clean cancellation.
- [ ] **P6-06 OCR results:** searchable image text, copy OCR button, loading/failed states; no network call. **DoD:** can find an image by embedded text and copy extracted text.
- [ ] **P6-07 Race protection:** delete/clear while OCR pending; stale callbacks must never resurrect deleted items. **DoD:** stress test 1,000 rapid changes + dismissals.

**Phase 6 exit:** slideout preview and OCR experience  entirely on-device.

### PHASE 7 — Comprehensive Settings, internationalization and accessibility (G5)

- [ ] **P7-01 General:** paste mode, launch-at-login with `SMAppService.mainApp`, play sound if verified, clear system clipboard if enabled. **DoD:** persisted toggles + OS permission/policy handling.
- [ ] **P7-02 Appearance:** title/search/footer/icon, source app icon, HEX swatches, sizing/position/screen, light/dark. **DoD:** every change observable without restart where possible.
- [ ] **P7-03 Search/Storage:** search modes/highlight; allowed formats and count/size options, DB stats. **DoD:** settings precisely match core behavior.
- [ ] **P7-04 Ignore/Privacy:** app picker outside `/Applications`, UTI editing, pause/ignore-next; validation/confirmation. **DoD:** app exclusions and markers applied before payload read.
- [ ] **P7-05 Hotkeys:** record/change/reset, collision handling, physical key layout and secure input fallback. **DoD:** no global event tap when not required.
- [ ] **P7-06 English + localization:** string catalog, layout expansion, CJK input, RTL visual QA, one non-English full flow. **DoD:** tests for Japanese IME and long translated labels.
- [ ] **P7-07 VoiceOver:** selected row item content/type/source/pin status; preview, buttons, menu and keyboard drag alternative. **DoD:** complete copy/paste operation via VoiceOver.
- [ ] **P7-08 Permissions/onboarding:** explain continuous clipboard history, accessibility auto-paste, sensitive exclusions, privacy controls. **DoD:** permissions denied/revoked state independently works.
- [ ] **P7-09 Appearance accessibility:** Reduce Motion, VoiceOver focus restoration, high contrast, menu bar over fullscreen. **DoD:** accessibility QA checklist passes.

**Phase 7 exit:** no missing core settings or accessibility-critical workflow; setting behaviors documented.

### PHASE 8 — Reliability/performance/security hardening (G5/G6)

- [ ] **P8-01 Leak/retention stress:** memory graph + synthetic 50k copies + orphan FK/FTS checks. **DoD:** stable bounded growth and no orphaned representations.
- [ ] **P8-02 Paste regression lab:** Finder, Safari, Chrome, Notes, Pages, Terminal, IDE, Spotlight, remote desktop, full-screen. **DoD:** documented matrix and fallback in unsupported targets.
- [ ] **P8-03 Layout regression:** multi-monitor, disconnection, scaled displays, Stage Manager, IME, overlay priority, preview safe bounds. **DoD:** no offscreen popup or stuck mouse intercept.
- [ ] **P8-04 Privacy audit:** denied markers, deleted items, logs, permissions, clipboard race, OCR/preview caches, external network review. **DoD:** no captured secrets in diagnostics; threat model updated.
- [ ] **P8-05 FFI fuzz/property tests:** malformed payload sizes/UTIs/invalid UTF-8; no panics across boundary. **DoD:** fuzz corpus clean and failure returns typed error.
- [ ] **P8-06 Performance benchmarks:** idle CPU/wakeups, memory, history summon, search, paste, thumbnails. **DoD:** thresholds in §10 met on real Apple silicon hardware.
- [ ] **P8-07 Database recovery:** migration failure/low disk/disk corruption/WAL checkpoint/forced kill, clean resume. **DoD:** no routine startup multi-minute cleanup.
- [ ] **P8-08 Parity signoff:** revisit feature inventory. **DoD:** every P0/P1 `F` ID has evidence, no unresolved high-severity regressions.

**Phase 8 exit:** privacy- and performance-reviewed candidate with all user-visible parity features complete.

### PHASE 9 — Packaging, CI, release and maintenance (G6)

- [ ] **P9-01 Developer ID:** hardened runtime, entitlement review, macOS 15 minimum, arm64-only archive. **DoD:** `codesign --verify --deep --strict` and arm64 architecture checks.
- [ ] **P9-02 Notarization:** Apple notary service credentials stored in secure CI secret provider; staple DMG. **DoD:** notarization approved and Gatekeeper test on separate Mac.
- [ ] **P9-03 Package:** accessible install experience, signed DMG, distribution manifest, checksums. **DoD:** fresh install/uninstall tested without leaving sensitive files unexpectedly.
- [ ] **P9-04 Update plan:** evaluate Sparkle signed appcast or manual downloads; verify threat model. **DoD:** downgrade/upgrades tested; no insecure auto-update mechanism.
- [ ] **P9-05 CI:** format, clippy, Rust tests, Swift build/tests, architecture check, dependency license audit, release artifacts. **DoD:** PR cannot merge with failing verified gates.
- [ ] **P9-06 Documentation:** README, keyboard guide, privacy note, permission troubleshooting, advanced `defaults`, changelog, issue template, third-party notices. **DoD:** clean-room user can install/use without support.
- [ ] **P9-07 RC testing:** two different Apple silicon Macs/OS versions if accessible; Mac 15.x and 26.x specifically. **DoD:** complete §9 manual test sheet, release tag, known limitations.

**Phase 9 exit:** signed, notarized, independently installable **Mimra v1.0** with demonstrable feature parity.

### PHASE 10 — Mimra-only differentiators (post-parity, optional G7)

- [ ] **P10-01 [+] Privacy profiles:** Work/Personal/Presentation profiles with app-level capture filters. Don't silently change permissions.
- [ ] **P10-02 [+] Sensitive-pattern review:** optional configurable heuristics (JWT/API-token/high-entropy patterns), **disabled by default** until false-positive UX tested; never claim guaranteed secret detection.
- [ ] **P10-03 [+] Configurable automatic expiration:** per-app and per-content-type TTL (e.g., OTP-like 1–5 minutes), with clear disclosure.
- [ ] **P10-04 [+] Offline encrypted-at-rest vault:** Keychain-managed SQLCipher prototype; validate entire DB + FTS + WAL and recovery on signing/notarized build; do not ship half-encryption.
- [ ] **P10-05 [+] Paste-as-transform:** explicitly opted-in trim/convert-case/normalize whitespace; preserve original item, show preview and no network AI.
- [ ] **P10-06 [+] Better workflow:** temporary paste stack / multi-item sequential paste, accessible hotkeys, reversible configuration, with strict privacy controls.
- [ ] **P10-08 [+] Optional sync research:** only after explicit security/privacy design; CloudKit does **not automatically guarantee end-to-end encryption** for custom content. Require user-controlled encryption and threat-model review before claiming E2EE.

---

## 9. Test plan with named acceptance scenarios

### 9.1 Rust automated tests (`cargo test`)

| Test ID | Exact scenario | Pass condition |
|---|---|---|
| T-CAP-01 | 100 unchanged clipboard polls | 0 Rust ingest calls and no DB writes |
| T-CAP-02 | UTF-8, emoji, CJK, empty/space-only, multiline text | No crash, deterministic policy and accurate replay |
| T-CAP-03 | Multiple representations and 2 pasteboard items | One logical event with proper group order |
| T-CAP-05 | Repeated copied identical text, Safari URL variants, Sheets | Expected recopy policy, no duplicate flood |
| T-TYPE-01 | RTF + HTML + text from fixture | All selected representations persisted and restored |
| T-TYPE-02 | PNG/TIFF/JPEG/HEIC image fixtures | Type-aware bytes valid, preview built async |
| T-TYPE-03 | File references / multiple file URLs | Round-trip references without plain-text downgrade |
| T-PRIV-01 | Concealed/transient/autogenerated UTI | No ingest, no OCR, no thumbnail, no logs |
| T-PRIV-02 | Custom ignored UTI | Pre-read filter rejects content |
| T-PRIV-03 | Ignored bundle app outside `/Applications` | Exclusion applied to captures |
| T-PRIV-04 | Universal Clipboard marker enabled | Excluded only when opted in |
| T-PRIV-06 | Pause and ignore-next across rapid changes | Exactly intended events omitted |
| T-HIST-01 | Clear unpinned vs clear all | Pins protected until explicitly confirmed clear all |
| T-HIST-02 | Persistence and migrations across restart | History and schema recover |
| T-HIST-03 | Pinned item at full retention capacity | No pinned eviction or panic |
| T-HIST-05 | Repeated insert/evict/clear (50k) | 0 orphan content/FTS, bounded DB size after maintenance |
| T-SRCH-01 | 10k items and 20 queries | Correct ranked results, bounded latency |
| T-SRCH-02 | Regex invalid/giant/non-ASCII | Graceful error, no crash/pathological lag |
| T-SRCH-04 | OCR results arriving after delete | No content resurrection |
| T-PIN-01 | Conflicting/reassigned keyboard pin keys | Unique bindings enforced |
| T-PIN-02 | Edit pin content | Search & replay reflect new content |
| T-PIN-03 | Drag/order edits persisted | Stable order and keyboard mappings |
| T-OCR-01 | Synthetic image with 2 languages | Text indexed on-device where Vision supports it |
| T-OCR-02 | OCR copy action | Correct extracted text; no request to remote endpoint |
| T-FFI-01 | Pass >10 MB or malformed bytes | Controlled rejection without aborting process |
| T-DB-01 | Simulated low disk/corruption/kill during transaction | No silent data loss; explicit recovery path |

### 9.2 Native manual / UI automation scenarios

**Each ID requires reproducible steps, OS/app version, screenshot or test log, expected/observed status, severity, and link to code/test.**

| Test ID | Check |
|---|---|
| T-UI-01 | Menu bar icon, summon and quiet non-Dock operation |
| T-UI-02 | Resize and scroll while history updates |
| T-UI-03 | Keyboard/mouse/IME selection without spurious hover changes |
| T-UI-04 | Preferences accessible even with hidden search/footer |
| T-UI-06 | Fullscreen, Chrome autocomplete, multi-monitor clamping |
| T-UI-07 | Removed external monitor doesn't strand panel off-screen |
| T-PASTE-01 | Copy-only vs paste to original target in each configured mode |
| T-PASTE-02 | Plain text paste correct, files/images explicitly handled |
| T-PASTE-03 | Accessibility denied/revoked then granted; copy fallback works |
| T-KEY-01 | Quick select 1–9 under each modifier |
| T-KEY-02 | Hotkey collisions and registration/unregistration |
| T-KEY-03 | Page Up/Down and delete selection stability |
| T-KEY-04 | Summon key cycle while holding/releasing modifiers |
| T-KEY-05 | `Control-K`, `Command-Z`, IME and system-reserved shortcut behavior |
| T-PREV-01 | Preview `Control-Space`, screen edge, resize, focus |
| T-PREV-02 | Auto preview, close no mouse capture, no view freeze |
| T-PREV-03 | Long text scrolling and layout |
| T-PREV-04 | Image preview sizes / HEIC / image dimensions |
| T-I18N-01 | Dvorak, French AZERTY, Japanese IME composing text |
| T-I18N-02 | English + another localization + RTL smoke tests |
| T-A11Y-01 | VoiceOver full search/pin/paste and labeled controls |
| T-REL-01 | Login item state, clean install, notarization, upgrade |
| T-SET-01 | General settings persistence |
| T-SET-02 | Denylist editor and types persistence |
| T-SET-03 | Appearance/Preview/Search settings persistence |

### 9.3 High-risk regression scenarios 

- Deleting first unpinned item must not select a wrong row.
- Clearing/deleting several items rapidly must not crash.
- Copying bottom-most pinned item at full capacity must not crash.
- Closing preview while moving mouse must not freeze/steal pointer events.
- Preview hotkey must not be accidentally registered globally.
- Popup must remain inside active screen and work over Chrome autofill/fullscreen.
- Copying from VS Code/Notes/Safari/Google Sheets must not flood history with duplicate variants.
- OCR and image previews must not decode unnecessarily on every list render.
- Large text preview must scroll/layout without large allocations/hangs.
- SQLite item representation rows and search rows must be removed on eviction, avoiding history database growth.
- User-facing settings numeric fields must not lose unsaved edits when focus changes.
- Search item with U+FFFC object replacement character must never hang UI.
- Japanese IME conversion confirmation must not accidentally paste an item.
- Password manager transient/concealed content must not be ingested.

---

## 10. Nonfunctional budgets and profiling methodology

**Targets below are Mimra engineering goals.** Measure real arm64 macOS hardware with a warmed database plus cold-start runs; document exact model, OS, sample size and method. Performance may be revised with evidence, but no silent budget removal.

| Metric | Initial target | Test method |
|---|---|---|
| Popup summon to usable search | p95 < 120 ms warm | 200 repetitions, UI signposts |
| Search over 10k mostly-text items | p95 < 50 ms Rust query | 100 queries, stable cold/warm distinction |
| 20k mixed history scroll | >= 55 FPS typical | Instruments + representative laptop |
| Unchanged-pasteboard idle CPU | < 0.5% average single process | 10-min Instruments measurement, on AC/battery |
| Clipboard read after detection | < 100 ms typical non-media | Signpost elapsed for ingestion |
| OCR | Deferred; never blocks typing/paste | Stress overlapping recognition tasks |
| Memory | No unbounded growth across 50k churn | Instruments allocations/leaks; record peak and steady-state |
| Rust→Swift error containment | 100% deterministic typed failures | FFI malformed input corpus |
| Data integrity | 0 orphan rows, 0 lost pinned items | DB integrity/churn tests |
| Network | 0 clipboard-content network requests | offline test and network inspection |
| Main-thread I/O | 0 synchronous SQLite/OCR/large decode | Instruments Thread Performance Checker |

For a performance regression: retain baseline report, reproduce with fixed fixture, profile, implement focused fix, then rerun against same machine/OS. No speculative “micro-optimizations” before correctness.

---

## 11. Security, quality and release gates

### Definition of Done for *every* task

- [ ] Fulfills linked `F-` feature and task specification; no behavior changed unexpectedly.
- [ ] Swift passes current strict-concurrency build and tests where relevant.
- [ ] Rust passes `cargo fmt --check`, `cargo clippy -- -D warnings`, unit/integration tests.
- [ ] Includes negative/cancellation/race tests where there is I/O, permission, concurrency or clipboard content.
- [ ] No raw clipboard content in logs, fixtures from real users, screenshots or telemetry.
- [ ] If adds DB schema change: migration forward test, cleanup/integrity test, recovery behavior.
- [ ] If adds OS interaction: tested on actual macOS 15+ Apple silicon device or marked `NOT VERIFIED` and blocked from release gate.
- [ ] No duplicated architecture layers; no `unsafe` Rust without a reviewed and documented justification.
- [ ] New setting localized; VoiceOver and keyboard navigation checked.
- [ ] `docs/STATUS.md` and parity matrix updated, with exact test commands/results.

### PR / agent report format (mandatory)

```markdown
## Task
P#-## — <one concise objective>

## Scope
Files/modules changed, related F IDs, constraints and dependencies.

## Implementation
Key choices and behavior, including fallback/error paths.

## Verification
- Environment: Xcode, SDK, macOS, hardware, Rust versions.
- Commands actually run: ...
- Tests passed: ...
- Tests not run: ... with why and exact commands for Mac.
- Manual steps and observed outcome: ...

## Privacy & quality
Clipboard contents in logs? [No/Explain]. New permissions? [No/Explain].
FFI/DB migration changes? [No/Explain]. Potential regressions? ...

## Remaining work
Open issues, risks and next unblocked task.
```

### Release blockade criteria (must have zero)

- Known path to capture concealed, excluded or transient entries into persistent history.
- Known wrong-target paste, permission bypass attempt or undisclosed Accessibility dependency.
- Crash/hang in common capture/paste flows, data corruption, orphaned DB payload growth.
- UI unusable with keyboard/VoiceOver at core flows; launch fails on macOS 15 arm64.
- Unreviewed dependencies or secrets in repository / release package.
- Unnotarized or incorrectly signed distributed binary presented as official signed release.
- Any P0/P1 parity row incorrectly marked verified or abandoned silently.

---

## 12. Open decisions and experiments (resolve; do not guess)

| ID | Decision/unknown | Proposed default | Evidence required |
|---|---|---|---|
| D-01 | Exact settings and default mappings | Audit mandatory | Baseline UI screenshots + manual checklist |
| D-02 | Background clipboard privacy prompts on macOS 15 vs 26 | Respect system UI, provide transparent onboarding | Real macOS 15/26 behavior and current Apple docs |
| D-03 | Carbon RegisterEventHotKey / shortcut helper feasibility | Narrow OS-supported global hotkey registration | Signed arm64 prototype + keyboard layout tests |
| D-04 | `NSPanel` nonactivating focus + IME behavior | Test multiple AppKit styles | Real Safari/Terminal/IME/fullscreen matrix |
| D-05 | Rust UniFFI strict Sendable limitations | Sync Rust API on worker | Version-pinned build and thread sanitizer tests |
| D-06 | SQLite FTS5 + optional SQLCipher static linking | Plain local SQLite first; encrypt after parity | Build/link, FTS, WAL, migration, key recovery tests |
| D-07 | Minimum supported media payload size | Conservative documented cap | Real image memory and storage profiling |
| D-08 | App sandbox/Apple App Store distribution | Direct Developer ID app baseline | Entitlements, signing, App Review requirements |
| D-09 | File URL fidelity across sandbox boundaries | Preserve native file-url data; show safe failure | Finder/Notes/Pages/Mail tests and sandbox docs |
| D-10 | Unverified legacy preferences and history sorting | Don't claim parity until confirmed | 2.8 app inspection |
| D-11 | iCloud sync status | Not a parity requirement | Design and threat model review |
| D-12 | macOS 26 Spotlight clipboard coexistence | Don't alter other app's history | User test for duplicate/copy interference |

---

## 13. Final release readiness checklist

- [ ] At least one real machine with **macOS 15 arm64** passes full clipboard, hotkey and copy/paste test plan.
- [ ] At least one real machine with **macOS 26 arm64** passes same plan (if available); record unsupported/untested combinations honestly.
- [ ] Core feature parity audit complete; all `F-001`–`F-064` checked, with `[R]` items verified or reclassified, and no undocumented P0/P1 gap.
- [ ] Rust unit/integration tests pass; Swift builds in strict concurrency; UI automation green on Mac; unrun manual tests listed.
- [ ] Accessibility/VoiceOver complete for open, search, paste, pin, edit, delete and settings.
- [ ] User understands why clipboard data is stored; app excludes known secret markers and respects ignored apps.
- [ ] Default experience uses no networking; no telemetry; no raw clipboard logging; no unintended sync.
- [ ] Rust/Swift binary is **arm64**, correctly signed and notarized; `codesign`, `spctl`, first-install Gatekeeper validated.
- [ ] DB retention and cleanup stress pass, with verified no orphaned representations or stale FTS entries.
- [ ] Code license, third-party notices, attribution notices (if any external code was used), icon/brand ownership reviewed.
- [ ] Restore/paste works in real apps and never silently targets the wrong app.
- [ ] Release changelog/README/keyboard cheatsheet/known limitations and troubleshooting published.

---

## 14. Research footnotes, provenance and cautions
- UniFFI Swift guide: https://mozilla.github.io/uniffi-rs/latest/swift/overview.html
- Apple `NSPasteboard` documentation: https://developer.apple.com/documentation/appkit/nspasteboard
- Apple `SMAppService` login API: https://developer.apple.com/documentation/servicemanagement/smappservice
- Apple Vision text recognition: https://developer.apple.com/documentation/vision/vnrecognizetextrequest

**Audit limitation:** This plan is based on platform API specifications, system frameworks, and documented requirements. Items tagged `[R]` require hands-on verification on device. The plan intentionally avoids presenting unverifiable preferences and cloud sync as confirmed requirements.

