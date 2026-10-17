import Foundation
import SQLite3

public struct SQLiteError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

final class SQLiteConnection {
    private var db: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw SQLiteError(message: "Could not open history database: \(message)")
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close(db)
    }

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw SQLiteError(message: message)
        }
    }

    func run(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(message: lastError) }
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[SQLValue]] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: lastError) }
            let count = sqlite3_column_count(stmt)
            var row: [SQLValue] = []
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLiteError(message: lastError) }
        for (index, value) in params.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT_PTR)
            case .null: sqlite3_bind_null(stmt, i)
            }
        }
        return stmt
    }
}

extension SQLValue {
    var int: Int64 {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .text(let s): return Int64(s) ?? 0
        case .null: return 0
        }
    }

    var double: Double {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .text(let s): return Double(s) ?? 0
        case .null: return 0
        }
    }

    var text: String {
        switch self {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .null: return ""
        }
    }

    var optionalInt: Int64? {
        if case .null = self { return nil }
        return int
    }
}
