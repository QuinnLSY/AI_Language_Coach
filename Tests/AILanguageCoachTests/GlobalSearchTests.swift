import XCTest

@testable import AIDomain
@testable import AIInfrastructure

/// 跨页全局搜索的纯函数与 SQL 安全（#414）。
///
/// 判据三块：①匹配与排序的口径（搜 "cat" 时 category 不该压过 cat）；
/// ②截断（对话命中可以成百上千条，不截断就把想要的那个挤没了）；
/// ③LIKE 转义（用户输入进 SQL 的**唯一**入口，一个 % 就能让查询变成「命中一切」）。
final class GlobalSearchTests: XCTestCase {

    // MARK: - 打分

    func testExactMatchBeatsPrefixBeatsWordStartBeatsContains() {
        let exact = GlobalSearch.score(text: "cat", query: "cat")
        let prefix = GlobalSearch.score(text: "category", query: "cat")
        let wordStart = GlobalSearch.score(text: "re-read", query: "read")
        let contains = GlobalSearch.score(text: "spread", query: "read")
        let miss = GlobalSearch.score(text: "dog", query: "cat")

        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, wordStart, "前缀要比「词首在中间」更相关")
        XCTAssertGreaterThan(wordStart, contains)
        XCTAssertEqual(miss, 0)
    }

    func testScoringIgnoresCase() {
        XCTAssertEqual(GlobalSearch.score(text: "CAT", query: "cat"), GlobalSearch.score(text: "cat", query: "cat"))
    }

    func testEmptyQueryNeverMatches() {
        XCTAssertEqual(GlobalSearch.score(text: "cat", query: ""), 0)
        // 空查询不该返回全部 —— 那不是「搜索」，是把整个词表倒出来。
        XCTAssertTrue(GlobalSearch.hits(query: "   ", vocabulary: [VocabularyEntry(word: "cat")]).isEmpty)
    }

    // MARK: - 片段

    func testSnippetAddsEllipsisOnlyWhenReallyTruncated() {
        let short = GlobalSearch.snippet(text: "I have a cat", query: "cat")
        XCTAssertFalse(short.contains("…"), "全文装得下却挂省略号，会让人以为被截断")

        let long = String(repeating: "word ", count: 40) + "cat" + String(repeating: " tail", count: 40)
        let snippet = GlobalSearch.snippet(text: long, query: "cat")
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("cat"))
        XCTAssertLessThan(snippet.count, long.count)
    }

    func testNormalizeCollapsesWhitespace() {
        XCTAssertEqual(GlobalSearch.normalize("  cat   \n dog "), "cat dog")
    }

    // MARK: - 合并与截断

    func testHitsGroupByKindInStableOrder() {
        let hits = GlobalSearch.hits(
            query: "cat",
            vocabulary: [VocabularyEntry(word: "cat", meaning: "猫")],
            dictionary: [DictionaryWord(word: "catalog", translation: "目录", bookID: "test")],
            messages: [GlobalSearchMessage(
                sessionID: UUID(), messageID: "m1", role: "user",
                snippet: "my cat is fat", createdAt: Date()
            )],
            readings: [ReadingPassage(title: "A cat", text: "a cat sat", questions: [], dayKey: 1)]
        )
        XCTAssertEqual(hits.map { $0.kind.rawValue },
                       [GlobalSearchKind.vocabulary.rawValue,
                        GlobalSearchKind.dictionary.rawValue,
                        GlobalSearchKind.conversation.rawValue,
                        GlobalSearchKind.reading.rawValue])
    }

    func testEachKindIsCapped() {
        let many = (0..<40).map { VocabularyEntry(word: "cat\($0)") }
        let hits = GlobalSearch.hits(query: "cat", vocabulary: many)
        XCTAssertEqual(hits.count, GlobalSearch.defaultLimitPerKind,
                       "一个来源不截断，搜常见词会把界面塞满、把想要的那个挤到看不见")
    }

    func testNonMatchingCandidatesDropped() {
        let hits = GlobalSearch.hits(query: "cat", vocabulary: [VocabularyEntry(word: "dog")])
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - SQL 安全

    func testLikeWildcardsAreEscaped() {
        XCTAssertEqual(LearningDatabase.likeEscaped("50%"), #"50\%"#)
        XCTAssertEqual(LearningDatabase.likeEscaped("a_b"), #"a\_b"#)
        // 转义符本身也要转，否则 `\%` 会被当成「转义后的普通字符」而丢掉转义。
        XCTAssertEqual(LearningDatabase.likeEscaped(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(LearningDatabase.likeEscaped("cat"), "cat")
    }

    /// 用户输入进 SQL 的**唯一**入口必须是参数绑定 + ESCAPE：
    /// 拼字符串时一个引号就能让整条查询变成语法错误（或更糟）。
    ///
    /// ⚠️ 只扫**非注释行**：注释里写了同样的字符串会让哨兵假绿（09-25 教训）。
    func testMessageSearchBindsParametersAndDeclaresEscape() throws {
        let raw = try String(contentsOfFile: "Sources/AIInfrastructure/LearningDatabase.swift", encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let body = lines.drop(while: { !$0.contains("func searchMessages") })
            .prefix(while: { !$0.contains("return rows.compactMap") })
            .joined(separator: "\n")
        XCTAssertTrue(body.contains("LIKE ?1"), "必须用参数绑定，不能把用户输入拼进 SQL")
        XCTAssertTrue(body.contains("ESCAPE"), "要声明转义符，likeEscaped 加的反斜杠才有意义")
        XCTAssertTrue(body.contains("likeEscaped"), "必须先转义再包 %…%：搜「50%」不该命中一切")
    }

    // MARK: - 命中之后要能定位（2026-10-01 补）

    /// 对话命中带着 `sessionID` —— 点了要能直接展开那一条记录，
    /// 否则落在记录页顶部，用户还得自己在几十条里翻。
    func testConversationHitCarriesItsSessionID() {
        let sessionID = UUID()
        let hit = GlobalSearchHit(id: "message|\(sessionID.uuidString)|m1",
                                  kind: .conversation, title: "我", detail: "…")
        XCTAssertEqual(hit.sessionID, sessionID)
        // 别把别的来源的 id 当成会话（kind 与前缀都要对上）。
        let reading = GlobalSearchHit(id: "reading|20261001|标题", kind: .reading,
                                      title: "标题", detail: "…")
        XCTAssertNil(reading.sessionID)
        let broken = GlobalSearchHit(id: "message|不是UUID|m1", kind: .conversation,
                                     title: "我", detail: "…")
        XCTAssertNil(broken.sessionID, "解析不出来就当没有，不能拿去跳转")
    }

    func testReadingHitCarriesDayKeyAndTitle() {
        let hit = GlobalSearchHit(id: "reading|20261001|The Slow Train",
                                  kind: .reading, title: "The Slow Train", detail: "…")
        XCTAssertEqual(hit.readingDayKey, 20261001)
        XCTAssertEqual(hit.readingTitle, "The Slow Train")
        let conversation = GlobalSearchHit(id: "message|x|y", kind: .conversation,
                                           title: "我", detail: "…")
        XCTAssertNil(conversation.readingDayKey)
    }

    /// 跳转必须真的用上这两个信息（解析出来却不用，等于没修）。
    func testOpeningAHitUsesTheLocatorsAndClearsTheQuery() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/AppState+GlobalSearch.swift",
                             encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        XCTAssertTrue(lines.joined(separator: "\n").contains(".sessionReview($0)"),
                      "对话命中没定位到会话")
        XCTAssertTrue(lines.joined(separator: "\n").contains("dayKey: hit.readingDayKey"),
                      "阅读命中没定位到那一天")
        // ⚠️ 清词这条必须**只看跳转函数体内**：`closeGlobalSearch()` 里也有一句
        // `globalSearchQuery = ""`，全文件匹配的话撤掉跳转处的清词也照样绿（假绿）。
        let openBody = lines
            .drop(while: { !$0.contains("func open(globalSearchHit") })
            .prefix(while: { !$0.contains("switch hit.kind") })
            .joined(separator: "\n")
        XCTAssertTrue(openBody.contains("globalSearchQuery = \"\""),
                      "点了结果要连查询词一起清（否则下次打开是「旧词 + 没有找到」）")
    }

    /// 阅读来源必须走**库里最近读过的**，不能只读内存里今天那一两篇。
    func testReadingSourceReadsStoredHistory() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/AppState+GlobalSearch.swift",
                             encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let body = lines.joined(separator: "\n")
        XCTAssertTrue(body.contains("services.recentReadings()"), "阅读来源没走库")
        XCTAssertFalse(body.contains("readingEntries.map { $0.passage }"),
                       "只读内存里的今天那批，昨天读的短文就搜不到")
    }
}
