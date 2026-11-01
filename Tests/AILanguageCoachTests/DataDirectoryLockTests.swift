import Foundation
import XCTest
@testable import AIInfrastructure

/// 数据独占性保护（本批 ①）。
///
/// 这组盯的是**两件会真丢数据的事**：
/// 1. 第二个实例撞上学习库后，被启动路径误判成「坏库」→ 把用户正在用的库隔离掉；
/// 2. 备份拷出「旧主库 + 新 WAL」的错配组合 → 恢复出来是坏的。
///
/// 判据尽量落在**真实行为**上（真锁、真连接、真 zip），源码哨兵只用来钉
/// 「撞锁分支不许打开库」这种从外部构造不出来的分支。
final class DataDirectoryLockTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    // MARK: - 锁本身

    func testSecondAcquisitionInSameProcessIsBusy() {
        guard case .acquired(let first) = DataDirectoryLock.acquire(directory: tempRoot) else {
            return XCTFail("第一次取锁应当成功")
        }
        defer { first.release() }

        guard case .busy = DataDirectoryLock.acquire(directory: tempRoot) else {
            return XCTFail("同一目录的第二次取锁必须被拒 —— 否则两个实例会同时写同一个库")
        }
    }

    func testReleaseAllowsReacquisition() {
        guard case .acquired(let first) = DataDirectoryLock.acquire(directory: tempRoot) else {
            return XCTFail("第一次取锁应当成功")
        }
        first.release()

        guard case .acquired(let second) = DataDirectoryLock.acquire(directory: tempRoot) else {
            return XCTFail("释放之后必须能重新拿到锁，否则正常退出会被自己挡住")
        }
        second.release()
    }

    func testRepeatedReleaseIsHarmless() {
        guard case .acquired(let lock) = DataDirectoryLock.acquire(directory: tempRoot) else {
            return XCTFail("第一次取锁应当成功")
        }
        lock.release()
        // ⚠️ 第二次必须是无操作：裸 close 一个已关闭的 fd 可能正好关掉别人刚拿到的同一个号。
        lock.release()

        guard case .acquired(let again) = DataDirectoryLock.acquire(directory: tempRoot) else {
            return XCTFail("重复 release 不该把锁状态弄坏")
        }
        again.release()
    }

    func testLockFileLivesInTheDataDirectory() {
        guard case .acquired(let lock) = DataDirectoryLock.acquire(directory: tempRoot) else {
            return XCTFail("第一次取锁应当成功")
        }
        defer { lock.release() }

        XCTAssertEqual(lock.fileURL.lastPathComponent, DataDirectoryLock.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.fileURL.path), "锁文件要落在目录里，方便排查「谁占着」")
        XCTAssertEqual(
            lock.fileURL.deletingLastPathComponent().standardizedFileURL,
            tempRoot.standardizedFileURL
        )
    }

    func testDifferentDirectoriesDoNotConflict() throws {
        let other = tempRoot.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        guard case .acquired(let a) = DataDirectoryLock.acquire(directory: tempRoot) else {
            return XCTFail("第一次取锁应当成功")
        }
        defer { a.release() }

        guard case .acquired(let b) = DataDirectoryLock.acquire(directory: other) else {
            return XCTFail("不同数据目录之间不该互相阻塞")
        }
        b.release()
    }

    // MARK: - SQLite 侧的配合

    func testBusyTimeoutIsConfigured() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        defer { db.close() }

        let values = try db.query("PRAGMA busy_timeout") { $0.int(0) ?? -1 }
        XCTAssertEqual(values.first, SQLiteDatabase.busyTimeoutMilliseconds,
                       "撞锁时必须是「等一会儿」而不是立刻抛错")
    }

    func testSynchronousIsNormal() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        defer { db.close() }

        let values = try db.query("PRAGMA synchronous") { $0.int(0) ?? -1 }
        XCTAssertEqual(values.first, 1, "NORMAL = 1；WAL 下这是安全档，显式钉住以免默认值漂移")
    }

    /// 另一个连接占着写锁时，本连接应当**等**，而不是立刻失败。
    func testWriterWaitsForTheOtherWriter() async throws {
        let path = tempRoot.appendingPathComponent("learning.db").path
        let holder = try SQLiteDatabase(path: path)
        let writer = try SQLiteDatabase(path: path)
        defer { holder.close(); writer.close() }

        try holder.run("CREATE TABLE t (v INTEGER)")
        try holder.run("BEGIN IMMEDIATE") // 占住写锁

        let insert = Task { try writer.run("INSERT INTO t (v) VALUES (1)") }
        try await Task.sleep(nanoseconds: 200_000_000)
        try holder.run("COMMIT")

        do {
            try await insert.value
        } catch {
            return XCTFail("写者应当在 busy_timeout 内等待对方，而不是立刻抛错：\(error)")
        }

        let counts = try writer.query("SELECT COUNT(*) FROM t") { $0.int(0) ?? 0 }
        XCTAssertEqual(counts.first, 1)
    }

    // MARK: - 备份

    func testBackupCarriesUserAssetDirectories() async throws {
        let data = tempRoot.appendingPathComponent("data", isDirectory: true)
        let backups = tempRoot.appendingPathComponent("backups", isDirectory: true)
        let attachments = data.appendingPathComponent("attachments", isDirectory: true)
        let courses = data.appendingPathComponent("courses", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: courses, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: data.appendingPathComponent("learning.db"))
        try Data("png".utf8).write(to: attachments.appendingPathComponent("cover.png"))
        try Data("{}".utf8).write(to: courses.appendingPathComponent("c1.json"))

        let backup = DataBackup(dataDirectory: data, backupDirectory: backups)
        let snapshot = try await backup.export()
        let listing = try Self.zipListing(snapshot.url)

        XCTAssertTrue(
            listing.contains { $0.hasSuffix("attachments/cover.png") },
            "用户上传的素材必须进备份包 —— 否则换机之后聊天里的图全成孤儿：\(listing)"
        )
        XCTAssertTrue(
            listing.contains { $0.hasSuffix("courses/c1.json") },
            "AI 排的课必须进包：\(listing)"
        )
        XCTAssertTrue(listing.contains { $0.hasSuffix("learning.db") }, "库本体不能漏")
    }

    func testBackupCheckpointsBeforeCopying() async throws {
        let data = tempRoot.appendingPathComponent("data", isDirectory: true)
        let backups = tempRoot.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: data.appendingPathComponent("learning.db"))

        let flag = FlagBox()
        let backup = DataBackup(
            dataDirectory: data,
            backupDirectory: backups,
            checkpoint: { flag.mark() }
        )
        _ = try await backup.export()
        XCTAssertTrue(
            flag.value,
            "拷库之前必须先 checkpoint —— 否则两次 copyItem 之间可能拷出「旧主库 + 新 WAL」"
        )
    }

    // MARK: - 源码哨兵（分支从外部构造不出来）

    func testLockedInstanceSkipsOpeningTheDatabase() throws {
        let source = try Self.code("Sources/AIServices/CoachServices.swift")

        XCTAssertTrue(
            source.contains(": Self.openLearningDatabase(at: path)"),
            "正向锚点：正常路径仍然要开库（否则下面的断言会因为「压根没有开库这回事」而恒绿）"
        )
        XCTAssertTrue(
            source.contains("? (database: nil, note: nil)"),
            "撞锁时必须跳过开库 —— 打开后的迁移写入会撞 BUSY，又被当成坏库隔离"
        )
        XCTAssertTrue(
            source.contains("guard !ProcessIdentity.isRunningTests else { return (nil, nil, false) }"),
            "测试进程必须豁免取锁，否则并行渲染测试会互相阻塞"
        )
    }

    // MARK: - 工具

    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        // ⚠️ 先剥整行注释：把一行代码注释掉是最自然的手改方式，而注释里往往
        // 留着一模一样的字符串 —— 不剥就等于允许「注释掉也算通过」。
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private nonisolated static func zipListing(_ url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }
}

/// 跨隔离域记录「闭包被调用过」。
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func mark() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
