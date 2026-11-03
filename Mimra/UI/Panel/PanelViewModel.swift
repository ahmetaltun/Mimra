// ==============================================================================
// Mimra — Panel View Model
// State management, keyboard navigation, search filtering, sorting, and selection logic.
// Linked Features: F-019, F-024, F-048, F-050, F-054
// Test IDs: T-UI-03, T-KEY-03, T-SRCH-01, T-SRCH-02
// ==============================================================================

import AppKit
import Foundation
import QuartzCore

@MainActor
public final class PanelViewModel: ObservableObject {
    public let coreClient: CoreClient

    @Published public var searchText: String = "" {
        didSet {
            if oldValue != searchText {
                let targetId = selectedItemId ?? selectedItem?.id
                let list = filteredItems
                if let targetId = targetId,
                   let foundIndex = list.firstIndex(where: { $0.id == targetId }) {
                    selectedIndex = foundIndex
                    selectedItemId = targetId
                } else {
                    selectedIndex = 0
                    selectedItemId = list.first?.id
                }
            }
        }
    }
    @Published public var items: [HistoryItemSummaryDto] = []
    @Published public var selectedIndex: Int = 0
    @Published public var selectedItemId: String?
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

    /// Active sort mode for history items (recency, copy count, or first copied).
    @Published public var sortMode: HistorySortMode = .recency

    /// Active pinned items arrangement (top, bottom, or inline).
    @Published public var pinArrangement: PinArrangement = .top

    /// Whether search results are ranked by relevance (true) or recency (false).
    @Published public var searchByRelevance: Bool = true

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

    /// Applies updated items while preserving the selected item by ID (Definition of Done: P4-04).
    public func applyItemsPreservingSelection(_ newItems: [HistoryItemSummaryDto]) {
        let targetId = selectedItemId ?? selectedItem?.id
        let previousIndex = selectedIndex
        self.items = newItems

        let list = filteredItems
        if list.isEmpty {
            self.selectedIndex = 0
            self.selectedItemId = nil
        } else if let targetId = targetId,
                  let foundIndex = list.firstIndex(where: { $0.id == targetId }) {
            self.selectedIndex = foundIndex
            self.selectedItemId = targetId
        } else {
            let clamped = min(previousIndex, list.count - 1)
            self.selectedIndex = max(0, clamped)
            self.selectedItemId = list[self.selectedIndex].id
        }
    }

    /// Move selection down (wraps around when reaching the bottom).
    public func selectNext() {
        let count = filteredItems.count
        guard count > 0 else { return }
        lastKeyboardNavTime = CACurrentMediaTime()
        selectedIndex = (selectedIndex + 1) % count
        selectedItemId = selectedItem?.id
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
        selectedItemId = selectedItem?.id
    }

    /// Move selection up by a page (T-KEY-03).
    public func selectPageUp(pageSize: Int = 10) {
        let count = filteredItems.count
        guard count > 0 else { return }
        lastKeyboardNavTime = CACurrentMediaTime()
        selectedIndex = max(0, selectedIndex - pageSize)
        selectedItemId = selectedItem?.id
    }

    /// Move selection down by a page (T-KEY-03).
    public func selectPageDown(pageSize: Int = 10) {
        let count = filteredItems.count
        guard count > 0 else { return }
        lastKeyboardNavTime = CACurrentMediaTime()
        selectedIndex = min(count - 1, selectedIndex + pageSize)
        selectedItemId = selectedItem?.id
    }

    /// Selects the first item in the list (Home key).
    public func selectFirst() {
        let count = filteredItems.count
        guard count > 0 else { return }
        lastKeyboardNavTime = CACurrentMediaTime()
        selectedIndex = 0
        selectedItemId = selectedItem?.id
    }

    /// Selects the last item in the list (End key).
    public func selectLast() {
        let count = filteredItems.count
        guard count > 0 else { return }
        lastKeyboardNavTime = CACurrentMediaTime()
        selectedIndex = max(0, count - 1)
        selectedItemId = selectedItem?.id
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
        selectedItemId = selectedItem?.id
    }

    /// Quick-pick shortcut selection (1-9).
    public func quickPick(number: Int, mode: PasteMode = .original, forcePaste: Bool? = nil) {
        guard number >= 1 && number <= 9 else { return }
        let targetIndex = number - 1
        let list = filteredItems
        if targetIndex < list.count {
            selectedIndex = targetIndex
            selectedItemId = list[targetIndex].id
            commitSelection(mode: mode, forcePaste: forcePaste)
        }
    }

    /// Commits the currently selected item (triggers paste or copy action).
    public func commitSelection(mode: PasteMode = .original, forcePaste: Bool? = nil) {
        guard let item = selectedItem else { return }
        onCommitItem?(item, mode, forcePaste)
        onDismiss?()
    }

    /// Deletes the currently selected item from SQLite storage while preserving selection stability.
    public func deleteSelectedItem() async -> Bool {
        guard let item = selectedItem else { return false }
        return await deleteItem(itemId: item.id)
    }

    /// Deletes an item by UUID from SQLite storage while maintaining selection stability (T-KEY-03).
    public func deleteItem(itemId: String) async -> Bool {
        do {
            let deleted = try await coreClient.deleteItem(itemId: itemId)
            if deleted {
                let remaining = items.filter { $0.id != itemId }
                applyItemsPreservingSelection(remaining)
            }
            return deleted
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// Loads history items and stats from SQLite via CoreClient actor with active sort and pin arrangement.
    public func loadData() async {
        isLoading = true
        do {
            let loaded = try await coreClient.listPageWithSort(
                sortMode: self.sortMode,
                pinArrangement: self.pinArrangement,
                limit: 100,
                offset: 0
            )
            let loadedStats = try await coreClient.getStats()
            applyItemsPreservingSelection(loaded)
            self.stats = loadedStats
            self.isLoading = false
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
                let loaded = try await coreClient.listPageWithSort(
                    sortMode: self.sortMode,
                    pinArrangement: self.pinArrangement,
                    limit: limit,
                    offset: offset
                )
                guard currentGen == self.searchGeneration else { return }
                applyItemsPreservingSelection(loaded)
            } else {
                let results = try await coreClient.searchPageWithOptions(
                    query: trimmed,
                    mode: effectiveMode,
                    sortByRelevance: self.searchByRelevance,
                    pinArrangement: self.pinArrangement,
                    limit: limit,
                    offset: offset
                )
                guard currentGen == self.searchGeneration else { return }
                applyItemsPreservingSelection(results)
            }
            self.isLoading = false
        } catch let CoreError.InvalidRegex(pattern: _, errorMessage: errorMsg) {
            guard currentGen == self.searchGeneration else { return }
            self.regexErrorMessage = errorMsg
            applyItemsPreservingSelection([])
            self.isLoading = false
        } catch {
            guard currentGen == self.searchGeneration else { return }
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }
}
