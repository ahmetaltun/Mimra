// ==============================================================================
// Mimra — Source Attribution & Application Icon Automated Tests (T-CAP-04)
// Linked Features: F-011, F-016
// ==============================================================================

import AppKit
import Foundation

@main
struct SourceAttributionTests {
    static func main() async {
        print("----------------------------------------------------------------------")
        print("Starting Source Attribution & App Icon Tests (T-CAP-04, F-011, F-016)")
        print("----------------------------------------------------------------------")

        // =========================================================================
        // 1. Source Bundle ID Detection from Pasteboard (F-011)
        // =========================================================================
        print("1. Testing Source Attribution Detection from Pasteboard...")

        let testPasteboard = NSPasteboard(name: NSPasteboard.Name("com.mimra.test.source.\(UUID().uuidString)"))
        let tempDbPath = "/tmp/mimra_source_test_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tempDbPath)
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(tempDbPath)-shm")
        }

        do {
            let client = try CoreClient(databasePath: tempDbPath)
            let monitor = ClipboardMonitor(pasteboard: testPasteboard, coreClient: client)

            // 1a. Item with explicit org.nspasteboard.source string
            testPasteboard.clearContents()
            let item1 = NSPasteboardItem()
            item1.setString("Copied link from browser", forType: .string)
            item1.setString("com.apple.Safari", forType: ClipboardProvenance.sourceAppType)
            testPasteboard.writeObjects([item1])

            monitor.checkForChanges()
            // Wait briefly for off-main actor ingestion task
            try await Task.sleep(nanoseconds: 100_000_000)

            let items1 = try await client.listPage(limit: 10, offset: 0)
            assert(!items1.isEmpty, "FAIL: Item should be ingested")
            assert(items1[0].sourceBundleId == "com.apple.Safari", "FAIL: Explicit source marker should be captured as 'com.apple.Safari', got \(String(describing: items1[0].sourceBundleId))")
            print("  ✓ Explicit org.nspasteboard.source string marker detected correctly")

            // 1b. Item with raw Data UTF-8 org.nspasteboard.source marker
            testPasteboard.clearContents()
            let item2 = NSPasteboardItem()
            item2.setString("Code snippet from editor", forType: .string)
            if let data = "com.apple.dt.Xcode".data(using: .utf8) {
                item2.setData(data, forType: ClipboardProvenance.sourceAppType)
            }
            testPasteboard.writeObjects([item2])

            monitor.checkForChanges()
            try await Task.sleep(nanoseconds: 100_000_000)

            let items2 = try await client.listPage(limit: 10, offset: 0)
            assert(items2.count >= 2, "FAIL: Second item should be ingested")
            assert(items2[0].sourceBundleId == "com.apple.dt.Xcode", "FAIL: Raw Data source marker should be decoded as 'com.apple.dt.Xcode', got \(String(describing: items2[0].sourceBundleId))")
            print("  ✓ Raw Data UTF-8 org.nspasteboard.source marker decoded correctly")

            // 1c. Item without marker falls back safely
            testPasteboard.clearContents()
            let item3 = NSPasteboardItem()
            item3.setString("Unmarked text snippet", forType: .string)
            testPasteboard.writeObjects([item3])

            monitor.checkForChanges()
            try await Task.sleep(nanoseconds: 100_000_000)

            let items3 = try await client.listPage(limit: 10, offset: 0)
            assert(items3.count >= 3, "FAIL: Third item should be ingested")
            // In headless/test runner, frontmostApplication may be nil or the test process bundle ID; must not crash
            print("  ✓ Unmarked item handled gracefully (sourceBundleId: \(String(describing: items3[0].sourceBundleId)))")

            // =====================================================================
            // 2. AppIconService Resolution & Caching (F-011, F-016)
            // =====================================================================
            print("\n2. Testing AppIconService Resolution & Caching...")

            let iconService = AppIconService.shared

            // 2a. Resolve known system app icon (Finder)
            guard let finderIcon = await iconService.icon(for: "com.apple.finder") else {
                fatalError("FAIL: Expected valid icon for 'com.apple.finder'")
            }
            assert(finderIcon.size.width > 0 && finderIcon.size.height > 0, "FAIL: Finder icon size must be positive")
            print("  ✓ Successfully resolved application icon for 'com.apple.finder'")

            // 2b. Synchronous cache hit
            let cachedFinderIcon = iconService.cachedIcon(for: "com.apple.finder")
            assert(cachedFinderIcon != nil, "FAIL: Synchronous cache hit for Finder icon should succeed")
            assert(cachedFinderIcon === finderIcon, "FAIL: Cached icon reference should match resolved instance")
            print("  ✓ Synchronous cache hit returned identical icon instance with zero latency")

            // 2c. Resolve Terminal icon
            guard let terminalIcon = await iconService.icon(for: "com.apple.Terminal") else {
                fatalError("FAIL: Expected valid icon for 'com.apple.Terminal'")
            }
            assert(terminalIcon.size.width > 0, "FAIL: Terminal icon size must be positive")
            print("  ✓ Successfully resolved application icon for 'com.apple.Terminal'")

            // 2d. Unknown / nonexistent bundle ID (unknown source safe)
            let unknownIcon = await iconService.icon(for: "com.nonexistent.fake.bundle.id.12345")
            assert(unknownIcon == nil, "FAIL: Unknown bundle ID must return nil safely")
            assert(iconService.cachedIcon(for: "com.nonexistent.fake.bundle.id.12345") == nil, "FAIL: Unknown bundle ID cached icon should be nil")
            print("  ✓ Unknown bundle ID handled safely without throwing or hanging ('unknown source safe')")

            // 2e. Empty / whitespace bundle ID
            let emptyIcon = await iconService.icon(for: "")
            assert(emptyIcon == nil, "FAIL: Empty bundle ID should return nil")
            let wsIcon = await iconService.icon(for: "   \n")
            assert(wsIcon == nil, "FAIL: Whitespace bundle ID should return nil")
            print("  ✓ Empty and whitespace bundle IDs safely rejected")

            // 2f. Cache Invalidation
            await iconService.invalidate(bundleId: "com.apple.finder")
            assert(iconService.cachedIcon(for: "com.apple.finder") == nil, "FAIL: Invalidation should remove Finder from cache")

            await iconService.invalidateAll()
            assert(iconService.cachedIcon(for: "com.apple.Terminal") == nil, "FAIL: InvalidateAll should clear all icons")
            print("  ✓ Invalidation mechanisms (single & all) verified")

            // =====================================================================
            // 3. Provenance & Replay Stamp (F-011)
            // =====================================================================
            print("\n3. Testing Replay Provenance Stamp...")

            let replayRep = RawRepresentation(groupIndex: 0, uti: "public.utf8-plain-text", payload: "Replayed content".data(using: .utf8)!)
            let replayedItems = PasteCoordinator.encodePasteboardItems(representations: [replayRep], mode: .original)
            assert(replayedItems.count == 1, "FAIL: Expected 1 replayed item")

            let stampedSource = replayedItems[0].string(forType: ClipboardProvenance.sourceAppType)
            assert(stampedSource == ClipboardProvenance.mimraBundleIdentifier, "FAIL: Replayed item must be stamped with 'com.mimra.app', got \(String(describing: stampedSource))")

            // Setting the stamped item on pasteboard
            testPasteboard.clearContents()
            testPasteboard.writeObjects(replayedItems)
            let isSelfAfterWrite = ClipboardProvenance.shared.isSelfGenerated(changeCount: testPasteboard.changeCount, pasteboard: testPasteboard)
            assert(isSelfAfterWrite, "FAIL: Stamped item must be recognized as self-generated")
            print("  ✓ PasteCoordinator stamps provenance and prevents self-recapture")

            print("----------------------------------------------------------------------")
            print("✓ ALL SOURCE ATTRIBUTION & APP ICON TESTS PASSED (T-CAP-04)")
            print("----------------------------------------------------------------------")
        } catch {
            fatalError("FAIL: Encountered unexpected error: \(error)")
        }
    }
}
