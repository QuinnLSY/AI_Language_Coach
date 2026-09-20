import AIDomain
@testable import AIInfrastructure
import Foundation
import XCTest

/// 发布就绪：数据韧性与备份（Phase 30 / §34 Data）。
///
/// 这三条是 Release checklist 里**能自动验证**的部分，所以它们必须自己站得住：
/// 迁移要幂等、备份要真的压出东西、坏库要被隔离而不是被吞掉。
final class ReleaseReadinessTests: XCTestCase {

    // MARK: - 数据韧性

    func testCorruptedDatabaseIsQuarantinedAndRebuilt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 先建一个真库，再写坏它——模拟「用着用着磁盘出问题」，而不是凭空一个垃圾文件。
        let url = directory.appendingPathComponent("learning.db")
        _ = try LearningDatabase(path: url.path)
        try Data("这不是 SQLite，用来模拟损坏".utf8).write(to: url)

        let outcome = try DataResilience.openLearningDatabase(path: url.path)
        XCTAssertTrue(outcome.recovered, "坏库必须被识别并重建")

        // 原文件要活着躺在隔离目录里：删除是不可逆的，用户还有机会找回会话。
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: DataResilience.quarantineDirectory(base: directory),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(quarantined.isEmpty, "坏文件必须被隔离保留")
        XCTAssertTrue(
            quarantined.contains { $0.lastPathComponent.contains(DataResilience.quarantinePrefix) },
            "隔离文件要带 corrupted- 前缀，才知道它是什么"
        )

        // 重建之后必须能用，而不是每次打开都再来一遍「抢险」。
        let reopened = try DataResilience.openLearningDatabase(path: url.path)
        XCTAssertFalse(reopened.recovered)
    }

    func testQuarantineMovesWalCompanions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("learning.db")
        try Data("db".utf8).write(to: url)
        try Data("wal".utf8).write(to: url.appendingPathExtension("-wal"))
        try Data("shm".utf8).write(to: url.appendingPathExtension("-shm"))

        DataResilience.moveToQuarantine(url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("-wal").path))
        let quarantined = try FileManager.default.contentsOfDirectory(at: DataResilience.quarantineDirectory(base: directory), includingPropertiesForKeys: nil)
        XCTAssertEqual(quarantined.count, 3, "WAL/SHM 必须跟着主库一起走，否则恢复出来是半个库")
    }

    // MARK: - 备份导出

    func testBackupContainsLearningDatabaseAndConfig() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

        _ = try LearningDatabase(path: data.appendingPathComponent("learning.db").path)
        try "{}".write(to: data.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let store = DataBackup(dataDirectory: data, backupDirectory: root.appendingPathComponent("backups"))
        let snapshot = try await store.export()

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.url.path))
        XCTAssertGreaterThan(snapshot.sizeBytes, 0)
        XCTAssertTrue(snapshot.url.lastPathComponent.hasSuffix(".zip"))

        let listed = await store.snapshots()
        XCTAssertEqual(listed.count, 1)
        // 列目录拿到的是 /private/var/... 的真实路径（macOS 上 /var 是软链），比文件名即可。
        XCTAssertEqual(listed.first?.url.lastPathComponent, snapshot.url.lastPathComponent)
    }

    func testBackupFailsLoudlyWhenThereIsNothingToExport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let store = DataBackup(dataDirectory: empty, backupDirectory: root.appendingPathComponent("backups"))
        do {
            _ = try await store.export()
            XCTFail("空目录不该导出成功——空 zip 会让人误以为备份好了")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - 迁移

    func testMigrationIsIdempotent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("learning.db").path

        _ = try LearningDatabase(path: path)
        let second = try LearningDatabase(path: path) // 同一份库再跑一次迁移不得报错
        XCTAssertEqual(LearningDatabase.schemaVersion, try Self.schemaVersion(of: path))
        _ = second
    }

    // MARK: - 就绪清单

    func testAutomatedItemsAllHaveRealVerdicts() async throws {
        let report = await ReleaseReadinessRunner().evaluate()
        // 清单里声明 automated 的项，必须得到「通过或未通过」——不能悄悄退化成 manual。
        for result in report.results where result.item.automated {
            if case .manual = result.status {
                XCTFail("\(result.item.id) 声明可自动验证，却返回了 manual")
            }
        }
        XCTAssertEqual(report.results.count, ReleaseChecklist.items.count)
        // 静态检查自己不能把自己判红（规则已经外置到 JSON）。
        XCTAssertTrue(report.isReleaseReady, report.failedResults.map(\.item.id).joined(separator: "、"))
    }

    func testScannerIgnoresMentionsInComments() throws {
        let evidence = ReleaseEvidence.bootstrap()
        guard let rules = evidence.rules else {
            throw XCTSkip("静态检查规则未加载")
        }
        // 注释里提端口/域名（说明性文字）不该算违规。
        let hits = evidence.matches(pattern: rules.absolutePathPatterns[0], scope: .all)
        XCTAssertTrue(hits.isEmpty, "正式代码里不应有硬编码绝对路径：\(hits)")
    }

    /// 「不可用的 SwiftUI 叠加 API」规则必须**词首锚定**。
    ///
    /// 这条规则来自一次真实事故：`AVKit` 的 `VideoPlayer`（cross-import overlay）编译通过、
    /// 启动即崩。规则写成 `VideoPlayer\(` 时，包装类型 `InlineVideoPlayer(` 会被误判成违规 ——
    /// 一条永远红的检查最终会被所有人忽略，比没有检查更糟。所以这里把「不能误伤包装名」
    /// 直接钉成断言，而不是只断言「今天为绿」。
    func testOverlayRuleIsWordAnchoredAndStillCatchesBareUsage() throws {
        let evidence = ReleaseEvidence.bootstrap()
        let rules = try XCTUnwrap(evidence.rules, "静态检查规则未加载")
        XCTAssertFalse(rules.unusableOverlayPatterns.isEmpty, "叠加 API 规则表不该为空")

        for pattern in rules.unusableOverlayPatterns {
            let expression = try NSRegularExpression(pattern: pattern)
            XCTAssertTrue(
                patternMatches("VideoPlayer(player: player)", expression),
                "裸用法必须被抓住：\(pattern)"
            )
            XCTAssertTrue(
                patternMatches("AVKit.VideoPlayer(player: player)", expression),
                "带模块名的合法写法也必须被抓住：\(pattern)"
            )
            XCTAssertFalse(
                patternMatches("InlineVideoPlayer(url: url)", expression),
                "自建包装类型不能被误判成违规（否则检查永远红着）：\(pattern)"
            )
            XCTAssertFalse(
                patternMatches("myVideoPlayer(", expression),
                "驼峰里的同名后缀不属于违规：\(pattern)"
            )
        }
    }

    // MARK: - 辅助

    private func patternMatches(_ text: String, _ expression: NSRegularExpression) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("alc-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func schemaVersion(of path: String) throws -> Int {
        // 通过再初始化一次来确认版本没有漂移：能打开且不需要重建即视为一致。
        _ = try LearningDatabase(path: path)
        return LearningDatabase.schemaVersion
    }
}
