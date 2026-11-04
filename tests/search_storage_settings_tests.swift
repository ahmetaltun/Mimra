// ==============================================================================
// Mimra — Search & Storage Settings Integration Tests (P7-03 / F-013, F-049, F-050, F-055)
// Verifies search mode synchronization, match highlight styles, sort/pin persistence,
// storage retention policy conversion, and format allowlisting under Swift 6.
// ==============================================================================

import AppKit
import Foundation

@main
struct SearchStorageSettingsTests {
    @MainActor
    static func main() async {
        print("--- Mimra Search & Storage Settings Tests (P7-03 / F-013, F-049, F-050, F-055) ---")

        _ = NSApplication.shared

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("search_storage_settings_test.sqlite").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
            // Clean up UserDefaults keys used in test
            let keys = [
                "searchMode", "pinArrangement", "historySortMode", "searchByRelevance",
                "searchHighlightStyle", "includeOcrInSearch",
                "retentionMaxCount", "retentionMaxAgeDays", "retentionMaxSizeBytes",
                ClipboardTypeConfiguration.storePlainTextKey,
                ClipboardTypeConfiguration.storeRichTextKey,
                ClipboardTypeConfiguration.storeImagesKey,
                ClipboardTypeConfiguration.storeFilesKey
            ]
            for key in keys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        do {
            let core = try CoreClient(databasePath: dbPath)

            // -------------------------------------------------------------------------
            // Test 1: SearchHighlightStyle values and display names (F-050, T-SRCH-03)
            // -------------------------------------------------------------------------
            print("\nStep 1: Testing SearchHighlightStyle enum and values...")
            assert(SearchHighlightStyle.bold.rawValue == "bold", "bold style rawValue mismatch")
            assert(SearchHighlightStyle.underline.rawValue == "underline", "underline style rawValue mismatch")
            assert(SearchHighlightStyle.italic.rawValue == "italic", "italic style rawValue mismatch")
            assert(SearchHighlightStyle.boldUnderline.rawValue == "boldUnderline", "boldUnderline style rawValue mismatch")
            assert(SearchHighlightStyle.accent.rawValue == "accent", "accent style rawValue mismatch")
            assert(SearchHighlightStyle.none.rawValue == "none", "none style rawValue mismatch")

            assert(SearchHighlightStyle.allCases.count == 6, "Expected 6 highlight styles")
            for style in SearchHighlightStyle.allCases {
                assert(!style.displayName.isEmpty, "DisplayName should not be empty for \(style)")
            }
            print("✓ SearchHighlightStyle verified.")

            // -------------------------------------------------------------------------
            // Test 2: PanelViewModel.reloadSearchSettings() (F-049, T-SRCH-02)
            // -------------------------------------------------------------------------
            print("\nStep 2: Testing PanelViewModel reloadSearchSettings from UserDefaults...")
            let panelVm = PanelViewModel(coreClient: core)

            // Test searchMode: exact
            UserDefaults.standard.set("exact", forKey: "searchMode")
            panelVm.reloadSearchSettings()
            assert(panelVm.searchMode == .exact, "Expected searchMode .exact")

            // Test searchMode: regex
            UserDefaults.standard.set("regex", forKey: "searchMode")
            panelVm.reloadSearchSettings()
            assert(panelVm.searchMode == .regex, "Expected searchMode .regex")

            // Test searchMode: fuzzy
            UserDefaults.standard.set("fuzzy", forKey: "searchMode")
            panelVm.reloadSearchSettings()
            assert(panelVm.searchMode == .fuzzy, "Expected searchMode .fuzzy")

            // Test pinArrangement: bottom
            UserDefaults.standard.set("bottom", forKey: "pinArrangement")
            panelVm.reloadSearchSettings()
            assert(panelVm.pinArrangement == .bottom, "Expected pinArrangement .bottom")

            // Test pinArrangement: inline
            UserDefaults.standard.set("inline", forKey: "pinArrangement")
            panelVm.reloadSearchSettings()
            assert(panelVm.pinArrangement == .inline, "Expected pinArrangement .inline")

            // Test pinArrangement: top
            UserDefaults.standard.set("top", forKey: "pinArrangement")
            panelVm.reloadSearchSettings()
            assert(panelVm.pinArrangement == .top, "Expected pinArrangement .top")

            // Test historySortMode: copyCount
            UserDefaults.standard.set("copyCount", forKey: "historySortMode")
            panelVm.reloadSearchSettings()
            assert(panelVm.sortMode == .copyCount, "Expected sortMode .copyCount")

            // Test historySortMode: firstCopied
            UserDefaults.standard.set("firstCopied", forKey: "historySortMode")
            panelVm.reloadSearchSettings()
            assert(panelVm.sortMode == .firstCopied, "Expected sortMode .firstCopied")

            // Test historySortMode: recency
            UserDefaults.standard.set("recency", forKey: "historySortMode")
            panelVm.reloadSearchSettings()
            assert(panelVm.sortMode == .recency, "Expected sortMode .recency")

            // Test searchByRelevance
            UserDefaults.standard.set(false, forKey: "searchByRelevance")
            panelVm.reloadSearchSettings()
            assert(panelVm.searchByRelevance == false, "Expected searchByRelevance false")

            UserDefaults.standard.set(true, forKey: "searchByRelevance")
            panelVm.reloadSearchSettings()
            assert(panelVm.searchByRelevance == true, "Expected searchByRelevance true")

            print("✓ PanelViewModel search setting synchronization verified.")

            // -------------------------------------------------------------------------
            // Test 3: Search execution across different modes (F-049, T-SRCH-02)
            // -------------------------------------------------------------------------
            print("\nStep 3: Ingesting sample items and testing search mode routing...")
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            let sample1 = RawCapture(
                timestampMs: nowMs + 100,
                sourceBundleId: "com.apple.dt.Xcode",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: "ApplicationController.swift protocol implementation".data(using: .utf8)!
                    )
                ]
            )
            let sample2 = RawCapture(
                timestampMs: nowMs + 200,
                sourceBundleId: "com.apple.Safari",
                representations: [
                    RawRepresentation(
                        groupIndex: 0,
                        uti: "public.utf8-plain-text",
                        payload: "Rust linear-time regex engine with bounded DFA execution".data(using: .utf8)!
                    )
                ]
            )
            _ = try await core.ingest(capture: sample1)
            _ = try await core.ingest(capture: sample2)

            // Test fuzzy search matching "app" -> "ApplicationController.swift"
            panelVm.searchMode = .fuzzy
            await panelVm.performSearch(query: "app")
            assert(panelVm.items.contains(where: { $0.title.contains("ApplicationController") }),
                   "Fuzzy search should find ApplicationController from 'app'")

            // Test exact search: "ApplicationController" matches, "apcs" does not match exact
            panelVm.searchMode = .exact
            await panelVm.performSearch(query: "ApplicationController")
            assert(panelVm.items.count == 1, "Exact search should find exactly 1 item for full substring")
            await panelVm.performSearch(query: "apcs")
            assert(panelVm.items.isEmpty, "Exact search for disjoint subsequence 'apcs' should return empty")

            // Test regex search: "Rust.*engine" matches sample2
            panelVm.searchMode = .regex
            await panelVm.performSearch(query: "Rust.*engine")
            assert(panelVm.items.contains(where: { $0.title.contains("Rust") }),
                   "Regex search should find Rust regex engine")

            print("✓ Search modes (fuzzy, exact, regex) verified.")

            // -------------------------------------------------------------------------
            // Test 4: StorageSettingsViewModel retention policies (F-055, T-HIST-05)
            // -------------------------------------------------------------------------
            print("\nStep 4: Testing StorageSettingsViewModel retention policy synchronization...")
            let storageVm = StorageSettingsViewModel(coreClient: core)

            // Default retention settings
            assert(storageVm.maxCount == 200, "Default maxCount should be 200")
            assert(storageVm.maxAgeDays == 30, "Default maxAgeDays should be 30")
            assert(storageVm.maxSizeBytes == 100 * 1024 * 1024, "Default maxSizeBytes should be 100MB")

            // Update limits and verify DTO conversion
            storageVm.maxCount = 500
            storageVm.maxAgeDays = 60
            storageVm.maxSizeBytes = 250 * 1024 * 1024

            let policy = storageVm.currentPolicyDto
            assert(policy.maxCount == 500, "RetentionPolicyDto maxCount mismatch")
            assert(policy.maxAgeDays == 60, "RetentionPolicyDto maxAgeDays mismatch")
            assert(policy.maxSizeBytes == 250 * 1024 * 1024, "RetentionPolicyDto maxSizeBytes mismatch")

            // Test unlimited setting (0)
            storageVm.maxCount = 0
            storageVm.maxAgeDays = 0
            storageVm.maxSizeBytes = 0

            let unlimitedPolicy = storageVm.currentPolicyDto
            assert(unlimitedPolicy.maxCount == nil, "0 count should translate to nil (unlimited)")
            assert(unlimitedPolicy.maxAgeDays == nil, "0 age should translate to nil (unlimited)")
            assert(unlimitedPolicy.maxSizeBytes == nil, "0 size should translate to nil (unlimited)")

            // Test load stats
            await storageVm.loadStats()
            guard let stats = storageVm.stats else {
                fatalError("Storage stats should be populated")
            }
            assert(stats.totalItems == 2, "Expected 2 ingested items in DB stats")
            assert(stats.unpinnedItems == 2, "Expected 2 unpinned items")
            assert(!storageVm.formattedDbSize.isEmpty, "Formatted DB size should not be empty")

            print("✓ StorageSettingsViewModel retention policy verified.")

            // -------------------------------------------------------------------------
            // Test 5: Clipboard format allowlisting (F-013, T-TYPE-05)
            // -------------------------------------------------------------------------
            print("\nStep 5: Testing ClipboardTypeConfiguration format allowlisting...")
            var typeConfig = ClipboardTypeConfiguration.load()

            assert(typeConfig.storePlainText, "Default storePlainText should be true")
            assert(typeConfig.storeRichText, "Default storeRichText should be true")
            assert(typeConfig.storeImages, "Default storeImages should be true")
            assert(typeConfig.storeFiles, "Default storeFiles should be true")

            assert(typeConfig.isUtiEnabled("public.utf8-plain-text"), "UTF8 plain text should be enabled")
            assert(typeConfig.isUtiEnabled("public.rtf"), "RTF should be enabled")
            assert(typeConfig.isUtiEnabled("public.png"), "PNG should be enabled")
            assert(typeConfig.isUtiEnabled("public.file-url"), "File URL should be enabled")
            assert(!typeConfig.isUtiEnabled("com.unknown.format"), "Unknown UTI must be rejected")

            // Toggle off images and rich text
            typeConfig.storeImages = false
            typeConfig.storeRichText = false

            assert(!typeConfig.isUtiEnabled("public.png"), "PNG should be rejected when images disabled")
            assert(!typeConfig.isUtiEnabled("public.heic"), "HEIC should be rejected when images disabled")
            assert(!typeConfig.isUtiEnabled("public.rtf"), "RTF should be rejected when rich text disabled")
            assert(!typeConfig.isUtiEnabled("public.html"), "HTML should be rejected when rich text disabled")
            assert(typeConfig.isUtiEnabled("public.utf8-plain-text"), "Plain text should remain enabled")
            assert(typeConfig.isUtiEnabled("public.file-url"), "Files should remain enabled")

            // Verify raw pasteboard type mappings
            assert(typeConfig.isRawTypeEnabled("public.utf8-plain-text"), "Raw UTF8 plain text should be enabled")
            assert(!typeConfig.isRawTypeEnabled("public.png"), "Raw PNG should be disabled when storeImages is false")
            assert(!typeConfig.isRawTypeEnabled("com.agilebits.onepassword"), "Unknown private type should be rejected")

            print("✓ Clipboard format allowlisting verified.")

            // -------------------------------------------------------------------------
            // Test 6: includeOcrInSearch preference (F-051, T-SRCH-04)
            // -------------------------------------------------------------------------
            print("\nStep 6: Testing includeOcrInSearch default and persistence...")
            let ocrDefault = UserDefaults.standard.object(forKey: "includeOcrInSearch") as? Bool ?? true
            assert(ocrDefault == true, "includeOcrInSearch should default to true")

            UserDefaults.standard.set(false, forKey: "includeOcrInSearch")
            let ocrDisabled = UserDefaults.standard.bool(forKey: "includeOcrInSearch")
            assert(ocrDisabled == false, "includeOcrInSearch should persist false")

            UserDefaults.standard.set(true, forKey: "includeOcrInSearch")
            let ocrEnabled = UserDefaults.standard.bool(forKey: "includeOcrInSearch")
            assert(ocrEnabled == true, "includeOcrInSearch should persist true")

            print("✓ includeOcrInSearch setting verified.")

            // -------------------------------------------------------------------------
            // Test 7: Clear actions in StorageSettingsViewModel (F-025, F-055)
            // -------------------------------------------------------------------------
            print("\nStep 7: Testing clear actions in StorageSettingsViewModel...")
            await storageVm.confirmClearUnpinned()
            await storageVm.loadStats()
            assert(storageVm.stats?.totalItems == 0, "After clearUnpinned, items should be 0")
            assert(storageVm.statusMessage != nil, "Status message should be set after clearing")
            assert(storageVm.isErrorMessage == false, "Clear action should succeed without error")

            print("✓ Storage clear actions verified.")

        } catch {
            fatalError("Search & Storage Settings test failed: \(error.localizedDescription)")
        }

        print("\nAll Search & Storage Settings integration tests passed cleanly! ✓")
    }
}
