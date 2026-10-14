import Foundation
import SQLite3

public struct QueryHistoryEntry: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var connectionID: UUID?
    public var database: String?
    public var sql: String
    public var executedAt: Date
    public var duration: TimeInterval
    public var rowCount: Int?
    public var errorMessage: String?

    public var succeeded: Bool { errorMessage == nil }
}

/// Executed statements, kept in a local SQLite database with an FTS5 index for search.
public final class QueryHistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "FoxlumeQuery.history")
    public static let didChangeNotification = Notification.Name("FoxlumeQuery.QueryHistoryStore.didChange")
    public static let maximumEntries = 10_000

    public init(url: URL = AppPaths.historyDatabase) {
        queue.sync {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                db = nil
                return
            }
            exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY,
                connection_id TEXT,
                database_name TEXT,
                sql TEXT NOT NULL,
                executed_at REAL NOT NULL,
                duration REAL NOT NULL DEFAULT 0,
                row_count INTEGER,
                error TEXT
            );
            CREATE INDEX IF NOT EXISTS history_executed_at ON history(executed_at);
            CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(sql, content='history', content_rowid='id', tokenize='unicode61');
            CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
                INSERT INTO history_fts(rowid, sql) VALUES (new.id, new.sql);
            END;
            CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
                INSERT INTO history_fts(history_fts, rowid, sql) VALUES ('delete', old.id, old.sql);
            END;
            """)
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    public func add(sql: String, connectionID: UUID?, database: String?, duration: TimeInterval, rowCount: Int?, error: String?) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var statement: OpaquePointer?
            let insert = "INSERT INTO history (connection_id, database_name, sql, executed_at, duration, row_count, error) VALUES (?, ?, ?, ?, ?, ?, ?)"
            guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, 1, connectionID?.uuidString)
            Self.bind(statement, 2, database)
            Self.bind(statement, 3, trimmed)
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, duration)
            if let rowCount { sqlite3_bind_int64(statement, 6, Int64(rowCount)) } else { sqlite3_bind_null(statement, 6) }
            Self.bind(statement, 7, error)
            sqlite3_step(statement)
            self.exec("DELETE FROM history WHERE id <= (SELECT id FROM history ORDER BY id DESC LIMIT 1 OFFSET \(Self.maximumEntries))")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
    }

    /// Newest first. `text` uses full-text prefix matching on every word.
    public func search(_ text: String, connectionID: UUID? = nil, limit: Int = 300) -> [QueryHistoryEntry] {
        queue.sync {
            guard let db else { return [] }
            let words = text
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
                .filter { !$0.isEmpty }
            var sql = "SELECT h.id, h.connection_id, h.database_name, h.sql, h.executed_at, h.duration, h.row_count, h.error FROM history h"
            var conditions: [String] = []
            if !words.isEmpty {
                sql += " JOIN history_fts f ON f.rowid = h.id"
                conditions.append("history_fts MATCH ?")
            }
            if connectionID != nil { conditions.append("h.connection_id = ?") }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += " ORDER BY h.id DESC LIMIT \(limit)"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var parameter: Int32 = 1
            if !words.isEmpty {
                let match = words.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
                Self.bind(statement, parameter, match)
                parameter += 1
            }
            if let connectionID { Self.bind(statement, parameter, connectionID.uuidString) }

            var entries: [QueryHistoryEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                entries.append(QueryHistoryEntry(
                    id: sqlite3_column_int64(statement, 0),
                    connectionID: Self.text(statement, 1).flatMap(UUID.init(uuidString:)),
                    database: Self.text(statement, 2),
                    sql: Self.text(statement, 3) ?? "",
                    executedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    duration: sqlite3_column_double(statement, 5),
                    rowCount: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 6)),
                    errorMessage: Self.text(statement, 7)
                ))
            }
            return entries
        }
    }

    public func delete(id: Int64) {
        queue.sync { _ = exec("DELETE FROM history WHERE id = \(id)") }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func clear(connectionID: UUID? = nil) {
        queue.sync {
            if let connectionID {
                exec("DELETE FROM history WHERE connection_id = '\(connectionID.uuidString)'")
            } else {
                exec("DELETE FROM history; INSERT INTO history_fts(history_fts) VALUES ('rebuild');")
            }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Wait for queued inserts. Used by tests.
    public func flush() {
        queue.sync {}
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }
}
