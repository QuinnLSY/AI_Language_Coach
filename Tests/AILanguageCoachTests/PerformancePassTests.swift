import XCTest
@testable import AIDomain
@testable import AIInfrastructure
@testable import AIServices
@testable import AppUI

/// ③ 性能体感批次（#436–#440）的语义锁定：
/// 索引存在性 / 词汇批量导入与去重 / 进度页词汇一次读取 / 状态下沉与渲染缓存的源码哨兵。
final class PerformancePassTests: XCTestCase {

    // MARK: - 工具

    private nonisolated static func makeTemporaryDB() throws -> (LearningDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("learning.db")
        let db = try LearningDatabase(path: url.path)
        return (db, url)
    }

    /// 剥注释行后的源码（哨兵判据只看代码，不看注释）。
    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 提取某个函数的**函数体**（brace 计数），避免同名调用点干扰。
    private nonisolated static func functionBody(named name: String, in source: String) throws -> String {
        try functionBody(after: "func \(name)", in: source)
    }

    /// 同上，但锚点是任意声明片段（ computed var 用 `var canSend: Bool` 这类）。
    private nonisolated static func functionBody(after marker: String, in source: String) throws -> String {
        guard let signature = source.range(of: marker) else {
            throw NSError(domain: "sentinel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到声明 \(marker)"])
        }
        guard let open = source.range(of: "{", range: signature.upperBound..<source.endIndex) else {
            throw NSError(domain: "sentinel", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 \(marker) 的函数体开头"])
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
                      userInfo: [NSLocalizedDescriptionKey: "\(marker) 函数体没有收口"])
    }

    private nonisolated static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - #436 索引

    /// 年度扫描的四条索引必须真实存在（建表时创建，老库打开也会补建）。
    func testYearlyScanIndexesExist() throws {
        let (db, url) = try Self.makeTemporaryDB()
        _ = db // 持有连接，别提前释放
        let reader = try SQLiteDatabase(path: url.path)
        defer { reader.close() }
        let names = try reader.query(
            "SELECT name FROM sqlite_master WHERE type = 'index'"
        ) { $0.string(0) }
        for expected in ["idx_messages_created", "idx_corrections_created",
                         "idx_vocab_reviews_created", "idx_vocab_word_nocase"] {
            XCTAssertTrue(names.contains(expected), "缺索引 \(expected) —— 年度/窗口扫描会退化成全表扫")
        }
    }

    /// word 的业务唯一键是**大小写不敏感**的（NOCASE 唯一索引 + 查重同口径）。
    func testVocabularyWordIsCaseInsensitiveUnique() async throws {
        let (db, url) = try Self.makeTemporaryDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = (try? await db.upsertVocabulary(VocabularyEntry(word: "Apple", source: .review))) ?? false
        XCTAssertTrue(first, "首次插入应当成功")
        let second = (try? await db.upsertVocabulary(VocabularyEntry(word: "apple", source: .review))) ?? false
        XCTAssertFalse(second, "大小写变体不允许再插一行（复习进度会裂成两份）")
        let all = try await db.allVocabulary()
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - #437 批量导入

    /// 批量插入的去重语义：空批 0；新词全插；重插 0；混批只插缺的；大小写变体不算新词。
    func testInsertVocabularyIfAbsentBatchSemantics() async throws {
        let (db, url) = try Self.makeTemporaryDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let empty = try await db.insertVocabularyIfAbsent([])
        XCTAssertEqual(empty, 0, "空批不该碰数据库")

        let batch = ["apple", "banana", "cherry"].map { VocabularyEntry(word: $0, source: .review) }
        let firstRun = try await db.insertVocabularyIfAbsent(batch)
        XCTAssertEqual(firstRun, 3, "三个新词应当全部插入")

        let secondRun = try await db.insertVocabularyIfAbsent(batch)
        XCTAssertEqual(secondRun, 0, "同一批重插不应新增（复习进度不能被抹平）")

        let mixed = ["banana", "date"].map { VocabularyEntry(word: $0, source: .review) }
        let mixedRun = try await db.insertVocabularyIfAbsent(mixed)
        XCTAssertEqual(mixedRun, 1, "混批只插缺的那一个")

        let caseVariant = [VocabularyEntry(word: "APPLE", source: .review)]
        let variantRun = try await db.insertVocabularyIfAbsent(caseVariant)
        XCTAssertEqual(variantRun, 0, "大小写变体不算新词")

        let all = try await db.allVocabulary()
        XCTAssertEqual(all.count, 4)
    }

    // MARK: - #438 进度页词汇一次读取

    /// snapshot / weeklyInsight 接受外部注入的词汇，不再各自全表扫一遍。
    func testProgressQueriesAcceptPreloadedVocabulary() async throws {
        let (db, url) = try Self.makeTemporaryDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = ProgressService(learning: db)
        let preloaded = [
            VocabularyEntry(word: "preloaded-one", source: .review),
            VocabularyEntry(word: "preloaded-two", source: .review),
        ]

        let bare = await service.snapshot()
        XCTAssertEqual(bare.vocabulary.total, 0, "空库不注入时词汇应为 0")

        let snapshot = await service.snapshot(preloadedVocabulary: preloaded)
        XCTAssertEqual(snapshot.vocabulary.total, 2, "snapshot 必须使用注入的词汇（否则三处取数各扫一遍）")

        let insight = await service.weeklyInsight(preloadedVocabulary: preloaded)
        let weekNewWords = insight?.weekNewWords ?? -1
        XCTAssertEqual(weekNewWords, 2, "weeklyInsight 必须使用注入的词汇折本周新增")

        let recap = await service.annualRecap(preloadedVocabulary: preloaded)
        let practiced = recap.weeks.flatMap { $0 }.compactMap { $0 }.contains { $0.activity.hasPractice }
        XCTAssertTrue(practiced, "年度记录：注入词汇后「今天收过词」应算练过")
    }

    /// reloadProgress 里词汇只取一次、三处消费点共用（源码哨兵，限定函数体）。
    func testReloadProgressFetchesVocabularyOnce() throws {
        let raw = try Self.code("Sources/AppUI/AppState+Progress.swift")
        let body = try Self.functionBody(named: "reloadProgress", in: raw)
        let fetches = Self.occurrences(of: "services.progressVocabulary()", in: body)
        XCTAssertEqual(fetches, 1, "词汇全量只许取一次（原来 snapshot/weeklyInsight/annualRecap 各扫一遍）")
        let consumers = Self.occurrences(of: "preloadedVocabulary: vocabulary", in: body)
        XCTAssertEqual(consumers, 4, "三件套（weeklyInsight/snapshot×2/annualRecap）都要吃同一份词汇")
    }

    // MARK: - #439 渲染

    /// 消息列表必须用 LazyVStack（长会话只渲染屏幕附近的气泡）。
    func testChatMessageListUsesLazyVStack() throws {
        let raw = try Self.code("Sources/AppUI/Views/ChatView.swift")
        XCTAssertTrue(
            raw.contains("LazyVStack(alignment: .leading, spacing: 14)"),
            "消息列表退回 VStack = 长会话一次性搭出全部气泡"
        )
    }

    /// MarkdownText 的 body 必须走缓存（cachedBlocks），parseBlocks 只许在缓存器内部调用一次。
    func testMarkdownTextBodyUsesParseCache() throws {
        let raw = try Self.code("Sources/AppUI/Components/MarkdownText.swift")
        let calls = Self.occurrences(of: "parseBlocks(text)", in: raw)
        XCTAssertEqual(calls, 1, "parseBlocks(text) 只许出现在 cachedBlocks 内部 —— body 直接调 = 流式 O(n²)")
        XCTAssertTrue(raw.contains("static func cachedBlocks"), "解析缓存被撤了")
    }

    // MARK: - #440 轮换状态下沉

    /// 轮换下标不得再留在 ChatView 根级：identifier 全文件清零 + 根级 Timer 撤掉 + canSend index-free。
    func testStarterQuestionRotationIsSunkIntoSubview() throws {
        let raw = try Self.code("Sources/AppUI/Views/ChatView.swift")
        XCTAssertEqual(Self.occurrences(of: "questionIndex", in: raw), 0,
                       "轮换下标又回到根级 = 每 3.4 秒重算整个对话视图")
        XCTAssertEqual(Self.occurrences(of: "Timer.publish", in: raw), 2,
                       "根级轮换时钟必须撤掉（只留 TypingDots 与占位子视图两处）")
        let canSendBody = try Self.functionBody(after: "var canSend: Bool", in: raw)
        XCTAssertTrue(canSendBody.contains("exam == nil && !starterQuestions.isEmpty"),
                      "canSend 必须用 index-free 判断")
        XCTAssertFalse(canSendBody.contains("rotator"),
                       "canSend 在父 body 里求值，读了 rotator（哪怕多一个 && 条件）父级就会订阅下标")
    }

    /// 轮换器语义：advance 守卫（输入空 / 没在生成 / 多于一条）与取模回绕。
    @MainActor
    func testStarterQuestionRotatorAdvanceGuards() {
        let rotator = StarterQuestionRotator()
        XCTAssertNil(rotator.current)

        rotator.update(questions: ["a", "b", "c"])
        XCTAssertEqual(rotator.current, "a")
        XCTAssertEqual(rotator.index, 0)

        // 输入框有字 / 正在生成 / 只有一条 —— 三种情况都不许动。
        rotator.advance(isInputEmpty: false, isGenerating: false)
        XCTAssertEqual(rotator.index, 0)
        rotator.advance(isInputEmpty: true, isGenerating: true)
        XCTAssertEqual(rotator.index, 0)
        rotator.update(questions: ["only"])
        rotator.advance(isInputEmpty: true, isGenerating: false)
        XCTAssertEqual(rotator.index, 0)

        // 正常轮换 + 回绕。
        rotator.update(questions: ["a", "b", "c"])
        rotator.advance(isInputEmpty: true, isGenerating: false)
        rotator.advance(isInputEmpty: true, isGenerating: false)
        XCTAssertEqual(rotator.current, "c")
        rotator.advance(isInputEmpty: true, isGenerating: false)
        XCTAssertEqual(rotator.current, "a", "轮换要回绕")

        // 同一批内容重复 update 不归零（换页重建视图不该打断轮换）。
        rotator.advance(isInputEmpty: true, isGenerating: false)
        XCTAssertEqual(rotator.index, 1)
        rotator.update(questions: ["a", "b", "c"])
        XCTAssertEqual(rotator.index, 1, "内容没变的 update 不该把轮换归零")
    }
}
