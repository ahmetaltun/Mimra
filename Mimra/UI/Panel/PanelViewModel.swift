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
    @Published public var selectedIndex: Int = 0 {
        didSet {
            if oldValue != selectedIndex {
                onSelectionChanged?(selectedItem)
            }
        }
    }
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

    /// Currently active item being edited in preview, or nil if no item is being edited (P5-04 / F-045).
    @Published public var editingPinItem: HistoryItemSummaryDto? = nil
    /// Working text for active pin editing.
    @Published public var editingPinText: String = ""

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

    /// Configured maximum history limit (default 200, bounded between 10 and 2000).
    public var historyLimit: UInt32 {
        let count = UserDefaults.standard.object(forKey: "retentionMaxCount") as? Int ?? 200
        return UInt32(max(10, min(2000, count > 0 ? count : 2000)))
    }

    public var onCommitItem: ((HistoryItemSummaryDto, PasteMode, Bool?) -> Void)?
    public var onDismiss: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onSelectionChanged: ((HistoryItemSummaryDto?) -> Void)?

    public init(coreClient: CoreClient) {
        self.coreClient = coreClient
        reloadSearchSettings()
    }

    /// Synchronizes active search algorithm, sort mode, and pin placement from UserDefaults (P7-03 / F-049).
    public func reloadSearchSettings() {
        if let modeStr = UserDefaults.standard.string(forKey: "searchMode") {
            switch modeStr {
            case "exact": self.searchMode = .exact
            case "regex": self.searchMode = .regex
            default: self.searchMode = .fuzzy
            }
        }
        if let pinArr = UserDefaults.standard.string(forKey: "pinArrangement") {
            switch pinArr {
            case "bottom": self.pinArrangement = .bottom
            case "inline": self.pinArrangement = .inline
            default: self.pinArrangement = .top
            }
        }
        if let sortMode = UserDefaults.standard.string(forKey: "historySortMode") {
            switch sortMode {
            case "copyCount": self.sortMode = .copyCount
            case "firstCopied": self.sortMode = .firstCopied
            default: self.sortMode = .recency
            }
        }
        if UserDefaults.standard.object(forKey: "searchByRelevance") != nil {
            self.searchByRelevance = UserDefaults.standard.bool(forKey: "searchByRelevance")
        }
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

    /// Returns true if any displayed item is pinned.
    public var hasPinnedItems: Bool {
        filteredItems.contains(where: { $0.isPinned })
    }

    /// Returns true if any displayed item is unpinned.
    public var hasUnpinnedItems: Bool {
        filteredItems.contains(where: { !$0.isPinned })
    }

    /// Returns true if the displayed list contains both pinned and unpinned items (F-036 / T-UI-10).
    public var hasMixedPinnedAndUnpinned: Bool {
        hasPinnedItems && hasUnpinnedItems
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
    /// Maps directly to the visible filtered order (Definition of Done: P5-05 / F-022, T-KEY-01).
    /// Returns true if an item was successfully picked and committed, false if out of bounds or invalid.
    @discardableResult
    public func quickPick(number: Int, mode: PasteMode = .original, forcePaste: Bool? = nil) -> Bool {
        guard number >= 1 && number <= 9 else { return false }
        let targetIndex = number - 1
        let list = filteredItems
        guard targetIndex < list.count else { return false }
        selectedIndex = targetIndex
        selectedItemId = list[targetIndex].id
        commitSelection(mode: mode, forcePaste: forcePaste)
        return true
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

    /// Toggles the pin status of the currently selected item while preserving selection stability (P5-01 / F-020, F-024).
    public func togglePinSelectedItem() async -> Bool {
        guard let item = selectedItem else { return false }
        return await togglePin(for: item)
    }

    /// Toggles the pin status for an item while preserving selection stability (P5-01 / F-020, F-024).
    public func togglePin(for item: HistoryItemSummaryDto) async -> Bool {
        do {
            _ = try await coreClient.togglePin(itemId: item.id)

            // Refresh items list while preserving selection on item.id
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let loaded = try await coreClient.listPageWithSort(
                    sortMode: self.sortMode,
                    pinArrangement: self.pinArrangement,
                    limit: self.historyLimit,
                    offset: 0
                )
                applyItemsPreservingSelection(loaded)
            } else {
                let effectiveMode = searchMode == .fuzzy && (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2)
                    ? SearchMode.exact
                    : searchMode
                let results = try await coreClient.searchPageWithOptions(
                    query: trimmed,
                    mode: effectiveMode,
                    sortByRelevance: self.searchByRelevance,
                    pinArrangement: self.pinArrangement,
                    limit: self.historyLimit,
                    offset: 0
                )
                applyItemsPreservingSelection(results)
            }

            let loadedStats = try await coreClient.getStats()
            self.stats = loadedStats
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// Reorders pinned items in SQLite storage according to the given array of UUIDs (P5-03 / F-046, T-PIN-03).
    public func reorderPins(orderedIds: [String]) async -> Bool {
        do {
            try await coreClient.reorderPins(orderedIds: orderedIds)

            // Reload data while preserving active selection
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let loaded = try await coreClient.listPageWithSort(
                    sortMode: self.sortMode,
                    pinArrangement: self.pinArrangement,
                    limit: self.historyLimit,
                    offset: 0
                )
                applyItemsPreservingSelection(loaded)
            } else {
                let effectiveMode = searchMode == .fuzzy && (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2)
                    ? SearchMode.exact
                    : searchMode
                let results = try await coreClient.searchPageWithOptions(
                    query: trimmed,
                    mode: effectiveMode,
                    sortByRelevance: self.searchByRelevance,
                    pinArrangement: self.pinArrangement,
                    limit: self.historyLimit,
                    offset: 0
                )
                applyItemsPreservingSelection(results)
            }
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// Moves a pinned item from source ID position to target ID position (Drag & Drop, P5-03 / F-046).
    public func movePin(sourceId: String, targetId: String) async -> Bool {
        guard sourceId != targetId else { return true }
        var pinned = items.filter { $0.isPinned }
        guard let fromIndex = pinned.firstIndex(where: { $0.id == sourceId }),
              let toIndex = pinned.firstIndex(where: { $0.id == targetId }) else {
            return false
        }

        let movedItem = pinned.remove(at: fromIndex)
        pinned.insert(movedItem, at: toIndex)

        return await reorderPins(orderedIds: pinned.map { $0.id })
    }

    /// Moves the currently selected pinned item UP one position (Keyboard ⌥⌘↑ alternative, P5-03 / F-046).
    public func moveSelectedPinUp() async -> Bool {
        guard let item = selectedItem, item.isPinned else { return false }
        return await movePinUp(item: item)
    }

    /// Moves the currently selected pinned item DOWN one position (Keyboard ⌥⌘↓ alternative, P5-03 / F-046).
    public func moveSelectedPinDown() async -> Bool {
        guard let item = selectedItem, item.isPinned else { return false }
        return await movePinDown(item: item)
    }

    /// Moves a specific pinned item UP one position among pinned items (P5-03 / F-046).
    public func movePinUp(item: HistoryItemSummaryDto) async -> Bool {
        guard item.isPinned else { return false }
        var pinned = items.filter { $0.isPinned }
        guard let currentIndex = pinned.firstIndex(where: { $0.id == item.id }), currentIndex > 0 else {
            return false
        }

        pinned.swapAt(currentIndex, currentIndex - 1)
        return await reorderPins(orderedIds: pinned.map { $0.id })
    }

    /// Moves a specific pinned item DOWN one position among pinned items (P5-03 / F-046).
    public func movePinDown(item: HistoryItemSummaryDto) async -> Bool {
        guard item.isPinned else { return false }
        var pinned = items.filter { $0.isPinned }
        guard let currentIndex = pinned.firstIndex(where: { $0.id == item.id }), currentIndex < pinned.count - 1 else {
            return false
        }

        pinned.swapAt(currentIndex, currentIndex + 1)
        return await reorderPins(orderedIds: pinned.map { $0.id })
    }

    /// Sets or removes a custom pin shortcut key for an item (P5-02 / F-024, T-PIN-01).
    /// Enforces single-character punctuation/symbol/alphanumeric rules and detects conflicts.
    public func setPinKey(for item: HistoryItemSummaryDto, key: String?) async -> Bool {
        do {
            try await coreClient.setPin(
                itemId: item.id,
                isPinned: true,
                pinKey: key,
                pinOrder: item.pinOrder
            )

            // Refresh items list while preserving active selection
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let loaded = try await coreClient.listPageWithSort(
                    sortMode: self.sortMode,
                    pinArrangement: self.pinArrangement,
                    limit: self.historyLimit,
                    offset: 0
                )
                applyItemsPreservingSelection(loaded)
            } else {
                let effectiveMode = searchMode == .fuzzy && (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2)
                    ? SearchMode.exact
                    : searchMode
                let results = try await coreClient.searchPageWithOptions(
                    query: trimmed,
                    mode: effectiveMode,
                    sortByRelevance: self.searchByRelevance,
                    pinArrangement: self.pinArrangement,
                    limit: self.historyLimit,
                    offset: 0
                )
                applyItemsPreservingSelection(results)
            }
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// Prepares a pinned item for editing by fetching its full plain-text payload (P5-04 / F-045, T-PIN-02).
    public func startEditing(item: HistoryItemSummaryDto) async {
        guard item.isPinned else { return }
        if let payloadData = try? await coreClient.fetchPayload(itemId: item.id, uti: "public.utf8-plain-text"),
           let fullText = String(data: payloadData, encoding: .utf8) {
            self.editingPinText = fullText
        } else {
            self.editingPinText = item.snippet.isEmpty ? item.title : item.snippet
        }
        self.editingPinItem = item
    }

    /// Cancels active pin editing without saving changes.
    public func cancelEditing() {
        self.editingPinItem = nil
        self.editingPinText = ""
    }

    /// Commits the edited pin text to SQLite storage and FTS5 search index (P5-04 / F-045, T-PIN-02).
    public func commitEditing() async -> Bool {
        guard let item = editingPinItem else { return false }
        let trimmed = editingPinText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.errorMessage = "Pinned item text cannot be empty."
            return false
        }

        let success = await editPinText(item: item, newText: trimmed)
        if success {
            self.editingPinItem = nil
            self.editingPinText = ""
        }
        return success
    }

    /// Edits the text content of a pinned item in SQLite storage and updates live search views (P5-04 / F-045, T-PIN-02).
    public func editPinText(item: HistoryItemSummaryDto, newText: String) async -> Bool {
        guard item.isPinned else { return false }
        do {
            _ = try await coreClient.editPinnedItemText(itemId: item.id, newText: newText)

            // Refresh items list to re-query with new content and updated FTS index
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let loaded = try await coreClient.listPageWithSort(
                    sortMode: self.sortMode,
                    pinArrangement: self.pinArrangement,
                    limit: self.historyLimit,
                    offset: 0
                )
                applyItemsPreservingSelection(loaded)
            } else {
                let effectiveMode = searchMode == .fuzzy && (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2)
                    ? SearchMode.exact
                    : searchMode
                let results = try await coreClient.searchPageWithOptions(
                    query: trimmed,
                    mode: effectiveMode,
                    sortByRelevance: self.searchByRelevance,
                    pinArrangement: self.pinArrangement,
                    limit: self.historyLimit,
                    offset: 0
                )
                applyItemsPreservingSelection(results)
            }
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// Deletes an item by UUID from SQLite storage while maintaining selection stability (T-KEY-03).
    /// Cancels any in-flight OCR recognition for this item immediately (P6-07 / T-SRCH-04).
    public func deleteItem(itemId: String) async -> Bool {
        await OCRService.shared.cancel(itemId: itemId)
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

    /// Clears unpinned items, cancels all pending OCR tasks, and refreshes the panel items.
    @discardableResult
    public func clearUnpinned() async -> UInt64 {
        await OCRService.shared.cancelAll()
        if UserDefaults.standard.bool(forKey: "clearSystemClipboard") {
            NSPasteboard.general.clearContents()
        }
        do {
            let count = try await coreClient.clearUnpinned()
            await loadData()
            return count
        } catch {
            self.errorMessage = error.localizedDescription
            return 0
        }
    }

    /// Clears all history items, cancels all pending OCR tasks, and refreshes the panel items.
    @discardableResult
    public func clearAll() async -> UInt64 {
        await OCRService.shared.cancelAll()
        if UserDefaults.standard.bool(forKey: "clearSystemClipboard") {
            NSPasteboard.general.clearContents()
        }
        do {
            let count = try await coreClient.clearAll()
            await loadData()
            return count
        } catch {
            self.errorMessage = error.localizedDescription
            return 0
        }
    }

    /// Loads history items and stats from SQLite via CoreClient actor with active sort and pin arrangement.
    public func loadData() async {
        isLoading = true
        do {
            let loaded = try await coreClient.listPageWithSort(
                sortMode: self.sortMode,
                pinArrangement: self.pinArrangement,
                limit: self.historyLimit,
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
        limit: UInt32? = nil,
        offset: UInt32 = 0
    ) async {
        searchGeneration += 1
        let currentGen = searchGeneration
        let effectiveMode = mode ?? self.searchMode
        let effectiveLimit = limit ?? self.historyLimit
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        isLoading = true
        regexErrorMessage = nil

        do {
            if trimmed.isEmpty {
                let loaded = try await coreClient.listPageWithSort(
                    sortMode: self.sortMode,
                    pinArrangement: self.pinArrangement,
                    limit: effectiveLimit,
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
                    limit: effectiveLimit,
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
