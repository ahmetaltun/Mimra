# Mimra — Paste Regression Lab & Target Matrix (P8-02)

> **Document Status:** Complete & Verified  
> **Linked Features:** F-001, F-002, F-017, F-020, F-021, F-029  
> **Linked Tests:** T-PASTE-01, T-PASTE-02, T-PASTE-03, T-PASTE-04, T-UI-06  
> **Last Updated:** 2026-11-04  

---

## 1. Overview & Objective

Mimra operates as a non-activating background panel (`LSUIElement = true`). When the user selects an item from history (or uses Quick Pick 1–9 / Cycle Summon), Mimra writes the item's representations to `NSPasteboard`, restores focus to the previously frontmost application, and synthesizes a `Command-V` keystroke via macOS `CGEventPost` (`.cghidEventTap`).

In macOS environments, target applications vary wildly in how they handle focus transitions, pasteboard types, accessibility permissions, secure text inputs, and full-screen spaces. This document records the empirical behavior, security mitigations, and fallback strategies for all primary macOS target environments.

---

## 2. Target Application Matrix

| Target Application | Target Bundle Identifier | Primary Content Types | Replay Mode Support | Security / Focus Nuances | Verification Status & Fallback Behavior |
|---|---|---|---|---|---|
| **Finder** | `com.apple.finder` | Files (`public.file-url`), folder drops, rename text | Original & Plain Text | Target focus can be desktop icon view, column view, or inline text field rename. | **VERIFIED.** Replays `public.file-url` and `NSFilenamesPboardType`. If inline text is selected, plain text pasted. If Accessibility denied, degrades cleanly to `copiedOnly(reason: .accessibilityPermissionDenied)`. |
| **Safari** | `com.apple.Safari` | HTML, plain text, Web URLs, images | Original & Plain Text | WebKit web views, address bar omnibox, and `<input type="password">`. | **VERIFIED.** Auto-paste synthesizes `Command-V`. If focused element is `AXSecureTextField`, keystroke injection is aborted and returns `copiedOnly(reason: .passwordFieldFocused)`. |
| **Google Chrome** | `com.google.Chrome` | HTML, plain text, URLs | Original & Plain Text | Omnibox autocomplete suggestions, web inputs, multi-profile windows. | **VERIFIED.** Auto-paste verified. If Chrome is in fullscreen Space, Mimra uses `.fullScreenAuxiliary` to appear above Chrome without switching Spaces; focus restored to PID. |
| **Apple Notes** | `com.apple.Notes` | RTF, HTML, styled text, attachments | Original & Plain Text | Multi-representation churn, rich text pasting. | **VERIFIED.** Full formatting preserved on `.original`. Plain text (`Option-Shift-Return`) strips styles while preserving UTF-8 text and newlines. |
| **Pages** | `com.apple.iWork.Pages` | RTFD, styled text, shapes | Original & Plain Text | Document canvas selection. | **VERIFIED.** Preserves rich attributes on `.original` mode, converts to clean plain text on `.plainText` mode. |
| **Terminal / iTerm2** | `com.apple.Terminal`, `com.googlecode.iterm2` | Plain text, shell commands | Plain Text enforced | Shell prompts, bracketed paste mode, non-printing control characters. | **VERIFIED.** If rich text or HTML is copied, `encodePlainTextItem` strips tags and control sequences, ensuring Terminal receives clean UTF-8 text without corrupted escape sequences. |
| **IDE (VS Code / Xcode)** | `com.microsoft.VSCode`, `com.apple.dt.Xcode` | Code snippets, indentation, trailing spaces | Original & Plain Text | Code editor buffers, multi-cursor, syntax highlighters. | **VERIFIED.** Trailing whitespace, line breaks (`\n` and `\r\n`), and tabs strictly preserved without alteration. |
| **Spotlight** | `com.apple.Spotlight` | Plain text search queries | Plain Text | Transient floating window. Dismisses when unfocused. | **VERIFIED.** When Spotlight dismisses upon Mimra summon, target application resolution detects termination or focus loss, safely returning `copiedOnly(reason: .noTargetApplication)` without hanging. |
| **Remote Desktop / VNC** | `com.microsoft.rdc.macos`, `com.apple.RemoteDesktop` | Remote clipboard text/files | Plain Text & Original | Remote session event trapping, lock screens. | **VERIFIED.** If remote client enables Secure Event Input or blocks synthetic keystrokes, `PasteCoordinator` degrades cleanly to `copiedOnly(reason: .secureInputActive)` or `copiedOnly(reason: .keystrokeInjectionFailed)`. |
| **Full-Screen Apps** | Any (`NSWindow.CollectionBehavior`) | All supported types | Original & Plain Text | Space transitions, Dock autohide, menubar concealment. | **VERIFIED.** Mimra panel has `.canJoinAllSpaces` and `.fullScreenAuxiliary`. When active, it stays on the fullscreen Space, avoids triggering a Mission Control transition, and restores focus directly to the fullscreen window. |

---

## 3. Fallback & Degradation Hierarchy

When an operation cannot complete full synthetic auto-paste, `PasteCoordinator` enforces a strict, fail-safe degradation hierarchy:

```
User selects History Item
        │
        ▼
[1] Write to NSPasteboard (atomic, with Mimra provenance marker)
        │
        ▼
Is autoPaste enabled? ─── No ───► Result: copiedOnly(.autoPasteDisabled)
        │ Yes
        ▼
Is target application active and valid? ─── No ───► Result: copiedOnly(.noTargetApplication / .targetAppTerminated)
        │ Yes
        ▼
Is Secure Event Input enabled on macOS? ─── Yes ───► Result: copiedOnly(.secureInputActive)
        │ No
        ▼
Is focused element a Password Field? ─── Yes ───► Result: copiedOnly(.passwordFieldFocused)
        │ No
        ▼
Are Accessibility permissions granted? ─── No ───► Result: copiedOnly(.accessibilityPermissionDenied)
        │ Yes
        ▼
Activate target app & verify frontmost PID ─── Mismatch ───► Result: copiedOnly(.targetActivationFailed)
        │ Match
        ▼
Inject synthetic Command-V (CGEventPost) ─── Post Failure ───► Result: copiedOnly(.keystrokeInjectionFailed)
        │ Success
        ▼
Result: pastedSuccessfully(targetPid, bundleId)
```

In every single fallback scenario:
1. The clipboard item is **guaranteed to be written** to `NSPasteboard.general`.
2. The user can manually press `Command-V` to paste.
3. No alert dialog, modal sheet, or audible error disrupts the user's flow.
4. Explanatory diagnostics are logged for debugging without logging sensitive clipboard contents.
