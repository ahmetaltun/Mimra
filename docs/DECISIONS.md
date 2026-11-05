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

---

## ADR-025: FTS5 Full-Text Search Engine, Safe Token Prefix Query Sanitization, and BM25 Ranking

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Users require instantaneous, predictable search-as-you-type (`F-019`, `F-048`, `T-SRCH-01`) across thousands of history items, including plain text, URLs, file references, OCR text, and title metadata. A robust implementation must satisfy:
1. **Index Synchronization & ACID Guarantees:** Virtual full-text search table (`search_fts`) must remain 100% in sync with `history_items` across inserts, updates, duplicate recopies, and deletions with zero orphaned posting entries.
2. **Query Syntax Resilience:** Raw user input typing punctuation (e.g. `*`, `(`, `)`, `:`, `"`, `AND`, `NOT`) directly into SQLite FTS5 `MATCH` queries triggers syntax errors. The engine must sanitize and safely tokenize user input.
3. **Relevance & Prefix Ranking:** As the user types (e.g. typing `compil`), terms should match prefix tokens (`"compil"*`) with BM25 weights prioritizing `title` (10.0x) over `search_text` (1.0x) and `ocr_text` (0.5x).
4. **Pinned Precedence & Pagination:** Pinned items must stay prioritized, followed by relevance-ranked matches, with stable offset/limit pagination across 10,000+ items.
5. **On-Demand Maintenance:** Provide explicit index integrity validation (`integrity-check`) and rebuild (`rebuild`) commands.

### Decision
1. **FTS5 Virtual Table & Triggers:**
   - Backed by external content table `history_items` (`content='history_items'`, `content_rowid='rowid'`, `tokenize='unicode61'`).
   - Synchronized atomically using `AFTER INSERT`, `AFTER DELETE`, and `AFTER UPDATE` triggers.
2. **Safe Query Sanitization (`sanitize_fts5_query`):**
   - Strips SQLite FTS5 control characters and punctuation delimiters.
   - Escapes internal quotes (`""`).
   - Wraps each valid word token into a quoted prefix wildcard token: `"{token}"*`.
   - Returns `None` if the input contains only punctuation or whitespace, safely skipping unnecessary FTS MATCH overhead.
3. **BM25 Relevance Scoring with Pinned Priority:**
   - Uses `bm25(search_fts, 10.0, 1.0, 0.5) AS rank` with `ORDER BY h.is_pinned DESC, CASE WHEN h.is_pinned = 1 THEN h.pin_order END ASC, rank ASC, h.last_copied_at_ms DESC`.
   - SQLite BM25 returns negative values, so `rank ASC` places highest relevance matches first.
4. **UniFFI and Swift Concurrency:**
   - Exposed `search_page`, `rebuild_search_index`, and `check_search_index_integrity` across UniFFI.
   - Integrated into `CoreClient` actor and `PanelViewModel.performSearch(query:limit:offset:)`.

### Consequences
* **Positive:** Bounded search latency (<10ms across 10,000 items on Apple Silicon); immune to FTS5 query syntax crashes; zero desync between content and index; stable pagination.
* **Negative:** Requires FTS5 compile-time support in SQLite (bundled and enabled).

---

## ADR-026: Deterministic Fuzzy Ranker, Word-Boundary Prioritization, Recency Boosts, and UTF-16 Highlight Ranges

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
While SQLite FTS5 provides fast prefix/token candidate search across 10,000+ items, users frequently search using acronyms (e.g. `vsc` for `Visual Studio Code`), non-prefix subsequences, or informal abbreviations. Furthermore, search results must indicate exact visual character matches in both title and snippet without index mismatches or grapheme corruption across international scripts (Greek, Cyrillic, CJK, emoji).

### Decision
1. **Two-Stage Hybrid Search Pipeline:**
   - **Candidate Retrieval:** FTS5 executes token prefix queries across the entire database, while a secondary lightweight query scans recent items (200 rows) to catch non-prefix acronyms and subsequences.
   - **Deterministic Ranking:** In-memory ranker evaluates each candidate against `title` and `snippet`.
2. **Subsequence & Boundary Scoring:**
   - Exact full-string match: $+3500$.
   - Exact substring match: $+2000$, with $+800$ bonus for start of string, $+500$ for word boundary.
   - Subsequence match: base $+500$, $+180$ per boundary match, $+80$ per consecutive character, $-3$ gap penalty.
   - Title matches are weighted $2.0\times$ relative to snippet matches.
3. **Logarithmic/Tiered Recency Boost:**
   - Applied via `calculate_recency_boost`: $< 5\text{ mins} \to +300$; $< 1\text{ hr} \to +200$; $< 24\text{ hrs} \to +100$; $< 7\text{ days} \to +40$.
   - Breaks ties predictably between items with identical text.
   - Pinned items receive a $+1,000,000$ priority boost so they always appear before unpinned results.
4. **UTF-16 Highlight Ranges for Swift UI (`HighlightRangeDTO`):**
   - Matched indices are calculated in UTF-16 code units and consolidated into contiguous `{ start, length }` ranges.
   - Compatible directly with AppKit/SwiftUI `NSRange` and `AttributedString`, ensuring emoji (`🚀` surrogate pairs) and combining Unicode marks never cause out-of-bounds or split graphemes.
   - Rendered natively in SwiftUI via `HighlightedLabel` with bold text and accent underline.

### Consequences
* **Positive:** High recall for acronyms (`vsc`), instantaneous typing responsiveness with zero keyboard lag, predictable recency tie-breaking, safe international script highlights, and clean separation between Rust ranking logic and SwiftUI rendering.
* **Negative:** None. Candidate in-memory scoring executes in $< 0.3\text{ms}$.

---

## ADR-027: Bounded Regular Expression Execution, Exact Substring Search Mode, Stale Search Cancellation, and Syntax Error Presentation

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Users require power-user search capabilities (`F-048`, `T-SRCH-02`), including exact case-insensitive substring searching and regular expression pattern matching. However, regex execution on arbitrary user input introduces significant security and stability hazards:
1. **Regular Expression Denial of Service (ReDoS):** Malicious, deeply nested, or catastrophic backtracking patterns (e.g. `(a+)+$`) can stall the CPU or exhaust memory.
2. **Crash Resilience on Syntax Errors:** Users construct regex patterns character-by-character. Intermediate partial inputs (e.g. `[a-z`, `(unclosed`, `*invalid`) must never panic across UniFFI or crash the application; they must produce informative, typed diagnostics.
3. **Stale Search Race Conditions:** Rapid typing triggers multiple asynchronous search requests. If an earlier complex search query completes after a newer simpler query, the UI could display stale results or flash incorrect highlight ranges.
4. **UTF-16 Highlight Alignment:** Regex match byte offsets must map 1:1 to UTF-16 code units for AppKit/SwiftUI `NSRange` and `AttributedString` consumption without panics on multi-byte characters or emoji.

### Decision
1. **Bounded Rust Regex Engine:**
   - In `RustCore/src/domain/search.rs`, implement `compile_bounded_regex(pattern)` using `regex::RegexBuilder` with:
     - Hard character limit: `MAX_REGEX_PATTERN_LEN = 256` characters.
     - Compiled size limit: `size_limit(64 * 1024)` (64 KB).
     - DFA size limit: `dfa_size_limit(256 * 1024)` (256 KB).
     - Case insensitivity: `case_insensitive(true)`.
   - On error or limit violation, return typed `CoreError::InvalidRegex { pattern, error_message }`.
2. **Exact Substring Search Mode (`SearchMode::Exact`):**
   - Direct case-insensitive substring matching using lowercase haystack and query needle.
   - Computes UTF-16 character offsets for all occurrences in title and snippet.
3. **UniFFI Error Propagation:**
   - Added `CoreError::InvalidRegex` to UniFFI export definitions, throwing typed `CoreError.invalidRegex` into Swift.
4. **Stale Search Cancellation in `PanelViewModel`:**
   - Introduce a monotonically increasing `searchGeneration: UInt64` counter.
   - Before firing an asynchronous search task, increment `searchGeneration`.
   - Upon completion, verify `generation == self.searchGeneration`. If stale, discard the result.
   - Catch `CoreError.invalidRegex` and publish `regexErrorMessage` to the UI while clearing stale results.
5. **Non-Intrusive Error Presentation:**
   - Display an inline warning banner above the search list in `FloatingPanelView.swift` when `regexErrorMessage` is populated, providing clear feedback without blocking keystrokes or popping disruptive alerts.

### Consequences
* **Positive:** Guaranteed linear-time ReDoS immunity; zero crash risk on invalid regex; typed and helpful error presentation in UI; race-free search result ordering via monotonic generation counters; accurate UTF-16 highlights across all modes.
* **Negative:** Patterns exceeding 256 characters or 64 KB compiled size are rejected with a descriptive error.

---

## ADR-028: Pinned Items Arrangement, Configurable Sort Modes, Selectable Highlight Styles, and Selection Identity Preservation

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Users require tailored organization and visual cues when browsing and searching clipboard history (`F-019`, `F-024`, `F-048`, `F-050`, `F-054`, `T-UI-03`, `T-KEY-03`):
1. **Pinned Placement:** Users have differing preferences for pinned items—some prefer pinned items grouped at the top, others at the bottom, and others mixed inline with recency.
2. **Sort Criteria:** Browsing history benefits from recency (`last_copied_at_ms DESC`), copy count / frequency (`copy_count DESC`), or chronological first-capture order (`first_copied_at_ms DESC`). In active search, results should be rankable by relevance or by recency.
3. **Highlight Customization:** Different visual themes require adaptable highlight treatments (bold, underline, italic, bold & underline, accent color, or none).
4. **Selection Jumping Bug (DoD Requirement):** In traditional clipboard manager lists, index-based selection (`selectedIndex = 2`) causes selection jumping:
   - When a new item is captured in the background, all rows shift down, jumping the user's selection to an unrelated item.
   - When an unpinned item is deleted above the selection, the selection shifts down.
   - When the currently selected item is deleted, resetting unconditionally to `0` disorients the user.
   - The Definition of Done strictly mandates: *selection remains on same ID on updates*.

### Decision
1. **Rust Storage & FFI Sort Pipeline:**
   - Introduced `HistorySortMode` (`Recency`, `CopyCount`, `FirstCopied`) and `PinArrangement` (`Top`, `Bottom`, `Inline`) in `RustCore/src/domain/dto.rs`.
   - Implemented `list_history_page_with_options` with parameterized, injection-proof SQL ORDER BY clauses.
   - Implemented `search_history_page_with_options` supporting `sortByRelevance` (relevance score vs recency tie-breaking) and `pin_arrangement`.
   - Exposed `listPageWithSort` and `searchPageWithOptions` across UniFFI with 100% backward-compatible default overloads.
2. **Selectable Highlight Styles:**
   - Implemented `SearchHighlightStyle` (`bold`, `underline`, `italic`, `boldUnderline`, `accent`, `none`) with SwiftUI display names.
   - Integrated with `HighlightedLabel` and persisted via `@AppStorage("searchHighlightStyle")`.
3. **Selection Identity Preservation (DoD):**
   - In `PanelViewModel`, introduced `selectedItemId: String?` tracking the UUID of the selected item.
   - Implemented `applyItemsPreservingSelection(_ newItems:)`:
     - If `selectedItemId` exists in the updated items list, locate its new index and update `selectedIndex` to match, guaranteeing selection stays locked to the same item ID.
     - If the selected item was deleted, clamp `selectedIndex` to `min(previousIndex, count - 1)` so the item currently occupying that visual slot is selected without jumping to index 0.
     - If the list becomes empty, gracefully set `selectedIndex = 0` and `selectedItemId = nil`.
   - When typing in `searchText`, if the previously selected item matches the new query, its selection is retained.
4. **Keyboard Navigation & Deletion Operations:**
   - Added `selectPageUp(pageSize:)`, `selectPageDown(pageSize:)`, `selectFirst()`, and `selectLast()` satisfying `T-KEY-03` and `F-030`.
   - Added `deleteSelectedItem()` and `deleteItem(itemId:)` with immediate in-memory item removal and selection clamping.
   - Bound Page Up (116), Page Down (121), Home (115), End (119), and Option-Delete / Command-Delete (51) in `FloatingPanel.handlePanelKeyDown`.
5. **Settings Configuration:**
   - Added a "Search & Sorting" tab in `SettingsView` exposing match highlight style, pin placement, history sort order, and search relevance ranking options.

### Consequences
* **Positive:** Complete elimination of spurious selection jumps during background copies or deletions; user preference support for pin positioning and highlight styling; resilient keyboard navigation with standard Page Up/Down and Option-Delete; 100% verified across 62 Rust unit tests and 30 Swift integration verification suites.
* **Negative:** Tracking selection by ID adds a linear scan (`firstIndex(where:)`) over the current page (up to 100 items), completing in < 5 microseconds on Apple Silicon.

---

## ADR-029: Multi-Dimensional Retention Policies (Count, Age, Size), Guaranteed Pin Preservation, and 50k-Event Churn Verification

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Unbounded local clipboard storage risks disk bloat, memory exhaustion, and slow FTS5 search performance (`F-025`, `F-052`, `F-053`, `T-HIST-01`, `T-HIST-03`, `T-HIST-05`). A production-grade clipboard manager storage engine must satisfy:
1. **Multi-Dimensional Retention:** Support item count caps (`max_count`), age limits (`max_age_days`), and storage byte budgets (`max_size_bytes`).
2. **Ironclad Pin Preservation:** Pinned items must NEVER be evicted by count, age, or size retention limits, nor by `clear_unpinned()`. Only an explicit `clear_all()` or specific item deletion may delete pinned items.
3. **Atomic Transactional Cleanup:** Inserts, duplicate resolution, and retention eviction must occur inside a single atomic SQLite transaction with zero orphan records in `item_representations` (via `ON DELETE CASCADE`) or in `search_fts` (via transactional `AFTER DELETE` triggers).
4. **Stress Verification (DoD):** Verify zero foreign key violations, zero FTS orphans, and 100% database integrity under a heavy 50,000-event churn workload.

### Decision
1. **Domain & DTO Types:**
   - Defined `RetentionPolicyDTO` (`max_count`, `max_age_days`, `max_size_bytes`) and `CleanupReportDTO` (`evicted_by_count`, `evicted_by_age`, `evicted_by_size`, `total_evicted`, `remaining_unpinned`, `remaining_pinned`, `freed_bytes`) in `RustCore/src/domain/dto.rs`.
2. **Unified Retention Pipeline (`enforce_retention_policy`):**
   - Implemented in `RustCore/src/storage/repository.rs` executing inside an active transaction:
     - Age filter: `DELETE FROM history_items WHERE is_pinned = 0 AND last_copied_at_ms < ?1`.
     - Count filter: Computes excess unpinned items and deletes the oldest unpinned rows.
     - Size budget filter: Queries oldest unpinned items ordered by `last_copied_at_ms ASC` and deletes until cumulative byte size falls below budget.
   - Pinned immunity: Every deletion query strictly enforces `is_pinned = 0`.
3. **UniFFI CoreClient Methods:**
   - Added `set_retention_policy`, `get_retention_policy`, `enforce_retention`, `checkpoint_wal`, and `vacuum_database` across `MimraCoreHandle` and `CoreClient`.
4. **50,000-Event Stress Churn Test (`T-HIST-05`):**
   - Implemented in `RustCore/src/storage/mod.rs` executing 50,000 events (fresh unique captures, duplicate recopies, pin updates, midway `clear_unpinned`, and interleaved retention sweeps).
   - Verifies:
     - 0 foreign key violations (`PRAGMA foreign_key_check`).
     - 0 orphaned `item_representations` rows.
     - 0 orphaned `search_fts` rows (`verify_search_index_integrity`).
     - 100% survival of all pinned anchor items.
     - Strict upper bounds on remaining unpinned item counts and byte size.
     - Database integrity passes `PRAGMA integrity_check`.

### Consequences
* **Positive:** Complete protection against unbounded disk usage; robust pin preservation guarantees; zero orphaned blobs or search rows; sub-7 second execution for 50k churn events on Apple Silicon.
* **Negative:** Measuring total payload size during size-budget eviction requires a `SUM(byte_size)` query across unpinned rows, indexed and completing in < 100 microseconds.

---

## ADR-030: Storage Settings Management, Live Disk Metrics, and Distinct Clear Confirmations

* **Status:** Accepted
* **Date:** 2026-11-03
* **Linked Feature / Task:** `F-025`, `F-055` / `P4-06` (Gate G4)
* **Linked Tests:** `T-HIST-01`, `T-HIST-05`

### Context
Users require full visibility into clipboard history disk usage and fine-grained control over retention limits, supported formats, and history deletion (`F-025`, `F-055`, `T-HIST-01`, `T-HIST-05`). A reliable storage management UI requires:
1. **Live Disk Metrics:** Display formatted database file size on disk (`ByteCountFormatter`), total items, pinned items, unpinned items, and data representation counts.
2. **Immediate DoD Metric Updates:** Disk metrics must update live after retention cleanup, WAL checkpointing, database vacuuming, or clear operations.
3. **Distinct Clear Confirmations:** Deleting unpinned history versus wiping all history (including pinned anchors) requires two completely distinct alert dialogs with explicit warning copy to prevent accidental data loss (`F-025`, `T-HIST-01`).
4. **Strict Concurrency Safety:** UniFFI calls must remain off-main thread; state updates must be coordinated through an observable view model conforming to Swift 6 strict concurrency (`-strict-concurrency=complete`).

### Decision
1. **Modular Storage ViewModel (`StorageSettingsViewModel`):**
   - Implemented as `@MainActor public final class StorageSettingsViewModel: ObservableObject` in `Mimra/UI/Settings/SettingsView.swift`.
   - Manages live `stats: StorageStatsDto?`, `isLoading`, `isPerformingAction`, and operation status messages (`statusMessage`).
   - Persists user preferences for `retentionMaxCount`, `retentionMaxAgeDays`, and `retentionMaxSizeBytes` in `UserDefaults`, while automatically synchronizing active policies with the Rust engine via `CoreClient.setRetentionPolicy(policy:)`.
2. **Double-Checked Shared CoreClient Access:**
   - Added thread-safe `CoreClient.shared` and `CoreClient.setSharedInstance()` to `Mimra/Bridge/CoreClient.swift` to allow SwiftUI views to cleanly access the storage client without blocking the main actor.
   - `AppDelegate` registers the active `CoreClient` on launch; `SettingsView(coreClient:)` and `StorageSettingsViewModel(coreClient:)` permit injection of mock or in-memory clients for isolated integration testing.
3. **Storage Settings UI Layout (`StorageSettingsTab`):**
   - Four structured sections:
     - **Database Metrics:** Live DB disk size, item counts, pinned count (highlighted as protected), and buttons for "Optimize Database" and "Refresh".
     - **History Retention Limits:** Pickers for Item Count (50, 100, 200, 500, 1000, Unlimited), Retention Duration (7, 14, 30, 90, 180, 365 days, Unlimited), Storage Budget (25MB, 50MB, 100MB, 250MB, 500MB, 1GB, Unlimited), and "Apply & Enforce Retention Now" action.
     - **Supported Formats:** Format enablement toggles for Plain Text, Rich Text (HTML/RTF), Images, and File references (`F-013`, `F-015`, `T-TYPE-05`).
     - **History Clear Actions:** Side-by-side action buttons for "Clear Unpinned..." and "Clear All History..." with explanatory captions.
4. **Distinct Confirmation Safeguards (`F-025`, `T-HIST-01`):**
   - `showClearUnpinnedAlert`: Confirms deletion of unpinned items and explicitly reassures the user that pinned clips will NOT be deleted.
   - `showClearAllAlert`: High-impact critical confirmation requiring explicit affirmation to wipe all history items, including all pinned clips.
   - Both actions trigger immediate WAL checkpoint / vacuum and refresh `stats` live so disk metrics reflect the new state immediately.

---

## ADR-031: Database Failure Recovery, Safe Quarantine, Online Vacuum Backups, and Backup Restoration

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
SQLite databases can experience corruption, unexpected process termination mid-transaction, low disk conditions (`SQLITE_FULL`), or incompatible future schema migrations (`schemaMismatch`). A catastrophic failure mode of naïve clipboard engines is unconditional database erasure or silent loss of pinned anchors upon launch errors. Mimra's Definition of Done mandates user-facing safe error presentation, zero silent data loss, and guaranteed recoverability.

### Decision
1. **Resilient Opening & Automatic Quarantine (`RustCore::storage::recovery`):**
   - When `open_database_resilient` detects database file corruption, malformed B-trees, or failed `PRAGMA integrity_check`:
     - The damaged database file, along with `-wal` and `-shm` auxiliary files, is renamed to timestamped quarantine backups (`mimra.sqlite.corrupt.<timestamp>.bak`).
     - A fresh database is initialized and migrated.
     - `attempt_salvage_corrupted_database` opens the quarantined file in read-only mode, extracting all readable `history_items` and `item_representations` records into the new database while skipping damaged pages.
     - The search index is rebuilt and database integrity verified.
     - A structured `DatabaseRecoveryReportDTO` is returned containing `was_recovered: true`, `quarantined_backup_path`, and `salvaged_items_count`.
2. **Strict Schema Mismatch Protection (`run_migrations`):**
   - If `schema_migrations` contains versions higher than `MAX_SUPPORTED_SCHEMA_VERSION` (e.g. app downgrade scenario), execution fails immediately with `CoreError::SchemaMismatch`.
   - The database is **never** quarantined or overwritten on schema mismatch.
3. **Transaction Rollback & Zero Orphan Records (`T-DB-01`):**
   - Ingestion, deduplication, and retention occur within single atomic SQLite transactions (`tx`).
   - Aborted or failed transactions automatically roll back, leaving zero orphaned items in `history_items` or `item_representations` and ensuring search triggers remain consistent.
4. **Online Atomic Backups via SQLite VACUUM INTO:**
   - `MimraCoreHandle::backup_database` leverages SQLite's `VACUUM INTO` to create a transactionally consistent, defragmented backup copy while the database is actively being read and written in WAL mode.
   - The generated backup is verified with `PRAGMA integrity_check` before returning.
5. **In-Place Live and Offline Restoration (`rusqlite::backup::Backup`):**
   - Active database connections can be restored in-place without file replacement using the SQLite Online Backup API.
   - Offline database restoration verifies the backup snapshot, safely creates a rollback point, writes the verified database, and runs migrations.
6. **User-Facing Presentation in Swift (`AppDelegate` & `StorageSettingsTab`):**
   - If recovery occurs on startup, `AppDelegate` displays a non-blocking informative alert detailing the quarantine path and salvaged item count.
   - `StorageSettingsTab` features a dedicated "Backup & Recovery" section with "Create Backup..." (`NSSavePanel`), "Verify Integrity" checks, and persistent recovery notices.

### Consequences
* **Positive:** Complete elimination of unconditional database wiping; transparent recovery notices; full resilience against simulated corruptions and transaction interrupts verified by `tests/failure_recovery_tests.swift` (`T-DB-01`).
* **Negative:** Minor disk overhead for timestamped quarantine `.bak` files when corruption occurs, ensuring forensic data preservation.

---

## ADR-032: Pin State Management, Stable Section Layout, Shortcut Invocations, and Retention Immunity

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Phase 5 introduces advanced pinning and keyboard operations (`F-020`, `F-024`, `F-036`, `F-053`). Clipboard history must allow users to pin high-frequency items as persistent anchors that are immune to retention capacity limits, clear-unpinned commands, and application restarts. Navigating and toggling pins must be seamless, with zero mouse dependency and no double separators or visual clutter.

### Decision
1. **Atomic Pin Toggling & Cleanup (`RustCore::storage::repository`):**
   - Added `toggle_pin_status` in `RustCore` which atomically reads the current `is_pinned` state:
     - When unpinned: pins the item, assigns the next ascending `pin_order`, and updates the database.
     - When pinned: unpins the item and explicitly resets `pin_order` and `pin_key` to `NULL`.
   - In `set_pin_status`: when `is_pinned == false`, `pin_key` and `pin_order` are forced to `None` in the SQL update, releasing the unique constraint on `idx_history_pin_key` and preventing constraint deadlocks.
2. **Swift FFI & Selection Stability (`CoreClient` & `PanelViewModel`):**
   - Added `togglePin(itemId:)` across UniFFI, `CoreClient`, and `PanelViewModel`.
   - `PanelViewModel::togglePin(for:)` updates the item in SQLite and reloads the current query view while preserving the active selection (`selectedIndex` / `selectedItemId`) on the toggled item, preventing disruptive selection jumps when the row moves into the pinned section.
3. **Keyboard Shortcuts & Direct Summon (`FloatingPanel::handlePanelKeyDown`):**
   - `Option-P`: Instantly toggles the pin status of the currently selected row (`F-020`, `F-024`, `T-PIN-01`).
   - `Option + <pin_key>`: When an item has an assigned shortcut key (`item.pinKey`), pressing `Option + <key>` directly commits that pinned item into the active application; pressing `Option + Shift + <key>` commits as plain text.
4. **Stable Pinned Section Divider (`FloatingPanelView`):**
   - Implemented conditional section demarcation conforming to `F-036`:
     - Under `pinArrangement == .top`: if both pinned and unpinned items exist in the filtered list, a clean, subtle `"HISTORY"` section header and single divider are rendered after the last pinned item.
     - Under `pinArrangement == .bottom`: a `"PINNED"` header and single divider are rendered before the first pinned item.
     - Pinned-only, unpinned-only, or inline lists render without extra headers, ensuring strict prevention of double separators.
5. **Interactive Pin Actions (`PanelItemRow`):**
   - Added hover/active pin toggle buttons:
     - Pinned items show an orange filled pin (`Image(systemName: "pin.fill")`) that unpins upon click.
     - Unpinned items show a subtle outline pin on row hover (`Image(systemName: "pin")`) that pins upon click.
   - Pinned shortcut badge: items with a custom `pinKey` display an orange `⌥KEY` badge, distinct from the standard `⌘1`–`⌘9` quick-pick numbers.
   - Native context menu provides right-click actions: "Pin/Unpin Item (⌥P)", "Copy to Clipboard", "Paste as Plain Text (⇧↵)", and "Delete Item (⌥⌫)".
6. **Retention Immunity & Restart Durability (`T-PIN-01`, `T-HIST-03`):**
   - Pinned items are guarded by `WHERE is_pinned = 0` across all retention eviction policies (count, age, size) and `clear_unpinned_history`.
   - Recopy duplicate ingestion retains the existing item's pinned state, `pin_order`, and `pin_key` while incrementing `copy_count`.

### Consequences
* **Positive:** Comprehensive pin management; deterministic order and shortcut preservation across restarts; full eviction immunity verified by `tests/pin_tests.swift`.
* **Negative:** None. Fully backwards-compatible with existing schema and migrations.

---

## ADR-033: Pin Shortcut Key Assignment, Punctuation Corpus, Non-US Layouts, and Reserved Conflict Protection

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
Pin management mandates expanding pin shortcut bindings beyond simple alphanumeric keys to include punctuation characters and symbols (`[];'./-=\\`) and international/non-US keyboard layouts (`ä, ö, ü, ß, é, è, ç, ñ, å, ş`). In addition, the engine must enforce unique bindings, prevent duplicate assignments case-insensitively, and prevent collisions with reserved keybindings (specifically `Option-P`, which is dedicated to toggling pin status).

### Decision
1. **Core Validation & Normalization (`RustCore::storage::repository::validate_pin_key`):**
   - Implemented strict validation for candidate pin shortcut keys:
     - Must be exactly one non-whitespace Unicode scalar/character.
     - Control characters (`c.is_control()`) are rejected with `CoreError::InvalidInput`.
     - Multi-character strings and empty/whitespace inputs are rejected with `CoreError::InvalidInput`.
     - Reserved keys `p` and `P` are rejected with `CoreError::PinKeyConflict` explaining that `Option-P` is reserved for toggling Pin/Unpin.
     - Valid inputs are normalized to lowercase for consistent case-insensitive keyboard matching.
2. **Case-Insensitive Duplicate Conflict Protection (`RustCore::storage::repository::set_pin_status`):**
   - Before updating `history_items`, queries SQLite with `LOWER(pin_key) = LOWER(?1) AND id != ?2`.
   - If another item already holds that key (even in differing case), returns `CoreError::PinKeyConflict { key, details }` naming the conflicting item's title.
   - Database unique index `idx_history_pin_key ON history_items(pin_key) WHERE pin_key IS NOT NULL` acts as an invariant database-level safeguard.
3. **Punctuation and Non-US Keyboard Layout Support (`F-024`, `T-PIN-01`):**
   - Full support for the complete punctuation test corpus: `[`, `]`, `;`, `'`, `.`, `/`, `-`, `=`, `\\`.
   - Full support for international layout characters: German (`ä, ö, ü, ß`), French (`é, è, ç`), Spanish (`ñ`), Nordic (`å`), Turkish (`ş`).
4. **AppKit Keyboard Event Normalization (`FloatingPanel::handlePanelKeyDown`):**
   - In `FloatingPanel`, checks both `charactersIgnoringModifiers` and `characters` against `matchedItem.pinKey?.lowercased()`.
   - This accommodates keyboard layouts where punctuation or symbol keys require Alt/Option dead keys or produce transformed characters under modifier chords.
   - Supports plain text execution when Shift is held simultaneously (`Option + Shift + <pin_key>`).
5. **Swift ViewModel & Context Menu Integration (`PanelViewModel` & `FloatingPanelView`):**
   - `PanelViewModel::setPinKey(for:key:)` allows assigning or clearing shortcut keys with active selection preservation.
   - `PanelItemRow` context menu offers "Remove Shortcut (⌥KEY)" when a shortcut key is assigned.

### Consequences
* **Positive:** Comprehensive punctuation and international keyboard shortcut support; collision-safe key assignment; verified by `tests/pin_shortcut_assignment_tests.swift` across all 35 test suites.
* **Negative:** None.

---

## ADR-034: Pinned Item Reordering Persistence, Drag-and-Drop, and Keyboard Accessibility Alternative

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
In clipboard history managers with pinned items (`F-046`, `T-PIN-03`), users need the ability to customize and adjust the sequence of pinned items. The core requirements include:
1. **Deterministic Order Across Relaunches:** The ordering of pinned items must persist reliably in SQLite storage and remain identical across application restarts and database reloads.
2. **Shortcut & Metadata Preservation:** Reordering pinned items must modify exclusively their display/ordering sequence (`pin_order`). Custom assigned shortcuts (`pin_key`), titles, representations, and metadata must remain completely unchanged.
3. **Drag-and-Drop Interaction:** Users should be able to drag a pinned row and drop it onto another pinned row to reposition it.
4. **Keyboard Accessibility Alternative:** Mouse/trackpad drag-and-drop is inaccessible to keyboard-only users, VoiceOver users, and fast keyboard workflows. A deterministic keyboard alternative (`Option + Command + Up` / `Option + Command + Down`), context menu actions ("Move Pin Up", "Move Pin Down"), and VoiceOver accessibility actions must be provided.
5. **Selection Stability:** Moving an item up or down—whether via keyboard or drag-and-drop—must keep the active selection anchored to the moved item, avoiding disruptive selection jumps or deselecting.
6. **Strict Error Handling & Transaction Integrity:** The reordering operation must execute within an atomic transaction. Any attempt to include an unpinned item, a non-existent UUID, or duplicate UUIDs must be rejected with explicit error types (`CoreError::PinReorderFailed`).

### Decision
1. **Rust Storage Engine (`RustCore::storage::repository::reorder_pins`):**
   - Implemented `reorder_pins(conn: &mut Connection, ordered_item_ids: &[Uuid]) -> Result<(), CoreError>`.
   - Checks input validity: non-empty list, no duplicate IDs (`HashSet` check).
   - Verifies each item exists and has `is_pinned = 1`. Any unpinned item returns `CoreError::PinReorderFailed("Item ... is not pinned")`.
   - Executes inside an atomic transaction: sets `pin_order = ?1` for each item according to its zero-based position in `ordered_item_ids`.
   - Leaves `pin_key` unchanged, strictly satisfying `F-046`.
2. **UniFFI Bridge & Swift CoreClient:**
   - Exposed `reorder_pins(ordered_ids: Vec<String>) -> Result<(), CoreError>` on `MimraCoreHandle`.
   - UniFFI generates `reorderPins(orderedIds: [String]) throws`.
   - `CoreClient::reorderPins(orderedIds:) async throws` invokes the Rust handle asynchronously off the main thread.
3. **SwiftUI Drag & Drop (`PinDragAndDropModifier` in `FloatingPanelView`):**
   - Pinned rows attach `.onDrag { NSItemProvider(object: item.id as NSString) }`.
   - Attached `.onDrop(of: [UTType.text], ...)` transfers the dropped item ID and invokes `viewModel.movePin(sourceId:targetId:)`.
4. **Keyboard Accessibility Alternative & Selection Stability (`PanelViewModel` & `FloatingPanel`):**
   - Added `moveSelectedPinUp()` and `moveSelectedPinDown()` to `PanelViewModel`.
   - `FloatingPanel::handlePanelKeyDown` intercepts `Option + Command + Up` (`keyCode 126`) and `Option + Command + Down` (`keyCode 125`).
   - `PanelViewModel::applyItemsPreservingSelection` anchors selection by `selectedItemId`, ensuring that as rows swap positions in the UI, focus remains on the moved item.
5. **VoiceOver and Context Menu Support:**
   - Added context menu buttons "Move Pin Up (⌥⌘↑)" and "Move Pin Down (⌥⌘↓)" on pinned rows.
   - Added `.accessibilityAction(named: "Move Pin Up")` and `.accessibilityAction(named: "Move Pin Down")`.
6. **Integration Verification (`tests/pin_reorder_tests.swift`):**
   - 7-step integration test suite verifying core API reordering, shortcut preservation, invalid input rejection, ViewModel drag-and-drop, keyboard navigation, PanelCoordinator event interception, and database relaunch determinism (`DoD`).

### Consequences
* **Positive:** Full feature parity for pin reordering; seamless keyboard accessibility (`⌥⌘↑`/`⌥⌘↓`); complete selection stability; persistent across restarts; fully verified by automated tests.
* **Negative:** None.

---

## ADR-035: In-Preview Pin Text Editing, Transactional Reindexing, and Unrelated Representation Preservation

* **Status:** Accepted  
* **Date:** 2026-11-03  
* **Deciders:** Mimra Core Engineering  

### Context
In pin workflows (`F-045`, `T-PIN-02`), users require the capability to edit the text content of pinned items directly within the preview/panel. Requirements include:
1. **Retained Pin ID & Ordering:** The item's stable UUID, `is_pinned` status, `pin_order`, and custom shortcut (`pin_key`) must remain strictly unchanged across text edits.
2. **Transactional FTS5 Reindexing:** When an item's text is modified, its title, search text, and FTS5 search postings must be updated atomically within the same transaction so that subsequent queries immediately match the new content and never match obsolete text.
3. **Copy & Paste Fidelity:** Replaying or copying the edited item must deliver the new content to target applications in both plain text and original rich text modes.
4. **Unrelated Representation Preservation:** Unrelated representations (such as metadata UTIs like `org.nspasteboard.source` or secondary items in other group indices) must not be corrupted or discarded.
5. **Keyboard Accessibility & In-Preview Editor:** The editor must be summonable via keyboard shortcut (`Command-E` / `⌘E`) and context menu, and dismissible via `Escape` or committable via `Command-Return` (`⌘↵`).

### Decision
1. **Rust Storage Engine (`RustCore::storage::repository::edit_pinned_item_text`):**
   - Implemented `edit_pinned_item_text(conn: &mut Connection, item_id: &Uuid, new_text: &str) -> Result<HistoryItemSummary, CoreError>`.
   - Validates that `item_id` exists (`CoreError::ItemNotFound`), is pinned (`CoreError::InvalidInput`), and `new_text` is non-empty (`CoreError::InvalidInput`).
   - Normalizes text with Unicode NFC.
   - Updates `public.utf8-plain-text` (and companion plain-text UTIs).
   - Generates matching synthetic HTML (`<meta charset='utf-8'><p>...</p>`) for `public.html` and drops stale RTF to guarantee rich-text paste fidelity.
   - Preserves all unrelated representations (e.g. `org.nspasteboard.source` and items with `group_index > 0`).
   - Recomputes BLAKE3 `content_hash`, `content_kind`, `title`, and `search_text`.
   - SQLite trigger `history_items_au` transactionally updates `search_fts`.
2. **UniFFI Bridge & Swift CoreClient:**
   - Exposed `edit_pinned_item_text` on `MimraCoreHandle` and regenerated Swift UniFFI bindings.
   - Added actor-isolated `editPinnedItemText(itemId:newText:)` to `CoreClient.swift`.
3. **SwiftUI In-Preview Editor (`PinEditorOverlay` in `FloatingPanelView`):**
   - Added `editingPinItem` and `editingPinText` to `PanelViewModel`.
   - Implemented `PinEditorOverlay`: presents text editor with character count, Cancel button, and Save Changes button.
   - In `FloatingPanel.handlePanelKeyDown`:
     - Intercepts `⌘E` (`keyCode 14`) to launch editing for the selected pin.
     - While editing, intercepts `Esc` (`keyCode 53`) to cancel and `⌘↵` (`keyCode 36`) to commit changes.
4. **Integration Verification (`tests/pin_edit_tests.swift`):**
   - 7-step test suite verifying plain-text edit, multi-representation edit, unrelated representation preservation, error guards, ViewModel integration, keyboard interception, and database cold relaunch determinism (`DoD`).

### Consequences
* **Positive:** Complete feature parity for in-preview pin editing; zero representation corruption; immediate FTS5 reindexing; full keyboard accessibility; persistent across restarts.
* **Negative:** None.

---

## ADR-036: Quick Pick 1–9 Number Selection, Full Modifier Matrix, and Visible Order Mapping

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Mimra keyboard interaction (`F-022`, `T-KEY-01`, `P5-05`), users require high-speed numeric quick selection (`1`–`9`) from the floating panel without reaching for the mouse or arrow keys.
Key requirements and challenges:
1. **Definition of Done — Visible Order Matching:** Quick picks `1`–`9` must map strictly to the items in their *currently displayed visible order* (`filteredItems[0...8]`). Whether items are arranged with pins on `.top`, `.bottom`, or `.inline`, sorted by recency or copy count, or narrowed by search queries, `⌘1` must always pick visible row 1, `⌘2` row 2, etc.
2. **Full Modifier Matrix (Copy / Paste / Plain Text):**
   - Standard (`⌘1`..`⌘9` or `⌃1`..`⌃9`): Default paste/copy according to `pasteAutomatically`.
   - Option (`⌥⌘1`..`⌥⌘9` or `⌥⌃1`..`⌥⌃9`): Inverts auto-paste (copies if auto-paste is ON; pastes if auto-paste is OFF).
   - Shift (`⇧⌘1`..`⇧⌘9` or `⇧⌃1`..`⇧⌃9`): Strips rich formatting to plain text mode.
   - Option-Shift (`⌥⇧⌘1`..`⌥⇧⌘9` or `⌥⇧⌃1`..`⌥⇧⌃9`): Plain text mode with inverted auto-paste.
3. **AppKit Shift & International Keyboard Pitfall:** macOS AppKit’s `event.charactersIgnoringModifiers` strips Command and Option but *does not strip Shift*. On US layouts, Shift-1 produces `"!"`, causing standard integer string parsing (`Int(chars)`) to fail. On French AZERTY layouts, the top-row number keys unshifted produce symbols (`&`, `é`, `"`, etc.).
4. **Keypad Support:** Full-size keyboards and external number pads generate distinct keypad virtual keycodes (`83`–`92`) with `.numericPad` flags that must resolve accurately to numbers `1`–`9`.
5. **Boundary & Capacity Limits:** Requesting numbers beyond available visible items (`targetIndex >= count`), invalid numbers (`< 1` or `> 9`), or empty lists must safely no-op without selection corruption, fatal drops, or unexpected dismissals.
6. **Active Pin Editing Immunity:** When the inline pin editor (`editingPinItem != nil`, P5-04) is open, numeric keystrokes must be passed through to the text editor rather than triggering panel quick picks.

### Decision
1. **Hardware Virtual Keycode Resolution (`PanelCoordinator.quickPickNumber`):**
   - Implemented `PanelCoordinator.quickPickNumber(for event: NSEvent) -> Int?`.
   - Maps ANSI top-row keycodes (`18`..`25`) and numeric keypad keycodes (`83`..`92`) directly to integers `1`..`9`. This guarantees deterministic resolution regardless of Shift state or international layout (such as AZERTY).
   - Provides character parsing fallback for synthetic headless test environments.
2. **Modifier Interception & Dispatch (`PanelCoordinator.handlePanelKeyDown`):**
   - Intercepts `Command` and `Control` modifier triggers paired with resolved numbers `1`..`9`.
   - Extracts `isOption = event.modifierFlags.contains(.option)` and `isShift = event.modifierFlags.contains(.shift)`.
   - Computes `mode: PasteMode = isShift ? .plainText : .original`.
   - Computes `forcePaste: Bool? = isOption ? !pasteCoordinator.pasteAutomatically : nil`.
   - Dispatches via `viewModel.quickPick(number:mode:forcePaste:)` and consumes the key event (`return true`).
3. **ViewModel Selection & Capacity Guards (`PanelViewModel.quickPick`):**
   - `@discardableResult public func quickPick(number: Int, mode: PasteMode = .original, forcePaste: Bool? = nil) -> Bool`.
   - Enforces `guard number >= 1 && number <= 9 else { return false }`.
   - Safely indexes into `filteredItems`: `guard targetIndex < list.count else { return false }`.
   - Updates `selectedIndex = targetIndex` and `selectedItemId = list[targetIndex].id`.
   - Commits selection and dismisses panel only when an item was validly picked.
4. **Visual Badge Parity (`FloatingPanelView.PanelItemRow`):**
   - Rendered an `HStack(spacing: 3)` displaying both custom pin shortcuts (`⌥KEY`) and visible row quick picks (`⌘1`–`⌘9`). Pinned items in the top 9 display both their permanent shortcut and their current row quick pick.
5. **Integration Verification (`tests/quick_pick_tests.swift`):**
   - 7-step test suite covering keycode mapping, Shift/AZERTY layout resilience, keypad keycodes, capacity limits, visible order matching under all pin arrangements and active search queries, full modifier combinations, pasteboard replay fidelity, and active pin editing immunity (`DoD`). Added as Step 37 in `scripts/test-all.sh`.

### Consequences
* **Positive:** Complete feature parity for 1–9 quick picks (`F-022`, `T-KEY-01`); layout-agnostic and shift-resilient; full modifier support (copy/paste/plain); strict visible order matching; 100% test coverage.
* **Negative:** None.

---

## ADR-037: Summon-Key Cycle Mode, Modifier Release Commit Protocol, and Cancellation Guards

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Mimra power keyboard workflows (`F-023`, `F-031`, `T-KEY-02`, `T-KEY-04`, `P5-06`), users require a fluid "quick-switcher" cycle mode:
1. **Summon-Key Cycling Workflow:**
   - When the user presses the global summon hotkey (`⇧⌘C` default), the panel appears.
   - If the user keeps holding the summon modifiers and presses the summon key (`C`) again, the panel enters **Cycle Mode** and advances selection down the list (`selectNext()`).
   - Each subsequent tap while holding modifiers advances selection with circular wrap-around at list boundaries.
   - When the user releases the held modifiers, Mimra immediately **commits** the selected item (pastes or copies according to `pasteAutomatically`), hides the panel, and restores focus to the target app.
2. **Single-Summon Non-Interference:**
   - If the user summons the panel once without repeating the summon key and then releases the modifiers, cycle mode must *not* activate. The panel must remain open for searching or manual browsing.
3. **Cancellation & Disarming Guards:**
   - **Escape Key:** Pressing Escape (`keyCode 53`) must immediately cancel cycle mode, hide the panel, and ensure subsequent modifier releases trigger zero commits.
   - **Focus Loss (`resignKey`):** If the user clicks elsewhere or switches applications while cycling, the panel must immediately cancel cycle mode and hide.
   - **Text Typing & IME Composition:** If the user types any character into the search field, cycle mode must safely disarm so that releasing modifiers does not trigger an accidental commit.
   - **Pin Keys & Navigation Independence:** Pin shortcuts (`⌥P`, `⌥<key>`) and manual navigation must operate without conflict or false cycle triggering.
4. **macOS Event Architecture Challenges:**
   - Carbon `RegisterEventHotKey` intercepts the summon key globally, but Carbon does *not* notify the application when modifier keys are released.
   - AppKit window event monitoring must observe `.flagsChanged` events when the panel is key window to detect modifier release without requiring elevated Accessibility keylogging entitlements.

### Decision
1. **Lifecycle & State Machine (`PanelCoordinator`):**
   - Maintained state properties: `isCycleActive: Bool`, `summonKeyCode: UInt32`, `summonModifiers: NSEvent.ModifierFlags`, and `cycleModeEnabled: Bool` (persisted in `UserDefaults`, default `true`).
   - Implemented `handleSummonHotkey()`:
     - If panel is hidden: invokes `show()`, loads data, centers on screen, and sets `isCycleActive = false`.
     - If panel is visible and `cycleModeEnabled`: invokes `cycleNext()`, advances selection via `viewModel.selectNext()`, and sets `isCycleActive = true`.
     - If panel is visible and `!cycleModeEnabled`: invokes `hide()`.
2. **Primary Modifier Resolution & `.flagsChanged` Interception:**
   - Added `primarySummonModifier: NSEvent.ModifierFlags` computed property resolving priority (`.command` > `.option` > `.control` > `.shift`).
   - Configured `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])`.
   - In `handlePanelFlagsChanged(event:)`:
     - Checks `guard isCycleActive else { return }`.
     - When `!event.modifierFlags.contains(primarySummonModifier)`, the user has released the held modifiers.
     - Invokes `commitCycle()`, disarming `isCycleActive = false`, committing selection via `viewModel.commitSelection(mode: .original, forcePaste: nil)`, and dismissing the panel.
3. **Cancellation Guards (`cancelCycle()`):**
   - `cancelCycle()` safely disarms `isCycleActive = false` and fires `onCycleCancelled?()`.
   - Wired `cancelCycle()` into `show()`, `hide()`, `panel.onResignKey`, `panel.onEscapePressed`, Return/Enter, Pin shortcuts, and non-handled character keystrokes.
   - Up and Down Arrow keys are permitted during cycle mode to fine-tune selection without disarming `isCycleActive`.
4. **Settings & Preferences:**
   - Added `@AppStorage("cycleModeEnabled")` toggle under General Settings in `SettingsView.swift`: *"Cycle through history with summon key"*.
5. **Comprehensive Verification (`tests/cycle_mode_tests.swift`):**
   - 14-step integration test suite covering modifier resolution, single summon non-commit, repeat summon cycling, circular wrap-around, reverse cycling, cancellation on Escape, cancellation on focus loss (`resignKey`), disarming on regular text input, manual arrow key navigation during cycle mode, in-panel summon key handling, preference toggle, pin operations independence, and empty history boundary resilience. Added as Step 38 in `scripts/test-all.sh`.

### Consequences
* **Positive:** Complete feature parity for summon-key cycling (`F-023`, `F-031`, `T-KEY-02`, `T-KEY-04`); seamless quick switcher workflow; robust cancellation guards; zero conflicts with pins, IME, or background apps; 100% test coverage.
* **Negative:** None.

---

## ADR-038: Navigation Semantics, Delete Selection Stability, and Section Separator Consistency

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In clipboard manager keyboard interactions (`P5-07`, `F-030`, `F-036`, `T-KEY-03`, `T-UI-10`), users rely heavily on page-based cursor jumps and uninterrupted selection stability during item deletions.
Historical edge cases motivated specific requirements:
1. **Page Up / Page Down Bounds Clamping:** Users on full-size or laptop keyboards (`Fn+Up` for `keyCode 116`, `Fn+Down` for `keyCode 121`) require jumping 10 rows per page step without jumping past boundaries or triggering invalid index exceptions. Home (`keyCode 115`) and End (`keyCode 119`) must instantly jump to the top and bottom.
2. **Critical Delete Selection Stability (Regression Prevention):**
   - *Deleting the first unpinned item:* When pinned items precede unpinned history (e.g. `[Pin0, Pin1, Unpin0, Unpin1]`), deleting `Unpin0` must preserve the selection on the successor unpinned item (`Unpin1` at visual index 2). Under no circumstances should the selection erroneously jump to pinned items (`Pin0` / `Pin1`) or reset to 0.
   - *Deleting middle items:* Preserves the visual row index, shifting the successor item into focus.
   - *Deleting the bottom item:* Smoothly clamps to the new bottom-most row (`count - 1`).
   - *Rapid successive deletions:* Deleting numerous items rapidly in sequence (e.g. 15 items) must never produce race conditions or out-of-bounds indexing.
   - *Exhaustion to empty state:* Deleting all remaining items must cleanly transition to `selectedIndex = 0`, `selectedItemId = nil`, and `selectedItem = nil`.
3. **List Sectioning & Separator Consistency (`F-036`, `T-UI-10`):**
   - *Pinned-only lists:* When all history items are pinned, no extraneous `HISTORY` headers or dividers should appear.
   - *History-only lists:* When no pinned items exist, no extraneous `PINNED` headers or dividers should appear.
   - *Mixed lists:* When both pinned and unpinned items exist, the top section is cleanly labeled, and exactly one subtle divider with section header separates pins from history. Double separators are strictly prohibited.
   - *Zero results empty state:* When search query matches 0 items, displays *"No Matches Found"* with query context; when total history is 0, displays *"Clipboard is Empty"*.

### Decision
1. **Navigation Clamping (`PanelViewModel`):**
   - `selectPageDown(pageSize: 10)`: `selectedIndex = min(count - 1, selectedIndex + pageSize)`.
   - `selectPageUp(pageSize: 10)`: `selectedIndex = max(0, selectedIndex - pageSize)`.
   - `selectFirst()`: `selectedIndex = 0`.
   - `selectLast()`: `selectedIndex = max(0, count - 1)`.
   - All navigation methods update `selectedItemId = selectedItem?.id` and refresh `lastKeyboardNavTime`.
2. **Selection Preservation on Deletion (`PanelViewModel.applyItemsPreservingSelection`):**
   - When the deleted item was selected, its ID is absent from `newItems`.
   - Clamps the index: `let clamped = min(previousIndex, list.count - 1)`, `selectedIndex = max(0, clamped)`.
   - Selects the successor item at the identical visual row position, satisfying the first-unpinned deletion invariant.
3. **Sectioning Helper Properties (`PanelViewModel`):**
   - Added `hasPinnedItems: Bool`, `hasUnpinnedItems: Bool`, and `hasMixedPinnedAndUnpinned: Bool`.
4. **Clean List Sectioning (`FloatingPanelView`):**
   - Section headers (`PINNED` / `HISTORY`) at index 0 render only when `hasMixedPinnedAndUnpinned` is true.
   - Section divider between pins and recents renders only at the exact boundary index. Zero double separators.
5. **Comprehensive Verification (`tests/nav_semantics_tests.swift`):**
   - 4-step integration test suite verifying Page Down / Page Up / Home / End clamping on 25 items, KeyDown event routing, first-unpinned deletion regression, middle deletion, bottom clamping, rapid deletion stress test (15 items), transition to empty state, pinned-only lists, history-only lists, mixed lists, and zero search results empty state. Added as Step 39 in `scripts/test-all.sh`.

### Consequences
* **Positive:** Complete feature parity for Page Up/Down navigation and list sectioning (`F-030`, `F-036`, `T-KEY-03`, `T-UI-10`); rock-solid cursor stability across deletions; zero double separators; 100% test coverage.
* **Negative:** None.

---

## ADR-039: Slideout Preview Panel Window Hierarchy, Geometry Clamping, and Mouse Transparency

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Mimra preview workflows (`P6-01`, `F-039`, `T-PREV-01`), users require a fluid slideout preview panel adjacent to the main history window:
1. **Window Hierarchy & Attachment:**
   - The preview panel must track the position, visibility, and space transitions of the main `FloatingPanel` without creating orphan windows or floating detached across macOS spaces.
2. **Screen Bounds & Edge Flipping:**
   - When the main panel is positioned normally, the preview should attach to its right edge.
   - If the main panel is close to the right display border such that the preview would overflow offscreen or onto an adjacent monitor, the preview must automatically flip to the left edge.
   - On small displays or near screen tops/bottoms, coordinates must strictly clamp inside `screen.visibleFrame` (accounting for menu bar and Dock).
3. **Mouse Transparency on Dismissal (DoD Invariant):**
   - A critical defect in floating overlay windows is a closed or hidden panel continuing to swallow mouse clicks. When the preview is closed, it must immediately disable mouse interception (`ignoresMouseEvents = true`), detach from the parent window, and order out.
4. **Display Changes & Rapid Toggles:**
   - Display environment changes (`NSApplication.didChangeScreenParametersNotification`) and window repositioning must immediately trigger layout updates without UI flickering or crashes.

### Decision
1. **Pure Geometry Engine (`PreviewBoundsCalculator`):**
   - Computes `PreviewPlacement(frame: CGRect, side: PreviewSide)` deterministically.
   - Default attachment: `origin.x = parentFrame.maxX + gap`.
   - Overflow detection: If `origin.x + effectiveWidth > screenVisibleFrame.maxX`, flips to `parentFrame.minX - gap - effectiveWidth` (`.left`).
   - If neither side fits fully, picks the side with more available room and clamps within `screenVisibleFrame`.
   - Top alignment: `origin.y = parentFrame.maxY - effectiveHeight`, clamped between `screenVisibleFrame.minY` and `screenVisibleFrame.maxY - effectiveHeight`.
2. **Native Non-Activating Panel (`PreviewPanel`):**
   - Subclass of `NSPanel` with `.nonactivatingPanel`, `.floating` level, and `.canJoinAllSpaces`.
   - `canBecomeKey = false` and `canBecomeMain = false` to guarantee keyboard focus remains on the main history search field.
   - `setMouseInterceptionEnabled(_ enabled: Bool)` dynamically toggles `ignoresMouseEvents = !enabled`.
3. **Preview Container & HUD Layout (`PreviewContainerView`):**
   - SwiftUI container featuring ultra-thin blurred material, rounded corners, source app icon, kind badge, pin shortcut indicators, structured metadata grid (byte size, copy count, first/last timestamps, representations), and keyboard hint footer.
4. **Lifecycle Coordination (`PreviewCoordinator`):**
   - Coordinates window creation, child window attachment (`parent.addChildWindow(panel, ordered: .above)`), content updates (`updateItemIfVisible`), and screen parameter notifications.
   - On `hide()`: disables mouse interception (`ignoresMouseEvents = true`), detaches child window from parent, and orders out.
5. **Panel Coordinator Integration (`FloatingPanel` & `PanelViewModel`):**
   - Added `onSelectionChanged` callback on `PanelViewModel` to stream selection updates directly to `previewCoordinator.updateItemIfVisible`.
   - Wired `Control-Space` (`keyCode 49` with `.control`) in `handlePanelKeyDown` to invoke `togglePreview()`.
   - Added `windowDidMove` and `windowDidResize` in `NSWindowDelegate` and chained layout updates into `centerOnActiveScreen`.
   - Integrated preview dismissal into `FloatingPanel.hide()`.
6. **Comprehensive Verification (`tests/preview_panel_tests.swift`):**
   - 10-step integration test suite verifying right placement, left flip on right overflow, vertical clamping, narrow screen fallback, panel window attributes, mouse transparency and child attachment, content updates on selection change, 50 rapid toggle cycles, main panel hide dismissal, and screen parameters notification handling. Added as Step 40 in `scripts/test-all.sh`.

### Consequences
* **Positive:** Complete satisfaction of `P6-01` (`F-039`, `T-PREV-01`); robust edge-flip and screen bounds clamping; guaranteed zero mouse interception when closed; seamless child window attachment; 100% test coverage.
* **Negative:** None.

---

## ADR-040: Slideout Preview In-Panel Shortcut Isolation, Auto-Open Debounce Engine, and Dismissal Safety

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Mimra preview workflows (`P6-02`, `F-040`, `T-PREV-02`), users require configurable preview opening behaviors and strict shortcut isolation:
1. **Local Shortcut Isolation (DoD Invariant):**
   - The preview toggle shortcut (`Control-Space` / `⌃Space`) must operate strictly as a local keyboard event within the active `FloatingPanel`.
   - It must **never** register a global Carbon hotkey or global event tap, avoiding collisions with system shortcuts (e.g. Input Source switching) or IDEs (e.g. code completion).
2. **Auto-Open Debounce & Rapid Navigation:**
   - When users browse through history rapidly (e.g., holding Down Arrow or stepping through rows), an auto-opening preview must not flash on every intermediate item or cause UI stutter.
   - A debounce delay must ensure only the item on which the user pauses for the configured duration triggers preview display.
3. **Dismissal & Inactivity Guards:**
   - If the main history panel is dismissed (via Escape, click outside, or item paste) while an auto-open timer is running, the timer must be cancelled immediately. The preview must never pop open after the parent window has closed.
4. **Instant Updates When Open:**
   - Once the preview is open, subsequent selection changes must update the preview content instantaneously without re-waiting for the debounce delay.

### Decision
1. **Strict Local Shortcut Routing (`FloatingPanel.handlePanelKeyDown`):**
   - Handled inside `FloatingPanel`'s local `NSEvent` key monitor (`keyCode == 49` with `.control`).
   - `HotkeyManager` exclusively registers global summon hotkeys and maintains zero references to `Control-Space`.
2. **Debounce Engine & State Machine (`PreviewCoordinator`):**
   - Maintained state: `isAutoOpenEnabled: Bool` (persisted in `UserDefaults.standard` as `"previewAutoOpenEnabled"`, default `false`) and `autoOpenDelayMs: Int` (default `400` ms).
   - `handleSelectionChanged(item:parent:)`:
     - Calls `cancelAutoOpenTimer()`.
     - If `isPreviewVisible`: updates SwiftUI hosting content immediately.
     - Else if `isAutoOpenEnabled && parent.isVisible`: spawns a cooperative `Task` sleeping for `autoOpenDelayMs * 1_000_000` nanoseconds.
     - Upon waking, verifies `!Task.isCancelled` and `parent.isVisible` before invoking `show(for:parent:)`.
3. **Cancellation Hooks (`cancelAutoOpenTimer()`):**
   - Inlined across `hide()`, `toggle()`, `show()`, `FloatingPanel.hide()`, and property setters when disabled.
4. **Appearance Settings (`SettingsView.swift`):**
   - Added *"Slideout Preview"* section under the Appearance tab with `@AppStorage("previewAutoOpenEnabled")` toggle and `@AppStorage("previewDelayMs")` picker (200ms Fast, 400ms Normal, 600ms Relaxed, 1000ms Slow), accompanied by clear explanatory hint text.
5. **Comprehensive Verification (`tests/preview_settings_tests.swift`):**
   - 7-step integration test suite verifying local shortcut isolation (no global registration), auto-open disabled by default, timer firing after configured delay, rapid navigation intermediate cancellation, panel dismissal cancellation, immediate updates when open, and `UserDefaults` round-trip persistence. Added as Step 41 in `scripts/test-all.sh`.

### Consequences
* **Positive:** Complete satisfaction of `P6-02` (`F-040`, `T-PREV-02`); strictly isolated in-panel keyboard interaction; fluid zero-stutter auto-open navigation; leak-free cancellation on dismissal; 100% test coverage.
* **Negative:** None.

---

## ADR-041: Native Non-Contiguous Text Preview, 1 MB Buffer Lazy Rendering, and Accessibility Selection

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Mimra preview workflows (`P6-03`, `F-041`, `T-PREV-03`), users frequently preview large text payloads (e.g. source code, stack traces, JSON logs, or multi-page documents up to 1 MB):
1. **SwiftUI Text Performance Bottleneck:**
   - Standard SwiftUI `Text` and `ScrollView` calculate full document glyph layout synchronously on the main thread. When rendering large text buffers (50 KB – 1 MB), this triggers severe UI hangs, beachballs, and excessive memory allocations.
2. **Text Selection & Accessibility:**
   - Users require native text selection (drag, double-click word, triple-click line), keyboard copy shortcut (`⌘C`), and VoiceOver accessibility integration within the preview window.
3. **Typography & Code Inspection:**
   - Code, logs, and structured text need an optional monospaced font mode, while prose benefits from proportional system fonts.
4. **Asynchronous Full-Payload Ingestion:**
   - While `HistoryItemSummaryDto` retains an abbreviated snippet for fast menu rendering, the slideout preview must display the entire payload without blocking the UI during SQLite blob extraction.

### Decision
1. **Native Text Engine (`NativeTextPreviewView`):**
   - Implemented an `NSViewRepresentable` wrapping AppKit's `NSScrollView` and `NSTextView`.
   - Enabled **non-contiguous layout** (`layoutManager.allowsNonContiguousLayout = true`). The layout engine computes line breaks and glyph positions lazily on-demand—only for the portion of text visible within the viewport.
   - Configured `isEditable = false` (read-only safety), `isSelectable = true` (accessibility and copy support), `drawsBackground = false`, and `textContainer.widthTracksTextView = true`.
   - Separated pure factory methods (`makeScrollView()` and `updateScrollView(_:)`) for headless unit testing without requiring active display contexts.
2. **Asynchronous Full-Payload Fetching (`PreviewContainerView`):**
   - Attached an asynchronous `.task(id: item?.id)` querying `CoreClient.getItemRepresentations(itemId:)` off the main actor.
   - Decodes plain text representations (`public.utf8-plain-text`, `NSStringPboardType`, `text/plain`) on background threads. Displays immediate snippet fallback while loading to ensure instantaneous view presentation.
3. **Text Inspection Toolbar & Controls:**
   - Added live text statistics (`X chars • Y lines`), a monospaced font toggle button (`chevron.left.forwardslash.chevron.right`), and a one-click copy button with temporary visual feedback.
4. **Comprehensive Verification (`tests/text_preview_tests.swift`):**
   - 8-step integration test suite verifying 1 MB buffer loading performance (initialization in ~101 ms, zero UI freeze), non-contiguous layout configuration, smooth scrolling simulation across 10,000 lines, accessibility text selection and substring extraction, monospace font toggling, scroll position reset on item switching, multi-byte Unicode/CJK/Emoji safety, and full text asynchronous loading via `CoreClient`. Added as Step 42 in `scripts/test-all.sh`.

### Consequences
* **Positive:** Complete satisfaction of `P6-03` (`F-041`, `T-PREV-03`); 1 MB text buffers scroll smoothly at full display refresh rate with zero UI freeze; native text selection and VoiceOver support; seamless monospace toggling; 100% test coverage.
* **Negative:** None.

---

## ADR-042: High-Performance Image Preview with Aspect Ratio Preservation, Native HEIC Support, and Metadata-First Bounded Caching

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Mimra preview workflows (`P6-04`, `F-042`, `T-PREV-04`), image items (screenshots, copied illustrations, photographs, and icons in PNG, JPEG, TIFF, and HEIC formats) require an in-depth slideout inspection experience:
1. **Aspect Ratio Preservation & Visual Fidelity:**
   - Previews must preserve exact width-to-height aspect ratios across diverse orientations (e.g. 16:9 widescreen, 4:3 standard, 1:1 square, and 9:16 portrait mobile screenshots) without stretching, distortion, or clipping.
   - Transparent PNGs and icons must remain clearly legible against dynamic light and dark macOS HUD materials.
2. **Main-Thread Performance & Zero UI Hitching:**
   - Full-resolution camera images or Retina screenshots can easily reach 24 to 48 megapixels. Decompressing raw bitmaps synchronously on the main thread would allocate hundreds of megabytes and cause severe frame drops and beachballs.
   - In accordance with Definition of Done (DoD), images must never be repeatedly decoded on each row or preview render.
3. **Instant Metadata Extraction:**
   - Users need immediate visibility of image dimensions (width × height px), format (PNG, JPEG, TIFF, HEIC), file byte size, aspect ratio, and color space without awaiting full pixel rendering.
4. **Apple Silicon Native HEIC Decoding:**
   - As macOS and iOS increasingly utilize HEIC for screenshots and photos, native Apple Silicon hardware-accelerated HEIC decoding is mandatory.

### Decision
1. **Metadata-First Inspection (`ImagePreviewService.extractMetadata`):**
   - Employs `CGImageSourceCreateWithData` with `kCGImageSourceShouldCache: false` and `CGImageSourceCopyPropertiesAtIndex`.
   - Extracts `kCGImagePropertyPixelWidth`, `kCGImagePropertyPixelHeight`, `kCGImagePropertyColorModel`, and format identifiers in `< 2 ms` directly from container headers without decompressing pixel bitmaps.
   - Computes simplified mathematical aspect ratios (e.g. `16:9`, `4:3`, `1:1`, `9:16`) using Euclidean greatest common divisor reduction.
2. **Dedicated Background Actor & In-Memory Bounded Caching (`ImagePreviewService`):**
   - Implemented an isolated actor with an `NSCache` bounded to 128 MB and 60 entries.
   - Coalesces concurrent in-flight decoding tasks via `[String: Task<ImagePreviewPayload?, Never>]` to ensure rapid list navigation never spawns redundant decoding passes.
   - Downscales preview rendering to `maxPixelSize: 1600` via `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailWithTransform: true`, guaranteeing crisp Retina rendering while bounding RAM consumption.
   - Exposes synchronous `cachedPreview(for:)` for instantaneous zero-latency cache hits when navigating history.
3. **SwiftUI Canvas Checkerboard & Aspect Ratio View (`ImagePreviewView`):**
   - Encapsulates display inside `Image(nsImage: payload.image).resizable().aspectRatio(contentMode: .fit)`.
   - Embeds a GPU-accelerated `CheckerboardBackdropView` using SwiftUI `Canvas` (tile size 10 pt) to guarantee transparent PNG and monochrome icon visibility across light/dark appearances.
   - Provides an image inspection toolbar showing dimensions pill, format badge, byte size pill, color space, and a quick "Copy Image" button that reconstitutes clipboard image representations with provenance stamps.
   - Implements graceful loading states and corrupted payload cards ("Unable to preview image") preventing crashes.
4. **Comprehensive Verification (`tests/image_preview_tests.swift`):**
   - 7-step integration test suite covering:
     - Aspect ratio and dimension extraction across 4:3, 16:9, 1:1, and portrait 9:16 formats.
     - Native ImageIO HEIC encoding and decoding fidelity with aspect ratio verification.
     - 2400x1200 high-resolution downscaling preserving 2:1 ratio and original metadata.
     - Synchronous and asynchronous cache hits with zero CPU decode overhead.
     - 8-thread concurrent request coalescing.
     - Cache clearing.
     - Negative resilience against empty buffers, random noise bytes, and truncated headers.
     - End-to-end SQLite ingestion and preview pipeline verification. Added as Step 43 in `scripts/test-all.sh`.

### Consequences
* **Positive:** Complete fulfillment of `P6-04` (`F-042`, `T-PREV-04`); zero main thread hitching; instant cache hits; native HEIC decoding on Apple Silicon; exact aspect ratio preservation; 100% test pass.
* **Negative:** None.

---

## ADR-043: On-Device Multilingual Vision Text Recognition & Search Synchronization

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
Mimra power search features (`P6-05`, `F-043`, `F-051`, `T-OCR-01`, `T-SRCH-04`) require on-device optical character recognition (OCR) for clipboard images (screenshots, photographs, diagrams, and scanned snippets):
1. **Zero Main-Thread Blocking:**
   - Vision text recognition involves heavy neural network inference and feature extraction. Running OCR synchronously on the main thread would freeze the UI and degrade clipboard response time.
2. **Multilingual Text Extraction & Automatic Language Detection:**
   - Users frequently copy multilingual content (e.g. English diagnostics combined with German, French, or Japanese text). OCR must automatically detect languages across text regions without requiring cumbersome manual settings.
3. **Clean Cancellation & Cooperative Preemption:**
   - When users rapidly copy multiple images or delete history items while OCR is in flight, the service must immediately abort obsolete recognition passes without leaking background threads, memory, or CPU cycles.
4. **Instant Searchability & FTS5 Synchronization:**
   - Recognized text must be transactionally indexed into RustCore's SQLite database and SQLite FTS5 search index (`search_fts`), enabling instant search in Fuzzy, Exact, and Regex modes with UTF-16 highlight ranges and preview snippets.
5. **Absolute Privacy & Zero Network Calls:**
   - Mimra's security core mandate strictly prohibits transmitting image bytes or extracted text over network sockets. Recognition must run 100% locally on Apple Silicon Neural Engine / GPU / CPU, and raw OCR payloads must never appear in logs.
6. **Stale Callback & Resurrection Protection:**
   - If an item is deleted or history is cleared while OCR is in flight, the completion callback must never resurrect the deleted item in SQLite or FTS5 indices.

### Decision
1. **Off-Main Background Execution via Swift Actor (`OCRService`):**
   - Implemented `OCRService` as a Swift actor offloading heavy Vision work to `Task.detached(priority: .userInitiated)` on system background queues.
   - Concurrency safety under Swift 6 strict concurrency achieved using `@preconcurrency import Vision` and thread-safe `RequestBox` for hardware-level cancellation.
2. **On-Device Apple Vision Pipeline (`VNRecognizeTextRequest`):**
   - Employs Apple's native `VNRecognizeTextRequest` configured with `.accurate` recognition level.
   - Activates automatic language detection (`request.automaticallyDetectsLanguage = true` on macOS 13+) paired with a comprehensive fallback candidate language array (`en-US`, `de-DE`, `fr-FR`, `es-ES`, `it-IT`, `pt-BR`, `zh-Hans`, `zh-Hant`, `ja-JP`, `ko-KR`).
   - Normalizes extracted text lines to Unicode NFC (`precomposedStringWithCanonicalMapping`) and trims whitespace.
3. **Cooperative Cancellation (`OCRService.cancel`, `cancelAll`):**
   - Maintained active task registry (`activeTasks: [String: Task<String, any Error>]`) and request registry (`activeBoxes: [String: RequestBox]`).
   - Cancelling an in-flight item immediately dispatches `request.cancel()` to abort Apple Vision hardware processing, while cooperative `Task.checkCancellation()` stops downstream processing.
4. **RustCore Transactional Storage & FTS5 Synchronization:**
   - Added `update_ocr_text(conn, item_id, ocr_text)` and `get_ocr_text(conn, item_id)` in `RustCore/src/storage/repository.rs` and exposed on `MimraCoreHandle` via UniFFI.
   - `UPDATE history_items SET ocr_text = ?1 WHERE id = ?2;` atomically fires the `history_items_au` SQLite trigger, updating `search_fts` in the same transaction.
   - Updated `RustCore/src/storage/search.rs` to include `ocr_text` in candidate evaluation, scoring images against extracted OCR text in Fuzzy, Exact, and Regex modes with UTF-16 highlight ranges and contextual snippet generation.
5. **Fail-Safe Stale Callback Protection (`T-SRCH-04`):**
   - `update_ocr_text` verifies rows affected: if the item was deleted before OCR completed, zero rows are updated and `Ok(false)` is returned. No `INSERT` is performed, preventing phantom item resurrection.
6. **Automatic Ingestion Hook in `ClipboardMonitor`:**
   - When an image item is ingested (`outcome.contentKind == "image"`), `ClipboardMonitor` automatically queues background OCR via `ocrService.recognizeAndIndex` without blocking clipboard polling or event dispatch.
7. **Comprehensive Verification (`tests/ocr_service_tests.swift`):**
   - Step 44 in `scripts/test-all.sh` executes 6 test stages:
     - Synthetic test image containing English and German text accurately recognized on-device.
     - Automatic ingestion, background indexing, and FTS5 search in Fuzzy, Exact, and Regex modes.
     - Clean cancellation of in-flight recognition tasks without exceptions or crashes.
     - `cancelAll()` bulk termination.
     - Stale callback protection with verified zero resurrection on deleted items.
     - Negative input resilience against empty data and corrupted byte streams.

### Consequences
* **Positive:** Complete fulfillment of `P6-05` (`F-043`, `T-OCR-01`); 100% on-device multilingual OCR; instantaneous FTS5 search across image text; zero main-thread hitching; robust cooperative cancellation; full Swift 6 strict concurrency compliance; 100% test pass.
* **Negative:** None.

---

## ADR-044: OCR Results Presentation, Quick Copy Action, and Display State Machine

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
Mimra Phase 6 requirements (`P6-06`, `F-044`, `T-OCR-02`) mandate seamless presentation of on-device OCR results in the user interface:
1. **Searchable Image Text in History & Snippet Previews:**
   - When browsing history or searching by embedded image text, users need to immediately see extracted OCR snippets with matching highlights in the list panel (`FloatingPanelView`).
2. **Dedicated "Copy OCR Text" Action in Image Preview Toolbar:**
   - In `ImagePreviewView`, users inspecting image previews need a dedicated, one-click action to copy the recognized text to the clipboard without copying the raw image bitmap.
3. **Robust Display Lifecycle & State Representation:**
   - On-device text recognition takes variable time (from tens of milliseconds on modern Apple Neural Engine to longer for high-resolution graphics). The UI must handle all states gracefully: `.idle`, `.loading`, `.success(text:)`, `.noTextDetected` (when an image contains no readable text), and `.failed(error:)` with explanatory tooltips.
4. **Self-Recapture Loop Safeguards (`F-012`, `F-020`):**
   - Copying extracted OCR text to `NSPasteboard` must stamp Mimra's provenance marker (`com.mimra.provenance` and `org.nspasteboard.source`) and record the self-write on `ClipboardProvenance` so the clipboard monitor does not erroneously capture the copied OCR text as a new history item.
5. **In-Flight Task Deduplication:**
   - When an image preview is opened while background ingestion OCR is already running, multiple callers requesting recognition for the same item ID must await the same shared in-flight task rather than thrashing or re-running expensive Vision passes.
6. **Zero Remote Network Transmission:**
   - All text extraction, storage, and previewing must operate 100% locally on-device without remote network calls.

### Decision
1. **History List Snippet Integration (`RustCore/src/storage/repository.rs`):**
   - Updated `list_history_page_with_options` to select `ocr_text` and display up to 160 characters of recognized text in `snippet` for image items when browsing history.
   - Preserves search highlighting automatically via `HighlightedLabel` in `FloatingPanelView.swift`.
2. **SwiftUI Display State Machine (`OCRDisplayState`):**
   - Defined `OCRDisplayState` enum (`.idle`, `.loading`, `.success(text:)`, `.noTextDetected`, `.failed(error:)`).
   - Integrated `ocrToolbarItem` in `ImagePreviewView.toolbarBar`:
     - Shows scanning spinner during `.loading`.
     - Shows "Copy OCR Text" button with copy confirmation feedback during `.success`.
     - Shows subtle "No text" badge when Vision finds zero readable text (`.noTextDetected`).
     - Shows "OCR error" badge with descriptive tooltip during `.failed(error:)`.
   - Added selectable recognized text drawer (`ocrTextSection`) in preview canvas for quick viewing and inline selection.
3. **Task Deduplication in `OCRService`:**
   - In `OCRService.recognizeText`, if an active task already exists in `activeTasks[taskKey]`, incoming callers await the existing task's value (`return try await existingTask.value`) to avoid duplicate computation.
4. **Provenance-Stamped Copy Actions:**
   - In `ImagePreviewView.copyOcrTextToClipboard`, written items are stamped with `ClipboardProvenance.provenanceType` and `ClipboardProvenance.sourceAppType`, followed by `ClipboardProvenance.shared.recordSelfWrite(on: pb)`.
   - Updated `ImagePreviewView.copyImageToClipboard` to use identical provenance protection.
5. **Comprehensive Verification (`tests/ocr_results_tests.swift`):**
   - Registered as Step 45 in `scripts/test-all.sh`.
   - Validates end-to-end image ingestion with synthetic invoice, FTS5 search discovery by embedded text, history list snippet verification, pasteboard copy verification with provenance checking, all `OCRDisplayState` transitions, and zero remote network calls.

### Consequences
* **Positive:** Complete fulfillment of `P6-06` (`F-044`, `T-OCR-02`); full image text capabilities; seamless UX with dedicated copy button and drawer; 100% on-device privacy guarantee; zero self-recapture loops.
* **Negative:** None.

---

## ADR-045: Stale OCR Callback Suppression, Deletion/Clear Race Invariants, and High-Concurrency Dismissal Safety

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In asynchronous clipboard architectures where image OCR inference executes concurrently in background queues, race conditions naturally arise when users delete items, clear history, or dismiss panels while text recognition is in flight (`P6-07`, `F-040`, `F-043`, `F-051`, `F-052`, `T-PREV-02`, `T-SRCH-04`):
1. **Ghost Item Resurrection Risk:**
   - If an item is deleted via UI action (`deleteItem`) or cleared in bulk (`clearUnpinned`, `clearAll`), a late-arriving OCR callback must never resurrect the deleted record in SQLite or the FTS5 search index (`search_fts`).
2. **Resource Wastage:**
   - Continuing heavy Apple Vision neural network computation on the Apple Neural Engine/GPU for items the user has already deleted wastes system resources, battery life, and thermal headroom.
3. **High-Concurrency Dismissal Stability:**
   - Rapid UI navigation, fast panel dismissals, and high-frequency clipboard ingestion (stress tested with 1,000 rapid operations) must operate deterministically with zero deadlocks, zero orphaned records, and clean task draining.

### Decision
1. **Transactional Row-Match Enforcement in RustCore (`RustCore/src/storage/repository.rs`):**
   - `update_ocr_text` executes `UPDATE history_items SET ocr_text = ?1 WHERE id = ?2;` within the connection mutex lock.
   - If the item was deleted prior to callback execution, rows affected is zero (`rows_affected == 0`).
   - The method immediately returns `Ok(false)` without executing any `INSERT`.
   - SQLite triggers (`history_items_au`, `history_items_ai`) never fire for non-matching updates, ensuring `search_fts` and `item_representations` remain completely untouched and clean of ghost records.
2. **Immediate Upstream Cancellation Hooks in Swift UI & ViewModels:**
   - `PanelViewModel.deleteItem(itemId:)` dispatches `await OCRService.shared.cancel(itemId: itemId)` prior to requesting deletion in `CoreClient`.
   - `PanelViewModel.clearUnpinned()`, `PanelViewModel.clearAll()`, `StatusBarCoordinator.clearUnpinned()`, `StatusBarCoordinator.clearAll()`, and `SettingsView` confirm actions immediately invoke `await OCRService.shared.cancelAll()`.
   - Cancelling aborts the in-flight Apple Vision request immediately via hardware-level `request.cancel()` in `RequestBox` and cooperatively stops detached tasks.
3. **Stress Testing 1,000 Rapid Changes + Dismissals (DoD Fulfillment):**
   - Implemented Rust unit test `test_ocr_delete_and_clear_race_protection` in `RustCore/src/storage/search.rs` executing 1,000 interleaved operations verifying zero resurrection, zero orphaned records, and 100% database/index integrity.
   - Implemented Swift integration test suite `tests/ocr_race_protection_tests.swift` (Step 46 in `scripts/test-all.sh`), testing:
     - Immediate deletion during in-flight Vision OCR (verifying zero resurrection in `history_items` and `search_fts`).
     - `clearUnpinned` during multiple concurrent OCR passes.
     - `clearAll` with pinned items during in-flight OCR.
     - 1,000 rapid changes + dismissals executing in < 1 second with 100% post-stress integrity verification and zero leaked tasks (`activeTaskCount == 0`).

### Consequences
* **Positive:** Complete fulfillment of `P6-07` and successful exit of **Phase 6**; mathematically guaranteed zero item resurrection on deleted or cleared items; immediate hardware cancellation saves battery and CPU; 1,000-operation high-concurrency stress test verified in automated test suite.
* **Negative:** None.

---

## ADR-046: Modern SMAppService.mainApp Launch-at-Login, Sound Feedback Integration, and System Clipboard Cleansing

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Phase 7, Task `P7-01` addresses essential general preferences (`F-020`, `F-035`, `F-056`, `F-062`, `F-064`, `T-SET-01`, `T-REL-01`):
1. **Launch at Login:** Legacy macOS launch-at-login approaches (such as `SMLoginItemSetEnabled` or helper app bundles inside `Contents/Library/LoginItems`) are deprecated on macOS 13+ and macOS 15+. Apple introduced `SMAppService.mainApp`, which requires handling specific service statuses: `.enabled`, `.notRegistered`, `.requiresApproval`, and `.notFound` (when running unbundled/in development).
2. **Audio Feedback:** Providing subtle acoustic tactile feedback upon committing clipboard items or copy operations improves accessibility and user confidence. Playback must be non-blocking and safe across headless test environments.
3. **System Clipboard Cleansing:** Power users requiring strict privacy need the ability to wipe the active macOS system clipboard (`NSPasteboard.general`) when clearing history unpinned or all items (`clearSystemClipboard`), ensuring no remnant remains in the OS pasteboard buffer.
4. **Auto-Paste Runtime Synchronization:** The `pasteAutomatically` preference stored in `UserDefaults` must be dynamically and consistently observed by `PasteCoordinator` without hard couplings across modules.

### Decision
1. **LaunchAtLoginService (`Mimra/macOS/LaunchAtLoginService.swift`):**
   - Implemented protocol `LaunchAtLoginProvider` to abstract `SMAppService.mainApp` for deterministic sandbox and unit test verification.
   - Observable `@MainActor` service providing status tracking (`.enabled`, `.notRegistered`, `.requiresApproval`, `.notFound`) and explanatory localized errors (`LaunchAtLoginError`).
   - Surfaces direct links to macOS System Settings Login Items (`SMAppService.openSystemSettingsLoginItems()`) when approval is required.
2. **SoundFeedbackService (`Mimra/macOS/SoundFeedbackService.swift`):**
   - Decoupled sound playback via `SoundPlaying` protocol and native `AppKitSoundPlayer` utilizing standard system sounds (`Pop`, `Tink`, `Purr`, `Blow`).
   - Persists `playSounds` and `soundEffect` in `UserDefaults`.
   - Connected via decoupled closure callback `PasteCoordinator.onAudioFeedback` in `AppDelegate.swift`, preventing unwanted cross-dependencies in unit tests.
3. **System Clipboard Cleansing (`clearSystemClipboard`):**
   - Added conditional `NSPasteboard.general.clearContents()` execution across `StatusBarCoordinator`, `PanelViewModel`, and `StorageSettingsViewModel` when the `clearSystemClipboard` preference toggle is active.
4. **GeneralSettingsTab (`Mimra/UI/Settings/SettingsView.swift`):**
   - Extracted modular `GeneralSettingsTab` presenting launch at login, paste mode, audio feedback, clipboard cleansing, quick switcher cycling, and core engine diagnostics.
5. **Automated Verification:**
   - Implemented `tests/general_settings_tests.swift` (Step 47 in `scripts/test-all.sh`), verifying all 4 launch-at-login state transitions, error handling, sound playback persistence, system clipboard clearing, and paste coordinator synchronization.

### Consequences
* **Positive:** Clean fulfillment of `P7-01` (`F-020`, `F-035`, `F-056`, `F-062`, `F-064`); robust, non-deprecated ServiceManagement launch-at-login; seamless audio feedback; reliable system clipboard purging.
* **Negative:** None.

---

## ADR-047: Appearance Customization, Positioning Modes, Dynamic Sizing, and Display Disconnect Resilience

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Phase 7, Task `P7-02` addresses comprehensive visual preferences and window presentation mechanics (`F-028`, `F-032`, `F-034`, `F-035`, `F-058`, `T-UI-05`, `T-UI-07`, `T-UI-08`, `T-UI-09`, `T-SET-03`):
1. **Window Element Visibility:** Users must have the option to show or hide the search field, header title, and footer toolbar without losing functionality (e.g. typing directly into history continues to search; keyboard navigation and `⌘,` settings remain accessible when footer is hidden).
2. **Flexible Screen Positioning:** Summoning the panel must support diverse multi-monitor and user workflows: Center of Active Screen, At Mouse Cursor, Center of Main Screen, Directly Below Status Bar Icon, or Remembering Last Position.
3. **Display Disconnect Recovery (`T-UI-07`):** When external monitors are unplugged while Mimra is closed or in `.rememberLast` mode, geometric placement must automatically clamp coordinates to the remaining visible display frame (`visibleFrame`), preventing windows from becoming stranded off-screen.
4. **Menu Bar Customization:** Configurable menu bar icon styles (Default clipboard, list clipboard, minimal paperclip, scissors, or completely hidden for hotkey-only users) and live preview snippet of the most recent copied clip.
5. **Theme Switching:** Instant switching between System, Light (`.aqua`), and Dark (`.darkAqua`) without application restart.

### Decision
1. **AppearanceConfiguration (`Mimra/macOS/AppearanceConfiguration.swift`):**
   - Implemented centralized `@MainActor` observable singleton managing `AppearanceTheme`, `PanelPositionMode`, `MenuBarIconStyle`, element toggles (`showSearchField`, `showTitle`, `showFooter`), and dimension constraints (`panelWidth`, `panelHeight`, `previewWidth`).
   - Defined pure geometric function `AppearanceConfiguration.computePanelOrigin(...)` enforcing mathematical boundary clamping within `screenVisibleFrame` across all positioning modes.
   - Live theme application via `NSApp?.appearance` and notification broadcast `MimraAppearanceDidChangeNotification`.
2. **StatusBarCoordinator Live Updates:**
   - Observes `AppearanceConfiguration.didChangeNotification` to instantly reflect icon style and title snippet updates without relaunch.
3. **FloatingPanel & FloatingPanelView Integration:**
   - Panel frame sizing dynamically reflects `panelWidth` and `panelHeight`.
   - `FloatingPanelView` conditionally presents `PanelSearchBar` and `PanelFooterBar`, maintaining 100% keyboard and hotkey discoverability.
   - `PreviewCoordinator.previewWidth` dynamically reads from and synchronizes with `AppearanceConfiguration`.
4. **AppearanceSettingsTab (`Mimra/UI/Settings/SettingsView.swift`):**
   - Modular tab exposing theme picker, window element toggles, positioning picker, menu bar icon choices, width/height sliders, and slideout preview controls.
5. **Automated Verification:**
   - Implemented `tests/appearance_settings_tests.swift` (Step 48 in `scripts/test-all.sh`), verifying theme switching, pure geometric placement calculation, screen edge clamping, display disconnect recovery, menu bar styles, element visibility, and sizing bounds.

### Consequences
* **Positive:** Complete fulfillment of `P7-02` (`F-028`, `F-032`, `F-034`, `F-035`, `F-058`); live observability without app restart; robust multi-monitor disconnect safety; clean SwiftUI architecture.
* **Negative:** None.

---

## ADR-048: Search and Storage Settings Synchronization, Match Highlighting, and Format Allowlisting

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Phase 7, Task `P7-03` requires end-to-end synchronization between user preferences and the core search/storage engines (`F-013`, `F-049`, `F-050`, `F-055`, `T-SRCH-02`, `T-SRCH-03`, `T-HIST-05`):
1. **Search Modes & Engine Synchronization (`F-049`, `T-SRCH-02`):** Users can configure default search behavior (Fuzzy, Exact Substring, or Rust bounded Regex) in Settings. When settings change, `PanelViewModel` must immediately reload its algorithm, pin arrangement (`.top`, `.bottom`, `.inline`), history sort mode (`.recency`, `.copyCount`, `.firstCopied`), and relevance ranking toggle without requiring application restart.
2. **Search Highlights (`F-050`, `T-SRCH-03`):** Match highlight styling across title and snippet must support selectable styles (`bold`, `underline`, `italic`, `boldUnderline`, `accent`, `none`) with instant visual updates via `@AppStorage("searchHighlightStyle")`.
3. **Format Allowlisting (`F-013`, `T-TYPE-05`):** Format enablement toggles (Plain Text, Rich Text HTML/RTF, Images, File references) in `StorageSettingsTab` govern `ClipboardTypeConfiguration`. When a category is disabled, raw clipboard representations of that category are rejected in Swift before reaching memory or SQLite disk storage.
4. **Retention Policies & Storage Metrics (`F-055`, `T-HIST-05`):** History limit pickers (Item count, age in days, storage budget in bytes) convert deterministically to `RetentionPolicyDto`, enforced transactionally by RustCore's retention sweeper with immediate WAL checkpointing, database vacuuming, and stats refreshes.
5. **OCR Ingestion Toggle (`F-051`, `T-SRCH-04`):** Background Apple Vision text recognition on captured images can be toggled via `includeOcrInSearch`, avoiding unnecessary background CPU/GPU processing when disabled.

### Decision
1. **SearchSettingsTab (`Mimra/UI/Settings/SettingsView.swift`):**
   - Implemented modular `SearchSettingsTab` integrated into `SettingsView` with tabs for General, Appearance, Search & Sorting, Storage, and Privacy.
   - Exposes pickers for search algorithm (`fuzzy`, `exact`, `regex`), OCR index inclusion toggle, match highlight style picker, pin placement picker, history sort mode picker, and relevance ranking toggle.
2. **PanelViewModel Synchronization (`PanelViewModel.reloadSearchSettings()`):**
   - Synchronizes `searchMode`, `pinArrangement`, `sortMode`, and `searchByRelevance` from `UserDefaults.standard`.
   - Invoked on initialization and when the history panel opens (`FloatingPanelView.task`), guaranteeing that preferences edited in Settings immediately dictate history panel search and layout behavior.
3. **StorageSettingsViewModel & Type Configuration:**
   - Standardized `currentPolicyDto` translation mapping integer selections to `RetentionPolicyDto` (treating 0 as unbounded/unlimited).
   - Wired `ClipboardTypeConfiguration` allowlist checks directly into `ClipboardMonitor.swift`.
   - Wired `includeOcrInSearch` toggle into `ClipboardMonitor.swift` image ingestion pipeline to guard background Vision OCR execution.
4. **Automated Verification:**
   - Created `tests/search_storage_settings_tests.swift` (added as Step 49 in `scripts/test-all.sh`), verifying highlight styles, `PanelViewModel.reloadSearchSettings()` mapping, search mode execution across fuzzy, exact, and regex queries, retention policy DTO conversion, format allowlisting, and unpinned history clearing.

### Consequences
* **Positive:** Complete fulfillment of `P7-03` (`F-013`, `F-049`, `F-050`, `F-055`); settings precisely govern core search and storage operations; verified with dedicated automated tests.
* **Negative:** None.

---

## ADR-049: Privacy Management, Application Exclusions Outside /Applications, Custom Ignored UTIs, and Pause Controls

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Phase 7, Task `P7-04` addresses comprehensive user privacy preferences, application deny lists, custom pasteboard type exclusions, and capture pausing (`F-009`, `F-010`, `F-057`, `T-PRIV-02`, `T-PRIV-03`, `T-SET-02`):
1. **Application Exclusions Outside `/Applications` (`F-010`, `T-PRIV-03`):** In addition to selecting standard applications installed in `/Applications` or currently running, users need the ability to browse and exclude any executable bundle or binary located anywhere on disk (e.g. `~/Downloads`, `~/Applications`, `/opt`, `/usr/local`). When a copied item originates from an excluded application (checked via bundle ID or binary file path), the pasteboard event must be dropped in Swift before inspecting or reading any payload bytes into memory or disk.
2. **Custom Ignored UTIs (`F-009`, `T-PRIV-02`):** Users can define arbitrary pasteboard format identifiers (e.g. `com.company.secret` or wildcard patterns like `org.custom.*`) to ignore. The filter must evaluate candidate types case-insensitively and match prefix wildcards before reading payload data.
3. **Capture State Controls (`F-026`, `F-057`):** Instant pausing of clipboard recording, single-shot "Ignore Next Copy" with automatic disarming after one drop, and remote Universal Clipboard rejection (`com.apple.is-remote-clipboard`).
4. **Validation & Confirmation (`F-057`, `T-SET-02`):** Adding UTIs must validate syntax and reject duplicates; removing applications or UTIs from the deny list requires distinct alert dialog confirmations to prevent accidental capture resumption.

### Decision
1. **IgnoredApplication Model (`Mimra/macOS/PrivacyFilter.swift`):**
   - Defined `IgnoredApplication` conforming to `Codable`, `Identifiable`, and `Sendable`, storing `bundleId`, `name`, and optional `path` to track binaries outside `/Applications`.
2. **PrivacyConfiguration (`Mimra/macOS/PrivacyConfiguration.swift`):**
   - `@MainActor` observable singleton managing `isPaused`, `ignoreNextCopy`, `ignoreUniversalClipboard`, `ignoredApplications`, and `customIgnoredUtis`.
   - Persists state to `UserDefaults` and notifies listeners via `MimraPrivacyConfigurationDidChange`.
   - Includes `browseAndAddApplication()` leveraging `NSOpenPanel` restricted to `.application` and `.unixExecutable` to pick external binaries.
   - Enforces UTI syntax validation and duplicate detection with typed `PrivacyConfigurationError`.
3. **PrivacyFilter Pre-Read Filtering:**
   - Evaluates `sourceBundleId` and `sourcePath` against `_ignoredAppBundleIds` and `_ignoredAppPaths`.
   - Implemented wildcard pattern matching `matchesCustomIgnoredUti(_:)` for custom types.
   - Evaluates metadata only; byte contents are never read when an exclusion matches.
4. **PrivacySettingsTab (`Mimra/UI/Settings/SettingsView.swift`):**
   - Replaced placeholder Privacy tab with a dedicated management interface displaying running app picker, file browser, custom UTI input with inline error feedback, removal confirmation alerts, and documented list of built-in sensitive markers.
5. **Automated Verification:**
   - Implemented `tests/privacy_settings_tests.swift` (Step 50 in `scripts/test-all.sh`), verifying UTI validation, exact/wildcard UTI rejection, bundle and path-based application exclusions, pause state, single-shot ignore-next disarming, and persistence across re-instantiation.

### Consequences
* **Positive:** Complete fulfillment of `P7-04` (`F-009`, `F-010`, `F-057`); pre-read privacy guarantees preserved; non-`/Applications` binary exclusions fully supported; confirmed with automated test runner.
* **Negative:** None.

---

## ADR-050: Hotkey Configuration, Collision Prevention, Reserved Shortcut Guards, and Carbon Re-Registration

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Phase 7, Task `P7-05` addresses configurable global and in-panel shortcuts (`F-023`, `T-KEY-02`):
1. **Shortcut Customization:** Users can view, record, change, and reset shortcuts for key workflows:
   - `summon`: Global shortcut to summon Mimra history panel (default: `⇧⌘C`).
   - `pin`: In-panel shortcut to pin/unpin selected clip (default: `⌥P`).
   - `delete`: In-panel shortcut to delete selected clip (default: `⌥Delete`).
   - `preview`: In-panel shortcut to toggle slideout preview (default: `⌃Space`).
   - `plainPaste`: In-panel shortcut to paste stripped plain text (default: `⇧Return`).
2. **Zero Global Keystroke Sniffing:** Strictly adhering to ADR-008 and Definition of Done, global summon uses native Carbon `RegisterEventHotKey`. In-panel shortcuts operate strictly locally inside the active history window via local monitors (`NSEvent.addLocalMonitorForEvents`). No global `CGEventTap` or accessibility keylogger permissions are ever requested or installed.
3. **Collision Detection & Reserved System Shortcut Protection (`T-KEY-02`):**
   - Global summon requires at least one modifier key (⌘, ⌥, ⌃, or ⇧) to prevent trapping regular typing.
   - Rejects macOS reserved shortcuts (⌘Q, ⌘W, ⌘H, ⌘,, ⌘C, ⌘V, ⌘X, ⌘Z, ⌘A).
   - Prevents assignment collisions across actions (e.g. attempting to assign summon to the same shortcut as pin).
4. **Dynamic Re-Registration:** When the global summon shortcut changes in Settings, the old Carbon hotkey is unregistered and the new hotkey is registered immediately without requiring an app restart.

### Decision
1. **KeyShortcut & HotkeyConfiguration (`Mimra/macOS/HotkeyConfiguration.swift`):**
   - Implemented `KeyShortcut` value type tracking `keyCode`, `modifierFlags`, Carbon modifier bitmasks, and display strings (`⇧⌘C`, `⌥P`, `⌥Delete`, `⌃Space`, `⇧Return`).
   - Implemented `HotkeyConfiguration` observable singleton persisting shortcuts in `UserDefaults` and broadcasting `MimraHotkeyConfigurationDidChange`.
   - Built collision engine validating candidates against reserved system combinations and active assignments before committing.
2. **HotkeyManager Registration Bridge (`Mimra/macOS/HotkeyManager.swift`):**
   - Added `registerSummonShortcut(_:action:)` translating `KeyShortcut` directly into Carbon `RegisterEventHotKey`.
   - `AppDelegate` observes `HotkeyConfiguration.didChangeNotification` on `@MainActor` to update `PanelCoordinator.summonKeyCode` and re-register the global Carbon hotkey.
3. **PanelCoordinator Integration (`Mimra/UI/Panel/FloatingPanel.swift`):**
   - Dynamic checking in `handlePanelKeyDown` matches against `HotkeyConfiguration.shared.pinShortcut`, `deleteShortcut`, `previewShortcut`, and `plainPasteShortcut` with backward-compatible defaults.
4. **HotkeysSettingsTab (`Mimra/UI/Settings/SettingsView.swift`):**
   - Interactive settings tab displaying current badges, recording state with Escape cancellation, per-item reset, and global "Restore All Default Shortcuts".
5. **Automated Verification:**
   - Implemented `tests/hotkey_settings_tests.swift` (Step 51 in `scripts/test-all.sh`), verifying default shortcut representations, missing modifiers rejection, reserved shortcut rejection, collision detection, dynamic Carbon registration, and persistence across re-instantiation.

### Consequences
* **Positive:** Complete fulfillment of `P7-05` (`F-023`, `T-KEY-02`); robust collision safeguards; zero keylogger permissions; verified with dedicated automated tests and native Xcode build.
* **Negative:** None.

---

## ADR-051: Internationalization, String Catalogs, RTL Layout Direction, and CJK IME Composition Delegation

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Phase 7, Task `P7-06` addresses comprehensive internationalization, keyboard layout adaptations, and CJK input method editor (IME) composition safety (`F-033`, `F-059`, `T-I18N-01`, `T-I18N-02`):
1. **Multi-Language Support & String Catalogs (`F-059`, `T-I18N-02`):**
   - Provide complete translations for initial launch languages: English (`en`), Japanese (`ja`), German (`de`), Turkish (`tr`), and Arabic (`ar`).
   - Use Apple's modern `.xcstrings` String Catalog JSON format (`Mimra/Resources/Localizable.xcstrings`).
   - Support dynamic in-app language switching and layout adaptation.
2. **Right-to-Left (RTL) Layout Direction (`F-059`):**
   - Correctly identify RTL languages (Arabic) and adjust UI layout directions and leading/trailing alignment accordingly.
   - Ensure German and Arabic expansion (>30-50% longer strings than English) renders cleanly without truncation or clipping.
3. **Japanese / CJK IME Marked Text Safety (`F-033`, `T-I18N-01`):**
   - When typing Japanese (Kanji/Hiragana/Katakana), Chinese (Pinyin), or Korean (Hangul) into the search bar, pressing `Return` converts/commits candidate text, and `Space` steps through candidates.
   - If the window intercepts `Return` as "commit item selection and paste" or `Escape` as "close panel" during marked text composition, IME input is broken and characters are prematurely committed or discarded.
   - AppKit's `NSTextInputClient.hasMarkedText()` must be checked. If active, `handlePanelKeyDown(event:)` must immediately return `false` to delegate the event directly to the input method.
4. **Alternative Keyboard Layouts: Dvorak & French AZERTY (`F-033`, `T-I18N-01`):**
   - On French AZERTY keyboards, numbers 1-9 on the top row require holding the Shift key or using physical key positions. Virtual keycodes (18-26, 83-92) must reliably route to quick-pick numbers 1-9 without layout confusion.
   - Provide `KeyCodeHelper` mapping virtual keycodes to logical characters across QWERTY, Dvorak, and AZERTY.

### Decision
1. **LocalizationService & Catalog (`Mimra/macOS/LocalizationService.swift`):**
   - Implemented `LocalizationService` managing active language (`AppLanguage`: `english`, `japanese`, `german`, `turkish`, `arabic`), RTL detection (`isRTL`), and lookup with English fallback.
   - Created Apple String Catalog `Mimra/Resources/Localizable.xcstrings` covering panel empty states, action buttons, settings tabs, and options.
   - Added Language Picker to `GeneralSettingsTab` in `SettingsView.swift`.
2. **IME Composition Guard in `FloatingPanel.swift`:**
   - Added `isImeComposingOverride` hook and `isImeComposing` property checking `(panel?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true`.
   - At the entry of `handlePanelKeyDown(event:)`, when `isImeComposing` is true, immediately return `false`.
3. **Layout-Independent Quick-Pick Numbers (`FloatingPanel.swift`):**
   - `PanelCoordinator.quickPickNumber(for:)` maps hardware virtual keycodes (18..25, 83..92) directly to numbers 1..9, preserving AZERTY and Dvorak compatibility.
4. **Automated Verification:**
   - Implemented `tests/localization_ime_tests.swift` (Step 52 in `scripts/test-all.sh`), verifying 5-language catalog lookup, RTL flag detection, layout expansion, CJK IME marked text delegation, Dvorak/AZERTY translations, and persistence across relaunch.

### Consequences
* **Positive:** Complete fulfillment of `P7-06` (`F-033`, `F-059`, `T-I18N-01`, `T-I18N-02`); IME composition completely protected from panel interception; full support for Dvorak, AZERTY, and RTL languages; 100% verified with automated tests and native Xcode build.
* **Negative:** None.

---

## ADR-052: VoiceOver Accessibility Semantics, Action Rotors, and Keyboard Alternatives for Pin Drag-and-Drop

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Phase 7, Task `P7-07` addresses VoiceOver accessibility, item metadata announcements, action rotor shortcuts, and keyboard accessibility alternatives (`F-060`, `T-A11Y-01`):
1. **VoiceOver Item Semantics (`F-060`, `T-A11Y-01`):**
   - Individual clipboard items comprise multiple visual elements (thumbnail, icon, text labels, color swatches, badges, and shortcut indicators). Without explicit combining, screen readers announce disconnected, fragmented subviews.
   - Rows must be declared as a single unified element (`.accessibilityElement(children: .combine)`).
   - The primary accessibility label must coherently describe title, content kind (Text, Formatted text, Image, File, Color `#HEX`, Web link `domain`), and source application (`from AppName`).
   - The status value must announce pinned status, custom pin shortcut (`Option+X`), multi-copy count (`copied 3 times`), vanished file warnings (`missing on disk`), and quick-pick index (`Quick-pick Command+1`).
   - VoiceOver hints must clearly explain keyboard controls (`Return to paste, Shift-Return for plain text, Option-P to pin/unpin, Option-Delete to delete, Option-Command-Up/Down to reorder`).
2. **Custom Accessibility Action Rotors:**
   - Screen reader users rely on VoiceOver actions to interact with list rows without moving focus.
   - Actions required: "Paste", "Copy", "Paste as Plain Text", "Pin / Unpin Item", "Edit Pin Content", "Move Pin Up", "Move Pin Down", "Delete Item".
3. **Keyboard Drag-and-Drop Alternative for Pinned Items (`F-046`, `F-060`):**
   - VoiceOver users cannot drag and drop pinned items using a mouse.
   - Full keyboard shortcuts (`⌥⌘↑` to move pin up, `⌥⌘↓` to move pin down) and programmatic rotor actions must provide a 100% functional alternative to mouse dragging.
4. **SwiftUI Type Checker Optimization:**
   - Chaining 10+ `.accessibilityAction` modifiers directly to complex view hierarchies triggers Swift compiler type-checking timeouts.
   - Encapsulating accessibility properties in an isolated `RowAccessibilityModifier` keeps view builder expression complexity linear.

### Decision
1. **Unified Accessibility Semantics (`PanelItemRow` in `Mimra/UI/Panel/FloatingPanelView.swift`):**
   - Implemented `accessibilityDescription`, `accessibilityStatusValue`, and `accessibilityRowHint` covering plain text, images, files, hex colors, and URLs.
   - Encapsulated rotor actions and accessibility traits in `RowAccessibilityModifier`.
2. **Keyboard Pin Reordering Support:**
   - `PanelCoordinator` catches `⌥⌘↑` (key code 126 with Option and Command) and `⌥⌘↓` (key code 125 with Option and Command), calling `viewModel.moveSelectedPinUp()` and `moveSelectedPinDown()`.
   - Wired `accessibilityAction(named: "Move Pin Up")` and `accessibilityAction(named: "Move Pin Down")` to `viewModel.movePinUp(item:)` and `movePinDown(item:)`.
3. **Controls and Preview Accessibility:**
   - Added descriptive accessibility labels to Search Bar text field and clear button.
   - Added accessibility labels to Preview close button, monospace toggle, quick copy image/text, and OCR text copy buttons.
   - Added accessibility labels to Pin Editor text view and Save/Cancel buttons.
4. **Automated Verification:**
   - Implemented `tests/voiceover_accessibility_tests.swift` (Step 53 in `scripts/test-all.sh`), verifying label generation across all content kinds, status values, hints, rotor actions, and keyboard pin reordering.

### Consequences
* **Positive:** Complete fulfillment of `P7-07` (`F-060`, `T-A11Y-01`); complete copy/paste lifecycle available via VoiceOver; fully accessible drag-and-drop alternatives for pinned items; verified with automated tests and native Xcode build.
* **Negative:** None.

---

## ADR-053: Educational Onboarding, Accessibility Consent, and Copy-Only Fallback Mode Architecture

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Phase 7, Task `P7-08` addresses first-launch educational onboarding, permissions transparency, and reliable copy-only fallback mode (`F-061`, `T-PASTE-03`):
1. **User Education & Privacy Transparency:**
   - Users need clear explanations regarding what continuous clipboard history is, where data is stored (100% locally in SQLite on-device with zero telemetry or network calls), and how sensitive items are safeguarded (automatic pre-read discarding of 1Password, Bitwarden, Keychain, and concealed markers).
2. **Accessibility Permission Clarity & Non-Coercive Fallback (`F-061`):**
   - macOS Accessibility permission is required *only* to simulate ⌘V into the previously active application.
   - If Accessibility permission is denied, revoked, or withheld by user choice, Mimra must **not** refuse to launch, crash, or present blocking modal traps.
   - Mimra must seamlessly operate in **Copy-Only Mode**: selecting an item copies it faithfully to `NSPasteboard`, allowing the user to paste manually with ⌘V.
3. **Dynamic Permission Transitions (`T-PASTE-03`):**
   - The application must gracefully handle runtime permission state transitions:
     - Starting in denied/revoked state: pastes degrade to `.copiedOnly(reason: .accessibilityPermissionDenied)`.
     - Granted in macOS System Settings: transitions live to auto-pasting with synthetic keystroke injection.
     - Revoked in macOS System Settings: degrades immediately and safely back to copy-only mode with zero crashes.
4. **Onboarding Access in Settings:**
   - The educational onboarding guide must be accessible at any time from General Settings, not just upon initial launch.

### Decision
1. **OnboardingService (`Mimra/macOS/OnboardingService.swift`):**
   - Implemented `OnboardingService` with `hasCompletedOnboarding` persistence in `UserDefaults`.
   - Structured 4 educational topics: `continuousHistory`, `accessibilityAndPaste`, `privacyAndExclusions`, and `shortcutsAndUsage`.
2. **OnboardingView & Window Controller (`Mimra/UI/Onboarding/OnboardingView.swift`):**
   - Built modern AppKit/SwiftUI onboarding window controller with step indicator progress, SF Symbols, interactive permission status badge with inline grant action, skip/dismiss controls, and full VoiceOver accessibility.
   - Added "Welcome & Privacy Guide..." action in `GeneralSettingsTab`.
   - In `AppDelegate.swift`, conditionally presented on first launch when `shouldShowOnboarding` is true.
3. **Copy-Only Degradation Engine (`PasteCoordinator.swift`):**
   - When `accessibilityChecker()` returns false, writes item representation payloads to `NSPasteboard` and returns `.copiedOnly(reason: .accessibilityPermissionDenied)`.
   - Verified that no synthetic keystroke is posted and system clipboard receives the copied data.
4. **Automated Verification:**
   - Implemented `tests/onboarding_permissions_tests.swift` (Step 54 in `scripts/test-all.sh`), verifying onboarding state machine, topic contents, persistence, usable copy-only fallback with denied permission, and dynamic grant/revoke state transitions.

### Consequences
* **Positive:** Complete fulfillment of `P7-08` (`F-061`, `T-PASTE-03`); non-coercive privacy-first onboarding; copy-only mode independently usable; verified with automated tests and native Xcode build.
* **Negative:** None.

---

## ADR-054: Appearance Accessibility, Full-Screen Auxiliary Clamping, and VoiceOver Focus Handover

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In Phase 7, Task `P7-09` addresses accessibility appearance features, high-contrast states, Reduce Motion, VoiceOver focus restoration, and full-screen auxiliary space clamping (`F-029`, `F-034`, `T-UI-06`, `T-UI-08`):
1. **Reduce Motion Compliance (`F-029`):**
   - Respect user preference `accessibilityReduceMotion` across all animations and transitions (e.g. spring progress dots in Onboarding and slideout previews).
2. **High-Contrast Selection & Differentiate Without Color (`F-034`):**
   - When macOS high contrast or differentiate without color settings are active, item selection must not rely purely on subtle accent color changes.
   - Distinct solid border outlines (`stroke(Color.primary, lineWidth: 2)`) and high-contrast text tags must be provided.
3. **VoiceOver & System Focus Restoration (`F-029`, `T-UI-06`):**
   - When the panel is dismissed via Escape, mouse click outside, or item commit, the previously frontmost application must be reactivated (`targetApp?.activate()`). This guarantees VoiceOver focus returns to the user's active document or text editor rather than leaving the screen reader focus stranded.
4. **Full-Screen Space Overlay & Boundary Clamping (`F-029`, `T-UI-06`):**
   - When summoned over a full-screen application or space:
     - Window must declare collection behaviors `.canJoinAllSpaces` and `.fullScreenAuxiliary` with window level `.floating` to float above document overlays without triggering disruptive space transitions.
     - `computePanelOrigin` must clamp coordinates strictly within `screen.visibleFrame` (preventing panel from extending offscreen or obscuring autohiding menu bar or dock regions).
     - If the user had previously remembered a panel position on a large external display that has since been disconnected, coordinates must be clamped safely back inside the visible bounds of the primary screen.

### Decision
1. **Accessibility Environment Observers (`FloatingPanelView.swift` & `OnboardingView.swift`):**
   - Integrated `@Environment(\.accessibilityReduceMotion)` to eliminate spring animations when Reduce Motion is enabled.
   - Integrated `@Environment(\.colorSchemeContrast)` and `@Environment(\.accessibilityDifferentiateWithoutColor)` to render high-contrast 2pt solid stroke outlines on selected items.
2. **Focus Restoration Engine (`FloatingPanel.swift`):**
   - In `FloatingPanel.hide()`, reactivates `targetApp` via `target.activate()`, ensuring clean focus restoration for VoiceOver and keyboard users.
3. **Multi-Monitor and Full-Screen Boundary Clamping (`AppearanceConfiguration.computePanelOrigin`):**
   - Clamps `x` to `[visibleFrame.minX, visibleFrame.maxX - width]` and `y` to `[visibleFrame.minY, visibleFrame.maxY - height]`.
4. **Automated Verification:**
   - Implemented `tests/appearance_accessibility_tests.swift` (Step 55 in `scripts/test-all.sh`), verifying `.canJoinAllSpaces` and `.fullScreenAuxiliary` collection behaviors, `.floating` window level, extreme boundary clamping (top-right, bottom-left, stranded disconnected monitors), focus restoration handover, and native appearance mode switching.

### Consequences
* **Positive:** Complete fulfillment of `P7-09` (`F-029`, `F-034`, `T-UI-06`, `T-UI-08`); Gate G5 exit criteria satisfied; verified with automated test suites and native Xcode build.
* **Negative:** None.

---

## ADR-055: Release Hardening, Fuzzing, Performance Budgets, Resilient Recovery, and Release Parity Signoff

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
Phase 8 represents the final release-hardening stage (Gate G6) before general availability, executing verification across reliability, performance, privacy, layout, database recovery, and ecosystem compatibility:
1. **P8-01 (Leak & Retention Stress):**
   - High-throughput copy cycle churn (3,000 synthetic copy cycles via `CoreClient`) must not leak resident memory (`mach_task_basic_info` RSS growth must stay below 30 MB budget).
   - Ingestion churn must strictly respect pinned item invariants and foreign-key referential integrity (zero orphaned representations).
2. **P8-02 (Paste Regression Lab):**
   - Empirical paste behavior across diverse macOS targets (Finder, Safari, Chrome, Notes, Pages, Terminal, VS Code/Xcode, Spotlight, Remote Desktop, Full-screen spaces) across 12 operational scenarios.
   - Graceful fallback for non-pasteable targets (password fields, secure event input, accessibility permission denial, dynamic app termination, Space mismatch).
3. **P8-03 (Layout Regression Lab):**
   - Multi-monitor coordinate clamping, dynamic external display disconnection recovery (`NSApplication.didChangeScreenParametersNotification`), Stage Manager 80pt left gutter reservation, safe preview bounds clamping with automatic side-flipping (right to left), and mouse event transparency (`ignoresMouseEvents = true` when hidden).
4. **P8-04 (Privacy & Security Audit):**
   - Complete zero-network surface verification (no `URLSession`, `Network.framework`, `reqwest`, `curl`, sockets).
   - Unified logging audit ensuring all log statements format public metadata only without clipboard contents.
   - Strict adherence to 14 password manager concealment markers, custom excluded bundle IDs, Universal Clipboard exclusion opt-out, and pause state bypass.
5. **P8-05 (FFI Fuzz & Property Tests):**
   - Stressing the UniFFI boundary with pathological payloads: empty/whitespace UTIs, giant 10MB payloads, non-UTF-8 binary blobs, 10,000-character UTI identifiers, embedded null bytes, regex ReDoS patterns, SQL injection sequences, and malformed UUIDs without panics or memory corruption.
6. **P8-06 (Performance Benchmarks):**
   - Nonfunctional performance budgets from §10 measured on Apple Silicon: ingestion latency (p95 < 100ms), FTS corpus search (p95 < 50ms), panel summon to first render (p95 < 120ms), cached thumbnail retrieval (< 5ms), and idle pasteboard polling CPU usage (< 0.5%).
7. **P8-07 (Database Recovery Lab):**
   - Database corruption resilience, automatic quarantine to timestamped `.bak` files, salvage of uncorrupted records, clean WAL checkpointing on restart, and rapid startup time (< 100ms) with zero blocking maintenance routines.
8. **P8-08 (Parity Signoff):**
   - Verification of all 64 feature IDs (`F-001` through `F-064`) against behavioral specifications, complete sign-off of Gate G6, and comprehensive test suite automation.

### Decision
1. **Dependency Profile Optimization (`RustCore/Cargo.toml`):**
   - Configured `[profile.dev.package."*"] opt-level = 3` so bundled C/Rust libraries (`libsqlite3-sys`, `rusqlite`, `blake3`, `regex`) execute with full vectorization and release speed during development and test runs while keeping Core development incremental builds fast.
2. **Automatic Screen Parameter Observation (`FloatingPanel.swift`):**
   - Registered `NSApplication.didChangeScreenParametersNotification` in `PanelCoordinator.init` alongside `PreviewCoordinator` to auto-reposition panel and preview views when external monitors connect or disconnect.
3. **Hardened Error Trapping & Property Fuzzing (`fuzz_tests.rs` & `ffi_fuzz_property_tests.swift`):**
   - Enforced linear-time regex matching and strongly typed `CoreError` mapping across UniFFI C-ABI, converting invalid syntax or boundary violations into actionable Swift error enums without crashing.
4. **Threat Model & Paste Matrix Specifications:**
   - Authored `docs/THREAT_MODEL.md` and `docs/PASTE_REGRESSION_MATRIX.md` to formalize privacy boundaries, attack vectors, mitigations, and cross-application paste semantics.
5. **Automated Verification Suites (Steps 56-62 in `scripts/test-all.sh`):**
   - Step 56: `tests/leak_retention_stress_tests.swift` (3,000 copy cycles, memory delta ~2 MB vs 30 MB budget, pin retention).
   - Step 57: `tests/paste_regression_lab_tests.swift` (10 apps, 12 scenarios, target verification, fallback modes).
   - Step 58: `tests/layout_regression_tests.swift` (Display disconnection, Stage Manager, side flip, mouse event transparency).
   - Step 59: `tests/privacy_audit_tests.swift` (14 password markers, excluded apps, universal clipboard opt-out, zero network).
   - Step 60: `tests/ffi_fuzz_property_tests.swift` (Pathological payloads, SQLi, ReDoS, giant buffers, UniFFI stability).
   - Step 61: `tests/performance_benchmarks.swift` (Ingest p95: 0.44ms, Search p95: 14.40ms, Summon p95: 3.36ms, Idle poll: 0.0006ms).
   - Step 62: `tests/database_recovery_lab_tests.swift` (Startup: 1.62ms, quarantine of corrupt databases, WAL checkpointing, atomic transactions).

### Consequences
* **Positive:** Complete fulfillment of Phase 8 (`P8-01` through `P8-08`), meeting all Gate G6 release criteria. Zero memory leaks, ultra-low latency, full crash and corruption resilience, 100% verified feature parity, and robust test suite passing in CI and native builds.
* **Negative:** None.

---

## ADR-039: Browser Image Classification, Slideout Preview Triggers, Settings Routing, History Item Limits, and Deletion Shortcut Isolation

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
User feedback and runtime inspection identified five specific usability and correctness issues:
1. **Browser Image Ingestion:** When copying an image from a web browser (Brave, Chrome, Safari), browsers provide multiple representations: `public.png`/`public.tiff` (bitmap data), `public.html` (`<img src="...">`), and `public.url`. In `HistoryItem::derive_content_kind`, having both `public.html` (rich text) and an image caused the item to be classified as `ContentKind::Mixed`. Furthermore, `NSAttributedString` HTML parsing produced an Object Replacement Character (`\u{FFFC}`), which `derive_text_fields` set as the item title and snippet. Consequently, the row displayed as completely blank with no thumbnail, no title, and failed to load `ImagePreviewView`.
2. **Preview Toggle (`⌃Space`):** On macOS, `Control + Space` (`⌃Space`) is frequently claimed by system-level Input Source switching ("Select previous input source"), preventing applications from receiving local event monitor key strokes. Additionally, users expect standard macOS Quick Look shortcuts (`Option + Space`, `Command + Y`, and `Space` when search text is empty) to trigger preview.
3. **Settings Button in Footer:** Clicking the gear icon in `PanelFooterBar` invoked `viewModel.onOpenSettings?()`, which called `self?.hide()` but omitted calling `self?.onSettingsRequested?()`. As a result, the settings window never opened from the footer button.
4. **History Item Limit Definition & UI:** Storage retention count existed in `StorageSettingsTab`, but `PanelViewModel` hardcoded `limit: 100` across all query calls, truncating visible items regardless of retention settings. Furthermore, an explicit solid maximum limit was needed with options accessible in Settings.
5. **Item Deletion Shortcut Overreach:** `FloatingPanel.handlePanelKeyDown` accepted both `Option + Backspace` and `Command + Backspace` (keyCode 51 with `.command`). In macOS, `Command + Backspace` is the universal text editing keystroke to delete to the beginning of the line inside a text/search field. Intercepting `Command + Backspace` erroneously deleted history items while typing.

### Decision
1. **Browser Image Classification & Title Derivation (`RustCore` & `Swift`):**
   - In `HistoryItem::derive_content_kind`: When `has_image` is true in a single-item copy, classify as `ContentKind::Image`, recognizing HTML and URL flavors as standard browser helper metadata.
   - In `HistoryItem::derive_text_fields`: Prioritize image metadata derivation (`"{format_name} ({size_str})"`) over helper URLs, while appending the URL to `search_text` for FTS5 index discovery.
   - In `canonicalize_text` and `PasteCoordinator.extractPlainText`: Strip attachment / object replacement characters (`\u{FFFC}`, `\u{FFFD}`) and reject synthesized plain-text representations that contain only replacement characters or whitespace.
   - In `FloatingPanelView.ItemThumbnailView` & `PreviewContainerView`: Support image thumbnails and `ImagePreviewView` whenever `contentKind == "image"` or `availableUtis` contains image formats (`public.png`, `public.tiff`, `public.jpeg`, `public.heic`).
2. **Robust Preview Shortcuts (`FloatingPanel.swift`):**
   - Support `previewShortcut` (`⌃Space`), `⌥Space`, `⌘Y` (macOS Quick Look), and `Space` (when search input is empty).
3. **Settings Button Routing (`FloatingPanel.swift`):**
   - Update `viewModel.onOpenSettings` to invoke `self?.onSettingsRequested?()`, routing directly to `StatusBarCoordinator.openSettings()`.
4. **Solid History Item Limit (`PanelViewModel.swift` & `SettingsView.swift`):**
   - Define a solid upper limit of 2,000 items (`50`, `100`, `200 [Recommended]`, `500`, `1,000`, `2,000 [Maximum Limit]`).
   - Expose the history limit picker in both `GeneralSettingsTab` and `StorageSettingsTab`.
   - Update `PanelViewModel` to use dynamic `historyLimit` (bounded to `[10, 2000]`) instead of hardcoded 100 across all query routines.
5. **Deletion Shortcut Isolation (`FloatingPanel.swift`):**
   - Require `Option + Backspace` (or configured delete shortcut) for item removal.
   - Explicitly disallow `Command + Backspace` (`!event.modifierFlags.contains(.command)`), passing it through to the search field for line-start text deletion.

### Consequences
* **Positive:** All browser-copied images display proper thumbnails, format labels, byte sizes, and full slideout previews; slideout preview opens via multiple standard macOS shortcuts; settings window opens reliably from the history footer; users can configure history size up to a solid 2,000 item limit; `Command + Backspace` safely edits text without accidental item deletion.
* **Negative:** None.

---

## ADR-056: History Window Dimensions, Accessibility Banner Removal, Preview Dynamic Height Adaptation, Vertical Text View Scrolling, and Preview Window Display Modes

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
User feedback requested five adjustments across the history window and slideout preview panel:
1. **Accessibility Warning Banner Removal:** The "Copy-Only Mode Active" banner displayed in the history window when Accessibility permissions were not granted cluttering the clipboard list interface.
2. **History Window Default Height:** Default history window height was 540 pt, which users requested to increase by 40% (to 756 pt) for greater item density and fewer scroll operations during lookup.
3. **Preview Window Height Matching History Window:** The slideout preview window previously used a hardcoded 460 pt height. Users requested that the preview window height always match the history window height (`parent.frame.height`, default 756 pt), ensuring complete visual alignment and maximum preview viewport area.
4. **Vertical Scrolling in Preview Window:** In `NativeTextPreviewView`, the underlying `NSTextView` was initialized with zero frame and without explicit `minSize`/`maxSize` or post-string-assignment `sizeToFit()` invocations. Because `textView.frame.height <= scrollView.contentSize.height`, `NSScrollView` disabled the vertical scroller (`isEnabled: false`), preventing trackpad/mouse vertical scrolling.
5. **Configurable Preview Window Display Modes:** Users required explicit options for preview presentation:
   - **Default Option (6.1):** Preview window hidden by default, toggled via keyboard shortcuts (`⌃Space`, `⌥Space`, `⌘Y`, `Space` when search text is empty).
   - **Option 1 (6.2):** Show preview window immediately alongside the history window.
   - **Option 2 (6.3):** Show preview window with a configurable delay on selection.

### Decision
1. **Accessibility Banner Removal (`FloatingPanelView.swift`):**
   - Removed `CopyOnlyBanner` from `FloatingPanelView.body`. Accessibility onboarding remains properly handled in dedicated onboarding views and settings without cluttering history navigation.
2. **History Window Height Increase (`AppearanceConfiguration.swift`, `FloatingPanelView.swift`, `SettingsView.swift`):**
   - Increased default `panelHeight` by 40% from 540 pt to 756 pt (540 * 1.4 = 756).
   - Updated `FloatingPanelView` ideal frame height to 756 pt and expanded the Settings slider range to 360...1000 pt.
3. **Preview Height Matching History Window (`PreviewCoordinator.swift`, `PreviewPanel.swift`):**
   - Configured `previewHeight` to directly match `parent.frame.height` (or `AppearanceConfiguration.shared.panelHeight`, default 756 pt) upon presentation, layout updates, and parent resizing.
   - Set `panel.maxSize = NSSize(width: 1200, height: parent.frame.height)`.
   - Both windows share identical height, aligning top and bottom flush with each other.
4. **Native Text Preview Vertical Scrolling (`NativeTextPreviewView.swift`, `FloatingPanel.swift`):**
   - Set `textView.minSize = NSSize(width: 0, height: 0)` and `textView.maxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)`.
   - Called `textView.sizeToFit()` upon initialization, text updates, font updates, and container width adjustments.
   - Ensured `scrollView.hasVerticalScroller = true` and `autohidesScrollers = true`.
   - Added keyboard scrolling support via `Option-Up` / `Option-Down` (`previewCoordinator.scrollPreview(by:)`) when the preview window is visible.
5. **Preview Window Display Modes (`PreviewCoordinator.swift`, `SettingsView.swift`):**
   - Introduced `PreviewDisplayMode`: `.manual` (default), `.immediate`, and `.delayed`.
   - Stored in UserDefaults under key `"previewDisplayMode"`, preserving backwards compatibility with `"previewAutoOpenEnabled"`.
   - Integrated `handleParentDidShow(item:parent:)` in `FloatingPanel.show()` to immediately present or schedule delayed preview presentation.
   - Updated Settings UI with a clean `Picker` allowing users to select their preferred mode and configure delay in milliseconds when `.delayed` is selected.

### Consequences
* **Positive:** History window is clean without intrusive banners; default history height displays 40% more items; preview window dynamically fits its content up to the history window height; full interactive vertical scrolling works for long text buffers; users have complete control over preview appearance behavior (manual/immediate/delayed).
* **Negative:** None.

---

## ADR-057: Settings Window Focus Retention and Left-Sidebar Navigation Architecture

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
User feedback and testing identified two critical issues when opening the Settings window from the history window:
1. **Settings Window Buried Under Other App Windows:** When clicking the gear / settings icon in the history window bottom-right footer, `FloatingPanel` dismissed itself by calling `hide()`. `hide()` was designed to reactivate the previously active application (`targetApp.activate()`) so focus would return to e.g. Google Chrome or Xcode after pasting. However, when transitioning to Settings, reactivating the external target app caused macOS WindowServer to immediately bring that external application to the foreground, pushing the newly created Settings window beneath other app windows.
2. **Settings Tab Bar Overflow & Chevrons:** The Settings window previously used a standard AppKit/SwiftUI top `TabView` fixed at 540 pt width with 6 tabs ("General", "Appearance", "Hotkeys", "Search & Sorting", "Storage", "Privacy"). Because 6 tabs exceeded the horizontal toolbar width, AppKit automatically collapsed trailing items into an obscure top-right `>>` chevron disclosure button, hiding navigation items and impairing discoverability.

### Decision
1. **Focus Retention Mechanism (`FloatingPanel.swift`, `StatusBarCoordinator.swift`):**
   - Added `hide(restoringFocus: Bool = true)` to `FloatingPanel`.
   - In `onOpenSettings` and `Command-,`, `FloatingPanel` dismisses with `hide(restoringFocus: false)`, preventing reactivation of the background external app.
   - In `StatusBarCoordinator.openSettings()`, configured:
     - Standard `window.level = .normal` ensuring Settings behaves like a proper macOS preference window, yielding naturally when switching to other apps rather than staying pinned on top of everything.
     - `window.makeKeyAndOrderFront(nil)` and `NSApp.activate(ignoringOtherApps: true)` to guarantee foreground activation upon opening.
     - Window dimensions expanded to `720 × 530 pt`.
     - Added `NSWindowDelegate` with `windowWillClose` to cleanly reset `settingsWindow = nil`.
2. **Left-Sidebar Navigation Redesign (`SettingsView.swift`):**
   - Replaced top `TabView` with a left-rail navigation sidebar and detail pane layout.
   - Introduced `SettingsCategory` enum: `.general`, `.appearance`, `.hotkeys`, `.searchSorting`, `.storage`, `.privacy` with SF Symbols and localized display titles.
   - Sidebar width fixed at 190 pt with standard macOS sidebar vibrancy and active item accent highlighting.
   - Detail pane fixed at 530 pt with vertical scrolling for comprehensive configuration controls.
   - Total window size 720 × 530 pt provides generous padding and completely eliminates tab bar overflow and disclosure chevrons.

### Consequences
* **Positive:** Settings window opens reliably in the foreground upon request without getting buried; behaves as a standard `.normal` level window that yields to background apps when switched away; all 6 navigation categories are immediately visible, labeled, and accessible without hidden chevrons; clean conformant macOS HIG design.
* **Negative:** None.

---

## ADR-058: APFS/HFS+ File Reference URL Resolution, Clean Path Presentation, and Bidirectional Audio Feedback on Copy and Paste

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
1. **File Reference URLs on Pasteboard:** When copying files or directories from macOS Finder, the operating system places Apple APFS/HFS+ File Reference URLs (`file:///.file/id=<vol>.<fileid>/`) onto `NSPasteboard.general` under `public.file-url`. Ingesting these raw payloads without resolving them caused RustCore to extract raw volume/inode IDs (e.g. `id=6571367.327946083`) as item titles and raw URI strings as subtitles, producing unreadable rows and breaking standard POSIX path assumptions.
2. **Path URI Scheme Stripping:** In the Floating Panel list, users expect clean, human-readable POSIX paths (`/Users/...` or `~/...`) rather than `file:///` URI scheme prefixes.
3. **Audio Feedback on Copy and Paste:** General Settings offers "Play sound on copy and paste", but audio feedback was only wired to paste operations in `PasteCoordinator`. Clipboard ingestion in `ClipboardMonitor` was unhooked from sound playback. Furthermore, `AppKitSoundPlayer` did not retain the active `NSSound` instance, risking premature ARC deallocation during asynchronous playback, and lacked explicit fallback to `/System/Library/Sounds/`.

### Decision
1. **File Reference URL Resolution (`ClipboardMonitor.swift`):**
   - Added `resolveFileUrlPayload(data:item:)` to detect and resolve APFS file reference URLs via `(url as NSURL).filePathURL` and `NSFilenamesPboardType`, ensuring only canonical file URLs are dispatched to RustCore.
2. **Clean Path & Title Derivation (`RustCore/src/domain/item.rs`):**
   - In `derive_text_fields()`, clean paths by stripping `file://localhost` and `file://`, percent-decoding into clean POSIX paths.
   - Set single file title to the clean basename and `search_text`/`snippet` to clean POSIX paths (without `file:///`).
   - Added defensive fallback for unresolved `id=` tokens.
3. **Resilient UI Formatting (`FloatingPanelView.swift`):**
   - Implemented `displayTitle` and `displaySnippet` to dynamically format titles and subtitles, stripping legacy `file:///` prefixes and resolving historical `id=` entries.
   - Enhanced `isFileVanished(path:)` to handle both resolved POSIX paths and file URLs.
4. **Bidirectional Audio Feedback (`AppDelegate.swift` & `SoundFeedbackService.swift`):**
   - Connected `clipboardMonitor.onIngest` to `SoundFeedbackService.shared.playFeedbackSound()` so copies trigger audio feedback.
   - Retained `activeSound` in `AppKitSoundPlayer` with NSLock synchronization to prevent ARC deallocation during playback.
   - Added fallback to `/System/Library/Sounds/<name>.aiff` with explicit `volume = 1.0`.

### Consequences
* **Positive:** Clean, human-readable titles and POSIX paths for copied files and folders; historical records display cleanly; audio feedback operates reliably on both copy and paste; no ARC sound clipping.
* **Negative:** None.

























---

## ADR-059: Floating Panel Window Chrome & Traffic Light Removal, and User-Configurable One-Line Compact History Row Architecture

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
1. **Window Buttons & Chrome on Floating Panel:** Mimra's floating clipboard panel uses `.titled` and `.fullSizeContentView` in its `NSPanel` style mask to retain macOS system shadows and edge-resizing support. However, AppKit by default renders standard traffic light buttons (Close, Minimize, Zoom) in the top-left corner, and SwiftUI's `NSHostingView` measures a top safe area inset of ~28pt, causing an awkward dark gap between the top rounded window border and the search bar.
2. **History Item Density:** The original history item row layout renders on two lines (Title + Snippet preview), taking ~50pt of vertical height. Users with larger monitors or heavy copy workloads requested a more compact single-line view to maximize visible item capacity without scrolling.

### Decision
1. **Panel Chrome and Traffic Light Removal (`FloatingPanel.swift` & `PreviewPanel.swift`):**
   - Implemented `hideStandardWindowButtons()` to hide and disable `.closeButton`, `.miniaturizeButton`, and `.zoomButton`.
   - Overrode `standardWindowButton(_:)` to ensure buttons remain hidden on AppKit layout passes.
   - Set `titlebarSeparatorStyle = .none`.
   - Added `.ignoresSafeArea()` to `FloatingPanelView` so that the glass background and search bar extend all the way to the top border with standard 10pt inset padding, matching Spotlight and Raycast.
2. **User-Configurable One-Line Compact History Option (`AppearanceConfiguration.swift`, `SettingsView.swift`, `FloatingPanelView.swift`):**
   - Defined `HistoryRowStyle` (`.standard` = two lines, `.compact` = one line) with key `"historyRowStyle"`, defaulting to `.standard` to preserve current behavior.
   - Added a segmented control picker in **Settings → Appearance → History Item Style**.
   - In `FloatingPanelView.swift`, implemented `compactRowContent` in `PanelItemRow` which renders thumbnail (16x16), single-line title with tail truncation, color/url/status badges, spacer, app icon, and shortcuts on one horizontal line (~28pt height), omitting the snippet.
   - Preserved two-line `standardRowContent` as default.

### Consequences
* **Positive:** Modern borderless floating panel design free of extraneous titlebar chrome and non-functional window buttons; users can choose between rich two-line snippets and high-density single-line rows; updates apply in real time via `@AppStorage`.
* **Negative:** None.

---

## ADR-060: Move History Item to Top on Paste / Selection

* **Status:** Accepted  
* **Date:** 2026-11-04  
* **Deciders:** Mimra Core Engineering  

### Context
In clipboard managers (e.g. Paste), when a user selects an item from history to paste or copy into a target application, that item should be promoted to the top of the history list for rapid repeated re-use.
Previously in Mimra:
1. Replaying an item to `NSPasteboard` recorded a self-write provenance marker to prevent self-recapture feedback loops.
2. Because the self-write was ignored by `ClipboardMonitor` and `PasteCoordinator` did not notify `RustCore`, `last_copied_at_ms` in `history_items` remained unchanged.
3. Therefore, the chosen item remained at its historical index instead of moving to the top.

### Decision
1. **Rust Storage Timestamp & Copy Count Bump (`RustCore/src/storage/repository.rs`):**
   - Implemented `touch_item(conn: &Connection, item_id: &Uuid, timestamp_ms: i64) -> Result<bool, CoreError>`.
   - Atomically updates `last_copied_at_ms = now_ms` and increments `copy_count = copy_count + 1` by UUID primary key.
   - Preserves `first_copied_at_ms`, text content representations, and pinned status.
2. **UniFFI Bridge & Swift Actor Integration (`RustCore/src/lib.rs` & `CoreClient.swift`):**
   - Exposed `touch_item(itemId: String, timestampMs: Option<i64>) -> Result<bool, CoreError>` on `MimraCoreHandle`.
   - Added asynchronous wrapper `touchItem(itemId: String, timestampMs: Int64? = nil)` on actor `CoreClient`.
3. **PasteCoordinator & PanelViewModel Integration (`PasteCoordinator.swift` & `PanelViewModel.swift`):**
   - In `PasteCoordinator.paste(...)`, after writing representations to `NSPasteboard`, `coreClient.touchItem(itemId: itemId)` updates persistent SQLite storage when `moveToTopOnPaste` is enabled.
   - In `PanelViewModel.commitSelection(...)`, `moveItemToTop(itemId: item.id)` optimistically reorders the in-memory items list for instant UI responsiveness.
   - Pinned items maintain their configured `pin_order` when `PinArrangement == .top`, while unpinned items sort to index 0 of the unpinned section.
4. **User-Configurable Preference (`SettingsView.swift`):**
   - Introduced `@AppStorage("moveToTopOnPaste") private var moveToTopOnPaste: Bool = true` in **Settings → General → Paste Behavior & Permissions**.
   - Defaults to `true` matching standard macOS clipboard manager behavior, while allowing users to disable automatic reordering if desired.

### Consequences
* **Positive:** Choosing an item moves it immediately to the top of history in both the UI and SQLite; rapid re-use workflow is fully supported; pinned items preserve their explicit manual ordering; fully configurable with a toggle in General Settings.
* **Negative:** None.

---

## ADR-061: Deep Clipboard Content Search & Contextual Excerpt Highlighting

* **Status:** Accepted  
* **Date:** 2026-11-05  
* **Deciders:** Mimra Core Engineering  

### Context
When users copied structured multi-line text (such as JSON payloads, source code, server logs, or notes) and searched for a keyword or regex pattern situated beyond the first line or first few lines, neither **Mixed / Fuzzy** nor **Regular Expression** modes could locate the item.

Investigation revealed:
1. SQLite FTS5 correctly indexed the entire content (`history_items.search_text`).
2. However, `search_history_page_with_options` in `RustCore/src/storage/search.rs` immediately truncated `search_text` to a 160-character preview `snippet` upon database retrieval and dropped `search_text`.
3. The secondary in-memory scoring filter (`score_item_with_mode`) evaluated only `title` and that truncated 160-character snippet.
4. Because JSON titles are derived as the first line (e.g. `{` or `[`), and the target keyword was located past character 160, `score_item_with_mode` returned `None`, causing `search.rs` to drop the matching item entirely.

### Decision
1. **Retain Full `search_text` in Candidate Pre-Filtering (`RawCandidate`):**
   - Maintained full `search_text` in `RawCandidate` across FTS5 and recent item queries.
2. **Bounded Content Match Locating (`find_content_match_offset`):**
   - Implemented bounded byte scanning capped at `MAX_CONTENT_SCAN_BYTES = 64 * 1024` (64 KB) per item to protect CPU and memory.
   - For `Exact`: case-insensitive substring search.
   - For `Regex`: bounded linear DFA scan (`re.find`).
   - For `Fuzzy`: literal substring scan, token-delimited FTS token matching, and short prefix subsequence matching.
3. **Contextual Excerpt Window Extraction (`extract_excerpt_around_byte`):**
   - Extracted a 160-character context excerpt window centered around the match with 35 characters of prefix context, preserving Unicode scalar character boundaries without truncation or panic risk.
4. **Rescoring & UTF-16 Highlight Alignment:**
   - Evaluated `score_item_with_mode` on `title` and the extracted context `excerpt`.
   - Populated `HistoryItemSummary.snippet` with the excerpt window and aligned `snippet_highlights` relative to that excerpt.
   - Handled OCR text similarly with excerpt extraction when matching recognized image text.

### Consequences
* **Positive:** Multi-line JSON, code snippets, logs, and essays can now be searched by any keyword across Mixed/Fuzzy, Exact, and Regex modes; the UI list row displays the contextual excerpt showing the matched term with bold/colored highlight styling; performance remains sub-millisecond (< 5 ms for 10,000 items).
* **Negative:** None. Storage cost is $0 as `search_text` and FTS5 were already stored in SQLite.

---

## ADR-062: End-to-End Runtime Search Pipeline & Debounced Keystroke Integration

* **Status:** Accepted  
* **Date:** 2026-11-05  
* **Deciders:** Mimra Core Engineering  

### Context
Following ADR-061 (which enabled deep content searching and excerpt generation in RustCore), testing the running application by copying an ~8,000-character payload containing the keyword `"arm64"` revealed that searching for `"arm64"` in the UI still returned zero results.

Investigation across the Swift UI layer uncovered an architectural disconnection:
1. `PanelViewModel.performSearch(query:mode:)` existed and handled debouncing counters and `CoreClient` search queries, but was **never called** when typing in the search bar. `searchText.didSet` did not trigger search.
2. `FloatingPanelView.swift` rendered `viewModel.filteredItems`, which ran a legacy in-memory filter: `items.filter { item.title.contains(query) || item.snippet.contains(query) }`.
3. `viewModel.items` was only populated once when opening the window via `loadData()`, where `snippet` was the initial 160-character prefix.
4. Because the user's keystrokes never invoked `performSearch`, SQLite FTS5, RustCore fuzzy matching, regex matching, and deep excerpt generation were completely bypassed in the live app.
5. In addition, when new clipboard items were copied while a search query was active in the panel, `.onReceive(.mimraClipboardDidIngest)` invoked `loadData()`, wiping out search state.

### Decision
1. **Debounced Search Triggering (`PanelViewModel.triggerSearch`):**
   - Wired `searchText.didSet` and `searchMode.didSet` to call `triggerSearch()`.
   - `triggerSearch()` cancels any in-flight search task and debounces by 40ms before calling `performSearch(query: searchText)`.
   - When `searchText` is cleared to empty, `performSearch(query: "")` restores the full recency history only if an active search was previously applied, preventing unnecessary re-queries.
2. **Dynamic List Binding (`PanelViewModel.filteredItems`):**
   - Introduced `@Published public private(set) var lastSearchQuery: String?` to track when `items` contains the results of a Core search for the active query.
   - When `lastSearchQuery?.lowercased() == query`, `filteredItems` returns `items` directly, preserving RustCore's BM25 ranking, deep excerpts, and UTF-16 highlight ranges.
   - When an asynchronous search is still debouncing or executing in the background, a synchronous title/snippet fallback filter is retained for instantaneous typing feedback and unit-test compatibility.
3. **Reactive Re-query on Configuration Changes (`reloadSearchSettings`):**
   - When the user toggles search mode (Fuzzy / Exact / Regex) or sort/pin arrangement, if `!searchText.isEmpty`, `reloadSearchSettings()` invalidates `lastSearchQuery` and triggers an immediate re-search.
4. **Clipboard Ingestion Awareness (`FloatingPanelView.swift`):**
   - Updated `.onReceive(.mimraClipboardDidIngest)` to call `performSearch(query: viewModel.searchText)` when a query is present, ensuring newly copied matching items appear without wiping the search view.

### Consequences
* **Positive:** Complete end-to-end integration between Swift UI search input and the RustCore SQLite FTS5 search engine; searching for keywords in 8,000+ character payloads works seamlessly; smooth 40ms typing debounce prevents SQLite lock churn; full backward compatibility with synchronous unit tests.
* **Negative:** None.

---

## ADR-063: Strict Word-Boundary Fuzzy Subsequence Matching & Elimination of False-Positive Content Matches

* **Status:** Accepted  
* **Date:** 2026-11-05  
* **Deciders:** Mimra Core Engineering  

### Context
Following the activation of the end-to-end runtime search pipeline (ADR-062), users reported that typing queries in the search bar returned unrelated history items—including completely unrelated pinned items appearing at the top of the search list.

Investigation revealed two root causes:
1. **Subsequence Matching on Arbitrary Content Payloads:** `find_content_match_offset` in `search.rs` executed `fuzzy_match` on up to 4,096 bytes of body text. For arbitrary text of several kilobytes (code, JSON, logs), any 3-to-5 character query almost inevitably matches as a scattered non-contiguous character subsequence (e.g. `'a'` on line 1, `'r'` on line 5, `'m'` on line 12). This falsely flagged unrelated items as content matches.
2. **Permissive Word-Jumping in `fuzzy_match`:** In `domain/search.rs`, Phase 2 allowed non-contiguous character jumps to land on arbitrary internal characters in the middle of words (giving positive $+30$ points). Consequently, any title or snippet containing the query letters in order—regardless of word boundaries—was accepted with a positive score. Pinned items received $+1,000,000$ priority boosts, causing unrelated pinned items to rise to the top of search results.

### Decision
1. **Strict Word-Boundary Rule for Non-Contiguous Subsequences (`domain/search.rs`):**
   - In `fuzzy_match` Phase 2, the initial character of an abbreviation MUST start on a word boundary (`tc.is_boundary == true`).
   - For all subsequent characters: if non-contiguous with the previous matched character (i.e. jumping across characters), the matched character MUST start on a word boundary (e.g. `_`, `-`, `/`, whitespace, or camelCase transitions).
   - Contiguous continuation (e.g. `'co'` following `'c'` in `'Code'`) is rewarded with a $+100$ bonus.
   - Any character jump landing on an internal non-boundary character immediately terminates the match and returns `None`.
   - Whitespace in the query is skipped during acronym matching to permit spaced inputs (e.g. `'v s c'` matches `'Visual Studio Code'`).
2. **Elimination of Arbitrary Subsequence Matches in Body Content (`storage/search.rs`):**
   - In `find_content_match_offset`, removed Step 3 (the 4 KB `fuzzy_match` scan).
   - Content matching strictly requires:
     1. Exact substring match of the query string, OR
     2. Exact substring match of the query's whitespace/punctuation-delimited tokens.
   - Text lacking the query terms or tokens as substrings is rejected as a content match.

### Consequences
* **Positive:** Complete elimination of false-positive search results; unrelated pinned items and recent history items no longer pollute search results; genuine word-boundary acronyms (`vsc` for `Visual Studio Code`, `gc` for `git commit`) and exact substrings remain 100% supported; high precision and high recall across all search modes.
* **Negative:** None.

---

## ADR-064: Observable Appearance Sizing Reactivity, Reset Defaults Action, Dynamic Window Resizing, and Settings Quit Action

* **Status:** Accepted  
* **Date:** 2026-11-05  
* **Deciders:** Mimra Core Engineering  

### Context
Users identified four usability defects in the Settings and Window sizing experience:
1. **Dimension Slider Values Not Updating Live:** In the Appearance settings tab, dragging the Panel Width, Panel Height, or Preview Width sliders did not update the numeric labels. The labels remained frozen at their initial values because `AppearanceConfiguration` implemented `ObservableObject` with computed properties reading from `UserDefaults`, but its `notifyChange()` helper only posted a `NotificationCenter` event and never called Combine's `objectWillChange.send()`.
2. **Dense Slider Tick Marks & Precision Discrepancies:** Sliders used `step: 20`, causing AppKit on macOS to render a cramped comb of 32 vertical tick marks on a 160 pt control and preventing snapping to exact defaults like 756 pt for Panel Height.
3. **No Reset to Defaults for Dimensions:** There was no quick way to restore factory panel and preview dimensions.
4. **Window Sizes Not Changing After Value Adjustment:** Changing the dimension sliders had zero effect on the actual floating history panel or preview window. `PanelCoordinator` and `PreviewCoordinator` never observed `AppearanceConfiguration.didChangeNotification`. Furthermore, `PanelCoordinator.positionPanel` only updated the window origin (`panel.setFrameOrigin`) using the stale `panel.frame.size` captured at initial creation rather than setting the window size.
5. **No Quit App Action in Settings Window:** There was no direct button to quit the application from the Settings window.

### Decision
1. **ObservableObject Combine Reactivity (`AppearanceConfiguration.swift`):**
   - Added `objectWillChange.send()` inside `AppearanceConfiguration.notifyChange()`, guaranteeing that all computed property setters notify SwiftUI of incoming updates.
   - Added factory default constants (`defaultPanelWidth: 440`, `defaultPanelHeight: 756`, `defaultPreviewWidth: 360`) and `resetDimensionsToDefaults()`.
2. **Clean Slider Layout & Real-Time Numeric Value Display (`SettingsView.swift`):**
   - Redesigned the "Dimensions & Sizing" section in `AppearanceSettingsTab` to place the feature title on the left, a smooth continuous slider with integer rounding (`round($0)`) in the middle, and a monospaced live numeric indicator (`440 pt`) on the right.
   - Added a "Reset Dimensions to Defaults" button that immediately restores factory defaults.
3. **Dynamic Window & Preview Frame Resizing (`FloatingPanel.swift`, `FloatingPanelView.swift`, `PreviewCoordinator.swift`):**
   - In `PanelCoordinator`, registered an observer for `AppearanceConfiguration.didChangeNotification` and implemented `applyAppearanceDimensions()`.
   - Updated `positionPanel` and `centerOnActiveScreen` to construct `targetSize = NSSize(width: config.panelWidth, height: config.panelHeight)` and apply both origin and size via `panel.setFrame(NSRect(origin: origin, size: targetSize), display: true)`.
   - Updated `FloatingPanelView` outer frame from hardcoded min/ideal/max constraints to `.frame(maxWidth: .infinity, maxHeight: .infinity)` so the SwiftUI root view dynamically fills the `NSPanel` content view.
   - In `PreviewCoordinator`, registered an observer for `AppearanceConfiguration.didChangeNotification` to immediately recalculate and apply the preview frame when visible or hidden.
4. **Settings Window Quit Action (`SettingsView.swift`):**
   - Integrated a native "Quit Mimra" button with a power icon and `⌘Q` indicator into the bottom-left sidebar of the Settings window directly above the version information.

### Consequences
* **Positive:** Moving the dimension sliders immediately updates the adjacent numeric values in real time without jumping or tick mark clutter; factory defaults can be restored with a single click; adjusting the dimensions immediately resizes and repositions the active floating history and preview windows; users can quit Mimra directly from the Settings window.
* **Negative:** None.

---

## ADR-065: Configurable History List Hover Selection, Dwell Debouncing, and Decoupled Visual Affordance

* **Status:** Accepted  
* **Date:** 2026-11-05  
* **Deciders:** Mimra Core Engineering  

### Context
In Mimra's floating history panel, moving the mouse cursor over history rows immediately changed the selected item (`selectedIndex`). This created several usability problems:
1. **Accidental Transit Selection:** Sweeping the cursor across items to reach the search field, settings icon, or an adjacent monitor selected every row the cursor crossed.
2. **Preview Thrashing:** Fleeting row hovers immediately updated the slideout preview panel, causing high CPU usage from unnecessary text parsing, image rendering, and OCR metadata recalculations.
3. **Loss of Keyboard Focus:** Users navigating with arrow keys or shortcut keys had their active selection hijacked by incidental mouse movements or cursor drift.

### Decision
1. **Configurable Hover Selection Modes (`HoverSelectionMode`):**
   - **`immediate` (Default):** Hovering over a row selects it immediately (outside the 250ms keyboard navigation guard).
   - **`delayed` (Dwell):** The cursor must pause and dwell on a row for a configurable period (150 ms snappy, 250 ms normal default, 400 ms relaxed) before the row is selected and the preview is updated.
   - **`disabled` (Keyboard & Click Only):** Mouse hover never alters the active list selection or slideout preview; list selection is owned exclusively by keyboard navigation, and clicking a row immediately commits/pastes it.
2. **Decoupled Visual Hover Affordance (`FloatingPanelView.swift`):**
   - Unselected rows show a subtle hover background tint (`Color.primary.opacity(0.06)`) when the cursor enters them, providing immediate tactile confirmation of cursor position without altering `selectedIndex` or causing the slideout preview to re-render.
   - Full accent coloring (`Color.accentColor`) remains reserved strictly for the active selected item.
3. **State Management & Deterministic Cancellation (`PanelViewModel.swift`, `FloatingPanel.swift`):**
   - Implemented `handleItemHover(index:isHovered:)` with a debounced async `Task` for dwell mode.
   - Any mouse exit, search query modification, or keyboard navigation (`selectNext`, `selectPrevious`, `selectFirst`, `selectLast`, `selectPageUp`, `selectPageDown`, `quickPick`, `searchText.didSet`) immediately cancels any active dwell task.
   - Panel hiding (`hide()`) cancels any active dwell task.
4. **Settings UI Integration (`SettingsView.swift`, `AppearanceConfiguration.swift`):**
   - Added a "Mouse Hover Selection" section in `AppearanceSettingsTab` containing a behavior picker (Immediate, Delayed, Disabled) and conditional dwell delay picker (150 ms, 250 ms, 400 ms).

### Consequences
* **Positive:** Complete elimination of accidental transit selections and preview flickering when moving the mouse across the history list; keyboard navigation is rock-solid and cannot be overridden by casual mouse movement in delayed/disabled modes; subtle visual hover affordance gives responsive feedback without side effects; full user choice with backward compatibility preserved.
* **Negative:** None.


---

## ADR-066: Official App Icon Ingestion, Premium Drag-and-Drop macOS DMG Architecture, and Developer ID Notarization CI Pipeline

* **Status:** Accepted  
* **Date:** 2026-11-05  
* **Deciders:** Mimra Core Engineering  

### Context
With Mimra exiting Phase 8 hardening, the project lacked three critical distribution capabilities:
1. **Application Icon:** The application bundle had no bundled icon assets, displaying a default generic system app icon in the Dock, App Switcher, and Finder.
2. **Branded Installer:** Distributing the application as a raw zip or bare app bundle creates high friction, lacks visual identity, and fails Gatekeeper expectations for a polished macOS utility.
3. **Automated Signing & Notarization:** Manual Developer ID signing and Apple notary service submission are error-prone and risk key exposure. A reproducible, secure GitHub Actions workflow is needed that imports certificates into an ephemeral keychain, signs with Hardened Runtime, notarizes via `xcrun notarytool`, staples tickets, packages a premium DMG, and publishes GitHub releases.

### Decision
1. **Asset Catalog & Standalone ICNS Ingestion:**
   - Ingested all 10 PNG representations from `Mimra_Appicon_Design/AppIcon.appiconset` into `Mimra/Resources/Assets.xcassets/AppIcon.appiconset`.
   - Generated a standalone, optimized `Mimra/Resources/AppIcon.icns` using macOS `iconutil`.
   - Configured `Mimra.xcodeproj` via `scripts/generate_xcodeproj.py` with `PBXResourcesBuildPhase` (`Assets.xcassets`, `Localizable.xcstrings`, `AppIcon.icns`) and `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;`.
   - Declared `CFBundleIconFile = AppIcon` and `CFBundleIconName = AppIcon` in `Mimra/Info.plist`.
2. **Premium macOS DMG Pipeline (`/premium-macos-dmg` Skill):**
   - Configured `packaging/dmg/dmg.config.json` with brand parameters matching Mimra's lavender/indigo visual identity (`#6C5ECF` primary, `#F6F5FD` background, `#1E1A34` ink).
   - Rendered pixel-perfect 720×460 (1x) and 1440×920 (@2x) Finder backgrounds featuring a centered connecting arrow ($x \approx 330 \to 392, y = 271$) and inner card container.
   - Built a deterministic Swift renderer `scripts/render_dmg_background.swift` that uses native AppKit/CoreGraphics for zero-dependency local and CI asset reproduction.
   - Implemented `scripts/build-dmg.sh` wrapping `create-dmg` with multi-representation Retina TIFF creation (`tiffutil -cathidpicheck`) and strict geometry (app at `202 271`, drop link at `520 271`, window size `720 460`, icon size `96`).
   - Implemented `scripts/verify-dmg.py` for automated `hdiutil verify`, read-only mount, single `.app` bundle, valid `/Applications` symlink, and code signature assertion.
3. **Automated GitHub Actions Release Workflow (`.github/workflows/release.yml`):**
   - Triggered on tag push (`v*`) and manual `workflow_dispatch`.
   - Executed on `macos-15` (Apple Silicon).
   - Manages an ephemeral macOS keychain (`$RUNNER_TEMP/build.keychain`) with automatic cleanup in an `always()` post block.
   - Enforces inside-out signing with `ENABLE_HARDENED_RUNTIME = YES` and timestamping via `secrets.APPLE_SIGNING_IDENTITY`.
   - Submits DMG to Apple Notary Service via `xcrun notarytool submit --wait` using `secrets.APPLE_ID`, `secrets.APPLE_PASSWORD`, and `secrets.APPLE_TEAM_ID`.
   - Staples notarization ticket using `xcrun stapler staple` and validates Gatekeeper compliance (`spctl --assess`).
   - Generates SHA256 checksums and publishes the DMG to GitHub Releases via `softprops/action-gh-release@v2`.

### Consequences
* **Positive:** Mimra presents a cohesive, branded experience across the OS and installer; DMG packaging is 100% reproducible locally and in CI; ephemeral keychain prevents secret leakage; Gatekeeper and Hardened Runtime requirements are fully automated.
* **Negative:** DMG creation requires `create-dmg` (installed automatically in CI via Homebrew).
