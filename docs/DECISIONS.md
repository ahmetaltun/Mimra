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

---

## ADR-010: Floating Panel Architecture & Non-Activating Behavior

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Clipboard manager summon must appear instantly over any workspace, including full-screen Spaces and auxiliary display windows, without stealing application activation from the foreground target process. Keystrokes must focus the search field while clicking outside or pressing Escape must smoothly dismiss the panel without corrupting window ordering.

### Decision
1. Implement `FloatingPanel` as an `NSPanel` subclass configured with:
   - `styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView]`
   - `level = .floating`
   - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
   - `canBecomeKey = true` (allows search text input focus)
   - `canBecomeMain = false` (prevents stealing main window/app focus)
   - Custom borderless translucent styling with `.ultraThinMaterial` and rounded corners.
2. Adopt **Option A (Screen Center on Active Display)** as the primary summon placement:
   - Identify active display containing the current mouse location (`NSEvent.mouseLocation`).
   - Clamp and center panel coordinates within `screen.visibleFrame`.
3. Track the target foreground application PID (`NSWorkspace.shared.frontmostApplication`) immediately before ordering front.
4. Dismiss on `resignKey()` or `cancelOperation` (Escape key) through clean delegate callbacks.

### Consequences
* **Positive:** Consistent summoning over all Spaces, full-screen apps, and multi-monitor setups; keyboard-first search focus; guaranteed tracking of target application for subsequent paste injection.
* **Negative:** Requires custom key navigation event routing.

---

## ADR-011: Carbon Hotkey State Isolation Under Swift 6 Strict Concurrency

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Under Swift 6 with `-strict-concurrency=complete`, types that wrap non-Sendable C pointers (such as `EventHandlerRef` and `EventHotKeyRef` from Carbon HIToolbox) cannot be directly manipulated in nonisolated class deinitializers of `@MainActor` types without violating strict concurrency safety.

### Decision
1. Encapsulate raw Carbon pointers (`EventHandlerRef`, `[UInt32: EventHotKeyRef]`) inside a dedicated `@unchecked Sendable` reference wrapper `CarbonHotKeyState`.
2. Clean up Carbon event handlers and hotkey registrations deterministically in `CarbonHotKeyState.deinit` as well as via an explicit `@MainActor func unregisterAll()` method during clean app termination.
3. Keep the high-level `HotkeyManager` class bound to `@MainActor` for seamless interaction with `PanelCoordinator` and UI components.

### Consequences
* **Positive:** Complete elimination of Swift 6 actor-isolation deinit errors; clean Carbon registration and unregistration lifecycle.
* **Negative:** Requires an inner pointer-holding state object.

---

## ADR-012: Status Bar Interaction Model & Modifier-Aware Clicks

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Standard macOS menu bar utilities provide multi-action capability from a single status bar item (primary toggle vs settings vs pausing vs context menu) without cluttering the menu bar with multiple controls. Setting `NSStatusItem.menu` directly suppresses custom left-click actions because AppKit automatically intercepts all mouse events to display the menu.

### Decision
1. Do not attach `NSMenu` directly to `statusItem.menu`. Instead, retain it in `contextMenu` and configure the status button to dispatch both `.leftMouseUp` and `.rightMouseUp` actions to a unified handler.
2. Implement modifier-aware click routing:
   - **Left-Click:** Toggles the native floating clipboard panel (`panelCoordinator.toggle()`).
   - **Option-Click:** Toggles capture pause/resume state directly (`togglePause()`) and updates the menu bar icon (`pause.circle` vs `doc.on.clipboard`) and accessibility label.
   - **Option-Shift-Click:** Opens Mimra Settings directly (`openSettings()`).
   - **Right-Click / Control-Click:** Presents the context menu positioned directly under the button using `menu.popUp(positioning:at:in:)`.

### Consequences
* **Positive:** Complete behavioral parity; instantaneous single-click panel summoning without intermediate menu friction; instant pause and settings shortcuts.
* **Negative:** Custom click event handling requires careful tracking of `NSApp.currentEvent` modifier flags.

---

## ADR-013: Search Interaction, Keyboard Navigation, and Local Event Monitor Isolation

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Users require fast keyboard-driven interaction within the floating clipboard panel: Up/Down arrow selection with wrap-around, Quick-pick via `⌘1`–`⌘9`, Return/Keypad Enter to commit, Escape to dismiss, `⌘,` to open Settings, and real-time FTS5/prefix filtering. In addition, mouse hovering must not accidentally overwrite keyboard selection (requiring a 250ms guard against spurious mouse motion).

In Swift 6 strict concurrency (`-strict-concurrency=complete`), `NSEvent.addLocalMonitorForEvents` returns an `Any?` token that cannot be accessed or deallocated from a nonisolated class `deinit` on a `@MainActor` class.

### Decision
1. Implement a reactive `PanelViewModel` managing:
   - Synchronous/asynchronous query filtering against SQLite / RustCore.
   - Circular keyboard selection navigation with wrap-around across item counts.
   - Quick-pick indexing (`⌘1`–`⌘9`) mapping directly to the displayed slice.
   - Mouse hover timestamp gating (ignoring hover events within 250ms of keyboard navigation).
   - Selection persistence and auto-scrolling via `ScrollViewReader`.
2. Intercept keyboard events using `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` when the panel is key window.
3. Encapsulate the local key monitor token in a thread-safe `KeyMonitorState: @unchecked Sendable` reference box with deterministic cleanup in its own `deinit` and explicit removal methods, satisfying Swift 6 isolation invariants.

### Consequences
* **Positive:** Fluid, zero-latency keyboard-first search and navigation; robust hover guard; full compliance with Swift 6 strict concurrency.
* **Negative:** Local event monitoring requires explicit unregistration on teardown.

---

## ADR-014: Replay Codec & Multi-Representation Pasteboard Reconstruction

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
When a user selects an item from Mimra's history, the stored representations must be accurately reconstituted on the system `NSPasteboard` without:
1. Losing original representations (e.g. rich text alongside plain text, multiple items copied together, or file URLs).
2. Triggering self-recapture feedback loops (where Mimra's own write is detected as a new copy).
3. Degrading data fidelity during plain-text paste downgrade requests.
4. Leaking confidential payloads or secret markers into system logs.

### Decision
1. Expose `get_item_representations(item_id: String) -> Result<Vec<RawRepresentation>, CoreError>` via Rust UniFFI to atomically retrieve all representations for an item in a single FFI boundary traversal.
2. Implement `PasteCoordinator` in Swift on the `@MainActor`:
   - **Original Mode (`.original`):** Group stored representations by their original `groupIndex` and generate native `NSPasteboardItem` instances. For each item, attach all preserved UTIs (`public.utf8-plain-text`, `public.html`, `public.rtf`, etc.).
   - **Plain Text Mode (`.plainText`):** Extract the canonical plain-text representation (or convert RTF/HTML via `NSAttributedString`), stripping formatting and populating a single `.string` / `public.utf8-plain-text` item.
   - **Multi-Item Support:** Multiple items (such as multiple files or selections) are preserved and reconstructed with matching item count and group indexing.
   - **Provenance Stamping:** Every reconstructed `NSPasteboardItem` is stamped with `ClipboardProvenance.provenanceType` (`com.mimra.provenance`) and source bundle `org.nspasteboard.source` (`com.mimra.app`), followed immediately by registering the resulting `changeCount` with `ClipboardProvenance.shared`.
3. Provide strongly-typed, explanatory errors (`PasteError.itemNotFound`, `PasteError.noValidRepresentations`, `PasteError.writeFailed`).

### Consequences
* **Positive:** Byte-for-byte fidelity across plain text, rich text, and multi-item copies; zero self-recapture loop risk; clean plain-text stripping; fully verified across FFI.
* **Negative:** Requires holding all representations for the target item in memory during the write operation (bounded by 10 MB limit).

---

## ADR-015: Focus Tracking, Focus Restoration, and Synthetic Keystroke Injection (Command-V)

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
When selecting an item from the floating panel to paste into a target application:
1. Mimra must know which application was frontmost before the panel was summoned.
2. Focus must be transferred smoothly back to that application before keystrokes are synthesized.
3. Keystrokes must be synthesized using supported macOS APIs without crashing or corrupting input queues.
4. If Accessibility permissions (`AXIsProcessTrusted()`) are unavailable or denied, Mimra must degrade safely to Copy-Only mode without panicking or posting unprivileged events.
5. Mimra must never inject keystrokes into itself or into an unexpected app.

### Decision
1. **Focus Tracking:**
   - In `PanelCoordinator.show()`, capture the frontmost application (`NSWorkspace.shared.frontmostApplication`), ignoring activations if the frontmost app is Mimra itself.
2. **Focus Restoration & Dismissal:**
   - Upon item selection, immediately hide the floating panel (`panel.orderOut(nil)`), freeing the WindowServer to restore focus to the previously active application.
   - Activate the target application explicitly via `targetApp.activate()`.
   - Provide an asynchronous delay (configurable, default 30ms) allowing the WindowServer window-focus handoff to complete.
3. **Synthetic Keystroke Injection:**
   - Inject `Command-V` using `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with key code `0x09` (`kVK_ANSI_V`) and `.maskCommand` flag.
   - Post events via `CGEventPost(.cghidEventTap, ...)` to the system event stream.
   - Inject `accessibilityChecker` and `keystrokePoster` dependencies into `PasteCoordinator` to guarantee deterministic automated testing without triggering physical keystrokes during CI test suites.
4. **Structured Outcomes:**
   - Return strongly-typed `PasteResult`:
     - `.pastedSuccessfully(targetPid:targetBundleId:)`
     - `.copiedOnly(reason:)` (`.autoPasteDisabled`, `.noTargetApplication`, `.targetAppTerminated`, `.accessibilityPermissionDenied`).
5. **Parity Modifier Support:**
   - Support `Option-Return` to toggle the user's `pasteAutomatically` setting for a single commit.
   - Support `Option-Shift-Return` and `Option-Shift-⌘1..9` to paste plain text.

### Consequences
* **Positive:** Robust clipboard behavior; safe and reliable keystroke injection; clean focus restoration; testable via dependency injection.
* **Negative:** Focus switching requires a short async delay before posting keystrokes.

---

## ADR-016: Plain Paste Format Stripping & Decoded POSIX File Reference Downgrade

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
When pasting clipboard history items without formatting (`PasteMode.plainText`, triggered via `Shift-Return`, `Option-Shift-Return`, `Shift-⌘1..9`, or `Option-Shift-⌘1..9`), applications must receive strictly unformatted text. This introduces several edge cases:
1. Rich text documents often contain multiple representations (`public.rtf`, `public.html`, `com.apple.webarchive`) alongside plain text; all rich representations must be stripped from the pasteboard so destination apps cannot paste rich text.
2. Captures may have RTF-only or HTML-only payloads without explicit `public.utf8-plain-text` UTIs.
3. Captures of files copied in Finder or other utilities carry file references (`public.file-url`, `NSURLPboardType`, `NSFilenamesPboardType`) that may contain percent-encoded URLs (e.g. `file:///Users/username/My%20Folder/Report.pdf`). When pasting as plain text, users expect clean POSIX paths (e.g. `/Users/username/My Folder/Report.pdf`).
4. Multiple files copied simultaneously across multiple groups or array entries must be cleanly represented as newline-delimited paths (`/path1\n/path2`).
5. Binary media items (pure images or PDFs with no text representations) must gracefully fall back to original representations rather than causing an empty clipboard write.

### Decision
1. Implement `PasteCoordinator.extractPlainText(from:)`:
   - Checks standard plain-text UTIs (`public.utf8-plain-text`, `NSStringPboardType`, `public.plain-text`, `public.text`), trying UTF-8, UTF-16, and Latin-1 decoding.
   - Extracts plain text from RTF/RTFD via `NSAttributedString(data:options:[.documentType: .rtf/.rtfd])`.
   - Extracts plain text from HTML via `NSAttributedString(data:options:[.documentType: .html])`.
   - Deserializes `NSFilenamesPboardType` property lists or converts `public.file-url` / `NSURLPboardType` into decoded POSIX paths via `URL.path` (resolving `%20` and percent-encodings).
   - Joins multiple file references across groups with newline separators (`\n`).
   - Falls back to generic text representations (source code, JSON, CSV, XML).
2. In `encodePlainTextItem`:
   - If plain text is extracted, write a single `NSPasteboardItem` with type `.string` (`public.utf8-plain-text`) and provenance markers. All rich UTIs are cleared.
   - If plain text cannot be extracted (pure image), gracefully fall back to original representation (`encodeOriginalItems`).
3. Modifier routing:
   - `Shift-Return` and `Shift-⌘1..9` commit in `.plainText` mode.
   - `Option-Shift-Return` and `Option-Shift-⌘1..9` commit in `.plainText` mode with inverted auto-paste preference (`forcePaste: !pasteAutomatically`).

### Consequences
* **Positive:** Complete plain paste fidelity; clean file URL conversion; no formatting leaks into text editors; graceful binary fallback.
* **Negative:** Converting very large RTF/HTML strings via `NSAttributedString` incurs a small CPU parsing cost.

---

## ADR-017: Multi-Layered Keystroke Injection Safety Guards

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Automated paste managers synthesize keystrokes (`Command-V`) to paste data into target applications. If executed blindly, synthetic keystrokes present severe security and correctness hazards:
1. **Unintended Target Injection:** If the target application terminated, crashed, or minimized, or if another application (Spotlight, notification center, lock screen, or switched Spaces) intercepted focus, synthetic keystrokes could paste private clipboard contents into the wrong window.
2. **Credential Leaks into Password Fields:** Pasting into password fields (`AXSecureTextField`) or while Secure Event Input is active could compromise user credentials or inject history into secure system prompts.
3. **Accessibility Fallback:** If `AXIsProcessTrusted()` is false, synthetic event posting fails or triggers system dialogs.
4. **False Claims of Success:** Returning success when keystrokes were not actually delivered misleads UI indicators and diagnostics.

### Decision
Implement an airtight, multi-layered guard pipeline in `PasteCoordinator.paste(...)`:
1. **Atomic Write First:** Always write the replayed item to `NSPasteboard` with provenance markers first, guaranteeing user data is safe on the clipboard regardless of keystroke outcome.
2. **Target App Existence & Termination Guard:** Verify `targetApp` is non-nil, not Mimra itself (`bundleIdentifier != "com.mimra.app"`), and not terminated (`!targetApp.isTerminated`). If terminated, return `.copiedOnly(reason: .targetAppTerminated)`.
3. **Secure Event Input Guard:** Query `IsSecureEventInputEnabled()` via Carbon HIToolbox. If active, abort keystroke injection and return `.copiedOnly(reason: .secureInputActive)`.
4. **Password Field Focus Guard:** If Accessibility is granted, inspect the focused element in the target application via `AXUIElementCopyAttributeValue` for `kAXSubroleAttribute == "AXSecureTextField"` or `kAXRoleAttribute == "AXSecureTextField"`. If focused, abort keystrokes and return `.copiedOnly(reason: .passwordFieldFocused)`.
5. **Accessibility Trust Guard:** Query `AXIsProcessTrusted()`. If denied, degrade cleanly to `.copiedOnly(reason: .accessibilityPermissionDenied)`.
6. **Focus Restoration & Verification:** Call `targetApp.activate()`, yield for focus transition (`activationDelayNanoseconds`), and verify that `frontmostAppProvider()?.processIdentifier == targetApp.processIdentifier`. If focus was intercepted, switched to another Space, or failed, abort keystrokes and return `.copiedOnly(reason: .targetActivationFailed)`.
7. **Synthetic Keystroke Injection:** Post `Command-V` via `CGEventPost(.cghidEventTap)`. If posting fails, return `.copiedOnly(reason: .keystrokeInjectionFailed)`.
8. **Dependency Injection for Testing:** Abstract `secureInputChecker`, `passwordFieldChecker`, `frontmostAppProvider`, `accessibilityChecker`, and `keystrokePoster` as `@Sendable` closures with static system defaults, allowing 100% deterministic test coverage in CI and CLI runners.

### Consequences
* **Positive:** Absolute guarantee that Mimra never pastes to an unintended target or password field; transparent degradation to copy-only mode with descriptive typed reasons; 100% testable without manual hardware interaction.
* **Negative:** Focus verification adds a check on `frontmostApplication` following activation.

---

## ADR-018: HTML & RTF Multi-Representation Capture, Replay Fidelity, and Plain-Text Synthesis

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
When macOS applications (Safari, Google Chrome, Apple Pages, Microsoft Word, Apple Notes, TextEdit) copy formatted text, they place multiple representations on the pasteboard simultaneously. This presents several challenges:
1. **UTI Variant Fragmentation:** Modern apps use standard UTIs (`public.html`, `public.rtf`, `com.apple.flat-rtfd`), whereas legacy AppKit or WebKit components use legacy type strings (`Apple HTML pasteboard type`, `NSHTMLPboardType`, `NSRTFPboardType`, `NSRTFDPboardType`).
2. **Searchability and Title Derivation:** Certain tools write only HTML or only RTF without a `public.utf8-plain-text` flavor. Without plain text, the entry would lack a descriptive title in the history UI and would be unsearchable in SQLite FTS5.
3. **Replay Fidelity:** When replaying original rich text, target applications expect all original representations preserved byte-for-byte. Furthermore, older Cocoa apps often query `item.string(forType: .string)` rather than `item.data(forType:)`.
4. **Resilience to Malformed Payloads:** Truncated or malformed HTML/RTF payloads must never crash the capture or replay pipelines.

### Decision
1. **Canonical UTI Standardization:**
   - In `ClipboardMonitor.supportedUtiMappings`, map legacy WebKit and AppKit identifiers (`Apple HTML pasteboard type`, `NSHTMLPboardType`, `NSRTFPboardType`, `com.apple.flat-rtfd`, `public.rtfd`, `NSRTFDPboardType`) to canonical UTIs (`public.html`, `public.rtf`, `com.apple.flat-rtfd`, `public.utf8-plain-text`).
2. **Swift Plain-Text Synthesis:**
   - In `ClipboardMonitor.extractRawCapture`, detect when an item group contains rich text (`public.html`, `public.rtf`, `com.apple.flat-rtfd`) but lacks `public.utf8-plain-text`.
   - Synthesize a `public.utf8-plain-text` representation derived via `PasteCoordinator.extractPlainText` so the item is immediately indexed and titled.
3. **Rust Defense-in-Depth Extraction:**
   - In `RustCore`, implement `HistoryItem::extract_text_from_html` and `HistoryItem::extract_text_from_rtf` to extract clean NFC-normalized plain text from HTML (stripping tags, decoding entities, spacing block elements) and RTF (skipping font/color tables, stripping control words, converting paragraph breaks, unescaping braces).
   - In `HistoryItem::derive_text_fields`, utilize this extracted text as a fallback when plain text is absent, ensuring FTS5 indexing and title derivation even when ingested directly via Rust FFI.
4. **Replay Compatibility:**
   - In `PasteCoordinator.encodeOriginalItems`, set both `.setData` and `.setString` for plain-text representations to ensure compatibility with both modern and legacy target applications.
   - In `PasteCoordinator.extractPlainText`, provide regex fallback scanners if `NSAttributedString` parsing fails on malformed or truncated inputs.

### Consequences
* **Positive:** Full round-trip fidelity across Word, Pages, Notes, Safari, and Chrome; all rich items are searchable in SQLite FTS5 and display readable titles; 100% resilient to malformed or truncated payloads.
* **Negative:** Synthesizing plain text adds an `NSAttributedString` conversion step during capture for rich-only copies.

---

## ADR-019: Lazy Non-Main-Thread Image Decoding, Memory-Bounded Thumbnail Caching, and Format Fidelity

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Users copy high-resolution screenshots, diagrams, and photos in various supported image formats (`public.png`, `public.tiff`, `public.jpeg`, `public.heic`). Unconstrained handling of image payloads introduces critical performance and memory hazards:
1. **Main-Thread Decoding Jitter:** Decoding multi-megabyte compressed images directly on the main thread during SwiftUI row evaluation causes dropped frames, input latency, and sluggish panel navigation.
2. **Unbounded Memory Consumption:** Decompressing full-size bitmaps (e.g., a 48 MP photo can consume 200 MB of uncompressed memory) would rapidly exhaust available memory if stored in an unconstrained cache.
3. **Repeated Redecoding:** Scrolling through history rows would repeatedly decompress identical images without an efficient thumbnail cache.
4. **Replay & Format Fallback:** Replaying images must preserve exact original bytes, and plain-text paste requests on pure images must gracefully fall back to the image representation rather than wiping the clipboard.

### Decision
1. **Asynchronous, Off-Main-Thread Thumbnailing:**
   - Implement `ImageThumbnailService` as a Swift actor.
   - Use `CGImageSourceCreateThumbnailAtIndex` with:
     - `kCGImageSourceShouldCache: false` (avoids immediate full-size allocation)
     - `kCGImageSourceCreateThumbnailFromImageAlways: true`
     - `kCGImageSourceCreateThumbnailWithTransform: true`
     - `kCGImageSourceThumbnailMaxPixelSize: 160` (clamped thumbnail bounds)
   - Perform all decoding tasks in background `Task`s off the main actor.
2. **Memory-Bounded Cache & Swift 6 Isolation:**
   - Wrap `NSCache<NSString, NSImage>` in an `@unchecked Sendable` `ThumbnailCacheBox` to satisfy Swift 6 strict concurrency while allowing synchronous, zero-latency cache hits via `cachedThumbnail(for:)`.
   - Enforce strict limits: `countLimit = 250` thumbnails, `totalCostLimit = 64 MB` estimated by pixel buffer size (`width * height * 4`).
3. **Task Coalescing:**
   - Maintain an in-flight task dictionary (`inFlightTasks: [String: Task<NSImage?, Never>]`) to deduplicate simultaneous requests for the same `itemId`, preventing redundant SQLite reads and duplicate decodes.
4. **UI Integration:**
   - In `FloatingPanelView.swift`, introduce `ItemThumbnailView`: renders a 22×22 thumbnail with 4pt continuous rounded corners and subtle border, seamlessly displaying the SF Symbol placeholder while decoding occurs asynchronously.
5. **Rust Domain Metadata:**
   - In `RustCore`, update `HistoryItem::derive_text_fields` for `ContentKind::Image` to generate descriptive titles incorporating format and human-readable byte size (e.g. `PNG Image (2.5 KB)`), indexing format metadata in FTS5.

### Consequences
* **Positive:** Zero main-thread decode latency; fluid 120 FPS scrolling; strictly capped RAM usage; descriptive image titles and searchability in Rust FTS5; 100% testable in automated CLI environments.
* **Negative:** Storing thumbnails consumes up to 64 MB of RAM when full (safely bounded and evictable).

---

## ADR-020: File Reference Normalization, Multi-File Group Ordering, Finder Pasteboard Replay, and Vanished-File Resilience

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
When files are copied in macOS Finder, Terminal, or third-party tools:
1. **Multi-Item Groups:** Copying multiple files generates distinct `NSPasteboardItem` objects on the pasteboard, each bearing `public.file-url` (`kUTTypeFileURL`). Legacy macOS utilities may write an `NSFilenamesPboardType` property list of POSIX path strings instead.
2. **URL Escaping and Titles:** File URLs carry percent-encodings (`file:///path/to/My%20Folder/Report%20File.pdf`) and may contain trailing directory slashes. List titles must display clean, unencoded basenames (`Report File.pdf` or `Projects`), while multi-file copies should indicate the count (`3 files`).
3. **Replay Fidelity:** Replaying file copies into Finder requires valid `NSPasteboardItem` structures with `.fileURL` types and data preserved across original group indices.
4. **Vanished Files:** If a referenced file has been deleted, moved, or unmounted between copy and paste:
   - Replay must not crash or fail.
   - Plain-text paste must continue to output the POSIX path string without silent downgrade or empty clipboard writes.
   - The UI must provide transparent visual indication that the target file no longer exists at its recorded path.

### Decision
1. **Rust Domain Normalization:**
   - In `RustCore/src/domain/item.rs`, evaluate `ContentKind::FileUrls` before plain text in `derive_text_fields`.
   - Implement `HistoryItem::percent_decode_str` to decode percent sequences (`%20` -> `' '`, etc.) and trim trailing slashes.
   - If 1 file: extract decoded basename. If >1 file: format as `"{} files"`.
   - Populate `search_text` with newline-delimited URLs so all filenames and full paths are indexed in FTS5.
2. **Swift Capture & Legacy Bridge:**
   - In `ClipboardMonitor.swift`, detect legacy `NSFilenamesPboardType` payloads if `public.file-url` is absent, parsing POSIX paths and generating canonical `public.file-url` representations.
   - Synthesize a `public.utf8-plain-text` flavor containing decoded POSIX paths for search and plain-text fallback.
3. **Finder-Compatible Replay:**
   - In `PasteCoordinator.swift`, iterate across sorted `groupIndex` values to emit matching `NSPasteboardItem`s. Set `.setString(trimmed, forType: .fileURL)` and `.setData(payload, forType: .fileURL)` with provenance markers.
   - In plain-text mode (`.plainText`), extract clean, newline-delimited POSIX paths without URL schemes.
4. **Vanished-File UX:**
   - In `FloatingPanelView.swift`, implement `isFileVanished(path:)`: inspects the local filesystem via `FileManager.default.fileExists(atPath:)`.
   - If the file has vanished from disk, display a subtle `"missing"` badge next to the title.

### Consequences
* **Positive:** Complete round-trip fidelity for Finder and Terminal file copies; multi-file group order preserved; clean percent-decoded titles; clear vanished-file UX; zero data degradation.
* **Negative:** Checking filesystem existence for displayed file items performs a fast stat check.



---

## ADR-021: URL Canonicalization, Web Page Title Attribution, HEX Color Swatch Previews, and Click-Safe Navigation

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Users frequently copy URLs (from Safari, Chrome, Slack, emails) and HEX color codes (from design tools like Figma, CSS, Xcode, terminal, web inspectors). Several specific requirements and pitfalls arise:
1. **URL Noise and Normalization:** Copied URLs often carry redundant default ports (`:80`, `:443`), redundant trailing consecutive slashes (`//`), and mixed-case schemes or hosts (`HTTPS://WWW.EXAMPLE.COM`). Furthermore, macOS browsers often provide rich metadata flavors (`public.url`, `public.url-name`, and `public.utf8-plain-text`).
2. **Searchability and Title Attribution:** When a user copies a link with an associated web page title (e.g. `public.url-name`), the page title should serve as the human-readable item title, while the normalized URL, host, and clean domain should be indexed in SQLite FTS5 for instant discovery.
3. **HEX Color Recognition & Visual Swatches:** Color codes are commonly formatted as `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, or with a `0x` prefix. Users want an immediate visual preview (swatch) of the color in the history list, but **text must remain primary**: pasting the item must output the exact text string (e.g., `#FF5733`), never an image or binary artifact.
4. **Click-Safe Navigation:** In a clipboard manager, clicking an item row must immediately select and commit the item for pasting/copying into the active recipient application. Clicking a row must **never** inadvertently launch the default web browser, preventing disruptive accidental browser tab explosions during keyboard or mouse navigation.

### Decision
1. **Rust Domain URL Canonicalization & FTS5 Indexing:**
   - Implement `CanonicalUrl` in `RustCore/src/domain/url_utils.rs`: converts scheme and host to lower case, removes default ports (80 for http, 443 for https, 21 for ftp), collapses duplicate consecutive slashes in paths, and extracts clean display domains (stripping `www.`).
   - In `HistoryItem::derive_text_fields`, recognize `public.url` UTI representations and plain-text URLs. If `public.url-name` is present, use it as the item title; otherwise use the canonical URL. Index the URL, domain, and host in `search_text` for FTS5 queries.
2. **Rust Domain HEX Color Parsing:**
   - Implement `HexColor` in `RustCore/src/domain/color.rs`: parses 3, 4, 6, and 8-digit hex strings (with `#` or `0x` prefix). Computes 8-bit channel expansion and ITU-R BT.601 perceptual luminance (`is_perceptually_dark`).
   - In `HistoryItem::derive_text_fields`, detect hex color plain text and index both the raw `#HEX` and stripped `HEX` for FTS5 searchability, keeping the exact copied string as the title.
3. **Swift Detection & SwiftUI Previews:**
   - In `Mimra/UI/Panel/ColorAndUrlPreview.swift`, create pure, non-blocking Swift detectors: `ColorDetector` (yielding `HexColorInfo`) and `UrlDetector` (yielding `UrlInfo`).
   - Create `ColorSwatchView`: renders a rounded rectangle with contrast outline border and an alpha checkerboard grid for translucent colors.
   - Create `UrlBadgeView`: renders a clean domain pill badge and link icon.
4. **Settings Toggles & Panel Integration:**
   - In `SettingsView.swift` (Appearance tab), add `@AppStorage("showColorSwatches")` and `@AppStorage("showUrlPreviews")` toggles.
   - In `FloatingPanelView.swift`:
     - `ItemThumbnailView`: Displays `ColorSwatchView` in place of the generic text icon when color swatches are enabled and a hex color is detected; shows `link` icon for URLs.
     - `PanelItemRow`: Shows an inline color swatch next to the hex text and a domain badge next to URLs.
5. **Click-Safe Row Guarantee:**
   - Standard row click or Return key exclusively commits the item (copy/paste into the active app).
   - An explicit external browser open action is provided via an isolated hover button (`NSWorkspace.shared.open(url)`) or future slideout preview, ensuring row selection remains 100% click-safe.

### Consequences
* **Positive:** Full feature parity for color swatches and URL previews; exact text payload preserved on paste; rich page title attribution; FTS5 domain and hex searchability; zero accidental browser activations.
* **Negative:** String inspection on row display occurs synchronously in SwiftUI; mitigated by lightweight, non-allocating regex-free parsing.


---

## ADR-022: Source Application Attribution via `org.nspasteboard.source`, LaunchServices Bundle Resolution, and Off-Main App Icon Caching

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Users copy content across dozens of diverse macOS applications (browsers, IDEs, terminal, office suites, design tools). Displaying the source application's identity and icon improves visual scanning and attribution. Key engineering considerations include:
1. **Source Attribution Extraction:** Applications may attach source markers either as explicit strings via `org.nspasteboard.source` or as raw UTF-8 `Data` buffers. If absent, the attribution must fall back to the frontmost active application via `NSWorkspace.shared.frontmostApplication`.
2. **LaunchServices Bundle Resolution:** Resolving an application icon from a bundle identifier (`NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` and `NSWorkspace.shared.icon(forFile:)`) involves disk inspection and LaunchServices lookups. Running this synchronously on the main thread during SwiftUI row rendering would cause dropped frames and UI jitter.
3. **App Updates & Staleness (F-016):** When an installed application updates its bundle or icon on disk, cached icons should refresh rather than displaying stale assets permanently.
4. **Unknown Sources & Remote Captures:** Content copied from uninstalled tools, CLI utilities, or remote Universal Clipboard devices may present unknown bundle identifiers or nil. The resolution pipeline must be 100% "unknown source safe", failing gracefully without panics, exceptions, or visual glitches.

### Decision
1. **Multi-Source Detection in `ClipboardMonitor`:**
   - In `ClipboardMonitor.detectSourceBundleId()`, first inspect all pasteboard items for `org.nspasteboard.source` (checking both `.string` and UTF-8 `.data`).
   - If not found, fall back to `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`.
   - Store the resulting identifier in `RawCapture.sourceBundleId`, persisted in SQLite via `HistoryItem.source_bundle_id`.
2. **Asynchronous, Memory-Bounded `AppIconService`:**
   - Implement `AppIconService` as a Swift actor.
   - Use an `@unchecked Sendable` `IconCacheBox` wrapping `NSCache<NSString, CachedIconEntry>` with `countLimit = 120`.
   - Store bundle file modification timestamps (`contentModificationDateKey`) in cache entries. If the on-disk bundle modification date is newer than the cached date, refresh the icon.
   - Coalesce simultaneous resolution requests for the same bundle ID via an in-flight task map (`inFlightResolutions`).
   - Provide a zero-contention synchronous fast path `cachedIcon(for:)` for immediate, flash-free SwiftUI rendering.
3. **SwiftUI Integration & Settings Toggle:**
   - Implement `SourceAppIconView`: renders a 14×14 rounded app icon with asynchronous resolution and graceful fallback to clear space if unknown.
   - In `PanelItemRow`, display `SourceAppIconView` adjacent to the row's status indicators.
   - In `SettingsView.swift` (Appearance tab), add user toggle `Show source application icon` (`showSourceAppIcon`, default `true`).
4. **Replay Provenance Guard:**
   - Replayed items continue to stamp `org.nspasteboard.source = "com.mimra.app"`, preventing self-recapture loops.

### Consequences
* **Positive:** Fast, asynchronous app icon resolution; zero main-thread disk I/O; icons refresh when applications update; complete resilience to unknown bundle IDs; user-configurable display.
* **Negative:** LaunchServices queries occur off-main on cold start; mitigated by bounded cache and coalescing.

---

## ADR-023: Deduplication Hardening Across Complex Applications

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
In complex macOS applications (Google Sheets, Microsoft Office, VS Code, Apple Notes, Safari, Chrome, Finder), naive raw-payload deduplication creates frequent duplicate storms or lost formatting:
1. **Google Sheets / Excel HTML Session Churn:**
   Copying spreadsheet cells attaches `public.utf8-plain-text` alongside `public.html`. Google Sheets generates dynamic session IDs (`data-sheets-root="session-xxxx"`), random CSS class names, and timestamps in its HTML payload on every copy. If content hashing compares raw HTML representations, identical cells copied twice produce different hashes, flooding history with duplicate entries.
2. **Safari & Web URL Variants (F-006, F-012):**
   Copying a URL from Safari's address bar puts plain text, while context-menu "Copy Link" includes `public.url`, `public.url-name` (page title), and plain text. Furthermore, trailing slashes (`https://example.com/foo/` vs `https://example.com/foo`), default ports (`:80`, `:443`), and case variations in hosts create distinct raw hashes despite referencing the identical resource.
3. **VS Code Trailing Whitespace & Newlines:**
   In VS Code and modern text editors, pressing Cmd+C on a line without selection copies the line with a trailing newline `\n`. Selecting the line text copies without the newline. Furthermore, code snippets frequently contain trailing spaces before newlines.
4. **Apple Notes & MS Office RTF Variations:**
   Apple Notes and MS Word emit RTF payloads with local font table definitions, stylesheet IDs, and document GUIDs that vary between consecutive copies of identical text.
5. **Multi-Representation Merging & Upgrade Progression:**
   When a user copies a plain text snippet and later copies the same snippet from a rich text editor (or vice versa), the existing history item must be updated with richer representations and refreshed formatting rather than creating a duplicate entry or dropping rich formatting.
6. **Finder Multi-File Selection Order:**
   Selecting files in Finder in different orders (e.g. file A then B vs file B then A) emits file URLs in arbitrary permutation.
7. **Rapid Burst Debouncing:**
   Multi-stage clipboard writes by complex editors can increment `changeCount` multiple times within < 100ms.

### Decision
1. **Canonical Deduplication Hashing (`HistoryItem::calculate_content_hash`):**
   - **Text & Rich Text with Plain Text:** Normalizes newlines (`\r\n` and `\r` -> `\n`), trims outer whitespace/newlines, NFC-normalizes Unicode, and trims trailing whitespace per line for multiline text (`canonicalize_text`).
   - **URLs (`public.url` or plain text URL):** Parsed via `CanonicalUrl::parse`, schemes and hosts lowercased, default ports 80/443 stripped, slashes collapsed, and trailing slashes normalized (`clean_url = canonical.normalized_url.trim_end_matches('/')`). Hashed as `URL:\n<normalized_url>`.
   - **Colors:** Parsed via `HexColor::parse` and hashed as `COLOR:\n<hex_clean>`.
   - **General Text:** Hashed as `TEXT:\n<canonical_text>`.
   - **Rich Text without Plain Text:** Extracts plain text from HTML or RTF; if non-empty, hashes extracted canonical text.
   - **File URLs (`public.file-url`):** Schemes stripped, percent-decoded, trailing slashes trimmed, NFC-normalized, and canonical paths sorted lexicographically before hashing (`canonicalize_file_url`).
   - **Images:** Hashes primary image representation payload (`IMAGE:\n<uti><payload>`).
2. **Transactional Representation Upsert & Upgrades (`update_recopy_and_merge`):**
   - On duplicate match via `find_by_content_hash`:
     - Upsert incoming representations into SQLite `item_representations` using `ON CONFLICT(item_id, group_index, uti) DO UPDATE SET payload = excluded.payload`.
     - Preserves existing rich representations when an item is recopied from a plain-text source (e.g. copying rich text then recopying in Terminal retains RTF/HTML).
     - Upgrades `content_kind` from `Text` to `RichText` if rich representations arrive.
     - Upgrades bare URL titles to rich web page titles when `public.url-name` arrives.
     - Updates `last_copied_at_ms`, increments `copy_count`, and recalculates `byte_size`.
     - Pinned status, order, key, and `first_copied_at_ms` remain completely preserved.
3. **Swift `ClipboardMonitor` Burst Debouncing:**
   - Detects rapid successive `changeCount` updates (< 100ms) from the same source app with identical representation fingerprint, skipping redundant processing to prevent duplicate storms during multi-stage pasteboard writes.

### Consequences
* **Positive:** Eliminates duplicate storms from Google Sheets, Excel, Safari, VS Code, and Apple Notes; preserves rich formatting across multi-representation recopies; upgrades bare URL titles to web page titles automatically; zero data loss.
* **Negative:** Slightly more CPU work per ingestion to compute canonical hash; offset by BLAKE3 efficiency (< 10 microseconds).

---

## ADR-024: Clipboard Format Enablement & Payload Filtering

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Users require granular preferences to choose which clipboard content types Mimra captures (plain text, rich text, images, and file references). Additionally, security and privacy requirements (`F-015`) dictate that unknown, proprietary, or unselected payload types (such as `WebArchive` or arbitrary binary blobs) must never be stored in SQLite or persisted to disk. Key architectural criteria include:
1. **Pre-Payload Filtering:** If a copied item contains only disabled formats (e.g. screenshot taken while images are disabled), the clipboard event must be rejected in Swift before reading raw byte payloads into memory or making FFI calls.
2. **Selective Representation Stripping:** If an item contains multiple formats (e.g. formatted text copied from Safari with plain text and HTML) and the user has disabled rich text, the rich representations (`public.html`, `public.rtf`) must be stripped in Swift, capturing only the plain text representation.
3. **Strict Payload Allowlisting (F-015):** Unsupported private payloads (e.g. `com.apple.webarchive`, `com.adobe.*`) must be dropped unconditionally.
4. **Live Settings Synchronization:** Toggling format settings in SwiftUI Settings must immediately take effect in the active `ClipboardMonitor` and `PrivacyFilter`.

### Decision
1. **`ClipboardTypeConfiguration` Domain Model:**
   - Implemented `ClipboardTypeConfiguration` with toggles for `storePlainText`, `storeRichText`, `storeImages`, and `storeFiles` (defaulting all to `true`).
   - Centralized `supportedUtiMappings` defining all allowlisted UTIs.
   - Provided `isUtiEnabled(canonicalUti:)` and `isRawTypeEnabled(rawType:)` to evaluate format enablement against user preferences.
2. **Early Metadata Evaluation in `PrivacyFilter`:**
   - In `PrivacyFilter.shouldCapture()`, check whether the pasteboard contains at least one enabled supported format (`_typeConfiguration.hasAnyEnabledType(in: allRawTypes)`). If not, drop with `.noSupportedTypes` before reading any data bytes into memory.
3. **Representation Stripping in `ClipboardMonitor`:**
   - In `ClipboardMonitor.extractRawCapture()`, filter each candidate representation against `typeConfiguration.isUtiEnabled(canonicalUti)`.
   - Strip disabled representations from multi-representation groups (e.g. dropping HTML/RTF while preserving plain text).
   - Skip legacy file serialization and plain text synthesis if their respective format toggles are disabled.
4. **SwiftUI Settings & Reactive Updates:**
   - Added a dedicated "Storage" tab in `SettingsView.swift` with user toggles bound to `@AppStorage`.
   - In `AppDelegate.swift`, observed `UserDefaults.didChangeNotification` to automatically reload `typeConfiguration` when preferences change.

### Consequences
* **Positive:** Full user control over captured formats (`F-013`); strict allowlist guarantees zero arbitrary or private binary payloads reach disk (`F-015`); multi-representation copies cleanly degrade to plain text when rich formats are disabled; zero main-thread overhead.
* **Negative:** None. Minimal overhead during pasteboard polling (< 1 microsecond).
