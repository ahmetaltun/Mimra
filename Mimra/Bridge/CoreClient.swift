// ==============================================================================
// Mimra — CoreClient Actor (Swift <-> Rust Bridge Worker)
// Off-main actor managing the RustCore database handle via UniFFI.
// Enforces strict concurrency safety under Swift 6.
// Linked Features: F-001, F-002, F-003, F-052
// Test IDs: T-CAP-01, T-CAP-02, T-HIST-02
// ==============================================================================

import Foundation
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "CoreClient")

// MimraCoreHandle wraps a Rust Mutex<Connection>, making it thread-safe.
extension MimraCoreHandle: @unchecked Sendable {}
extension IngestResultDto: @unchecked Sendable {}
extension HistoryItemSummaryDto: @unchecked Sendable {}
extension StorageStatsDto: @unchecked Sendable {}
extension RawRepresentation: @unchecked Sendable {}
extension RawCapture: @unchecked Sendable {}
extension HighlightRangeDto: @unchecked Sendable {}
extension SearchMode: @unchecked Sendable {}
extension HistorySortMode: @unchecked Sendable {}
extension PinArrangement: @unchecked Sendable {}
extension RetentionPolicyDto: @unchecked Sendable {}
extension CleanupReportDto: @unchecked Sendable {}

extension HistoryItemSummaryDto {
    /// Backward-compatible initializer for tests without explicit highlights.
    public init(
        id: String,
        contentKind: String,
        title: String,
        snippet: String,
        isPinned: Bool,
        pinOrder: UInt32?,
        pinKey: String?,
        sourceBundleId: String?,
        firstCopiedAtMs: Int64,
        lastCopiedAtMs: Int64,
        copyCount: UInt32,
        byteSize: UInt64,
        availableUtis: [String]
    ) {
        self.init(
            id: id,
            contentKind: contentKind,
            title: title,
            snippet: snippet,
            isPinned: isPinned,
            pinOrder: pinOrder,
            pinKey: pinKey,
            sourceBundleId: sourceBundleId,
            firstCopiedAtMs: firstCopiedAtMs,
            lastCopiedAtMs: lastCopiedAtMs,
            copyCount: copyCount,
            byteSize: byteSize,
            availableUtis: availableUtis,
            titleHighlights: [],
            snippetHighlights: []
        )
    }
}

/// Actor managing the connection to the RustCore SQLite engine.
public actor CoreClient {
    private let handle: MimraCoreHandle
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _shared: CoreClient?

    /// Shared singleton instance for application components.
    public static var shared: CoreClient {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _shared {
            return existing
        }
        do {
            let client = try CoreClient()
            _shared = client
            return client
        } catch {
            fatalError("Failed to initialize default CoreClient: \(error)")
        }
    }

    /// Overrides the shared CoreClient instance (e.g. for testing).
    public static func setSharedInstance(_ client: CoreClient) {
        lock.lock()
        defer { lock.unlock() }
        _shared = client
    }

    /// Standard database directory in Application Support.
    public static var defaultDatabasePath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        let mimraDir = appSupport.appendingPathComponent("com.mimra.app", isDirectory: true)

        // Ensure directory exists with 0700 permissions (privacy first)
        if !FileManager.default.fileExists(atPath: mimraDir.path) {
            try? FileManager.default.createDirectory(
                at: mimraDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        return mimraDir.appendingPathComponent("mimra.sqlite").path
    }

    /// Private initializer wrapping an existing handle.
    private init(handle: MimraCoreHandle) {
        self.handle = handle
    }

    /// Initializes a CoreClient with a SQLite database at the specified path (or default path).
    public init(databasePath: String? = nil) throws {
        let path = databasePath ?? Self.defaultDatabasePath
        logger.info("Opening MimraCoreHandle at path: \(path, privacy: .public)")
        self.handle = try MimraCoreHandle.open(dbPath: path)
    }

    /// Creates an in-memory CoreClient instance, ideal for testing and ephemeral sessions.
    public static func inMemory() throws -> CoreClient {
        let handle = try MimraCoreHandle.openInMemory()
        return CoreClient(handle: handle)
    }

    // MARK: - API Forwarding to RustCore

    /// Ingests a new clipboard capture into the database.
    public func ingest(capture: RawCapture) throws -> IngestResultDto {
        return try handle.ingest(capture: capture)
    }

    /// Lists a paginated slice of history items.
    public func listPage(limit: UInt32 = 50, offset: UInt32 = 0) throws -> [HistoryItemSummaryDto] {
        return try handle.listPage(limit: limit, offset: offset)
    }

    /// Returns a paginated list of history item summaries with configurable sort order and pinned arrangement.
    public func listPageWithSort(
        sortMode: HistorySortMode = .recency,
        pinArrangement: PinArrangement = .top,
        limit: UInt32 = 50,
        offset: UInt32 = 0
    ) throws -> [HistoryItemSummaryDto] {
        return try handle.listPageWithSort(
            sortMode: sortMode,
            pinArrangement: pinArrangement,
            limit: limit,
            offset: offset
        )
    }

    /// Searches history items using SQLite FTS5, deterministic fuzzy ranker, or bounded regex.
    public func searchPage(
        query: String,
        mode: SearchMode = .fuzzy,
        limit: UInt32 = 50,
        offset: UInt32 = 0
    ) throws -> [HistoryItemSummaryDto] {
        return try handle.searchPage(query: query, mode: mode, limit: limit, offset: offset)
    }

    /// Searches history items with explicit relevance sorting and pinned arrangement.
    public func searchPageWithOptions(
        query: String,
        mode: SearchMode = .fuzzy,
        sortByRelevance: Bool = true,
        pinArrangement: PinArrangement = .top,
        limit: UInt32 = 50,
        offset: UInt32 = 0
    ) throws -> [HistoryItemSummaryDto] {
        return try handle.searchPageWithOptions(
            query: query,
            mode: mode,
            sortByRelevance: sortByRelevance,
            pinArrangement: pinArrangement,
            limit: limit,
            offset: offset
        )
    }

    /// Rebuilds the FTS5 virtual search index.
    public func rebuildSearchIndex() throws {
        try handle.rebuildSearchIndex()
    }

    /// Checks FTS5 virtual search index integrity against the history_items table.
    public func checkSearchIndexIntegrity() throws -> Bool {
        return try handle.checkSearchIndexIntegrity()
    }

    /// Fetches the raw byte payload for a specific representation of an item.
    public func fetchPayload(itemId: String, uti: String) throws -> Data? {
        return try handle.fetchPayload(itemId: itemId, uti: uti)
    }

    /// Fetches all stored representations for a given history item.
    public func getItemRepresentations(itemId: String) throws -> [RawRepresentation] {
        return try handle.getItemRepresentations(itemId: itemId)
    }

    /// Deletes a history item by UUID.
    public func deleteItem(itemId: String) throws -> Bool {
        return try handle.deleteItem(itemId: itemId)
    }

    /// Clears all unpinned history items from the database.
    public func clearUnpinned() throws -> UInt64 {
        return try handle.clearUnpinned()
    }

    /// Clears all history items (pinned and unpinned) from the database.
    public func clearAll() throws -> UInt64 {
        return try handle.clearAll()
    }

    /// Sets or clears the pin state of an item.
    public func setPin(
        itemId: String,
        isPinned: Bool,
        pinKey: String? = nil,
        pinOrder: UInt32? = nil
    ) throws {
        try handle.setPin(itemId: itemId, isPinned: isPinned, pinKey: pinKey, pinOrder: pinOrder)
    }

    /// Sets the maximum number of unpinned items retained before eviction.
    public func setMaxUnpinned(limit: UInt32) {
        handle.setMaxUnpinned(limit: limit)
    }

    /// Configures the multi-dimensional history retention policy (count, age, size).
    public func setRetentionPolicy(policy: RetentionPolicyDto) {
        handle.setRetentionPolicy(policy: policy)
    }

    /// Queries the currently configured retention policy.
    public func getRetentionPolicy() -> RetentionPolicyDto {
        return handle.getRetentionPolicy()
    }

    /// Manually triggers retention policy enforcement across the database.
    public func enforceRetention(policy: RetentionPolicyDto? = nil) throws -> CleanupReportDto {
        return try handle.enforceRetention(policy: policy)
    }

    /// Flushes WAL pages back into the main database and truncates the WAL file.
    public func checkpointWal() throws -> UInt32 {
        return try handle.checkpointWal()
    }

    /// Reclaims unused freelist disk pages.
    public func vacuumDatabase() throws {
        try handle.vacuumDatabase()
    }

    /// Queries current storage usage statistics.
    public func getStats() throws -> StorageStatsDto {
        return try handle.getStats()
    }
}
