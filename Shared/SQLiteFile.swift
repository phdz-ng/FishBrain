import Foundation
import SQLite3

/// A thin wrapper over the system SQLite, for reading (and, in tests and exports, writing) the small
/// databases inside Anki packages. Not thread-safe; use it on one queue and close it when done.
final class SQLiteFile {
    enum Value: Equatable {
        case null
        case int(Int64)
        case text(String)
        case blob(Data)

        var int: Int64? { if case .int(let v) = self { v } else { nil } }
        var text: String? {
            switch self {
            case .text(let v): v
            case .int(let v): String(v)
            default: nil
            }
        }
    }

    struct SQLiteError: Error, Equatable {
        var message: String
    }

    private var handle: OpaquePointer?

    /// Opens `url`. `readOnly` for a file someone else made; otherwise it is created if missing.
    init(url: URL, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(message: message)
        }
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "failed"
            sqlite3_free(error)
            throw SQLiteError(message: message)
        }
    }

    /// Runs a statement with `?` placeholders and returns its rows.
    @discardableResult
    func query(_ sql: String, _ binds: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed")
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in binds.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, position)
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(v.count), transient) }
            }
        }

        var rows: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed")
            }
            let count = sqlite3_column_count(statement)
            var row: [Value] = []
            for column in 0..<count {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(statement, column)))
                case SQLITE_TEXT:
                    row.append(.text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""))
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), length > 0 {
                        row.append(.blob(Data(bytes: bytes, count: length)))
                    } else {
                        row.append(.blob(Data()))
                    }
                case SQLITE_FLOAT: row.append(.text(String(sqlite3_column_double(statement, column))))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }
}
