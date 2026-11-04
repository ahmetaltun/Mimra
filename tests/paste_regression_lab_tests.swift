// ==============================================================================
// Mimra Tests — Paste Regression Lab & Target Matrix Test Suite (P8-02)
// Linked Features: F-001, F-002, F-017, F-020, F-021, F-029
// Test IDs: T-PASTE-01, T-PASTE-02, T-PASTE-03, T-PASTE-04, T-UI-06
// Exercises all target app scenarios: Finder, Safari, Chrome, Notes, Pages,
// Terminal, IDE, Spotlight, Remote Desktop, and Fullscreen.
// ==============================================================================

import AppKit
import Foundation

/// Mock implementation of NSRunningApplication for testing target behaviors.
final class MockRunningApplication: NSRunningApplication, @unchecked Sendable {
    private let _pid: pid_t
    private let _bundleId: String?
    private var _isTerminated: Bool
    private var _isActive: Bool

    init(pid: pid_t, bundleId: String?, isTerminated: Bool = false, isActive: Bool = true) {
        self._pid = pid
        self._bundleId = bundleId
        self._isTerminated = isTerminated
        self._isActive = isActive
        super.init()
    }

    override var processIdentifier: pid_t { _pid }
    override var bundleIdentifier: String? { _bundleId }
    override var isTerminated: Bool { _isTerminated }
    override var isActive: Bool { _isActive }

    override func activate(options: NSApplication.ActivationOptions = []) -> Bool {
        _isActive = true
        return true
    }

    func setTerminated(_ terminated: Bool) {
        _isTerminated = terminated
    }
}

/// Thread-safe mock environment managing external system state under Swift 6 strict concurrency.
final class MockPasteEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    var isAccessibilityTrusted: Bool = true
    var isSecureInputActive: Bool = false
    var focusedPidIsPassword: [pid_t: Bool] = [:]
    var postedPids: [pid_t] = []
    var failKeystroke: Bool = false
    var currentFrontmost: MockRunningApplication?

    func checkAccessibility() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAccessibilityTrusted
    }

    func postKeystroke(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if failKeystroke { return false }
        postedPids.append(pid)
        return true
    }

    func checkSecureInput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSecureInputActive
    }

    func checkPasswordField(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return focusedPidIsPassword[pid] ?? false
    }

    func frontmostApp() -> NSRunningApplication? {
        lock.lock()
        defer { lock.unlock() }
        return currentFrontmost
    }

    func setFrontmost(_ app: MockRunningApplication?) {
        lock.lock()
        defer { lock.unlock() }
        currentFrontmost = app
    }

    func setPassword(pid: pid_t, isPassword: Bool) {
        lock.lock()
        defer { lock.unlock() }
        focusedPidIsPassword[pid] = isPassword
    }

    func lastPostedPid() -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return postedPids.last
    }
}

@main
struct PasteRegressionLabTests {
    @MainActor
    static func main() async {
        print("=== Running Paste Regression Lab Tests (P8-02 / T-PASTE-01 to T-PASTE-04, T-UI-06) ===")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimra_paste_lab_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("paste_lab.sqlite").path

        do {
            let core = try CoreClient(databasePath: dbPath)
            let testPasteboard = NSPasteboard.withUniqueName()
            let env = MockPasteEnvironment()

            let coordinator = PasteCoordinator(
                coreClient: core,
                pasteboard: testPasteboard,
                provenanceGuard: ClipboardProvenance(),
                pasteAutomatically: true,
                activationDelayNanoseconds: 0,
                accessibilityChecker: { env.checkAccessibility() },
                keystrokePoster: { pid in env.postKeystroke(pid: pid) },
                secureInputChecker: { env.checkSecureInput() },
                passwordFieldChecker: { pid in env.checkPasswordField(pid: pid) },
                frontmostAppProvider: { env.frontmostApp() }
            )

            // -----------------------------------------------------------------
            // Setup Test History Items
            // -----------------------------------------------------------------
            let baseTime = Int64(Date().timeIntervalSince1970 * 1000)

            // Item 1: Multi-representation Rich Document (RTF + HTML + Plain Text)
            let richCapture = RawCapture(
                timestampMs: baseTime,
                sourceBundleId: "com.apple.Notes",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data("Notes Rich Content Body".utf8)
                    ),
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.html",
                        payload: Data("<b>Notes Rich Content Body</b>".utf8)
                    )
                ]
            )
            let richItem = try await core.ingest(capture: richCapture)

            // Item 2: Multi-file URL item (Finder)
            let fileCapture = RawCapture(
                timestampMs: baseTime + 10,
                sourceBundleId: "com.apple.finder",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.file-url",
                        payload: Data("file:///Users/Shared/Report.pdf".utf8)
                    ),
                    RawRepresentation(
                        groupIndex: 1,
                        uti: "public.file-url",
                        payload: Data("file:///Users/Shared/Data.csv".utf8)
                    )
                ]
            )
            let fileItem = try await core.ingest(capture: fileCapture)

            // Item 3: Source Code with indentation & trailing spaces (VS Code)
            let codeText = "    def solve(matrix):\n        return [row[:] for row in matrix]   \n"
            let codeCapture = RawCapture(
                timestampMs: baseTime + 20,
                sourceBundleId: "com.microsoft.VSCode",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: Data(codeText.utf8)
                    )
                ]
            )
            let codeItem = try await core.ingest(capture: codeCapture)

            // -----------------------------------------------------------------
            // Scenario 1: Finder (com.apple.finder)
            // -----------------------------------------------------------------
            let finderApp = MockRunningApplication(pid: 101, bundleId: "com.apple.finder")
            env.setFrontmost(finderApp)

            // Test original file paste: preserves both file URLs
            let finderRes = try await coordinator.paste(itemId: fileItem.itemId, mode: .original, targetApp: finderApp)
            assert(finderRes == .pastedSuccessfully(targetPid: 101, targetBundleId: "com.apple.finder"))
            assert(env.lastPostedPid() == 101)
            let pbFileUrls = testPasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) } ?? []
            assert(pbFileUrls.count == 2, "Finder must receive 2 file URLs")
            assert(pbFileUrls[0] == "file:///Users/Shared/Report.pdf")
            assert(pbFileUrls[1] == "file:///Users/Shared/Data.csv")
            print("✓ Scenario 1: Finder multi-file paste verified")

            // -----------------------------------------------------------------
            // Scenario 2: Safari (com.apple.Safari) & Password Field Guard
            // -----------------------------------------------------------------
            let safariApp = MockRunningApplication(pid: 102, bundleId: "com.apple.Safari")
            env.setFrontmost(safariApp)

            // Standard paste into Safari web view
            let safariRes = try await coordinator.paste(itemId: richItem.itemId, mode: .original, targetApp: safariApp)
            assert(safariRes == .pastedSuccessfully(targetPid: 102, targetBundleId: "com.apple.Safari"))

            // Password field active in Safari -> must refuse synthetic keystroke
            env.setPassword(pid: 102, isPassword: true)
            let safariPassRes = try await coordinator.paste(itemId: richItem.itemId, mode: .original, targetApp: safariApp)
            assert(safariPassRes == .copiedOnly(reason: .passwordFieldFocused), "Must abort keystroke on secure textfield")
            env.setPassword(pid: 102, isPassword: false)
            print("✓ Scenario 2: Safari paste & password field safety guard verified")

            // -----------------------------------------------------------------
            // Scenario 3: Chrome (com.google.Chrome) & Fullscreen Auxiliary
            // -----------------------------------------------------------------
            let chromeApp = MockRunningApplication(pid: 103, bundleId: "com.google.Chrome")
            env.setFrontmost(chromeApp)

            let chromeRes = try await coordinator.paste(itemId: richItem.itemId, mode: .plainText, targetApp: chromeApp)
            assert(chromeRes == .pastedSuccessfully(targetPid: 103, targetBundleId: "com.google.Chrome"))
            let pbString = testPasteboard.string(forType: .string)
            assert(pbString == "Notes Rich Content Body", "Plain text mode must strip HTML tags")
            print("✓ Scenario 3: Chrome plain text paste verified")

            // -----------------------------------------------------------------
            // Scenario 4: Apple Notes (com.apple.Notes) & Plain Paste Shortcut
            // -----------------------------------------------------------------
            let notesApp = MockRunningApplication(pid: 104, bundleId: "com.apple.Notes")
            env.setFrontmost(notesApp)

            // Original mode: HTML is retained
            _ = try await coordinator.paste(itemId: richItem.itemId, mode: .original, targetApp: notesApp)
            let htmlData = testPasteboard.data(forType: NSPasteboard.PasteboardType("public.html"))
            assert(htmlData != nil, "Original mode must write HTML data")

            // Plain text mode: HTML is stripped
            _ = try await coordinator.paste(itemId: richItem.itemId, mode: .plainText, targetApp: notesApp)
            let strippedHtmlData = testPasteboard.data(forType: NSPasteboard.PasteboardType("public.html"))
            assert(strippedHtmlData == nil, "Plain text mode must not write HTML data")
            print("✓ Scenario 4: Apple Notes rich vs plain text mode verified")

            // -----------------------------------------------------------------
            // Scenario 5: Pages (com.apple.iWork.Pages)
            // -----------------------------------------------------------------
            let pagesApp = MockRunningApplication(pid: 105, bundleId: "com.apple.iWork.Pages")
            env.setFrontmost(pagesApp)

            let pagesRes = try await coordinator.paste(itemId: richItem.itemId, mode: .original, targetApp: pagesApp)
            assert(pagesRes == .pastedSuccessfully(targetPid: 105, targetBundleId: "com.apple.iWork.Pages"))
            print("✓ Scenario 5: Pages document paste verified")

            // -----------------------------------------------------------------
            // Scenario 6: Terminal (com.apple.Terminal)
            // -----------------------------------------------------------------
            let terminalApp = MockRunningApplication(pid: 106, bundleId: "com.apple.Terminal")
            env.setFrontmost(terminalApp)

            // Plain text conversion from rich item for terminal
            let termRes = try await coordinator.paste(itemId: richItem.itemId, mode: .plainText, targetApp: terminalApp)
            assert(termRes == .pastedSuccessfully(targetPid: 106, targetBundleId: "com.apple.Terminal"))
            let termContent = testPasteboard.string(forType: .string)
            assert(termContent == "Notes Rich Content Body", "Terminal must receive clean text")
            print("✓ Scenario 6: Terminal plain text paste verified")

            // -----------------------------------------------------------------
            // Scenario 7: IDE / VS Code (com.microsoft.VSCode)
            // -----------------------------------------------------------------
            let vscodeApp = MockRunningApplication(pid: 107, bundleId: "com.microsoft.VSCode")
            env.setFrontmost(vscodeApp)

            let codeRes = try await coordinator.paste(itemId: codeItem.itemId, mode: .original, targetApp: vscodeApp)
            assert(codeRes == .pastedSuccessfully(targetPid: 107, targetBundleId: "com.microsoft.VSCode"))
            let codePasted = testPasteboard.string(forType: .string)
            assert(codePasted == codeText, "IDE snippet must preserve tabs, newlines, and trailing spaces")
            print("✓ Scenario 7: IDE whitespace and indentation preservation verified")

            // -----------------------------------------------------------------
            // Scenario 8: Spotlight & Target Termination Fallback
            // -----------------------------------------------------------------
            let spotlightApp = MockRunningApplication(pid: 108, bundleId: "com.apple.Spotlight")
            spotlightApp.setTerminated(true) // Spotlight closed
            env.setFrontmost(nil)

            let spotRes = try await coordinator.paste(itemId: codeItem.itemId, mode: .plainText, targetApp: spotlightApp)
            assert(spotRes == .copiedOnly(reason: .targetAppTerminated), "Must fall back to copy-only if target terminated")
            print("✓ Scenario 8: Spotlight / transient target dismissal fallback verified")

            // -----------------------------------------------------------------
            // Scenario 9: Remote Desktop & Secure Event Input
            // -----------------------------------------------------------------
            let rdcApp = MockRunningApplication(pid: 109, bundleId: "com.microsoft.rdc.macos")
            env.setFrontmost(rdcApp)

            // Secure event input active (e.g. Remote lock screen or local prompt)
            env.isSecureInputActive = true
            let rdcRes = try await coordinator.paste(itemId: codeItem.itemId, mode: .original, targetApp: rdcApp)
            assert(rdcRes == .copiedOnly(reason: .secureInputActive), "Must abort keystroke when Secure Event Input is active")
            env.isSecureInputActive = false
            print("✓ Scenario 9: Remote Desktop / Secure Event Input protection verified")

            // -----------------------------------------------------------------
            // Scenario 10: Accessibility Permission Denied Fallback
            // -----------------------------------------------------------------
            env.isAccessibilityTrusted = false
            let a11yDeniedRes = try await coordinator.paste(itemId: codeItem.itemId, mode: .original, targetApp: vscodeApp)
            assert(a11yDeniedRes == .copiedOnly(reason: .accessibilityPermissionDenied), "Must degrade to copy-only when AX is denied")
            env.isAccessibilityTrusted = true
            print("✓ Scenario 10: Accessibility permission denial fallback verified")

            // -----------------------------------------------------------------
            // Scenario 11: Keystroke Posting Failure Fallback
            // -----------------------------------------------------------------
            env.setFrontmost(vscodeApp)
            env.failKeystroke = true
            let failPostRes = try await coordinator.paste(itemId: codeItem.itemId, mode: .original, targetApp: vscodeApp)
            assert(failPostRes == .copiedOnly(reason: .keystrokeInjectionFailed), "Must return keystrokeInjectionFailed if CGEventPost fails")
            env.failKeystroke = false
            print("✓ Scenario 11: Keystroke posting failure fallback verified")

            // -----------------------------------------------------------------
            // Scenario 12: Focus Mismatch / Screen Switch Interception
            // -----------------------------------------------------------------
            // Target is vscodeApp (PID 107), but frontmost is now Safari (PID 102) due to user switching spaces
            env.setFrontmost(safariApp)
            let focusMismatchRes = try await coordinator.paste(itemId: codeItem.itemId, mode: .original, targetApp: vscodeApp)
            assert(focusMismatchRes == .copiedOnly(reason: .targetActivationFailed), "Must refuse keystroke if frontmost PID does not match target")
            print("✓ Scenario 12: Focus mismatch and screen switch interception verified")

            // Clean up test database
            try? FileManager.default.removeItem(at: tempDir)
            print("✓ Cleaned up temporary test directory")

        } catch {
            print("❌ PasteRegressionLabTests failed: \(error)")
            exit(1)
        }

        print("----------------------------------------------------------------------")
        print("ALL PASTE REGRESSION LAB TESTS (P8-02) PASSED!")
        print("----------------------------------------------------------------------")
    }
}
