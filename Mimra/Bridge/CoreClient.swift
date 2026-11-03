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

/// Actor managing the connection to the RustCore SQLite engine.
public actor CoreClient {
    private let handle: MimraCoreHandle

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

    /// Fetches the raw byte payload for a specific representation of an item.
    public func fetchPayload(itemId: String, uti: String) throws -> Data? {
        return try handle.fetchPayload(itemId: itemId, uti: uti)
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

    /// Queries current storage usage statistics.
    public func getStats() throws -> StorageStatsDto {
        return try handle.getStats()
    }
}
