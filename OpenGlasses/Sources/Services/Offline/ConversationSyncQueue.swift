import Foundation
import SQLite3

/// Where a queued conversation sync item is in its lifecycle. Distinct from `OpState` (Field
/// Assist) -- `confirmedM2` and `confirmedM4` are two different real ACKs, not one generic "done".
enum SyncState: String, Codable {
    case pending
    case inFlight
    case confirmedM2      // durable on M2's fallback queue, not yet on M4
    case confirmedM4      // landed in glasses:events -- fully synced
    case savedLocalFile   // last resort: M4 and M2 both unreachable, wrote a Documents file
    case failed
}

/// One conversation waiting to reach the Overseer's memory. Deliberately NOT `QueuedOp` --
/// conversations are a separate concern from the Field Assist queue (see 2026-08-05 design spec).
struct SyncItem: Identifiable, Codable, Equatable {
    let id: String
    let sessionId: String
    var payload: Data       // JSON: {"session_id":, "source":, "pairs": [...]}
    let createdAt: Date
    var attempts: Int
    var state: SyncState

    init(id: String = UUID().uuidString,
         sessionId: String,
         payload: Data = Data(),
         createdAt: Date = Date(),
         attempts: Int = 0,
         state: SyncState = .pending) {
        self.id = id
        self.sessionId = sessionId
        self.payload = payload
        self.createdAt = createdAt
        self.attempts = attempts
        self.state = state
    }
}

/// Durable, append-only queue of `SyncItem`, backed by SQLite -- mirrors `OfflineQueue`'s storage
/// pattern (same WAL journal mode, same recoverInFlight-on-open strand recovery), but with its own
/// table so a Field Assist bug can never affect conversation sync or vice versa.
@MainActor
final class ConversationSyncQueue {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `path` is injectable so tests can use a throwaway file (and reopen it to prove survival).
    init(path: URL? = nil) {
        let url = path ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("conversation_sync_queue.sqlite")
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            NSLog("[ConversationSyncQueue] Failed to open database at %@", url.path)
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS sync_items (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            payload BLOB,
            created_at REAL NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'pending',
            seq INTEGER
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_sync_items_state ON sync_items(state)")
        recoverInFlight()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Startup recovery

    /// Re-arm items stranded `inFlight` by a process killed mid-delivery -- same rationale as
    /// `OfflineQueue.recoverInFlight()`: only one process ever owns this file, so any `inFlight`
    /// row seen at open time is a strand, not a real in-progress delivery.
    @discardableResult
    func recoverInFlight() -> Int {
        exec("UPDATE sync_items SET state = 'pending' WHERE state = 'inFlight'")
        return Int(sqlite3_changes(db))
    }

    // MARK: - Mutations

    func enqueue(_ item: SyncItem) {
        let sql = "INSERT OR REPLACE INTO sync_items (id, session_id, payload, created_at, attempts, state, seq) " +
                  "VALUES (?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM sync_items))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, item.id)
        bindText(stmt, 2, item.sessionId)
        item.payload.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(item.payload.count), Self.transient)
        }
        sqlite3_bind_double(stmt, 4, item.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 5, Int32(item.attempts))
        bindText(stmt, 6, item.state.rawValue)
        _ = sqlite3_step(stmt)
    }

    func mark(_ id: String, state: SyncState, attempts: Int? = nil) {
        let sql = attempts == nil
            ? "UPDATE sync_items SET state = ? WHERE id = ?"
            : "UPDATE sync_items SET state = ?, attempts = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, state.rawValue)
        if let attempts {
            sqlite3_bind_int(stmt, 2, Int32(attempts))
            bindText(stmt, 3, id)
        } else {
            bindText(stmt, 2, id)
        }
        _ = sqlite3_step(stmt)
    }

    // MARK: - Queries

    func pending() -> [SyncItem] {
        let sql = "SELECT id, session_id, payload, created_at, attempts, state FROM sync_items " +
                  "WHERE state = 'pending' ORDER BY created_at ASC, seq ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [SyncItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(rowToItem(stmt))
        }
        return results
    }

    var pendingCount: Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sync_items WHERE state = 'pending'", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Counts by state, for the status UI (Task 7).
    func counts() -> [SyncState: Int] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT state, COUNT(*) FROM sync_items GROUP BY state", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var result: [SyncState: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let state = SyncState(rawValue: String(cString: sqlite3_column_text(stmt, 0))) ?? .pending
            result[state] = Int(sqlite3_column_int(stmt, 1))
        }
        return result
    }

    // MARK: - Helpers

    private func rowToItem(_ stmt: OpaquePointer?) -> SyncItem {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let sessionId = String(cString: sqlite3_column_text(stmt, 1))
        let blob = sqlite3_column_blob(stmt, 2)
        let blobLen = Int(sqlite3_column_bytes(stmt, 2))
        let payload = blob != nil ? Data(bytes: blob!, count: blobLen) : Data()
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let attempts = Int(sqlite3_column_int(stmt, 4))
        let state = SyncState(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .pending
        return SyncItem(id: id, sessionId: sessionId, payload: payload,
                         createdAt: createdAt, attempts: attempts, state: state)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }
}
