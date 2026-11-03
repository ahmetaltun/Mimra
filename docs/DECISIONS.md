# Mimra — Architecture Decision Records (ADRs)

> This document records key architectural decisions, rationale, trade-offs, and consequences for Mimra.

---

## ADR-001: Component Ownership & Language Separation

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Mimra requires seamless native macOS look, feel, accessibility, and pasteboard integration, combined with predictable, high-performance, crash-safe data storage, indexing, and deduplication.

### Decision
We enforce a strict two-tier architecture:
1. **AppKit + SwiftUI (macOS Adapter & UI):**
   - Owns UI layout, `NSPanel`, `NSStatusItem`, keyboard events, `NSPasteboard` polling, and Accessibility paste.
   - **Prohibited:** Never directly executes SQL, manages disk persistence, or performs deduplication.
2. **Rust (`RustCore`):**
   - Owns SQLite database management, schema migrations, FTS5 full-text indexing, content hashing (`BLAKE3`), deduplication, retention eviction, and search ranking.
   - **Prohibited:** Never imports or calls macOS AppKit/UIKit APIs directly.

### Consequences
* **Positive:** Clean separation of concerns. UI changes cannot corrupt persistent state. Rust logic is 100% testable via standard `cargo test` on macOS/Linux.
* **Negative:** Requires an FFI boundary and serializing DTOs between Swift and Rust.

---

## ADR-002: UniFFI Statically-Linked Native Bridge (`aarch64-apple-darwin`)

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Communication between Swift and Rust needs to be type-safe, performant, and resilient against runtime symbol resolution failures.

### Decision
* We will use **UniFFI** to generate type-safe Swift bindings from Rust declarations.
* `RustCore` will be compiled as an `aarch64-apple-darwin` static library (`.a`) and linked directly into the macOS application binary.
* No separate background helper daemons or dynamic libraries (`.dylib`) with fragile `@rpath` dependencies will be used in v1.

### Consequences
* **Positive:** Monolithic, self-contained arm64 binary. No dynamic library loading issues or dylib search path hijack vulnerabilities.
* **Negative:** Compilation requires rustc toolchain and build step before Xcode linking.

---

## ADR-003: Concurrency and Thread Safety Policy

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
macOS main thread must remain completely fluid (60/120 FPS). Generated UniFFI sync calls can perform disk I/O, hash computations, or database locks.

### Decision
1. All AppKit coordinators (`PanelCoordinator`, `ClipboardMonitor`, `PasteCoordinator`) reside on the `@MainActor`.
2. All UniFFI Rust calls **must be dispatched off the main thread** using a dedicated serial background queue or Swift `actor` executor.
3. The main thread will only receive immutable Swift DTOs ready for display.
4. Rust errors across FFI are returned as typed `Result<T, CoreError>` and mapped to Swift `CoreError` enums. Rust code must never panic across the FFI boundary.

### Consequences
* **Positive:** Guaranteed zero main-thread disk I/O or SQLite lock contention. Complies with Swift 6 strict concurrency checks.
* **Negative:** Asynchronous coordination required between UI events and database queries.

---

## ADR-004: Ingestion Boundary & Privacy Pre-Filter in Swift

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Users copy sensitive credentials, password manager items, and private content. Password managers mark these items with specific pasteboard types (e.g., `org.nspasteboard.ConcealedType`). Storing or indexing these violates privacy.

### Decision
1. Swift's `ClipboardMonitor` inspects `NSPasteboard` metadata, item types, and source application bundle identifier **before reading or copying any payload bytes**.
2. If any concealed/transient marker is present, or if the source application is in the user's ignore list:
   - The pasteboard event is dropped immediately.
   - Zero payload bytes are extracted.
   - The event **never reaches Rust, SQLite, thumbnails, OCR, or debug logs**.
3. Capture pause and "ignore next copy" states are tracked in Swift and reset safely upon observing an external pasteboard change.

### Consequences
* **Positive:** Fail-closed privacy guarantee. Credential markers cannot accidentally leak to disk or FTS5 indices.
* **Negative:** Swift monitor must maintain a comprehensive, documented list of known password manager UTIs.

---

## ADR-005: Menu-Bar Agent Application Model (`LSUIElement = true`)

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
A clipboard manager must be unobtrusive, available globally, and never clutter the macOS Dock or Mission Control.

### Decision
1. Configure `Info.plist` with `LSUIElement = true` (Application is agent).
2. Maintain a status item (`NSStatusItem`) in the system menu bar at all times to serve as an anchor and provide fallback access to Settings, Pause, Clear, and Quit.
3. Display history using an `NSPanel` with `.nonactivatingPanel` behavior to prevent stealing focus from active applications during invocation.

### Consequences
* **Positive:** Unobtrusive system utility matching proven user interaction models.
* **Negative:** Requires careful handling of key window status, keyboard event dispatching, and IME (Input Method Editor) focus.

---

## ADR-006: Paste and Focus Restoration Protocol

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
When the user selects an item to paste, Mimra must dismiss itself, return focus to the previously active application, and simulate a paste keystroke without race conditions or targeting the wrong window.

### Decision
1. Prior to opening the popup panel, record the active foreground application PID (`NSWorkspace.shared.frontmostApplication`).
2. Upon user paste selection:
   - Copy the target representations to `NSPasteboard.general` stamped with a private Mimra provenance marker (`com.mimra.provenance`) to prevent self-recapture.
   - Dismiss the `NSPanel`.
   - Restore focus to the recorded target application.
   - If Accessibility permission is granted: simulate `Command-V` using `CGEvent`.
   - If Accessibility permission is NOT granted: retain the payload on the clipboard, do not inject keystrokes, and present an explanatory notice to the user.
3. If the target application has terminated or focus switched to an unexpected application, abort the simulated keystroke and keep the item on the clipboard.

### Consequences
* **Positive:** Safe, reliable paste behavior that never pastes into unauthorized or wrong windows. Clear fallback for users without Accessibility rights.
* **Negative:** Accessibility permission required for automatic paste.

---

## ADR-007: SQLite Storage Engine, FTS5, and Data Integrity

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Clipboard history can contain thousands of text items, URLs, rich text representations, and image metadata. Queries must be instant, and deletion must never leave orphaned content or search index entries.

### Decision
1. Rust manages a local SQLite database with `PRAGMA foreign_keys = ON;` and `PRAGMA journal_mode = WAL;`.
2. Content representations are stored in an `item_representations` table with `ON DELETE CASCADE` referencing `history_items(id)`.
3. Fast search is backed by an `fts5` virtual table (`search_fts`) synchronized inside single database transactions with `history_items`.
4. Ingestion, duplicate resolution, and retention limit eviction occur in a single atomic transaction.
5. All migrations are numbered, tracked in `schema_migrations`, and verified by forward-migration unit tests.

### Consequences
* **Positive:** High query speed, crash resilience (WAL mode), zero orphaned representation blobs, and ACID guarantees.
* **Negative:** Requires bundled SQLite build configuration with FTS5 enabled.


---

## ADR-008: macOS 15+ & macOS 26 Policy, Permissions & Hotkey Strategy

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Clipboard managers require global hotkey summoning, continuous clipboard observation, and focus-restored keystroke injection (`Command-V`). macOS 15 and macOS 26 enforce strict privacy controls around background event observation and input injection.

### Decision
1. **Global Hotkey Summoning:**
   - Use the native Carbon `RegisterEventHotKey` API for the global summon shortcut (`Shift-Command-C` default).
   - **Rationale:** Unlike `CGEventTap`, `RegisterEventHotKey` does **not** require Accessibility (`AXIsProcessTrusted`) permissions, allowing users to summon Mimra immediately upon first launch without onboarding permission friction.
2. **Keystroke Simulation & Accessibility Degradation:**
   - Automatic paste uses `CGEventPost` to inject `Command-V` to the previous foreground process.
   - Injecting events requires Accessibility permissions (`AXIsProcessTrusted`).
   - If Accessibility is not granted, Mimra degrades gracefully to **Copy-Only Mode**: the user's selected item is loaded into `NSPasteboard.general`, and a non-intrusive banner explains that manual pasting (`Command-V`) is active until Accessibility is enabled in System Settings.
3. **Background Clipboard Polling:**
   - Polling `NSPasteboard.general.changeCount` every ~500ms is standard for user-session utilities on macOS 15+ and does not require elevated entitlements.
   - Reading payload data occurs strictly after changeCount advances and passes our Swift privacy pre-filters.
4. **Distribution Target:**
   - Direct Developer ID notarized distribution. Sandboxed Mac App Store distribution restricts synthetic keystroke injection, preventing automatic paste capability.

### Consequences
* **Positive:** Frictionless initial onboarding (summon works immediately without permissions). Safe fallback for users who deny Accessibility rights.
* **Negative:** Automatic paste requires user consent in macOS System Settings > Privacy & Security > Accessibility.

---

## ADR-009: Swift 6 Strict Concurrency Isolation via `CoreClient` Actor

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Under Swift 6 with `-strict-concurrency=complete`, passing mutable state or performing synchronous blocking operations across concurrency domains is prohibited. The UniFFI-generated Swift binding wraps Rust objects (`MimraCoreHandle`), which contain an internal thread-safe Rust `Mutex<rusqlite::Connection>`. Calling Rust SQLite queries from `@MainActor` would block UI rendering.

### Decision
1. Wrap `MimraCoreHandle` within a Swift `actor CoreClient` executing off the main actor.
2. Mark `MimraCoreHandle` and pure value DTOs (`IngestResultDto`, `HistoryItemSummaryDto`, `StorageStatsDto`, `RawRepresentation`, `RawCapture`) with `@unchecked Sendable` conformance.
3. `@MainActor` components (`ClipboardMonitor`, `StatusBarCoordinator`, `HistoryView`) communicate with `CoreClient` exclusively via `async`/`await`.
4. Ensure the SQLite storage directory `~/Library/Application Support/com.mimra.app` is created with POSIX `0700` (`rwx------`) permissions so that only the current user can access the database file.

### Consequences
* **Positive:** Complete elimination of main thread blocking during database writes, queries, and retention cleanups. Enforces strict zero-leak file permissions.
* **Negative:** Requires asynchronous calls and task coordination from SwiftUI / AppKit.
