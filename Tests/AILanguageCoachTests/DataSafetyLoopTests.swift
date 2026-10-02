import AIDomain
import AIServices
import AIInfrastructure
@testable import AppUI
@testable import AIDomain
import Foundation
import XCTest

/// ② 数据安全闭环（2026-10-02）：备份不无限堆积 / 删除进废纸篓 /
/// 清除记忆前自动留底 + 包事务 / 学习记录导出人类可读。
///
/// ⚠️ 全程用**显式** `databasePath` 与临时目录：裸 `CoachServices()` 会落到用户真实库上。
@MainActor
final class DataSafetyLoopTests: XCTestCase {

    // MARK: - 备份保留策略

    /// 超出保留份数时，清掉的是**最旧**的，最新的一律留着。
    func testPruneKeepsTheNewestAndTrashesTheOldest() async throws {
        let dir = Self.makeBackupDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 15 份时间戳递增的备份包（内容随便，snapshots 只认文件名与扩展名）。
        let stamps = (1...15).map { Self.stamp(day: $0) }
        for stamp in stamps {
            try Data("zip".utf8).write(to: dir.appendingPathComponent("AI_Language_Coach_备份_\(stamp).zip"))
        }

        let backup = DataBackup(dataDirectory: dir, backupDirectory: dir)
        let removed = try await backup.prune(keeping: 12)

        XCTAssertEqual(removed, 3, "15 份留 12 份，应当清掉 3 份")
        let remaining = await backup.snapshots()
        XCTAssertEqual(remaining.count, 12)
        // 最新的（day 15…4）必须都在：按时间戳保留，不按文件属性。
        for day in 4...15 {
            let name = "AI_Language_Coach_备份_\(Self.stamp(day: day)).zip"
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path),
                          "较新的 \(name) 不该被清掉")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("AI_Language_Coach_备份_\(Self.stamp(day: 1)).zip").path),
                       "最旧的应当被清掉")
    }

    /// 没超限就什么都不动。
    func testPruneUnderLimitRemovesNothing() async throws {
        let dir = Self.makeBackupDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for day in 1...5 {
            try Data("zip".utf8).write(to: dir.appendingPathComponent("AI_Language_Coach_备份_\(Self.stamp(day: day)).zip"))
        }
        let backup = DataBackup(dataDirectory: dir, backupDirectory: dir)
        let removed = try await backup.prune(keeping: 12)
        let remainingCount = await backup.snapshots().count
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(remainingCount, 5)
    }

    /// 删除只认备份目录里的 zip：别处的路径必须被拒之门外。
    func testDeleteBackupRefusesPathsOutsideTheBackupDirectory() async throws {
        let dir = Self.makeBackupDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = DataBackup(dataDirectory: dir, backupDirectory: dir)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-outside-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        // ⚠️ `await` 进不了 XCTAssert 的 autoclosure，改 do/catch。
        do {
            try await backup.deleteBackup(at: outside)
            XCTFail("备份目录之外的路径不许删")
        } catch {
            // 预期路径：必须抛错。
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "外面的文件必须原样还在")
    }

    // MARK: - 清除记忆：留底 + 空库跳过

    /// 有内容可清时：删除前必须先在备份目录留一份「清除前」的底。
    func testClearLearningMemoryBacksUpBeforeDeleting() async throws {
        let (services, dataDir, backupDir) = Self.makeIsolatedServices()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        defer { try? FileManager.default.removeItem(at: backupDir) }
        let session = ChatSession(id: UUID(), startedAt: Date())
        await services.persistSession(session)
        await services.persistCorrection(
            GrammarCorrection(original: "I go school", corrected: "I go to school", explanation: "缺介词"),
            sessionID: session.id
        )

        let cleared = try await services.clearLearningMemory()
        XCTAssertGreaterThan(cleared.total, 0, "插入过纠错，清除必须有量")

        let snapshots = await Self.backupInspector(dataDir: dataDir, backupDir: backupDir).snapshots()
        XCTAssertEqual(snapshots.count, 1, "应当恰好留了一份底")
        XCTAssertTrue(snapshots.first?.url.lastPathComponent.contains("清除前") == true,
                      "留底文件名要带「清除前」标记，实际：\(snapshots.first?.url.lastPathComponent ?? "无")")
    }

    /// 没有可清的内容时：直接返回，**不制造空留底**（备份目录不堆垃圾）。
    func testClearLearningMemoryWithNothingToClearSkipsTheBackup() async throws {        let (services, dataDir, backupDir) = Self.makeIsolatedServices()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        defer { try? FileManager.default.removeItem(at: backupDir) }

        let cleared = try await services.clearLearningMemory()
        XCTAssertEqual(cleared.total, 0)

        let snapshots = await Self.backupInspector(dataDir: dataDir, backupDir: backupDir).snapshots()
        XCTAssertTrue(snapshots.isEmpty, "空清除不该留底，实际：\(snapshots.map(\.url.lastPathComponent))")
    }

    /// `:memory:` 库没有落盘文件可保护：清除照样要能走（不留底也不拦），否则内存库永远清不动。
    func testClearLearningMemoryWithInMemoryDatabaseStillWorks() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-memclear-\(UUID().uuidString).json")
        )
        let services = CoachServices(config: store, databasePath: ":memory:")
        let sessionID = UUID()
        await services.persistSession(ChatSession(id: sessionID, startedAt: Date()))
        await services.persistCorrection(
            GrammarCorrection(original: "I have went", corrected: "I went", explanation: "past tense"),
            sessionID: sessionID
        )

        let cleared = try await services.clearLearningMemory()
        XCTAssertGreaterThanOrEqual(cleared.corrections, 1, "内存库的清除不该被「留不了底」拦住")

        let backupDirectory = await services.backupDirectory
        let inspector = DataBackup(dataDirectory: backupDirectory, backupDirectory: backupDirectory)
        let snapshots = await inspector.snapshots()
        XCTAssertTrue(snapshots.isEmpty, "没有落盘文件就没有「底」可留")
    }

    /// 库不可用时必须报错，且**不**产生留底（什么都没删，凭什么留底）。
    func testClearLearningMemoryThrowsWhenTheDatabaseWillNotOpen() async throws {
        let services = CoachServices(databasePath: "/dev/null/alc-no-such-dir/learning.db")
        let available = await services.isPersistenceAvailable
        XCTAssertFalse(available, "这条用例要求库打不开")

        do {
            _ = try await services.clearLearningMemory()
            XCTFail("库打不开应当抛错，而不是返回 0 假装清干净了")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(message.contains("学习库"), "错误要说明原因，实际：\(message)")
        }

        let backupDirectory = await services.backupDirectory
        let inspector = DataBackup(
            dataDirectory: backupDirectory,
            backupDirectory: backupDirectory
        )
        let snapshots = await inspector.snapshots()
        XCTAssertTrue(snapshots.isEmpty, "失败路径不该留底")
    }

    // MARK: - 导出（纯函数）

    /// Markdown 要把会话、说话人与纠错表写全，且表格单元格里的竖线必须转义。
    func testMarkdownCoversSessionsAndCorrectionsAndEscapesPipes() {
        let summary = SessionSummary(
            sessionID: UUID(),
            startedAt: Self.date("2026-10-02 14:30"),
            endedAt: Self.date("2026-10-02 15:00"),
            messageCount: 2,
            corrections: [GrammarCorrection(
                original: "I | like | it",
                corrected: "I like it",
                explanation: "竖线测试, 逗号测试"
            )]
        )
        let transcript = LearningDataExporter.SessionTranscript(
            summary: summary,
            messages: [
                ChatMessage(role: .system, content: "system prompt 应当被跳过"),
                ChatMessage(role: .user, content: "Hello\nworld"),
                ChatMessage(role: .assistant, content: "Hi there"),
            ]
        )

        let output = LearningDataExporter.export(sessions: [transcript], vocabulary: [], now: Self.date("2026-10-02 20:00"))
        let md = output.markdown

        XCTAssertTrue(md.contains("# 学习记录导出"))
        XCTAssertTrue(md.contains("## 练习会话（1 次）"))
        XCTAssertTrue(md.contains("**我**：Hello world"), "换行要压成空格，实际：\(md)")
        XCTAssertTrue(md.contains("**老师**：Hi there"))
        XCTAssertFalse(md.contains("system prompt"), "system 消息不该出现在导出里")
        XCTAssertTrue(md.contains("| I ｜ like ｜ it |"), "竖线必须换成全角，实际：\(md)")
        XCTAssertTrue(md.contains("## 错题汇总（1 条）"))
        XCTAssertEqual(md.filter { $0 == "|" }.count % 2, 0, "表格行必须成对出现竖线")
    }

    /// CSV 字段转义（RFC 4180）：含逗号 / 引号 / 换行的字段加引号，内部引号翻倍。
    func testCSVEscapingFollowsRFC4180() {
        XCTAssertEqual(LearningDataExporter.csvEscape("plain"), "plain")
        XCTAssertEqual(LearningDataExporter.csvEscape("a,b"), "\"a,b\"")
        XCTAssertEqual(LearningDataExporter.csvEscape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(LearningDataExporter.csvEscape("line1\nline2"), "\"line1\nline2\"")
    }

    /// CSV 表体：单词本一行一词，列与表头对齐；空本子只剩表头。
    func testCSVRowsMatchTheHeaderShape() {
        let entry = VocabularyEntry(
            word: "serendipity",
            meaning: "意外发现的乐趣, 缘分",
            example: "A serendipity moment.",
            createdAt: Self.date("2026-10-02 08:00")
        )
        let output = LearningDataExporter.export(sessions: [], vocabulary: [entry], now: Date())
        let lines = output.csv.split(separator: "\r\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "表头 + 1 行")
        XCTAssertTrue(lines[0].hasPrefix("单词,"))
        XCTAssertTrue(lines[1].contains("\"serendipity\"") == false, "普通字段不该被加引号")
        XCTAssertTrue(lines[1].contains("意外发现的乐趣, 缘分"))

        let empty = LearningDataExporter.export(sessions: [], vocabulary: [], now: Date())
        XCTAssertEqual(empty.csv.split(separator: "\r\n").count, 1, "空单词本只剩表头")
        XCTAssertTrue(empty.markdown.contains("（还没有练习会话）"))
    }

    // MARK: - 接线哨兵（源码级，跳过注释行）

    /// 「清除前留底」必须写在删除**之前**，且留底失败要中止删除。
    func testClearLearningMemoryBacksUpBeforeDeleteInSource() throws {
        let raw = try Self.code("Sources/AIServices/CoachServices.swift")
        let body = try Self.functionBody(named: "clearLearningMemory", in: raw)
        let backupCall = try XCTUnwrap(
            body.range(of: "export(label: \"清除前\")"),
            "clearLearningMemory 里没有「清除前」留底 —— 后悔药被撤了"
        )
        let deleteCall = try XCTUnwrap(
            body.range(of: "learning.clearLearningMemory()"),
            "clearLearningMemory 里没有删除调用，哨兵判据失效"
        )
        XCTAssertLessThan(backupCall.lowerBound, deleteCall.lowerBound, "留底必须在删除之前")
        XCTAssertTrue(body.contains("已中止删除"), "留底失败必须中止删除，不能带病继续")
    }

    /// 四条 DELETE 必须包在事务里（半清除状态比全不清更糟）。
    func testClearLearningMemoryRunsInATransaction() throws {
        let raw = try Self.code("Sources/AIInfrastructure/LearningDatabase.swift")
        let body = try Self.functionBody(named: "clearLearningMemory", in: raw)
        XCTAssertTrue(body.contains("runInTransaction"), "四条 DELETE 必须包进事务，任一失败整体回滚")
    }

    /// 自动备份补完新包必须 prune（自动化自己堆的文件自己收）。
    func testAutoBackupPrunesAfterExport() throws {
        let raw = try Self.code("Sources/AppUI/AppState+Maintenance.swift")
        let body = try Self.functionBody(named: "ensureAutoBackupIfNeeded", in: raw)
        XCTAssertTrue(body.contains("pruneBackups"), "自动备份成功后要清理旧包，否则备份目录只进不出")
    }

    /// 设置页要有删除与 Finder 入口；记录页要有导出入口。
    func testManagementEntriesAreWired() throws {
        let settings = try Self.code("Sources/AppUI/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("deleteBackup(at: item.url)"), "备份行上要有删除按钮")
        XCTAssertTrue(settings.contains("revealBackupsInFinder"), "要有「在 Finder 中显示」入口")

        let records = try Self.code("Sources/AppUI/Views/RecordsView.swift")
        XCTAssertTrue(records.contains("exportLearningRecords"), "记录页要有「导出学习记录」入口")
    }

    // MARK: - 现场工具

    private nonisolated static func makeBackupDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-backup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 一套完全隔离的 CoachServices：库、配置、备份全落在临时目录里（互不共享）。
    private nonisolated static func makeIsolatedServices() -> (CoachServices, URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-datasafety-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backupDir = dir.appendingPathComponent("backups", isDirectory: true)
        let services = CoachServices(
            databasePath: dir.appendingPathComponent("learning.db").path,
            backupDirectory: backupDir
        )
        return (services, dir, backupDir)
    }

    /// 备份目录的检查入口（与被测服务同一份目录构造，读的是真东西）。
    private nonisolated static func backupInspector(dataDir: URL, backupDir: URL) -> DataBackup {
        DataBackup(dataDirectory: dataDir, backupDirectory: backupDir)
    }

    /// `DataBackup.fileStamp` 同形状的文件名时间戳（day 当天序号，递增即可）。
    private nonisolated static func stamp(day: Int) -> String {
        String(format: "202601%02d-120000", day)
    }

    private nonisolated static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: text) ?? Date()
    }

    /// 读源码并剥掉注释行（注释里的同款字符串不该把哨兵骗绿）。
    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 提取某个函数的**函数体**（brace 计数），避免同名调用点干扰。
    private nonisolated static func functionBody(named name: String, in source: String) throws -> String {
        guard let signature = source.range(of: "func \(name)") else {
            throw NSError(domain: "sentinel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到函数 \(name)"])
        }
        guard let open = source.range(of: "{", range: signature.upperBound..<source.endIndex) else {
            throw NSError(domain: "sentinel", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 \(name) 的函数体开头"])
        }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[open.lowerBound..<index])
                }
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "sentinel", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "\(name) 的函数体没有闭合"])
    }
}
