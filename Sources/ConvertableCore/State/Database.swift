import Foundation
import SQLite3

/// Thin, synchronous wrapper over the system SQLite. One connection per instance;
/// callers serialize access (the store actor does this for the app).
public final class Database {
    public enum Failure: Error, CustomStringConvertible {
        case open(path: String, message: String)
        case exec(sql: String, message: String)
        case prepare(sql: String, message: String)
        case step(sql: String, message: String)
        case bind(index: Int32, message: String)

        public var description: String {
            switch self {
            case let .open(path, m): return "sqlite open \(path): \(m)"
            case let .exec(sql, m): return "sqlite exec `\(sql.prefix(80))`: \(m)"
            case let .prepare(sql, m): return "sqlite prepare `\(sql.prefix(80))`: \(m)"
            case let .step(sql, m): return "sqlite step `\(sql.prefix(80))`: \(m)"
            case let .bind(i, m): return "sqlite bind #\(i): \(m)"
            }
        }
    }

    public enum Value: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    public struct Row {
        let stmt: OpaquePointer
        let columns: [String: Int32]

        public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        public func int(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(stmt, i) }
        public func double(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
        public func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        public func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
        public func int(_ name: String) -> Int64? { columns[name].flatMap(int) }
        public func double(_ name: String) -> Double? { columns[name].flatMap(double) }
        public func text(_ name: String) -> String? { columns[name].flatMap(text) }
        public func blob(_ name: String) -> Data? { columns[name].flatMap(blob) }
    }

    private let handle: OpaquePointer
    public let path: String
    /// Serializes every call. Recursive so `transaction` bodies can call back in.
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h { sqlite3_close(h) }
            throw Failure.open(path: path, message: msg)
        }
        handle = h
        self.path = path
        sqlite3_busy_timeout(handle, 5_000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA synchronous=NORMAL")
    }

    public static func inMemory() throws -> Database { try Database(path: ":memory:") }

    deinit { sqlite3_close(handle) }

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.exec(sql: sql, message: errorMessage)
        }
    }

    /// Runs a statement that returns no rows.
    @discardableResult
    public func run(_ sql: String, _ params: [Value] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw Failure.step(sql: sql, message: errorMessage) }
        return Int(sqlite3_changes(handle))
    }

    public func query<T>(_ sql: String, _ params: [Value] = [], _ map: (Row) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var columns: [String: Int32] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            columns[String(cString: sqlite3_column_name(stmt, i))] = i
        }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try map(Row(stmt: stmt, columns: columns))); continue }
            if rc == SQLITE_DONE { break }
            throw Failure.step(sql: sql, message: errorMessage)
        }
        return out
    }

    public func scalar(_ sql: String, _ params: [Value] = []) throws -> Value? {
        try query(sql, params) { row -> Value in
            switch sqlite3_column_type(row.stmt, 0) {
            case SQLITE_INTEGER: return .integer(sqlite3_column_int64(row.stmt, 0))
            case SQLITE_FLOAT: return .real(sqlite3_column_double(row.stmt, 0))
            case SQLITE_TEXT: return .text(row.text(0) ?? "")
            case SQLITE_BLOB: return .blob(row.blob(0) ?? Data())
            default: return .null
            }
        }.first
    }

    public var lastInsertRowID: Int64 { lock.lock(); defer { lock.unlock() }; return sqlite3_last_insert_rowid(handle) }

    /// Insert and return the new row id atomically with respect to other threads.
    @discardableResult
    public func insert(_ sql: String, _ params: [Value] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try run(sql, params)
        return sqlite3_last_insert_rowid(handle)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        get { (try? scalar("PRAGMA user_version")).flatMap { if case let .integer(v) = $0 { return Int(v) }; return nil } ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws { try exec("PRAGMA user_version=\(v)") }

    // MARK: - Internals

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure.prepare(sql: sql, message: errorMessage)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case let .integer(v): rc = sqlite3_bind_int64(stmt, idx, v)
            case let .real(v): rc = sqlite3_bind_double(stmt, idx, v)
            case let .text(v): rc = sqlite3_bind_text(stmt, idx, v, -1, transient)
            case let .blob(v): rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), transient) }
            }
            guard rc == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw Failure.bind(index: idx, message: errorMessage)
            }
        }
        return stmt
    }
}

// Convenience literals so call sites read naturally: db.run("…", [.text(x), 42, 3.5])
extension Database.Value: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(stringLiteral value: String) { self = .text(value) }
    public init(floatLiteral value: Double) { self = .real(value) }
}
extension Database.Value {
    public init(_ s: String?) { self = s.map { .text($0) } ?? .null }
    public init(_ i: Int64?) { self = i.map { .integer($0) } ?? .null }
    public init(_ i: Int?) { self = i.map { .integer(Int64($0)) } ?? .null }
    public init(_ d: Double?) { self = d.map { .real($0) } ?? .null }
    public init(_ b: Bool) { self = .integer(b ? 1 : 0) }
    public init(_ date: Date?) { self = date.map { .real($0.timeIntervalSince1970) } ?? .null }
}
