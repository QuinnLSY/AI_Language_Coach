import AIDomain
@testable import AIInfrastructure
import AppCore
import Foundation
import XCTest

/// 备份导入与恢复（#209）：换机迁移 / 误删恢复的校验链。
///
/// 这一组测试守住的是**「绝不部分覆盖」**：坏包在 inspect 就被拦下，
/// stage 只写暂存不动现有数据，真正替换发生在重启后的 apply。
final class BackupImportTests: XCTestCase {

    // MARK: - 工具

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 用 ditto 打一个真 zip（与产品同一套压缩方式），`keepParent` 决定是否带父文件夹。
    private func zipPayload(files: [String: Data], keepParent: Bool) throws -> URL {
        let staging = try makeTemporaryDirectory()
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: payload.appendingPathComponent(name))
        }
        let destination = staging.appendingPathComponent("backup.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = keepParent
            ? ["-c", "-k", "--keepParent", payload.path, destination.path]
            : ["-c", "-k", payload.path, destination.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "测试自身的 zip 打包不应失败")
        return destination
    }

    /// 建一个带学习库 + 配置的数据目录。
    private func makeDataDirectory() throws -> URL {
        let data = try makeTemporaryDirectory()
        _ = try LearningDatabase(path: data.appendingPathComponent("learning.db").path)
        try #"{"dailyGoalMinutes": 20}"#.write(
            to: data.appendingPathComponent("config.json"), atomically: true, encoding: .utf8
        )
        return data
    }

    private func sqliteHeaderData() throws -> Data {
        // 直接借 LearningDatabase 生成一个真 SQLite 文件的头。
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.db")
        _ = try LearningDatabase(path: url.path)
        return try Data(contentsOf: url)
    }

    // MARK: - 校验（inspect）

    func testInspectAcceptsValidBackupAndReportsScope() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try makeDataDirectory()
        let store = DataBackup(dataDirectory: data, backupDirectory: root.appendingPathComponent("backups"))
        let snapshot = try await store.export()

        let plan = try await store.inspectBackup(at: snapshot.url)
        XCTAssertTrue(plan.includesDatabase)
        XCTAssertTrue(plan.includesConfig)
        XCTAssertTrue(plan.scopeDescription.contains("学习库"))
        XCTAssertTrue(plan.scopeDescription.contains("配置"))
    }

    func testInspectRejectsCorruptZip() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try makeDataDirectory()
        let store = DataBackup(dataDirectory: data, backupDirectory: root.appendingPathComponent("backups"))

        let garbage = root.appendingPathComponent("garbage.zip")
        try Data("这不是 zip，是随手写坏的文件".utf8).write(to: garbage)

        do {
            _ = try await store.inspectBackup(at: garbage)
            XCTFail("坏包必须被拦下")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("损坏") || error.localizedDescription.contains("无法读取"),
                "报错要说明包坏了，而不是含糊失败：\(error.localizedDescription)"
            )
        }
    }

    func testInspectRejectsNonSQLiteDatabase() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try makeDataDirectory()
        let store = DataBackup(dataDirectory: data, backupDirectory: root.appendingPathComponent("backups"))

        let zip = try zipPayload(
            files: [
                "learning.db": Data("不是 SQLite 的假库".utf8),
                "config.json": Data("{}".utf8),
            ],
            keepParent: true
        )

        do {
            _ = try await store.inspectBackup(at: zip)
            XCTFail("假库必须被 SQLite 文件头校验拦下")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("SQLite"),
                "假库要被 SQLite 文件头校验拦下：\(error.localizedDescription)"
            )
        }
    }

    func testInspectRejectsBrokenConfigJSON() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try makeDataDirectory()
        let store = DataBackup(dataDirectory: data, backupDirectory: root.appendingPathComponent("backups"))

        let zip = try zipPayload(
            files: [
                "learning.db": try sqliteHeaderData(),
                "config.json": Data("这不是 json{{".utf8),
            ],
            keepParent: false
        )

        do {
            _ = try await store.inspectBackup(at: zip)
            XCTFail("坏配置必须被 JSON 校验拦下")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("JSON"),
                "坏配置要被 JSON 校验拦下：\(error.localizedDescription)"
            )
        }
    }

    func testInspectRejectsBackupWithoutRecoverableContent() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try makeDataDirectory()
        let store = DataBackup(dataDirectory: data, backupDirectory: root.appendingPathComponent("backups"))

        let zip = try zipPayload(files: ["remote-calls.jsonl": Data("{}".utf8)], keepParent: true)
        do {
            _ = try await store.inspectBackup(at: zip)
            XCTFail("没有可恢复内容的备份必须被拦下")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - 暂存（stage）与回滚保障

    func testStageRestoreWritesPendingAndSafetyBackupWithoutTouchingCurrentData() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try makeDataDirectory()
        let backups = root.appendingPathComponent("backups")
        let store = DataBackup(dataDirectory: data, backupDirectory: backups)
        let snapshot = try await store.export()

        // 备份导出之后，当前数据继续往前走（模拟「备份之后又练了几天」）。
        try #"{"dailyGoalMinutes": 45}"#.write(
            to: data.appendingPathComponent("config.json"), atomically: true, encoding: .utf8
        )

        let plan = try await store.stageRestore(at: snapshot.url)
        XCTAssertTrue(plan.includesDatabase)

        // 暂存里有备份的旧配置（20 分钟），现有配置还是新的 45 分钟 —— 没被当场覆盖。
        let pending = DataBackup.pendingRestoreDirectory(dataDirectory: data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        let pendingConfig = try String(contentsOf: pending.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertTrue(pendingConfig.contains("20"), "暂存里应是备份里的旧配置")
        let currentConfig = try String(contentsOf: data.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertTrue(currentConfig.contains("45"), "现有配置在重启前必须原封不动")

        // 覆盖前的后悔药：备份目录里多出一份「恢复前」留底。
        let listed = await store.snapshots()
        XCTAssertTrue(
            listed.contains { $0.url.lastPathComponent.contains("恢复前") },
            "恢复前自动备份必须存在：\(listed.map { $0.url.lastPathComponent })"
        )
    }

    // MARK: - 启动应用（apply）

    func testApplyPendingRestoreReplacesFilesAndCleansStaleWal() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try makeDataDirectory()

        // 手工构造「待恢复」暂存：备份里的旧配置 + 一个真 SQLite 库（不带 WAL）。
        let pending = DataBackup.pendingRestoreDirectory(dataDirectory: data)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let backupDB = try makeDataDirectory()
        try FileManager.default.copyItem(
            at: backupDB.appendingPathComponent("learning.db"),
            to: pending.appendingPathComponent("learning.db")
        )
        try #"{"dailyGoalMinutes": 20}"#.write(
            to: pending.appendingPathComponent("config.json"), atomically: true, encoding: .utf8
        )

        // 当前数据继续变化：配置改掉 + 留一个备份里没有的旧 WAL（不同库的 WAL 是毒药）。
        try #"{"dailyGoalMinutes": 99}"#.write(
            to: data.appendingPathComponent("config.json"), atomically: true, encoding: .utf8
        )
        try Data("stale".utf8).write(to: data.appendingPathComponent("learning.db-wal"))

        let note = DataBackup.applyPendingRestoreIfNeeded(dataDirectory: data)

        let applied = try XCTUnwrap(note)
        XCTAssertTrue(applied.contains("替换"), "应用说明要说清楚替换了什么：\(applied)")
        let config = try String(contentsOf: data.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertTrue(config.contains("20"), "配置应被替换回备份里的版本")
        let dbHandle = try FileHandle(forReadingFrom: data.appendingPathComponent("learning.db"))
        let dbHeader = try dbHandle.read(upToCount: 16) ?? Data()
        try dbHandle.close()
        XCTAssertEqual(dbHeader, Data("SQLite format 3\u{0}".utf8), "主库应是备份里的 SQLite 文件")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: data.appendingPathComponent("learning.db-wal").path),
            "备份没带 WAL，旧的必须删掉"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pending.path),
            "应用完暂存目录要清掉"
        )
    }

    func testApplyWithoutPendingReturnsNil() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(DataBackup.applyPendingRestoreIfNeeded(dataDirectory: root))
    }
}
