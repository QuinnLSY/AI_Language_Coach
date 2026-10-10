import AppCore
import Foundation
import SQLite3

/// 参数值：仅覆盖本应用需要的类型。
public enum SQLiteValue: Sendable, Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    public static func int(_ v: Int) -> SQLiteValue { .int(Int64(v)) }
}

/// 查询结果行访问器。
public struct SQLiteRow {
    fileprivate let statement: OpaquePointer
    fileprivate let columnCount: Int32

    public func hasColumn(_ index: Int32) -> Bool {
        index >= 0 && index < columnCount && sqlite3_column_type(statement, index) != SQLITE_NULL
    }

    public func string(_ index: Int32) -> String? {
        guard hasColumn(index) else { return nil }
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    public func int(_ index: Int32) -> Int? {
        guard hasColumn(index) else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    public func double(_ index: Int32) -> Double? {
        guard hasColumn(index) else { return nil }
        return sqlite3_column_double(statement, index)
    }
}

/// 系统自带 libsqlite3 的最小封装（无第三方依赖）。
/// 设计约束：只暴露 run / query / 事务批处理；所有错误 → `AppError.database`。
/// 线程安全：SQLite 以 SQLITE_OPEN_FULLMUTEX 打开，handle 仅在 init/close/deinit 中变更 → @unchecked Sendable。
public final class SQLiteDatabase: @unchecked Sendable {

    private var handle: OpaquePointer?
    public let path: String

    /// `:memory:` 或临时文件路径用于测试。
    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw AppError.database("无法打开数据库 \(path)：\(message)")
        }
        handle = db
        try run("PRAGMA journal_mode=WAL")
        try run("PRAGMA foreign_keys=ON")
    }

    public func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    // MARK: - 基础操作

    /// 执行写语句（INSERT / UPDATE / DELETE / DDL / PRAGMA）。
    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw AppError.database("SQL 执行失败：\(lastError())\nSQL: \(sql)")
        }
    }

    /// 执行查询并逐行映射。
    public func query<T>(_ sql: String, _ params: [SQLiteValue] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }

        var rows: [T] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            rows.append(try map(SQLiteRow(statement: statement, columnCount: sqlite3_column_count(statement))))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else {
            throw AppError.database("SQL 查询失败：\(lastError())\nSQL: \(sql)")
        }
        return rows
    }

    /// 在单个事务内执行一段操作（可读可写）。任一失败即回滚。
    ///
    /// 与下面的批处理版并存：只要「先读后写」的判据必须原子（例如
    /// 「数量没变才删」），就得用这个 —— 批处理版读不了中间状态，
    /// 把判据放在事务外面，两个操作之间就有窗口。
    public func runInTransaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    /// 在单个事务内顺序执行多条语句。任一失败即回滚。
    public func runInTransaction(_ statements: [(sql: String, params: [SQLiteValue])]) throws {
        try run("BEGIN IMMEDIATE")
        do {
            for item in statements {
                try run(item.sql, item.params)
            }
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    /// 单条 SQL 允许携带的绑定变量上限（**保守取值**）。
    ///
    /// ⚠️ SQLite 的 `SQLITE_MAX_VARIABLE_NUMBER` 在旧版本是 **999**，新版本才提到 32766。
    /// 批量 `IN (...)` 这类语句必须按它分页，否则 `sqlite3_prepare_v2` 直接失败 →
    /// 整条事务回滚 → 表现为「界面上删掉了、库里一条没删」，下次启动整批复活。
    /// 取 500 是刻意留余量：同一条语句里往往还有别的绑定参数（如 `session_id = ?N`）。
    public static let maxBoundVariables = 500

    /// 当前 schema 版本（`PRAGMA user_version`）。
    public func schemaVersion() throws -> Int {
        try query("PRAGMA user_version", map: { $0.int(0) ?? 0 }).first ?? 0
    }

    public func setSchemaVersion(_ version: Int) throws {
        // ⚠️ 这是全库**唯一**一处把值直接插进 SQL 的地方，别照抄到别处：
        // PRAGMA **不接受绑定参数**（`PRAGMA user_version = ?1` 是语法错误），只能拼字符串。
        // 拼进来的是 `Int`，本身没有注入面；下面这道 guard 是把这个前提**钉住** ——
        // 哪天参数换成字符串，这里会立刻失败，而不是悄悄多出一条注入路。
        guard version >= 0 else {
            throw AppError.database("schema 版本不能为负（收到 \(version)）")
        }
        try run("PRAGMA user_version=\(version)")
    }

    // MARK: - 私有

    private func prepare(_ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
        // ⚠️ 绑定参数上限**由本层自己守**，不依赖 SQLite 的版本默认值：
        // 旧版 SQLite 只有 999 个变量，超限时 `sqlite3_prepare_v2` 的报错指向 SQL 形状，
        // 根本看不出是「参数太多」。这里提前给出可读错误，同时让「批量语句必须分页」
        // 成为**可判定的**判据 —— 少了分页就会立刻抛错，而不是「碰巧这台机器的上限够用」。
        guard params.count <= Self.maxBoundVariables else {
            throw AppError.database(
                "单条 SQL 的绑定参数过多（\(params.count) 个，上限 \(Self.maxBoundVariables)）：批量语句请分页"
            )
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AppError.database("SQL 预处理失败：\(lastError())\nSQL: \(sql)")
        }
        do {
            try bind(params, to: statement)
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private func lastError() -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func bind(_ params: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .int(let v):
                result = sqlite3_bind_int64(statement, index, v)
            case .real(let v):
                result = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                result = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            }
            guard result == SQLITE_OK else {
                throw AppError.database("参数绑定失败：\(lastError())")
            }
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
