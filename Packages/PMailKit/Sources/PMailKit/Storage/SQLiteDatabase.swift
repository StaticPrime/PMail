import Foundation
import os
import SQLite3

/// A value bound to a statement's `?`.
enum SQLiteValue: Sendable, Hashable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Data)
    case null

    static func int(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
    static func optionalText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
}

/// One row of an answer, read by column number (from 0).
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }

    func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    func blob(_ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// A small SQLite database: statements with bound values, rows read by column, and transactions. It belongs to one
/// actor, which is the only one to use it.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var prepared: [String: OpaquePointer] = [:]
    private static let log = Logger(subsystem: "com.pugglesoft.PMail", category: "Storage")
    /// Tells SQLite to copy bound text and data.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (or makes) the database in a file, or in memory when `file` is nil (for tests).
    init(file: URL?) throws {
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(file?.path ?? ":memory:", &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            let reason = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(status)"
            sqlite3_close(opened)
            throw PMailError.notSupported("The mail kept on this Mac couldn’t be opened (\(reason)).")
        }
        handle = opened
        if file != nil {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
    }

    deinit {
        for statement in prepared.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    /// Runs SQL that needs no values and returns no rows (several statements are fine).
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let reason = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw failure(reason)
        }
    }

    /// Runs one statement with values, returning no rows.
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        try query(sql, values) { _ in }
    }

    /// Runs one statement with values, handing each row to `read`.
    func query(_ sql: String, _ values: [SQLiteValue] = [], _ read: (SQLiteRow) throws -> Void) throws {
        let statement = try statement(for: sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let status: Int32 = switch value {
            case let .text(text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let .integer(number): sqlite3_bind_int64(statement, position, number)
            case let .real(number): sqlite3_bind_double(statement, position, number)
            case let .blob(data):
                data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            case .null: sqlite3_bind_null(statement, position)
            }
            guard status == SQLITE_OK else { throw failure(lastError) }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw failure(lastError) }
            try read(SQLiteRow(statement: statement))
        }
    }

    /// The first column of the first row, as a whole number.
    func integer(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        var found = 0
        try query(sql, values) { row in found = row.int(0) }
        return found
    }

    /// Runs work in one transaction: all of it is kept, or none if it throws.
    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func statement(for sql: String) throws -> OpaquePointer {
        if let statement = prepared[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure(lastError) }
        prepared[sql] = statement
        return statement
    }

    private var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    private func failure(_ reason: String) -> PMailError {
        Self.log.error("SQLite: \(reason, privacy: .public)")
        return .notSupported("The mail kept on this Mac couldn’t be read or saved (\(reason)).")
    }
}
