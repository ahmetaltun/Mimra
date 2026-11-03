// ==============================================================================
// Mimra — Panel View Model
// State management, keyboard navigation, search filtering, and selection logic.
// Linked Features: F-019
// Test IDs: T-UI-03
// ==============================================================================

import AppKit
import Foundation
import QuartzCore

@MainActor
public final class PanelViewModel: ObservableObject {
    public let coreClient: CoreClient

    @Published public var searchText: String = "" {
        didSet {
            // Reset selection to top row only when search filter actually changes
            if oldValue != searchText {
                selectedIndex = 0
            }
        }
    }
    @Published public var items: [HistoryItemSummaryDto] = []
    @Published public var selectedIndex: Int = 0
    @Published public var isLoading: Bool = false
    @Published public var stats: StorageStatsDto?
    @Published public var errorMessage: String?
    @Published public var searchMode: SearchMode = .fuzzy {
        didSet {
            if oldValue != searchMode {
                regexErrorMessage = nil
            }
        }
    }
    @Published public var regexErrorMessage: String?

    /// Monotonically increasing counter to discard stale asynchronous search results.
    public private(set) var searchGeneration: UInt64 = 0

    /// Timestamp of last keyboard navigation to guard against accidental mouse-hover overrides.
    public private(set) var lastKeyboardNavTime: CFTimeInterval = 0

    public var onCommitItem: ((HistoryItemSummaryDto, PasteMode, Bool?) -> Void)?
    public var onDismiss: (() -> Void)?
    public var onOpenSettings: (() -> Void)?

    public init(coreClient: CoreClient) {
        self.coreClient = coreClient
    }

    /// Items filtered in real-time by search text matching title or snippet.
    public var filteredItems: [HistoryItemSummaryDto] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return items
        }
        return items.filter { item in
            item.title.lowercased().contains(query) ||
            item.snippet.lowercased().contains(query)
        }
    }

    /// Currently highlighted item in the filtered list.
    public var selectedItem: HistoryItemSummaryDto? {
        let list = filteredItems
        guard !list.isEmpty, selectedIndex >= 0, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    /// Move selection down (wraps around when reaching the bottom).
    public func selectNext() {
        let count = filteredItems.count
        guard count > 0 else { return }
        lastKeyboardNavTime = CACurrentMediaTime()
        selectedIndex = (selectedIndex + 1) % count
    }

    /// Move selection up (wraps around to the bottom when at index 0).
    public func selectPrevious() {
        let count = filteredItems.count
        guard count > 0 else { return }
        lastKeyboardNavTime = CACurrentMediaTime()
        if selectedIndex <= 0 {
            selectedIndex = count - 1
        } else {
            selectedIndex -= 1
        }
    }

    /// Set selection index directly with optional hover guard.
    public func selectIndex(_ index: Int, fromHover: Bool = false) {
        if fromHover {
            // Accidental hover guard: ignore hover events occurring within 250ms of keyboard navigation
            let elapsed = CACurrentMediaTime() - lastKeyboardNavTime
            guard elapsed > 0.25 else { return }
        }
        let count = filteredItems.count
        guard index >= 0, index < count else { return }
        selectedIndex = index
    }

    /// Quick-pick shortcut selection (1-9).
    public func quickPick(number: Int, mode: PasteMode = .original, forcePaste: Bool? = nil) {
        guard number >= 1 && number <= 9 else { return }
        let targetIndex = number - 1
        let list = filteredItems
        if targetIndex < list.count {
            selectedIndex = targetIndex
            commitSelection(mode: mode, forcePaste: forcePaste)
        }
    }

    /// Commits the currently selected item (triggers paste or copy action).
    public func commitSelection(mode: PasteMode = .original, forcePaste: Bool? = nil) {
        guard let item = selectedItem else { return }
        onCommitItem?(item, mode, forcePaste)
        onDismiss?()
    }

    /// Loads history items and stats from SQLite via CoreClient actor.
    public func loadData() async {
        isLoading = true
        do {
            let loaded = try await coreClient.listPage(limit: 100, offset: 0)
            let loadedStats = try await coreClient.getStats()
            self.items = loaded
            self.stats = loadedStats
            self.isLoading = false
            // Ensure selection stays within valid bounds
            if selectedIndex >= filteredItems.count {
                selectedIndex = max(0, filteredItems.count - 1)
            }
        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }

    /// Performs search against the SQLite engine via CoreClient under the active or specified SearchMode.
    /// Discards stale query results if a newer keystroke has already fired.
    public func performSearch(
        query: String,
        mode: SearchMode? = nil,
        limit: UInt32 = 100,
        offset: UInt32 = 0
    ) async {
        searchGeneration += 1
        let currentGen = searchGeneration
        let effectiveMode = mode ?? self.searchMode
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        isLoading = true
        regexErrorMessage = nil

        do {
            if trimmed.isEmpty {
                let loaded = try await coreClient.listPage(limit: limit, offset: offset)
                guard currentGen == self.searchGeneration else { return }
                self.items = loaded
            } else {
                let results = try await coreClient.searchPage(
                    query: trimmed,
                    mode: effectiveMode,
                    limit: limit,
                    offset: offset
                )
                guard currentGen == self.searchGeneration else { return }
                self.items = results
            }
            self.selectedIndex = 0
            self.isLoading = false
        } catch let CoreError.InvalidRegex(pattern: _, errorMessage: errorMsg) {
            guard currentGen == self.searchGeneration else { return }
            self.regexErrorMessage = errorMsg
            self.items = []
            self.selectedIndex = 0
            self.isLoading = false
        } catch {
            guard currentGen == self.searchGeneration else { return }
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }
}
