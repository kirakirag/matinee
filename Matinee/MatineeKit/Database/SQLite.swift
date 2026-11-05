import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// A value bound to a `?` parameter. SQL is never built from strings; values always go through here.
enum SQLValue {
    case text(String), int(Int), real(Double), blob(Data), null
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Not thread-safe on its own; `Store` serialises access.
final class SQLite {
    private let db: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: rc, message: message)
        }
        db = handle
    }

    deinit {
        for stmt in statements.values { sqlite3_finalize(stmt) }
        sqlite3_close_v2(db)
    }

    func execute(_ sql: String, _ binds: [SQLValue] = []) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_reset(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw error(rc) }
    }

    func query<T>(_ sql: String, _ binds: [SQLValue] = [], row: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_reset(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { throw error(rc) }
            out.append(try row(Row(stmt: stmt)))
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Cached prepared statement, reset and with `binds` applied.
    private func prepare(_ sql: String, _ binds: [SQLValue]) throws -> OpaquePointer {
        let stmt: OpaquePointer
        if let cached = statements[sql] {
            stmt = cached
        } else {
            var p: OpaquePointer?
            let rc = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &p, nil)
            guard rc == SQLITE_OK, let p else { throw error(rc) }
            statements[sql] = p
            stmt = p
        }
        sqlite3_clear_bindings(stmt)
        for (i, value) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32 = switch value {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .blob(let data):
                data.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else { throw error(rc) }
        }
        return stmt
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }

    struct Row {
        let stmt: OpaquePointer
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int? { isNull(i) ? nil : Int(sqlite3_column_int64(stmt, i)) }
        func real(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
        func blob(_ i: Int32) -> Data? {
            guard !isNull(i), let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }
}
