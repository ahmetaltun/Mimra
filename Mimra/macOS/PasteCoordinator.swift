// ==============================================================================
// Mimra — Paste & Replay Coordinator
// Reconstructs valid NSPasteboard items from typed payloads with provenance markers,
// resolves target focus, and executes synthetic keystroke injection (Command-V).
// Linked Features: F-012, F-020, F-021
// Test IDs: T-PASTE-01, T-PASTE-02, T-CAP-05
// ==============================================================================

import ApplicationServices
import AppKit
import Carbon
import CoreGraphics
import Foundation
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "PasteCoordinator")

/// Paste mode determining whether to preserve all rich formats or strip to plain text.
public enum PasteMode: Sendable, Equatable {
    /// Replays all captured representations faithfully (text, HTML, RTF, images, file URLs).
    case original
    /// Strips rich formatting and writes only plain text to the pasteboard.
    case plainText
}

/// Outcome of a paste or copy operation.
public enum PasteResult: Sendable, Equatable {
    /// Item was copied to clipboard without synthetic keystroke injection.
    case copiedOnly(reason: CopyOnlyReason)
    /// Item was copied to clipboard and synthetic Command-V keystroke was posted to target application.
    case pastedSuccessfully(targetPid: pid_t, targetBundleId: String?)
}

/// Reason explaining why an operation resulted in copy-only without auto-pasting.
public enum CopyOnlyReason: Sendable, Equatable {
    /// User configured the application to copy only by default (or inverted via Option modifier).
    case autoPasteDisabled
    /// Target application was not found or was Mimra itself.
    case noTargetApplication
    /// Target application terminated before focus could be restored.
    case targetAppTerminated
    /// macOS Accessibility permissions (AXIsProcessTrusted) were not granted.
    case accessibilityPermissionDenied
    /// Secure Event Input is active on the system (e.g. system password prompt, lock screen).
    case secureInputActive
    /// A password or secure text field (AXSecureTextField) is focused in the target application.
    case passwordFieldFocused
    /// Target application failed to gain frontmost focus (screen switched, minimized, or focus intercepted).
    case targetActivationFailed
    /// Synthetic keystroke injection (Command-V) failed.
    case keystrokeInjectionFailed
}

/// Type signature for checking whether macOS Accessibility permissions are granted.
public typealias AccessibilityChecker = @Sendable () -> Bool

/// Type signature for posting synthetic Command-V keystrokes to a target process.
public typealias KeystrokePoster = @Sendable (pid_t) -> Bool

/// Type signature for checking whether Secure Event Input is enabled on macOS.
public typealias SecureInputChecker = @Sendable () -> Bool

/// Type signature for checking whether a password or secure text field is focused in a target application.
public typealias PasswordFieldChecker = @Sendable (pid_t) -> Bool

/// Type signature for providing the currently frontmost application.
public typealias FrontmostAppProvider = @Sendable () -> NSRunningApplication?

/// Strongly-typed, explanatory errors that can occur during replay and paste operations.
public enum PasteError: LocalizedError, Sendable, Equatable {
    case itemNotFound(String)
    case emptyPayload(String)
    case noValidRepresentations(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound(let id):
            return "History item with ID '\(id)' was not found in local storage."
        case .emptyPayload(let id):
            return "The payload for item '\(id)' was empty."
        case .noValidRepresentations(let id):
            return "No valid representations could be reconstructed for item '\(id)'."
        case .writeFailed(let reason):
            return "Failed to write items to NSPasteboard: \(reason)"
        }
    }
}

/// Coordinates the reconstruction of valid NSPasteboard items from stored representations,
/// applying provenance markers to prevent self-recapture loops, and auto-pasting into target apps.
@MainActor
public final class PasteCoordinator {
    public let coreClient: CoreClient
    public let pasteboard: NSPasteboard
    public let provenanceGuard: ClipboardProvenance

    /// Whether to automatically paste into the frontmost app by default upon item selection.
    public var pasteAutomatically: Bool

    /// Delay in nanoseconds before posting synthetic keystrokes to allow WindowServer focus switch.
    public var activationDelayNanoseconds: UInt64

    /// Dependency-injected Accessibility trust checker.
    public let accessibilityChecker: AccessibilityChecker

    /// Dependency-injected synthetic keystroke poster.
    public let keystrokePoster: KeystrokePoster

    /// Dependency-injected Secure Event Input checker.
    public let secureInputChecker: SecureInputChecker

    /// Dependency-injected password / secure text field checker.
    public let passwordFieldChecker: PasswordFieldChecker

    /// Dependency-injected provider for the frontmost application.
    public let frontmostAppProvider: FrontmostAppProvider

    /// Callback invoked whenever an item is successfully written to pasteboard.
    public var onItemWritten: ((String, PasteMode) -> Void)?

    /// Callback invoked with the final outcome of a paste operation.
    public var onPasteResult: ((PasteResult) -> Void)?
    public var onAudioFeedback: (@MainActor () -> Void)?

    /// Default accessibility checker querying macOS system trust.
    nonisolated public static let defaultAccessibilityChecker: AccessibilityChecker = {
        AXIsProcessTrusted()
    }

    /// Default keystroke poster injecting Command-V into the system event tap.
    nonisolated public static let defaultKeystrokePoster: KeystrokePoster = { pid in
        let source = CGEventSource(stateID: .combinedSessionState)
        // Virtual key code 0x09 is 'v' (kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Default checker verifying if Secure Event Input is enabled on macOS.
    nonisolated public static let defaultSecureInputChecker: SecureInputChecker = {
        IsSecureEventInputEnabled()
    }

    /// Default checker querying whether a password or secure text field has focus in the target application.
    nonisolated public static let defaultPasswordFieldChecker: PasswordFieldChecker = { pid in
        let appElement = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard result == .success, let element = focusedValue, CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return false
        }
        let axElement = element as! AXUIElement
        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleValue) == .success,
           let subrole = subroleValue as? String, subrole == "AXSecureTextField" {
            return true
        }
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String, role == "AXSecureTextField" {
            return true
        }
        return false
    }

    /// Default provider for the frontmost application.
    nonisolated public static let defaultFrontmostAppProvider: FrontmostAppProvider = {
        MainActor.assumeIsolated {
            NSWorkspace.shared.frontmostApplication
        }
    }

    public init(
        coreClient: CoreClient,
        pasteboard: NSPasteboard = .general,
        provenanceGuard: ClipboardProvenance = .shared,
        pasteAutomatically: Bool = (UserDefaults.standard.object(forKey: "pasteAutomatically") as? Bool) ?? true,
        activationDelayNanoseconds: UInt64 = 30_000_000,
        accessibilityChecker: @escaping AccessibilityChecker = PasteCoordinator.defaultAccessibilityChecker,
        keystrokePoster: @escaping KeystrokePoster = PasteCoordinator.defaultKeystrokePoster,
        secureInputChecker: @escaping SecureInputChecker = PasteCoordinator.defaultSecureInputChecker,
        passwordFieldChecker: @escaping PasswordFieldChecker = PasteCoordinator.defaultPasswordFieldChecker,
        frontmostAppProvider: @escaping FrontmostAppProvider = PasteCoordinator.defaultFrontmostAppProvider
    ) {
        self.coreClient = coreClient
        self.pasteboard = pasteboard
        self.provenanceGuard = provenanceGuard
        self.pasteAutomatically = pasteAutomatically
        self.activationDelayNanoseconds = activationDelayNanoseconds
        self.accessibilityChecker = accessibilityChecker
        self.keystrokePoster = keystrokePoster
        self.secureInputChecker = secureInputChecker
        self.passwordFieldChecker = passwordFieldChecker
        self.frontmostAppProvider = frontmostAppProvider
    }

    // MARK: - Replay Codec

    /// Encodes a list of stored raw representations into native AppKit `NSPasteboardItem`s.
    public static func encodePasteboardItems(
        representations: [RawRepresentation],
        mode: PasteMode = .original
    ) -> [NSPasteboardItem] {
        guard !representations.isEmpty else {
            return []
        }

        switch mode {
        case .plainText:
            return encodePlainTextItem(representations: representations)
        case .original:
            return encodeOriginalItems(representations: representations)
        }
    }

    /// Reconstructs original multi-representation items, grouped by their original `groupIndex`.
    private static func encodeOriginalItems(
        representations: [RawRepresentation]
    ) -> [NSPasteboardItem] {
        let grouped = Dictionary(grouping: representations, by: { $0.groupIndex })
        let sortedGroupIndices = grouped.keys.sorted()
        var items: [NSPasteboardItem] = []

        for groupIndex in sortedGroupIndices {
            guard let groupReps = grouped[groupIndex], !groupReps.isEmpty else {
                continue
            }

            let pbItem = NSPasteboardItem()
            for rep in groupReps {
                let type = NSPasteboard.PasteboardType(rep.uti)
                pbItem.setData(rep.payload, forType: type)
                if (rep.uti == "public.utf8-plain-text" || rep.uti == "public.plain-text"),
                   let str = String(data: rep.payload, encoding: .utf8) {
                    pbItem.setString(str, forType: .string)
                } else if rep.uti == "public.file-url",
                          let urlStr = String(data: rep.payload, encoding: .utf8) {
                    let trimmed = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalUrlStr: String
                    if trimmed.contains("/.file/id="), let url = URL(string: trimmed), let resolved = (url as NSURL).filePathURL {
                        finalUrlStr = resolved.standardizedFileURL.absoluteString
                    } else {
                        finalUrlStr = trimmed
                    }
                    pbItem.setString(finalUrlStr, forType: .fileURL)
                } else if rep.uti == "public.url",
                          let urlStr = String(data: rep.payload, encoding: .utf8) {
                    let trimmed = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    pbItem.setString(trimmed, forType: .URL)
                } else if rep.uti == "public.url-name",
                          let nameStr = String(data: rep.payload, encoding: .utf8) {
                    let trimmed = nameStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    pbItem.setString(trimmed, forType: NSPasteboard.PasteboardType("public.url-name"))
                }
            }

            // Stamp provenance marker and source application to prevent recapture
            stampProvenance(on: pbItem)
            items.append(pbItem)
        }

        return items
    }

    /// Strips rich formatting and constructs a single plain-text pasteboard item.
    private static func encodePlainTextItem(
        representations: [RawRepresentation]
    ) -> [NSPasteboardItem] {
        guard let plainText = extractPlainText(from: representations),
              let textData = plainText.data(using: .utf8) else {
            // Fall back to original representations if plain text cannot be extracted
            return encodeOriginalItems(representations: representations)
        }

        let pbItem = NSPasteboardItem()
        pbItem.setData(textData, forType: .string)
        pbItem.setString(plainText, forType: .string)

        stampProvenance(on: pbItem)
        return [pbItem]
    }

    /// Extracts the best plain-text string from a list of representations.
    public static func extractPlainText(from representations: [RawRepresentation]) -> String? {
        func clean(_ text: String) -> String? {
            let cleaned = text
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\u{FFFD}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        // 1. Check for standard UTF-8 plain text
        let plainUtis: Set<String> = [
            "public.utf8-plain-text",
            "NSStringPboardType",
            "public.plain-text",
            "public.text"
        ]
        if let textRep = representations.first(where: { plainUtis.contains($0.uti) }) {
            if let str = String(data: textRep.payload, encoding: .utf8)
                ?? String(data: textRep.payload, encoding: .utf16)
                ?? String(data: textRep.payload, encoding: .isoLatin1),
               let cleaned = clean(str) {
                return cleaned
            }
        }

        // 2. Check for RTF / RTFD and convert to plain text
        if let rtfRep = representations.first(where: {
            $0.uti == "public.rtf" || $0.uti == "NSRTFPboardType"
        }) {
            if let attrStr = try? NSAttributedString(
                data: rtfRep.payload,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ), let cleaned = clean(attrStr.string) {
                return cleaned
            }
            if let rtfStr = String(data: rtfRep.payload, encoding: .utf8) ?? String(data: rtfRep.payload, encoding: .ascii) {
                let stripped = rtfStr
                    .replacingOccurrences(of: "\\\\[a-zA-Z]+-?[0-9]*[ ]?", with: " ", options: .regularExpression, range: nil)
                    .replacingOccurrences(of: "[{}]", with: "", options: .regularExpression, range: nil)
                if let cleaned = clean(stripped) {
                    return cleaned
                }
            }
        }

        if let rtfdRep = representations.first(where: {
            $0.uti == "com.apple.flat-rtfd" || $0.uti == "public.rtfd" || $0.uti == "com.apple.rtfd" || $0.uti == "NSRTFDPboardType"
        }) {
            if let attrStr = try? NSAttributedString(
                data: rtfdRep.payload,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            ), let cleaned = clean(attrStr.string) {
                return cleaned
            }
        }

        // 3. Check for HTML and convert to plain text
        if let htmlRep = representations.first(where: {
            $0.uti == "public.html" || $0.uti == "NSHTMLPboardType" || $0.uti == "Apple HTML pasteboard type"
        }) {
            if let attrStr = try? NSAttributedString(
                data: htmlRep.payload,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            ), let cleaned = clean(attrStr.string) {
                return cleaned
            }
            if let htmlStr = String(data: htmlRep.payload, encoding: .utf8) ?? String(data: htmlRep.payload, encoding: .isoLatin1) {
                let stripped = htmlStr.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression, range: nil)
                if let cleaned = clean(stripped) {
                    return cleaned
                }
            }
        }

        // 4. Check for File URLs (single or multiple files across groups)
        let fileReps = representations.filter {
            $0.uti == "public.file-url" || $0.uti == "NSURLPboardType" || $0.uti == "NSFilenamesPboardType"
        }
        if !fileReps.isEmpty {
            var filePaths: [String] = []
            for rep in fileReps {
                if rep.uti == "NSFilenamesPboardType" {
                    if let plist = try? PropertyListSerialization.propertyList(from: rep.payload, format: nil) as? [String] {
                        filePaths.append(contentsOf: plist)
                    }
                } else if let rawString = String(data: rep.payload, encoding: .utf8) {
                    let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("file://") {
                        if let url = URL(string: trimmed) {
                            let resolved = (url as NSURL).filePathURL ?? url
                            filePaths.append(resolved.path)
                        }
                    } else if trimmed.hasPrefix("/") {
                        filePaths.append(trimmed)
                    }
                }
            }
            if !filePaths.isEmpty {
                return filePaths.joined(separator: "\n")
            }
        }

        // 5. Check for Web URLs (P3-04)
        if let urlRep = representations.first(where: { $0.uti == "public.url" }) {
            if let rawString = String(data: urlRep.payload, encoding: .utf8) {
                let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        // 6. Fallback for generic text-like data (source code, json, csv, etc.)
        for rep in representations {
            let uti = rep.uti.lowercased()
            if uti.contains("json") || uti.contains("xml") || uti.contains("source-code") || uti.contains("csv") || uti.contains("tsv") {
                if let str = String(data: rep.payload, encoding: .utf8), !str.isEmpty {
                    return str
                }
            }
        }

        return nil
    }

    /// Stamps the proprietary Mimra provenance marker and source application type onto an item.
    private static func stampProvenance(on item: NSPasteboardItem) {
        item.setData(Data(), forType: ClipboardProvenance.provenanceType)
        item.setString(ClipboardProvenance.mimraBundleIdentifier, forType: ClipboardProvenance.sourceAppType)
    }

    // MARK: - Pasteboard Write

    /// Reconstructs and writes the specified history item to the pasteboard.
    ///
    /// - Parameters:
    ///   - itemId: The UUID string of the item to write.
    ///   - mode: Replay mode (.original or .plainText).
    /// - Returns: The updated pasteboard `changeCount`.
    @discardableResult
    public func writeToPasteboard(
        itemId: String,
        mode: PasteMode = .original
    ) async throws -> Int {
        // 1. Fetch representations from RustCore
        let representations: [RawRepresentation]
        do {
            representations = try await coreClient.getItemRepresentations(itemId: itemId)
        } catch let error as CoreError {
            switch error {
            case .ItemNotFound(let id):
                throw PasteError.itemNotFound(id)
            default:
                throw PasteError.writeFailed("Core error fetching representations: \(error)")
            }
        } catch {
            throw PasteError.writeFailed("Unexpected error fetching representations: \(error)")
        }

        guard !representations.isEmpty else {
            throw PasteError.noValidRepresentations(itemId)
        }

        // 2. Encode native NSPasteboardItem objects
        let items = Self.encodePasteboardItems(representations: representations, mode: mode)
        guard !items.isEmpty else {
            throw PasteError.noValidRepresentations(itemId)
        }

        // 3. Clear and write atomically to NSPasteboard
        pasteboard.clearContents()
        let success = pasteboard.writeObjects(items)
        guard success else {
            throw PasteError.writeFailed("NSPasteboard.writeObjects failed.")
        }

        // 4. Record self-write in provenance tracker to prevent recapture loop
        provenanceGuard.recordSelfWrite(on: pasteboard)

        logger.debug("Successfully replayed item '\(itemId, privacy: .public)' to pasteboard with changeCount: \(self.pasteboard.changeCount, privacy: .public)")

        onItemWritten?(itemId, mode)
        return pasteboard.changeCount
    }

    // MARK: - Auto-Paste Execution

    /// Writes the item to the pasteboard and, if permitted, restores focus and injects Command-V.
    ///
    /// - Parameters:
    ///   - itemId: UUID of the history item to paste.
    ///   - mode: Replay mode (.original or .plainText).
    ///   - targetApp: The target application to restore focus to.
    ///   - forcePaste: Explicit override for pasteAutomatically (e.g. Option key modifier).
    /// - Returns: The resulting `PasteResult` detailing whether keystroke injection took place.
    @discardableResult
    public func paste(
        itemId: String,
        mode: PasteMode = .original,
        targetApp: NSRunningApplication? = nil,
        forcePaste: Bool? = nil
    ) async throws -> PasteResult {
        // 1. Always load the item into NSPasteboard first
        try await writeToPasteboard(itemId: itemId, mode: mode)

        // 2. Bump recopy timestamp in RustCore (moves item to top of history under recency sorting)
        let shouldMoveToTop = (UserDefaults.standard.object(forKey: "moveToTopOnPaste") as? Bool) ?? true
        if shouldMoveToTop {
            do {
                _ = try await coreClient.touchItem(itemId: itemId)
            } catch {
                logger.warning("Failed to touch item '\(itemId, privacy: .public)': \(error)")
            }
        }

        // Play subtle audio feedback on copy/paste commit (P7-01 / F-035, F-056)
        await MainActor.run {
            onAudioFeedback?()
        }

        // 3. Determine whether auto-paste should execute
        let userDefaultPaste = UserDefaults.standard.object(forKey: "pasteAutomatically") as? Bool
        let effectivePaste = userDefaultPaste ?? pasteAutomatically
        let shouldAutoPaste = forcePaste ?? effectivePaste
        guard shouldAutoPaste else {
            logger.debug("Auto-paste disabled. Replay concluded in copy-only mode.")
            let res = PasteResult.copiedOnly(reason: .autoPasteDisabled)
            onPasteResult?(res)
            return res
        }

        // 3. Validate target application exists and is not Mimra itself
        guard let target = targetApp,
              target.bundleIdentifier != ClipboardProvenance.mimraBundleIdentifier else {
            logger.info("No valid external target application. Replay concluded in copy-only mode.")
            let res = PasteResult.copiedOnly(reason: .noTargetApplication)
            onPasteResult?(res)
            return res
        }

        // 4. Validate target application has not terminated
        guard !target.isTerminated else {
            logger.info("Target application terminated before focus could be restored. Degraded to copy-only mode.")
            let res = PasteResult.copiedOnly(reason: .targetAppTerminated)
            onPasteResult?(res)
            return res
        }

        // 5. Guard against pasting when Secure Event Input is active on macOS (e.g. password prompts, lock screens)
        if secureInputChecker() {
            logger.info("Secure Event Input is active on the system. Refusing synthetic keystroke injection. Degraded to copy-only mode.")
            let res = PasteResult.copiedOnly(reason: .secureInputActive)
            onPasteResult?(res)
            return res
        }

        // 6. Guard against pasting into password or secure text fields in the target application
        if passwordFieldChecker(target.processIdentifier) {
            logger.info("Password or secure text field is focused in target application. Refusing synthetic keystroke injection. Degraded to copy-only mode.")
            let res = PasteResult.copiedOnly(reason: .passwordFieldFocused)
            onPasteResult?(res)
            return res
        }

        // 7. Verify macOS Accessibility permissions
        guard accessibilityChecker() else {
            logger.info("Accessibility permission not granted. Degraded to copy-only mode.")
            let res = PasteResult.copiedOnly(reason: .accessibilityPermissionDenied)
            onPasteResult?(res)
            return res
        }

        // 8. Restore focus to the target application
        target.activate()

        // 9. Yield briefly to allow WindowServer focus transition
        if activationDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: activationDelayNanoseconds)
        }

        // 10. Verify target application gained frontmost focus (guard against screen switch, minimization, or focus interception)
        if let currentFrontmost = frontmostAppProvider() {
            guard currentFrontmost.processIdentifier == target.processIdentifier else {
                logger.warning("Target application PID \(target.processIdentifier) failed to gain frontmost focus (screen switched, minimized, or focus intercepted). Refusing synthetic keystroke.")
                let res = PasteResult.copiedOnly(reason: .targetActivationFailed)
                onPasteResult?(res)
                return res
            }
        }

        // 11. Inject synthetic Command-V keystroke
        let pid = target.processIdentifier
        let posted = keystrokePoster(pid)
        guard posted else {
            logger.error("Failed to post Command-V synthetic keystroke to target PID \(pid, privacy: .public).")
            let res = PasteResult.copiedOnly(reason: .keystrokeInjectionFailed)
            onPasteResult?(res)
            return res
        }

        logger.debug("Successfully injected Command-V keystroke into target PID \(pid, privacy: .public).")
        let res = PasteResult.pastedSuccessfully(targetPid: pid, targetBundleId: target.bundleIdentifier)
        onPasteResult?(res)
        return res
    }
}
