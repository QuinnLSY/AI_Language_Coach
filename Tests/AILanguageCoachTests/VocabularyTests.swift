import AIDomain
import AIInfrastructure
import AIServices
import XCTest

/// 词汇本（第 24 步）：调度纯函数 / 输出解析 / 生词清洗 / 落库与去重。
final class VocabularyTests: XCTestCase {

    // MARK: - ReviewScheduler（复习调度，Plan §24 硬要求：复习逻辑与 UI 分离）

    /// ⚠️ `createdAt` 的默认值**必须**是「此刻」而不是某个固定时刻：
    /// `VocabularyStats` 的今日指标靠 `createdAt < 今天 0 点` 区分「今天新加的词」，
    /// 默认值一改，既有用例的语义会跟着静默变化（实测把它设成 1970 后
    /// `testStatsCounts` 的「今天起初到期」从 0 变成 3）。要固定时间就在用例里显式传。
    private func makeEntry(
        word: String = "apple",
        meaning: String = "",
        mastery: Int = 0,
        reviewCount: Int = 0,
        lastReviewedAt: Date? = nil,
        ease: Double = ReviewScheduler.defaultEase,
        createdAt: Date = Date()
    ) -> VocabularyEntry {
        VocabularyEntry(
            word: word, meaning: meaning, mastery: mastery,
            reviewCount: reviewCount, lastReviewedAt: lastReviewedAt, ease: ease,
            createdAt: createdAt
        )
    }

    func testNewWordIsAlwaysDue() {
        // 没复习过的新词永远当天到期 —— 否则加了词就再也不会见到第二面。
        XCTAssertTrue(ReviewScheduler.isDue(makeEntry(mastery: 0)))
        // 刚复习完的（掌握度 3 → 间隔 4 天）不该立刻又到期。
        XCTAssertFalse(ReviewScheduler.isDue(makeEntry(mastery: 3, lastReviewedAt: Date())))
    }

    func testMasteredWordIsNeverDue() {
        XCTAssertFalse(ReviewScheduler.isDue(makeEntry(mastery: 5, lastReviewedAt: Date(timeIntervalSinceNow: -100 * 86_400))))
        XCTAssertTrue(makeEntry(mastery: 5).isMastered)
    }

    func testIntervalGrowsWithMastery() throws {
        // 掌握度 1 → 间隔 1 天：刚复习完不到 1 天不该到期。
        let yesterday = Date(timeIntervalSinceNow: -0.5 * 86_400)
        XCTAssertFalse(ReviewScheduler.isDue(makeEntry(mastery: 1, lastReviewedAt: yesterday)))
        // 掌握度 0 → 间隔 0 天：复习完立刻又到期（今天内可反复过）。
        XCTAssertTrue(ReviewScheduler.isDue(makeEntry(mastery: 0, lastReviewedAt: Date())))
        // 掌握度 2 → 间隔 2 天：过了 2 天多才到期。
        let threeDaysAgo = Date(timeIntervalSinceNow: -3 * 86_400)
        XCTAssertTrue(ReviewScheduler.isDue(makeEntry(mastery: 2, lastReviewedAt: threeDaysAgo)))
    }

    func testGradedRememberedRaisesMasteryAndCapsAtFive() {
        let now = Date()
        let up = ReviewScheduler.graded(makeEntry(mastery: 2, reviewCount: 1), .remembered, now: now)
        XCTAssertEqual(up.mastery, 3)
        XCTAssertEqual(up.reviewCount, 2)
        XCTAssertEqual(up.lastReviewedAt, now)

        let capped = ReviewScheduler.graded(makeEntry(mastery: 5), .remembered, now: now)
        XCTAssertEqual(capped.mastery, 5, "掌握度封顶 5")
    }

    func testGradedForgottenLowersMasteryAndFloorsAtZero() {
        let down = ReviewScheduler.graded(makeEntry(mastery: 3), .forgotten)
        XCTAssertEqual(down.mastery, 2)
        XCTAssertEqual(down.reviewCount, 1)
        let floored = ReviewScheduler.graded(makeEntry(mastery: 0), .forgotten)
        XCTAssertEqual(floored.mastery, 0, "保底 0，不为负")
    }

    // MARK: - 每词难度系数（复习间隔按词自适应）

    /// 中性系数下间隔必须**与没有这个系数时完全一样** ——
    /// 老用户升级上来不该发现复习节奏变了。
    func testDefaultEaseLeavesTheLadderUntouched() {
        for mastery in 0..<ReviewScheduler.intervalDays.count {
            let base = Double(ReviewScheduler.intervalDays[mastery])
            XCTAssertEqual(
                ReviewScheduler.reviewIntervalDays(for: makeEntry(mastery: mastery)),
                base, accuracy: 1e-9,
                "掌握度 \(mastery) 在中性系数下间隔应仍是 \(base) 天"
            )
        }
    }

    /// 「总忘的词」要比同档位的其它词更早被叫回来 —— 这条就是这次改造的全部目的。
    func testForgottenWordsComeBackSoonerThanSameMasteryPeers() {
        let reviewedAt = Date()
        let threeDaysLater = Date(timeIntervalSinceNow: 3 * 86_400)
        let stubborn = makeEntry(mastery: 3, lastReviewedAt: reviewedAt, ease: ReviewScheduler.minEase)
        let easy = makeEntry(mastery: 3, lastReviewedAt: reviewedAt, ease: ReviewScheduler.maxEase)
        // 同为间隔 4 天的档位，第 3 天：系数触底的已到期（4×0.52≈2.1 天），封顶的还没到（≈4.5 天）。
        XCTAssertTrue(ReviewScheduler.isDue(stubborn, now: threeDaysLater))
        XCTAssertFalse(ReviewScheduler.isDue(easy, now: threeDaysLater))
    }

    /// 系数跟着判分走，且不越界。
    func testEaseMovesWithGradesAndStaysWithinBounds() {
        var forgotten = makeEntry(mastery: 3)
        for _ in 0..<6 { forgotten = ReviewScheduler.graded(forgotten, .forgotten) }
        XCTAssertEqual(forgotten.ease, ReviewScheduler.minEase, accuracy: 1e-9, "连错到底要触底")

        var remembered = makeEntry(mastery: 0)
        for _ in 0..<5 { remembered = ReviewScheduler.graded(remembered, .remembered) }
        XCTAssertEqual(remembered.ease, ReviewScheduler.maxEase, accuracy: 1e-9, "连对到底要封顶")

        // 答错减得比答对加得多：忘一次的代价本就该大于记住一次的收益。
        XCTAssertGreaterThan(ReviewScheduler.easeStepDown, ReviewScheduler.easeStepUp)
    }

    /// 系数必须能落库取回。
    ///
    /// ⚠️ 这条专治「静默失效」：`ease` 在 init 里**有默认值**，读库时漏掉这一列
    /// 编译器一声不响 —— 表现是「自适应做了但好像没生效」，极难查。
    func testEaseSurvivesDatabaseRoundTrip() async throws {
        // ⚠️ `inMemory()` 是**同步** throwing 工厂（actor 的 static 方法默认 nonisolated），
        // 写 `try await` 会吃一条 "no 'async' operations occur within 'await'" 警告。
        let db = try LearningDatabase.inMemory()
        var entry = makeEntry(word: "stubborn", mastery: 2)
        entry.ease = ReviewScheduler.minEase
        // ⚠️ 别把 `await` 写进 XCTAssert 的 autoclosure —— 它不支持并发，编译不过。
        let inserted = try await db.upsertVocabulary(entry)
        XCTAssertTrue(inserted, "前提：这个词确实新插入了")
        let all = try await db.allVocabulary()
        let restored = try XCTUnwrap(all.first)
        XCTAssertEqual(restored.ease, ReviewScheduler.minEase, accuracy: 1e-9)
    }

    func testStatsCounts() {
        let now = Date()
        let entries = [
            makeEntry(word: "a", mastery: 5, lastReviewedAt: now),           // 已掌握
            makeEntry(word: "b", mastery: 0, lastReviewedAt: now),           // 到期（间隔 0）
            makeEntry(word: "c", meaning: "苹果", mastery: 3, lastReviewedAt: now), // 未到期
        ]
        let stats = VocabularyStats.from(entries, now: now)
        XCTAssertEqual(stats.total, 3)
        XCTAssertEqual(stats.mastered, 1)
        XCTAssertEqual(stats.due, 1)
        XCTAssertEqual(stats.defined, 1)
        // 这三个词都是「此刻」建的 → 今天 0 点时它们还不存在，不进今天的复习指标。
        XCTAssertEqual(stats.dueAtDayStart, 0)
        XCTAssertEqual(VocabularyStats.from([]), .empty)
    }

    // MARK: - 当天起初的到期盘子（每日任务的固定指标）

    /// 三种词各自归谁：
    /// - 昨天入本、今天之前就到期且没碰过 → **算**（今天 0 点的存量）；
    /// - 昨天入本、今天复习过 → **也算**（`lastReviewedAt` 已被这次复习覆盖，光看它反而漏算；
    ///   而复习队列只取到期词，「今天碰过」本身就说明它今天开始时到期）；
    /// - 今天才入本 → **不算**（今天 0 点时它还不在词汇本里）。
    func testDueAtStartOfDayCountsTheMorningBacklog() {
        let calendar = Calendar.current
        let now = Date()
        let midnight = calendar.startOfDay(for: now)
        let yesterday = midnight.addingTimeInterval(-3_600)
        let twoDaysAgo = midnight.addingTimeInterval(-2 * 86_400)

        let aged = VocabularyEntry(
            word: "aged", mastery: 1, reviewCount: 1,
            lastReviewedAt: twoDaysAgo, createdAt: twoDaysAgo)
        let reviewedToday = VocabularyEntry(
            word: "today", mastery: 2, reviewCount: 1,
            lastReviewedAt: now, createdAt: yesterday)
        let mastered = VocabularyEntry(
            word: "done", mastery: 5, reviewCount: 9,
            lastReviewedAt: twoDaysAgo, createdAt: twoDaysAgo)
        let addedToday = VocabularyEntry(word: "fresh", mastery: 0, createdAt: now)

        let due = ReviewScheduler.dueAtStartOfDayEntries(
            [aged, reviewedToday, mastered, addedToday], day: now, calendar: calendar
        )
        XCTAssertEqual(due.map(\.word).sorted(), ["aged", "today"])
    }

    /// **核心回归**：今天起初 8 个到期词，复习掉 3 个之后指标**仍然是 8**。
    ///
    /// 撤掉修复（指标改回「此刻到期」）时这条会红：那会算成 5。
    /// 用户原话：「今日原本的复习任务是 8 个单词，完成之后应该还是显示 8/8 已完成」
    /// —— 指标是**当天定住**的量，不随复习缩水。
    func testDayStartIndicatorDoesNotShrinkAsYouReview() {
        let calendar = Calendar.current
        let now = Date()
        let midnight = calendar.startOfDay(for: now)
        let yesterday = midnight.addingTimeInterval(-86_400)

        // 8 个昨天入本、掌握度 0 的词：间隔 0 天 → 今天 0 点一定到期。
        func entry(_ index: Int, reviewedAt: Date?) -> VocabularyEntry {
            VocabularyEntry(
                word: "w\(index)",
                mastery: reviewedAt == nil ? 0 : 1,
                reviewCount: reviewedAt == nil ? 0 : 1,
                lastReviewedAt: reviewedAt,
                createdAt: yesterday
            )
        }

        var entries = (1...8).map { entry($0, reviewedAt: nil) }
        XCTAssertEqual(
            VocabularyStats.from(entries, now: now, calendar: calendar).dueAtDayStart, 8,
            "前提：今天起初 8 个词到期")

        // 复习掉 3 个（答对 → 掌握度 1 → 间隔 1 天 → 今天不再到期）。
        for index in 1...3 { entries[index - 1] = entry(index, reviewedAt: now) }
        let midway = VocabularyStats.from(entries, now: now, calendar: calendar)
        XCTAssertEqual(midway.due, 5, "「此刻到期」确实少了 3 个 —— 那个口径本身没错，只是不能当指标")
        XCTAssertEqual(midway.dueAtDayStart, 8, "今日指标必须还是 8，不许缩成 5")
        XCTAssertEqual(midway.dueAtDayStartReviewed, 3)

        // 剩下 5 个也复习完 → 指标还是 8，完成度 8：任务该显示 8/8，而不是整项消失。
        for index in 4...8 { entries[index - 1] = entry(index, reviewedAt: now) }
        let done = VocabularyStats.from(entries, now: now, calendar: calendar)
        XCTAssertEqual(done.due, 0)
        XCTAssertEqual(done.dueAtDayStart, 8)
        XCTAssertEqual(done.dueAtDayStartReviewed, 8)
    }

    /// 「多完成的不应该再计入」：今天新加的词被复习了也不算进今日指标的分子/分母。
    func testWordsAddedTodayNeverEnterTheDayStartIndicator() {
        let calendar = Calendar.current
        let now = Date()
        let midnight = calendar.startOfDay(for: now)
        let yesterday = midnight.addingTimeInterval(-86_400)

        let backlog = [
            VocabularyEntry(
                word: "old1", mastery: 1, reviewCount: 1,
                lastReviewedAt: now, createdAt: yesterday),     // 今天复习过 → 算，且算完成
            VocabularyEntry(word: "old2", mastery: 0, createdAt: yesterday),  // 今天还没碰 → 算
        ]
        // 今天加了 5 个词、顺手复习了 —— 这是「多做」，不进今天的指标。
        let fresh = (1...5).map {
            VocabularyEntry(
                word: "new\($0)", mastery: 1, reviewCount: 1,
                lastReviewedAt: now, createdAt: now)
        }

        let stats = VocabularyStats.from(backlog + fresh, now: now, calendar: calendar)
        XCTAssertEqual(stats.dueAtDayStart, 2, "今天新加的词不算今天的复习任务")
        XCTAssertEqual(stats.dueAtDayStartReviewed, 1, "分子也只数今天起初那批里复习过的")
        XCTAssertEqual(stats.due, 1, "此刻到期只剩 old2（其余都已答对、间隔被拉长）")
    }

    // MARK: - 释义解析（键值行；词汇本与每日推荐共用同一套）

    func testDefinitionRuleParsesKeyedLines() {
        let raw = """
        phonetic: /səbˈstænʃl/
        pos: adj.
        meaning: 大量的；实质性的；重要的
        explanation: 强调数量或程度超出一般，多用于正式书面语境。
        example: The government made substantial changes to the education policy.
        translation: 政府对教育政策做出了重大调整。
        synonyms: considerable、significant
        antonyms: slight、minor
        keywords: -
        """
        let parsed = VocabularyDefinitionRule.parse(raw)
        XCTAssertEqual(parsed.phonetic, "/səbˈstænʃl/")
        XCTAssertEqual(parsed.pos, "adj.")
        XCTAssertEqual(parsed.senses, "大量的；实质性的；重要的")
        XCTAssertEqual(parsed.senseList, ["大量的", "实质性的", "重要的"], "多义要全部列出")
        XCTAssertEqual(parsed.explanation, "强调数量或程度超出一般，多用于正式书面语境。")
        XCTAssertEqual(parsed.example, "The government made substantial changes to the education policy.")
        XCTAssertEqual(parsed.exampleTranslation, "政府对教育政策做出了重大调整。")
        XCTAssertEqual(parsed.synonyms, ["considerable", "significant"])
        XCTAssertEqual(parsed.antonyms, ["slight", "minor"])
        XCTAssertEqual(parsed.keywords, "", "`-` = 没有重点单词（单个词）")
        XCTAssertFalse(parsed.isEmpty)
        XCTAssertFalse(parsed.isLegacy)
    }

    func testDefinitionRuleParsesPhraseKeywordsAndChineseKeys() {
        // 词组：没有音标，有重点单词；键名用中文也应认得。
        let parsed = VocabularyDefinitionRule.parse("""
        * 音标：-
        * 词性：phr.
        * 中文释义：考虑；顾及
        * 解释：正式书面用语，名词短语可放在 take 之后或 into account 之前。
        * 例句：We must take into account the cost of living.
        * 例句翻译：我们必须把生活成本考虑进去。
        * 近义词：bear in mind、allow for
        * 反义词：-
        * 重点单词：take (v.) 拿；account (n.) 账户；consideration (n.) 考虑
        """)
        XCTAssertEqual(parsed.phonetic, "", "词组不显示音标")
        XCTAssertEqual(parsed.pos, "phr.")
        XCTAssertEqual(parsed.senses, "考虑；顾及")
        XCTAssertEqual(parsed.synonyms, ["bear in mind", "allow for"])
        XCTAssertEqual(parsed.antonyms, [])
        XCTAssertEqual(parsed.exampleTranslation, "我们必须把生活成本考虑进去。")
        XCTAssertEqual(parsed.keywords, "take (v.) 拿；account (n.) 账户；consideration (n.) 考虑")
    }

    func testPhoneticGuardsAgainstBareSlashAndRescuesStrayIPA() {
        // 模型实测出现过只回一个「/」的音标：视为缺席，卡片上不能显示孤零零的斜杠。
        let bare = VocabularyDefinitionRule.parse("""
        phonetic: /
        pos: n.
        meaning: 爱好；消遣
        explanation: 指工作学习之外的娱乐活动。
        example: She has a hobby of painting landscapes.
        """)
        XCTAssertEqual(bare.phonetic, "", "裸斜杠不是音标")

        // 音标被写到没带键的行里（或键名没认出来）时，兜底搜捕要把它救回来。
        let stray = VocabularyDefinitionRule.parse("""
        pos: n.
        meaning: 习惯
        /ˈhɒbɪ/
        example: Reading is my favourite hobby.
        """)
        XCTAssertEqual(stray.phonetic, "/ˈhɒbɪ/", "没带键的音标也要能救回")

        // 合法音标原样保留（英式 / 美式、方括号写法都算）。
        XCTAssertTrue(VocabularyDefinitionRule.isUsablePhonetic("/ɪnˈkriːs/"))
        XCTAssertTrue(VocabularyDefinitionRule.isUsablePhonetic("[ˈhɒbi]"))
        XCTAssertFalse(VocabularyDefinitionRule.isUsablePhonetic("/"))
        XCTAssertFalse(VocabularyDefinitionRule.isUsablePhonetic("//"))
        XCTAssertFalse(VocabularyDefinitionRule.isUsablePhonetic("-"))

        // 中文行里的「A/B」不能当成音标（必须含字母且不是 CJK）。
        XCTAssertNil(VocabularyDefinitionRule.phoneticCandidate(in: "中文/解释/说明"))
        XCTAssertEqual(VocabularyDefinitionRule.phoneticCandidate(in: "word /ˈsaɪkl/ here"), "/ˈsaɪkl/")
    }

    func testNeedsPhoneticOnlyForSingleWords() {
        XCTAssertTrue(VocabularyService.needsPhonetic("hobby"))
        XCTAssertFalse(VocabularyService.needsPhonetic("take into account"), "词组没有音标")
        XCTAssertFalse(VocabularyService.needsPhonetic("What would you like to order?"))
    }

    func testKeywordsValueDropsItsOwnLabel() {
        // 值自带「重点单词：」前缀时必须去掉 —— 否则复习卡会渲染成
        // 「重点单词 重点单词：cycle (n.)；phase (n.)」重复两遍。
        let duplicated = VocabularyDefinitionRule.parse("""
        meaning: 循环；周期
        keywords: 重点单词：cycle (n.)；phase (n.)
        """)
        XCTAssertEqual(duplicated.keywords, "cycle (n.)；phase (n.)")
        // 正常的纯值不受影响。
        let plain = VocabularyDefinitionRule.parse("keywords: cycle (n.)；phase (n.)")
        XCTAssertEqual(plain.keywords, "cycle (n.)；phase (n.)")
    }

    func testDefinitionRuleRepairsPlaceholderEcho() {
        // qwen3:8b 实测会把格式行的字段名当值回显：必须视为缺席，绝不能落库。
        let echoed = VocabularyDefinitionRule.parse("""
        phonetic: PHONETIC
        pos: POS
        meaning: 百分比；百分率
        explanation: EXPLANATION
        example: EXAMPLE
        translation: EXAMPLE_TRANSLATION
        synonyms: SYNONYMS
        antonyms: -
        keywords: -
        """)
        XCTAssertEqual(echoed.phonetic, "")
        XCTAssertEqual(echoed.pos, "")
        XCTAssertEqual(echoed.senses, "百分比；百分率")
        XCTAssertEqual(echoed.explanation, "")
        XCTAssertEqual(echoed.example, "")
        XCTAssertEqual(echoed.exampleTranslation, "")
        XCTAssertEqual(echoed.synonyms, [])
        // 整段都是回显（没有任何真实内容）→ 视为空，UI 退回「还没有释义」。
        let pure = VocabularyDefinitionRule.parse("phonetic: PHONETIC\npos: POS\nmeaning: MEANING")
        XCTAssertTrue(pure.isEmpty)
    }

    func testDefinitionRuleFallsBackToLegacyFormats() {
        // 旧词汇本 v2：义项 || 例句 || 重点单词。
        let v2 = VocabularyDefinitionRule.parse("苹果||I eat an apple every day.||apple (n.) 苹果")
        XCTAssertEqual(v2.senses, "苹果")
        XCTAssertEqual(v2.example, "I eat an apple every day.")
        XCTAssertEqual(v2.keywords, "apple (n.) 苹果")

        // 旧每日推荐 v1：词性 || 释义 || 例句 || 例句翻译 || 近义 || 反义。
        let v1 = VocabularyDefinitionRule.parse(
            "adj.||大量的、显著的||A substantial rise.||大幅上升。||considerable、significant||slight、minor"
        )
        XCTAssertEqual(v1.pos, "adj.")
        XCTAssertEqual(v1.senses, "大量的、显著的")
        XCTAssertEqual(v1.exampleTranslation, "大幅上升。")
        XCTAssertEqual(v1.synonyms, ["considerable", "significant"])

        // 旧版（v2 落库）：一段中文 + 「重点单词：」行 → 段落与重点单词都还原，
        // 并且**标记为 legacy**，UI 会给出「重新释义」把音标 / 词性 / 例句翻译补上。
        let stored = VocabularyDefinitionRule.parse("旧版落库的一段中文释义。\n重点单词：boost (v.) 提升")
        XCTAssertEqual(stored.legacyText, "旧版落库的一段中文释义。")
        XCTAssertEqual(stored.keywords, "boost (v.) 提升")
        XCTAssertTrue(stored.isLegacy)
        XCTAssertTrue(stored.senses.isEmpty)
        // 整段原样再编码：重点单词行要拼回去（老数据不会被压扁）。
        XCTAssertEqual(stored.encoded, "旧版落库的一段中文释义。\n重点单词：boost (v.) 提升")

        // 完全认不出结构（没有键值行、没有 `||`）→ 整段进 legacyText。
        let plain = VocabularyDefinitionRule.parse("这是一段完全自由格式的旧释义。\n没有任何标签。")
        XCTAssertTrue(plain.isLegacy)
        XCTAssertEqual(plain.legacyText, "这是一段完全自由格式的旧释义。\n没有任何标签。")
    }

    func testDefinitionRoundTripsThroughStoredEncoding() {
        let original = VocabularyDefinition(
            phonetic: "/ˈæpl/",
            pos: "n.",
            senses: "苹果；苹果树",
            explanation: "可数名词，指水果。",
            example: "I eat an apple every day.",
            exampleTranslation: "我每天吃一个苹果。",
            synonyms: ["fruit"],
            keywords: ""
        )
        let restored = VocabularyDefinitionRule.decodeStored(original.encoded)
        XCTAssertEqual(restored.phonetic, original.phonetic)
        XCTAssertEqual(restored.pos, original.pos)
        XCTAssertEqual(restored.senses, original.senses)
        XCTAssertEqual(restored.explanation, original.explanation)
        XCTAssertEqual(restored.exampleTranslation, original.exampleTranslation)
        XCTAssertEqual(restored.synonyms, ["fruit"])
        XCTAssertFalse(restored.isLegacy, "结构化数据往返后不应退化成 legacy")
    }

    func testSanitizedStoredMeaningCleansLegacyEchoRows() {
        // 历史坏数据（释义=「MEANING」+「重点单词： EXAMPLE」两行垃圾）→ 清完为空，
        // 退回「还没有释义」让用户重新查释义。
        let corrupt = VocabularyDefinitionRule.sanitizedStoredMeaning("MEANING\n重点单词： EXAMPLE")
        XCTAssertEqual(corrupt, "")
        // 好数据原样保留。
        let good = "详细的中文释义。\n重点单词：boost (v.) 提升"
        XCTAssertEqual(VocabularyDefinitionRule.sanitizedStoredMeaning(good), good)
        // 坏行剔除但好行保留。
        let partial = VocabularyDefinitionRule.sanitizedStoredMeaning("MEANING\n真正的释义。")
        XCTAssertEqual(partial, "真正的释义。")
        // 空壳键值行（值是 `-` 或字段名）整行剔除，正常键值行保留。
        let keyed = "meaning: 苹果\nexplanation: -\npos: POS"
        XCTAssertEqual(VocabularyDefinitionRule.sanitizedStoredMeaning(keyed), "meaning: 苹果")
    }

    // MARK: - 词条解析（近义词 / 反义词 / 重点单词共用）

    func testTermParsesCompleteAndBrokenEntries() {
        let complete = VocabularyTermParser.parse("take (v.) 拿")
        XCTAssertEqual(complete.word, "take")
        XCTAssertEqual(complete.pos, "v.")
        XCTAssertEqual(complete.translation, "拿")
        XCTAssertTrue(complete.isComplete)

        // 只有英文（模型漏了中文）—— 不再拼出半截括号。
        let noChinese = VocabularyTermParser.parse("cycle (n.)")
        XCTAssertEqual(noChinese.word, "cycle")
        XCTAssertEqual(noChinese.pos, "n.")
        XCTAssertEqual(noChinese.translation, "")
        XCTAssertFalse(noChinese.isComplete)
        XCTAssertEqual(noChinese.displayText, "cycle (n.)")

        // 只有中文（模型漏了英文）—— 保留中文，不凭空补空词性。
        let noWord = VocabularyTermParser.parse("循环")
        XCTAssertEqual(noWord.word, "")
        XCTAssertEqual(noWord.pos, "")
        XCTAssertEqual(noWord.translation, "循环")
        XCTAssertFalse(noWord.isComplete)

        // 全角括号 / 无词性 / 序号前缀都要认。
        let fullWidth = VocabularyTermParser.parse("（n.）苹果")
        XCTAssertEqual(fullWidth.pos, "n.")
        XCTAssertEqual(fullWidth.translation, "苹果")
        XCTAssertEqual(VocabularyTermParser.parse("significant 显著的").word, "significant")
        XCTAssertEqual(VocabularyTermParser.parse("1. take (v.) 拿").word, "take")
        XCTAssertTrue(VocabularyTermParser.parse("   ").isEmpty)
    }

    func testTermListSplitsAndKeepsTermsIntact() {
        let terms = VocabularyTermParser.parseList("take (v.) 拿；account (n.) 账户；consideration (n.) 考虑")
        XCTAssertEqual(terms.map(\.word), ["take", "account", "consideration"])
        XCTAssertEqual(terms.map(\.translation), ["拿", "账户", "考虑"])
        // 括号内的「/」不是分隔符（词性 adj./n. 不能被劈开）。
        let multiPos = VocabularyTermParser.parseList("significant (adj./n.) 显著的")
        XCTAssertEqual(multiPos.count, 1)
        XCTAssertEqual(multiPos.first?.pos, "adj./n.")
        XCTAssertEqual(multiPos.first?.translation, "显著的")
    }

    func testDefinitionExposesTermLists() {
        let definition = VocabularyDefinitionRule.parse("""
        meaning: 大量的；实质性的
        synonyms: considerable (adj.) 大量的、significant (adj.) 显著的
        antonyms: slight (adj.) 轻微的
        keywords: make (v.) 做出；change (n.) 改变
        """)
        XCTAssertEqual(definition.synonymTerms.map(\.translation), ["大量的", "显著的"])
        XCTAssertEqual(definition.synonymTerms.first?.pos, "adj.")
        XCTAssertEqual(definition.antonymTerms.map(\.word), ["slight"])
        XCTAssertEqual(definition.keywordTerms.map(\.word), ["make", "change"])
        XCTAssertEqual(definition.keywordTerms.map(\.translation), ["做出", "改变"])
    }

    func testSynonymListKeepsSlashInsidePartOfSpeech() {
        // 旧解析器按「/」拆近反义词，会把 (adj./n.) 劈成两半；现在不能。
        let parsed = VocabularyDefinitionRule.parse("meaning: 显著的\nsynonyms: significant (adj./n.) 显著的")
        XCTAssertEqual(parsed.synonyms, ["significant (adj./n.) 显著的"])
        XCTAssertEqual(parsed.synonymTerms.first?.pos, "adj./n.")
    }

    // MARK: - 重点单词：必须是英文 + 缺词性/中文的自动补全

    func testKeywordLineIsHiddenWhenItHasNoEnglish() {
        // 实测：模型把中文释义塞进 keywords（「你好、打招呼」）。
        let chineseOnly = VocabularyDefinitionRule.parse("meaning: 你好；嗨\nkeywords: 你好、打招呼")
        XCTAssertEqual(chineseOnly.keywordTerms.map(\.word), ["", ""])
        XCTAssertTrue(chineseOnly.displayKeywordTerms.isEmpty, "没有英文的重点单词 → 整行不显示")

        // 混排：只留下带英文的条目。
        let mixed = VocabularyDefinitionRule.parse("meaning: 你好\nkeywords: 你好、how come (phr.) 怎么会")
        XCTAssertEqual(mixed.displayKeywordTerms.map(\.word), ["how come"])
        XCTAssertEqual(mixed.displayKeywordTerms.first?.translation, "怎么会")
    }

    func testKeywordCommaSeparatedEnglishSplitsIntoTerms() {
        // 实测：`precipitation , rainfall, drizzle, drought` —— 逗号分隔的英文重点单词。
        let definition = VocabularyDefinitionRule.parse(
            "meaning: 降水\nkeywords: precipitation , rainfall, drizzle, drought"
        )
        XCTAssertEqual(definition.displayKeywordTerms.map(\.word), ["precipitation", "rainfall", "drizzle", "drought"])
        XCTAssertTrue(definition.displayKeywordTerms.allSatisfy { $0.translation.isEmpty })
        // 中文翻译里的「，」后面不是英文 → 不算分隔符。
        let chinese = VocabularyTermParser.parseList("take (v.) 拿，拿住")
        XCTAssertEqual(chinese.count, 1)
        XCTAssertEqual(chinese.first?.translation, "拿，拿住")
    }

    func testTermsNeedingCompletionOnlyPicksEnglishIncompleteTerms() {
        let definition = VocabularyDefinitionRule.parse("""
        meaning: 降水
        synonyms: rainfall (n.) 降雨、drizzle (n.)
        keywords: precipitation , drought
        """)
        // rainfall 完整 → 不补；drizzle / precipitation / drought 缺中文 → 要补。
        XCTAssertEqual(definition.termsNeedingCompletion.map(\.word), ["drizzle", "precipitation", "drought"])

        // 纯中文的重点单词不进补全队列（连该补哪个词都不知道）。
        let chineseOnly = VocabularyDefinitionRule.parse("meaning: 你好\nkeywords: 你好、打招呼")
        XCTAssertTrue(chineseOnly.termsNeedingCompletion.isEmpty)

        let complete = VocabularyDefinitionRule.parse("meaning: 拿\nsynonyms: take (v.) 拿")
        XCTAssertTrue(complete.termsNeedingCompletion.isEmpty)
    }

    func testCompletionParsesModelLines() {
        let map = VocabularyTermCompletion.parse("""
        rainfall||n.||降雨；雨量
        2. drizzle|n.|毛毛雨；细雨
        - drought||n.||干旱
        precipitation||n.||降水；沉淀
        word||pos||translation
        这一行没有分隔符也不是词条
        """)
        XCTAssertEqual(map["rainfall"]?.pos, "n.")
        XCTAssertEqual(map["rainfall"]?.translation, "降雨；雨量")
        XCTAssertEqual(map["drizzle"]?.pos, "n.")
        XCTAssertEqual(map["drought"]?.translation, "干旱")
        XCTAssertEqual(map["precipitation"]?.translation, "降水；沉淀")
        XCTAssertNil(map["word"], "字段名回显不能当内容")
        XCTAssertEqual(map.count, 4)
    }

    func testPatchedMergesCompletedTermsBackIntoDefinition() {
        let definition = VocabularyDefinitionRule.parse("""
        meaning: 降水
        synonyms: rainfall (n.) 降雨
        keywords: precipitation , rainfall, drizzle
        """)
        let completed: [String: VocabularyTerm] = [
            "precipitation": VocabularyTerm(word: "precipitation", pos: "n.", translation: "降水"),
            "rainfall": VocabularyTerm(word: "rainfall", pos: "n.", translation: "降雨"),
            "drizzle": VocabularyTerm(word: "drizzle", pos: "n.", translation: "毛毛雨"),
        ]
        let patched = definition.patched(with: completed)
        let patchedKeywords = VocabularyTermParser.parseList(patched.keywords)
        XCTAssertEqual(patchedKeywords.map(\.word), ["precipitation", "rainfall", "drizzle"])
        XCTAssertEqual(patchedKeywords.map(\.pos), ["n.", "n.", "n."])
        XCTAssertEqual(patchedKeywords.map(\.translation), ["降水", "降雨", "毛毛雨"])
        // 补全后不再需要补。
        XCTAssertTrue(patched.termsNeedingCompletion.isEmpty)
        // 近义词原样保留。
        XCTAssertEqual(patched.synonyms, ["rainfall (n.) 降雨"])
    }

    func testPatchedDropsChineseOnlyKeywords() {
        let definition = VocabularyDefinitionRule.parse("meaning: 你好\nkeywords: 你好、打招呼")
        let patched = definition.patched(with: [
            "how come": VocabularyTerm(word: "how come", pos: "phr.", translation: "怎么会")
        ])
        XCTAssertEqual(patched.keywords, "", "纯中文的重点单词在补全落库时被清掉")
    }

    // MARK: - 每日推荐（Daily Recommendation）

    /// 固定种子随机源：让选词测试可复现。
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func makeBank(easy: Int, medium: Int, hard: Int, phrases: Int = 0, vocabulary: Int = 0) -> [DailyWord] {
        var bank: [DailyWord] = []
        for index in 0..<easy { bank.append(DailyWord(word: "easy\(index)", difficulty: 1)) }
        for index in 0..<medium { bank.append(DailyWord(word: "med\(index)", difficulty: 2)) }
        for index in 0..<hard { bank.append(DailyWord(word: "hard\(index)", difficulty: 3)) }
        for index in 0..<phrases { bank.append(DailyWord(word: "phrase \(index)", difficulty: 4)) }
        for index in 0..<vocabulary {
            bank.append(DailyWord(word: "vocab\(index)", difficulty: DailyWord.vocabularyLevel))
        }
        return bank
    }

    func testDailyPickerFollowsQuota() {
        // 雅思配额：3 简单 / 5 中等 / 2 困难 / 2 词组；生词档另占 4 个（见下面几条）。
        XCTAssertEqual(
            DailyWordPicker.quota,
            [1: 3, 2: 5, 3: 2, 4: 2, DailyWord.vocabularyLevel: 4]
        )
        XCTAssertEqual(DailyWordPicker.total, 16, "含生词档的名义上限")
        XCTAssertEqual(DailyWordPicker.quotaTotal(forDeclared: [1, 2, 3, 4]), 12, "只有词典四档时的实际总数")
        var rng = SeededRNG(state: 42)
        // 这个词库不含生词档 → 生词配额不参与，仍是 12 张（收起态 3 页整）。
        let picked = DailyWordPicker.pick(from: makeBank(easy: 10, medium: 10, hard: 10, phrases: 10), using: &rng)
        XCTAssertEqual(picked.count, 12)
        XCTAssertEqual(picked.filter { $0.difficulty == 1 }.count, 3)
        XCTAssertEqual(picked.filter { $0.difficulty == 2 }.count, 5)
        XCTAssertEqual(picked.filter { $0.difficulty == 3 }.count, 2)
        XCTAssertEqual(picked.filter(\.isPhrase).count, 2, "再随机给两个词组")
        // 同一批内不重复。
        XCTAssertEqual(Set(picked.map(\.word)).count, 12)
        // 档位标签：4 词组 / 5 生词（前三档仍是简单 / 中等 / 困难）。
        XCTAssertEqual(DailyWord.difficultyLabel(for: 4), "词组")
        XCTAssertEqual(DailyWord.difficultyLabel(for: 2), "中等")
        XCTAssertEqual(DailyWord.difficultyLabel(for: DailyWord.vocabularyLevel), "生词")
    }

    func testDailyPickerExcludesAndToleratesSmallBank() {
        var rng = SeededRNG(state: 7)
        let bank = makeBank(easy: 4, medium: 6, hard: 3, phrases: 2)
        let first = DailyWordPicker.pick(from: bank, using: &rng)
        // 刷新时排除上一批：不会再抽到同一批词。
        let second = DailyWordPicker.pick(from: bank, excluding: Set(first.map { $0.word.lowercased() }), using: &rng)
        XCTAssertEqual(Set(first.map(\.word)).intersection(second.map(\.word)), [])
        // 词不够时有多少给多少，不崩。
        let tiny = DailyWordPicker.pick(from: makeBank(easy: 1, medium: 0, hard: 0), using: &rng)
        XCTAssertEqual(tiny.count, 1)
        XCTAssertEqual(tiny.first?.difficulty, 1)
    }

    func testDailyPickerFillsDeficitFromLowestUnfinishedLevel() {
        // 中等 / 困难 / 词组全学完（整体排除）→ 12 个位置全由简单档补。
        let bank = makeBank(easy: 20, medium: 20, hard: 3, phrases: 2)
        let mediumHardPhrases = Set(bank.filter { $0.difficulty != 1 }.map { $0.word.lowercased() })
        var rng = SeededRNG(state: 11)
        let easyFilled = DailyWordPicker.pick(from: bank, excluding: mediumHardPhrases, using: &rng)
        XCTAssertEqual(easyFilled.count, 12, "学完的档位由「还没学完的最低档」补满")
        XCTAssertTrue(easyFilled.allSatisfy { $0.difficulty == 1 })

        // 简单 / 困难 / 词组学完 → 轮到中等档补（缺 3 + 2 + 2 = 7 个位置）。
        var rng2 = SeededRNG(state: 12)
        let mediumExcluding = Set(
            bank.filter { $0.difficulty == 1 || $0.difficulty >= 3 }.map { $0.word.lowercased() }
        )
        let mediumFilled = DailyWordPicker.pick(from: bank, excluding: mediumExcluding, using: &rng2)
        XCTAssertEqual(mediumFilled.count, 12)
        XCTAssertTrue(mediumFilled.allSatisfy { $0.difficulty == 2 })

        // 词库整体不够 → 有多少给多少。
        var rng3 = SeededRNG(state: 13)
        let tiny = DailyWordPicker.pick(from: makeBank(easy: 2, medium: 3, hard: 0, phrases: 0), using: &rng3)
        XCTAssertEqual(tiny.count, 5, "词库只有 5 个可用词就展示 5 个")
        // 同批内仍然不重复。
        XCTAssertEqual(Set(tiny.map(\.word)).count, 5)
    }

    func testDailyPagerKeepsFourCardsPerPage() {
        // 收起态：每页完整 4 张卡（2 行 × 2 列），右侧上下按钮翻页。
        let words = (0..<12).map { DailyWord(word: "w\($0)", difficulty: 1) }
        XCTAssertEqual(DailyWordPager.pageCount(words), 3)
        XCTAssertEqual(DailyWordPager.page(words, index: 0).map(\.word), ["w0", "w1", "w2", "w3"])
        XCTAssertEqual(DailyWordPager.page(words, index: 2).map(\.word), ["w8", "w9", "w10", "w11"])
        // 越界页码夹到最后一页（不会崩、不会空屏）。
        XCTAssertEqual(DailyWordPager.page(words, index: 9).count, 4)
        XCTAssertEqual(DailyWordPager.page(words, index: -3).map(\.word).first, "w0")
        // 不足一页按实际条数。
        let few = Array(words.prefix(6))
        XCTAssertEqual(DailyWordPager.pageCount(few), 2)
        XCTAssertEqual(DailyWordPager.page(few, index: 1).count, 2)
        XCTAssertTrue(DailyWordPager.page([], index: 0).isEmpty)
        // 16 张（4 生词 + 12 雅思词）正好 4 页整 —— 「收起态翻页完整」就是这一条：
        // 最后一页同样有 4 张，不会翻出一个半空的尾巴页。
        let full = (0..<16).map { DailyWord(word: "f\($0)", difficulty: 1) }
        XCTAssertEqual(DailyWordPager.pageCount(full), 4)
        XCTAssertEqual(DailyWordPager.page(full, index: 3).count, 4)
    }

    func testDailyPagerSplitsPageIntoTwoColumns() {
        // 收起态用普通行列排 2×2（不用 LazyVGrid：懒容器子视图不参与过渡动画，
        // 卡片滑走时「查释义」按钮会留在原地）。
        let words = (0..<4).map { DailyWord(word: "w\($0)", difficulty: 1) }
        let rows = DailyWordPager.rows(words, perRow: 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].map(\.word), ["w0", "w1"])
        XCTAssertEqual(rows[1].map(\.word), ["w2", "w3"])

        // 最后一行不足时按实际条数（漏一个卡片也不会空出整行）。
        let odd = Array(words.prefix(3))
        XCTAssertEqual(DailyWordPager.rows(odd, perRow: 2).map { $0.count }, [2, 1])
        XCTAssertTrue(DailyWordPager.rows([], perRow: 2).isEmpty)
        // 每页正好 4 张 → 2 行，行数与页容量一致。
        XCTAssertEqual(DailyWordPager.rows(DailyWordPager.page(words, index: 0)).count, 2)
    }

    // MARK: - 生词档（每日推荐第 5 档：练习里遇到的生词）

    func testDailyPickerGivesVocabularyItsOwnFullPage() {
        var rng = SeededRNG(state: 99)
        let bank = makeBank(easy: 10, medium: 10, hard: 10, phrases: 10, vocabulary: 6)
        let picked = DailyWordPicker.pick(from: bank, using: &rng)

        XCTAssertEqual(picked.count, 16, "4 生词 + 12 雅思词 = 收起态 4 页整")
        XCTAssertEqual(picked.filter(\.isVocabularyWord).count, 4)
        // 生词占住**最前 4 位** → 收起态第一页就是「你自己的词」。
        XCTAssertTrue(
            picked.prefix(4).allSatisfy(\.isVocabularyWord),
            "生词档在 levelOrder 最前，出结果时也按这个顺序拼接"
        )
        XCTAssertEqual(Set(picked.map(\.word)).count, 16, "同批不重复")
    }

    func testDailyPickerKeepsThePageFullWhenVocabularyIsShort() {
        var rng = SeededRNG(state: 100)
        let bank = makeBank(easy: 10, medium: 10, hard: 10, phrases: 10, vocabulary: 2)
        let picked = DailyWordPicker.pick(from: bank, using: &rng)

        XCTAssertEqual(
            picked.count, 16,
            "生词只有 2 个时缺口由词典档顶满 —— 少这一张就会翻出半空的尾巴页"
        )
        XCTAssertEqual(picked.filter(\.isVocabularyWord).count, 2)
        XCTAssertEqual(picked.filter { $0.difficulty == 1 }.count, 5, "缺的 2 个位子落到简单档")
    }

    func testDailyPickerDropsTheVocabularyQuotaWhenNothingSuppliesIt() {
        var rng = SeededRNG(state: 101)
        let bank = makeBank(easy: 10, medium: 10, hard: 10, phrases: 10)
        let picked = DailyWordPicker.pick(from: bank, using: &rng)

        XCTAssertEqual(picked.count, 12, "词汇本里一个生词都没有 → 这一档不存在，配额一起消失")
        XCTAssertLessThan(picked.count, DailyWordPicker.total, "total 是名义上限（含生词档）")
        XCTAssertTrue(picked.allSatisfy { !$0.isVocabularyWord })
        // ⚠️ 这一条是「生词**没供货**」与「生词**被学完**」的分水岭：后者才该走补齐。
        XCTAssertEqual(picked.filter { $0.difficulty == 1 }.count, 3, "简单档不该被顶成 7 个")
    }

    func testDuplicateNamesAcrossSourcesDoNotWasteAQuotaSlot() {
        var rng = SeededRNG(state: 2027)
        // 同一个词同时长在两本词典里（`say` / `go` 这类几本书都收的词很常见）。
        let shared = DailyWord(word: "shared", difficulty: 1)
        let sources = [
            [shared],
            [shared] + (0..<8).map { DailyWord(word: "b\($0)", difficulty: 2) },
        ]
        let picked = DailyWordPicker.pick(fromSources: sources, using: &rng)

        // 简单档实际只有 1 个可用词 → 差的 2 个位子由中等档补上，总数仍是 8 个名额。
        // （旧顺序是「先按配额切 3 个、出结果再去重」，重复词占掉的名额会白白丢掉。）
        XCTAssertEqual(picked.count, DailyWordPicker.quotaTotal(forDeclared: [1, 2]))
        XCTAssertEqual(Set(picked.map(\.word)).count, 8, "同批不重复，且没浪费名额")
        XCTAssertEqual(picked.filter { $0.difficulty == 2 }.count, 7)
    }

    func testVocabularyWordWinsWhenItAlsoLivesInTheBank() {
        var rng = SeededRNG(state: 2028)
        let bank = [
            DailyWord(word: "focus", difficulty: 1),
            DailyWord(word: "easy0", difficulty: 1),
            DailyWord(word: "easy1", difficulty: 1),
            DailyWord(word: "easy2", difficulty: 1),
            // 生词档：与词库重名（练习里收过 focus）。
            DailyWord(word: "focus", difficulty: DailyWord.vocabularyLevel),
            DailyWord(word: "vocab0", difficulty: DailyWord.vocabularyLevel),
        ] + (0..<10).map { DailyWord(word: "med\($0)", difficulty: 2) }
        let picked = DailyWordPicker.pick(fromSources: [bank], using: &rng)

        XCTAssertEqual(picked.count, 12, "生词档 2（缺 2 补齐）+ 简单 3 + 中等 5 = 12，一个名额都没浪费")
        XCTAssertEqual(picked.filter { $0.word == "focus" }.count, 1, "跨档同名只出现一次")
        XCTAssertEqual(
            picked.first { $0.word == "focus" }?.difficulty,
            DailyWord.vocabularyLevel,
            "生词档在 levelOrder 最前 → 同名时由它先占位"
        )
    }

    // MARK: - 练习生词池（口径纯函数）

    func testVocabularyPoolSkipsMasteredAndExcluded() {
        let entries = [
            makeEntry(word: "alpha"),
            makeEntry(word: "beta", mastery: ReviewScheduler.masteredMastery),
            makeEntry(word: "gamma"),
        ]
        let pool = DailyVocabularyPool.candidates(from: entries, excluding: ["gamma"])

        XCTAssertEqual(pool.map(\.word), ["alpha"])
        XCTAssertTrue(pool.allSatisfy { $0.difficulty == DailyWord.vocabularyLevel })
    }

    func testVocabularyPoolPrefersPracticedThenNewest() {
        let entries = [
            makeEntry(word: "fresh", createdAt: Date(timeIntervalSince1970: 900)),
            makeEntry(word: "drilled", reviewCount: 2, createdAt: Date(timeIntervalSince1970: 100)),
            makeEntry(word: "recent", createdAt: Date(timeIntervalSince1970: 500)),
        ]
        XCTAssertEqual(
            DailyVocabularyPool.candidates(from: entries).map(\.word),
            ["drilled", "fresh", "recent"],
            "练过的优先，其余按入本时间倒序"
        )
    }

    func testVocabularyPoolIsStableAndCapped() {
        let entries = (0..<10).map {
            makeEntry(word: "w\($0)", createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        let first = DailyVocabularyPool.candidates(from: entries)
        let second = DailyVocabularyPool.candidates(from: entries)

        XCTAssertEqual(
            first.count,
            DailyWordPicker.quota[DailyWord.vocabularyLevel] ?? 0,
            "上限 = 生词档配额"
        )
        XCTAssertEqual(first.map(\.word), second.map(\.word), "**刻意不洗牌**：同一批词每天都该出现，直到毕业")
        XCTAssertEqual(first.first?.word, "w9", "最近入本的排最前")
    }

    func testVocabularyPoolDedupesSameWordInDifferentCase() {
        let entries = [makeEntry(word: "Apple"), makeEntry(word: "apple")]
        XCTAssertEqual(
            DailyVocabularyPool.candidates(from: entries).map(\.word),
            ["Apple"],
            "大小写不同的两条是同一个词"
        )
    }

    func testVocabularyPoolIgnoresBlankAndHonoursCustomLimit() {
        XCTAssertTrue(DailyVocabularyPool.candidates(from: [makeEntry(word: "   ")]).isEmpty)
        let entries = (0..<5).map { makeEntry(word: "w\($0)") }
        XCTAssertEqual(DailyVocabularyPool.candidates(from: entries, limit: 2).count, 2)
        XCTAssertTrue(DailyVocabularyPool.candidates(from: entries, limit: 0).isEmpty)
    }

    func testWordBankParseFiltersInvalidAndDuplicates() throws {
        let json = """
        [
          {"word": "  significant ", "difficulty": 2},
          {"word": "significant", "difficulty": 3},
          {"word": "", "difficulty": 1},
          {"difficulty": 1},
          {"word": "echo"},
          {"word": String(repeating: "a", count: 50), "difficulty": 1}
        ]
        """.replacingOccurrences(of: "String(repeating: \"a\", count: 50)", with: "\"" + String(repeating: "a", count: 50) + "\"")
        let parsed = VocabularyWordBank.parse(Data(json.utf8))
        XCTAssertEqual(parsed?.count, 2, "重复 / 空词 / 缺词 / 超长词全部过滤")
        XCTAssertEqual(parsed?.first?.word, "significant")
        XCTAssertEqual(parsed?.first?.difficulty, 2)
        // 缺 difficulty 默认中等档。
        XCTAssertEqual(parsed?.last?.word, "echo")
        XCTAssertEqual(parsed?.last?.difficulty, 2)
        XCTAssertNil(VocabularyWordBank.parse(Data("not json".utf8)))
    }

    func testNormalizeTrimsQuotesAndRejectsLongInput() {
        XCTAssertEqual(VocabularyService.normalize("  apple "), "apple")
        XCTAssertEqual(VocabularyService.normalize("“How come…”"), "How come…")
        XCTAssertEqual(VocabularyService.normalize(""), "")
        XCTAssertEqual(VocabularyService.normalize(String(repeating: "a", count: 50)), "", "超过 48 字符不是「一个词」")
    }

    // MARK: - 落库（schema v7）

    func testUpsertDeduplicatesByWordAndKeepsProgress() async throws {
        let database = try LearningDatabase.inMemory()
        let version = try await database.schemaVersion()
        // 「至少 v7」才是这条测试真正要的（词汇表从 v7 起存在）。写死等号会被下一次迁移误伤。
        XCTAssertGreaterThanOrEqual(version, 7, "词汇表属于 schema v7")

        let first = VocabularyEntry(word: "apple", meaning: "苹果", mastery: 3, reviewCount: 2, source: .review)
        let inserted = try await database.upsertVocabulary(first)
        XCTAssertTrue(inserted)

        // 同词再导入（复盘去重的关键）：不覆盖，保住掌握度与释义。
        let duplicate = VocabularyEntry(word: "apple", meaning: "", source: .review)
        let insertedAgain = try await database.upsertVocabulary(duplicate)
        XCTAssertFalse(insertedAgain, "重复词不应再插入")

        let all = try await database.allVocabulary()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.meaning, "苹果")
        XCTAssertEqual(all.first?.mastery, 3)
        XCTAssertEqual(all.first?.source, .review)
    }

    func testRecordReviewUpdatesAndLogs() async throws {
        let database = try LearningDatabase.inMemory()
        let original = VocabularyEntry(word: "banana", mastery: 1)
        try await database.upsertVocabulary(original)

        let graded = ReviewScheduler.graded(original, .remembered)
        try await database.recordVocabularyReview(graded, remembered: true)

        let all = try await database.allVocabulary()
        XCTAssertEqual(all.first?.mastery, 2)
        XCTAssertEqual(all.first?.reviewCount, 1)
        XCTAssertNotNil(all.first?.lastReviewedAt)
    }

    func testDeleteRemovesEntry() async throws {
        let database = try LearningDatabase.inMemory()
        let entry = VocabularyEntry(word: "cherry")
        try await database.upsertVocabulary(entry)
        try await database.deleteVocabulary(id: entry.id)
        let all = try await database.allVocabulary()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - 服务编排

    func testServiceWithoutDatabaseStaysHarmless() async {
        let llm = LLMManager()
        let service = VocabularyService(llm: llm, learning: nil, failures: PersistenceFailureRecorder())
        let entries = await service.entries()
        XCTAssertTrue(entries.isEmpty, "没有数据库时返回空，不崩")
        let added = await service.add(word: "apple")
        XCTAssertNil(added)
    }

    func testServiceImportDeduplicates() async throws {
        let database = try LearningDatabase.inMemory()
        let service = VocabularyService(llm: LLMManager(), learning: database, failures: PersistenceFailureRecorder())

        // 两份复盘都提到同一个词 → 只收一条。
        let review1 = SessionReview(sessionID: UUID(), newWords: ["apple", "banana"])
        let review2 = SessionReview(sessionID: UUID(), newWords: ["Apple", "  banana  "])
        try await database.saveReview(review1)
        try await database.saveReview(review2)

        let imported = await service.importFromReviews()
        XCTAssertEqual(imported, 2, "apple/banana 各收一条，重复与空白清洗后不再收")
        let entries = await service.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.word).sorted(), ["Apple", "banana"], "保留原样大小写")
        XCTAssertEqual(entries.map(\.source), [.review, .review])
    }
}
