import XCTest

@testable import AIDomain
@testable import AIInfrastructure

/// 第 31 步三项需求的**纯逻辑守卫**：每日跟读、词族树、划词。
///
/// 三条放在同一份文件里：它们都是「模型给的文本 → 结构化」这一层的判据，
/// 判据一旦改（比如 diffficulty 字段换了语法），在这一个文件里就能看到全貌。
final class DailyWordContentTests: XCTestCase {

    // MARK: - 需求一：每日跟读（按情景现生成 20 句）

    func testShadowingDayKeyDependsOnlyOnDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let morning = Date(timeIntervalSince1970: 1_780_000_000)
        let evening = morning.addingTimeInterval(9 * 3600)

        // ⚠️ 这是「今天之内不换句子」的唯一保证：同一天的任意时刻必须算出同一个键。
        // 用时间戳当键的话，早上练一半、晚上回来发现句子全换了。
        XCTAssertEqual(
            ShadowingDailyRule.dayKey(morning, calendar: calendar),
            ShadowingDailyRule.dayKey(evening, calendar: calendar)
        )
        XCTAssertEqual(
            ShadowingDailyRule.dayKey(morning, calendar: calendar).count,
            10,
            "日期键必须是 yyyy-MM-dd（不足两位要补零），否则跨月/跨年会排错序"
        )
    }

    func testShadowingScenarioRotationChangesAcrossDays() {
        let scenarios = (0..<7).map {
            Scenario(
                id: "s\($0)",
                title: "情景\($0)",
                titleZh: "情景\($0)",
                category: "日常",
                difficulty: 2,
                level: "A2",
                objective: "",
                aiRole: "partner",
                learnerRole: "learner",
                opening: "hi"
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let day1 = Date(timeIntervalSince1970: 1_780_000_000)
        let day2 = day1.addingTimeInterval(26 * 3600)

        let first = ShadowingDailyRule.rotatedScenarios(
            from: scenarios, date: day1, calendar: calendar
        )
        let second = ShadowingDailyRule.rotatedScenarios(
            from: scenarios, date: day2, calendar: calendar
        )

        XCTAssertEqual(first.count, ShadowingDailyRule.dailyScenarioCount)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count, "同一天里不能重复选同一个情景")
        XCTAssertNotEqual(first.map(\.id), second.map(\.id), "换一天必须换一批情景")

        // 同一天再算一次必须完全一致（=「刷新页面句子不换」）。
        let again = ShadowingDailyRule.rotatedScenarios(
            from: scenarios, date: day1, calendar: calendar
        )
        XCTAssertEqual(first.map(\.id), again.map(\.id))

        // 情景池比要选的还少：有几个给几个，不补空、不越界。
        let few = ShadowingDailyRule.rotatedScenarios(from: Array(scenarios.prefix(3)), date: day1)
        XCTAssertEqual(few.count, 3)
        XCTAssertTrue(ShadowingDailyRule.rotatedScenarios(from: [], date: day1).isEmpty)
    }

    func testShadowingParseGroupsSentencesUnderTheirTopic() {
        let raw = """
        topic: 机场值机 | 3
        sentence: I'd like to check in for the morning flight to Vancouver. | 我想办理去温哥华的早班机值机。 | check in 连读
        sentence: Could you confirm whether the overweight baggage fee can be paid by card? | 请问超重行李费能用卡付吗？
        topic: 酒店入住 | 4
        sentence: We booked a quiet room facing the courtyard, and I hope the renovation is finished. | 我们订了朝中庭的安静房间，希望装修已经结束了。
        sentence: I'm afraid there must be a mistake with the reservation. | 恐怕预订出了差错。 | there's 弱读
        """

        let drills = ShadowingDailyRule.parse(raw)

        XCTAssertEqual(drills.count, 4)
        XCTAssertEqual(drills[0].topic, "机场值机")
        XCTAssertEqual(drills[0].difficulty, 3)
        XCTAssertEqual(drills[0].translation, "我想办理去温哥华的早班机值机。")
        XCTAssertEqual(drills[0].focus, "check in 连读")
        // ⚠️ 句子归属于它**上面最近的那个 topic**：topic 一变，后面的句子跟着换归属。
        XCTAssertEqual(drills[2].topic, "酒店入住")
        XCTAssertEqual(drills[2].difficulty, 4)
        // id 必须带 topic 序号：两个情景的第 0 句不能撞 id（去重会吞掉一句）。
        XCTAssertEqual(Set(drills.map(\.id)).count, 4)
    }

    func testShadowingParseDropsOrphanSentencesAndHonorsLimit() {
        // topic 之前的句子没有情景归属 —— 页面无处安放，必须丢。
        let raw = """
        sentence: orphan one | 孤儿句
        topic: 点餐
        sentence: I'll have the grilled salmon. | 我要烤三文鱼。
        sentence: Could I get the dressing on the side? | 酱汁可以放旁边吗？
        """
        let drills = ShadowingDailyRule.parse(raw, limit: 1)
        XCTAssertEqual(drills.map(\.text), ["I'll have the grilled salmon."], "孤儿句要丢，且 limit 要生效")

        // 难度再越界也要夹回 1...5。
        let crazy = ShadowingDailyRule.parse("topic: x | 99\nsentence: hello | 你好")
        XCTAssertEqual(crazy.first?.difficulty, 5)
    }

    // MARK: - 需求二：词族树

    func testDictionaryDetailParsesFamilyTree() {
        let raw = """
        word: rival
        phonetic: /ˈraɪvl/
        family_root: riv | 河
        family_branch: rival | n. | 竞争对手 | riv 河：溪流 + -al 与……有关的
        family_member: rival | rivalry | n. | 竞争；较量 | rival + -ry 表示性质/状态
        family_member: rival | rivalrous | adj. | 竞争性的 | rival + -ous 充满……的
        family_member: rivalry | rivality | n. | 对立状态 | rivalry + -ity 名词后缀
        family_member: derivative | rivulet | n. | 小溪 | riv 河 + -ulet 小称后缀
        """

        let detail = DictionaryDetailRule.parse(raw, fallbackWord: "rival")

        XCTAssertEqual(detail.family.root, "riv")
        XCTAssertEqual(detail.family.rootMeaning, "河")
        XCTAssertEqual(detail.family.branches.count, 2, "挂不上的关联词必须升为分支，而不是丢掉")
        XCTAssertEqual(detail.family.branches.map(\.word), ["rival", "rivulet"])

        // 二级嵌套：`rivality` 挂在 `rivalry` 下面，不是平铺在根下。
        let rival = detail.family.node(for: "rival")
        XCTAssertEqual(rival?.children.map(\.word), ["rivalry", "rivalrous"])
        XCTAssertEqual(
            detail.family.node(for: "rivalry")?.children.map(\.word),
            ["rivality"],
            "关联词自己还可以再挂关联词（树本来就该是多层）"
        )
        let rivulet = detail.family.node(for: "rivulet")
        XCTAssertEqual(rivulet?.pos, "n.")
        XCTAssertEqual(rivulet?.translation, "小溪")
        XCTAssertEqual(rivulet?.morphology, "riv 河 + -ulet 小称后缀")

        XCTAssertTrue(detail.family.contains("rival"))
        XCTAssertFalse(detail.family.contains("unrelated"))

        // ⚠️ 父词恰好是某个字段名时不能被吞掉：`derivative` / `word` / `sentence` / `origin`
        // 都在 `knownKeys` 里（它们是别的行的键名），而它们本身也是正经英文单词。
        // 被吞掉的话整行会左移一格 —— 父词变词条、词条变词性（实测就是这样翻的车）。
        let borrowed = DictionaryDetailRule.parse(
            """
            word: word
            family_root: word | 词
            family_member: word | wording | n. | 措辞 | word + -ing
            family_member: sentence | sentential | adj. | 句子的 | sentence + -ial
            """,
            fallbackWord: "word"
        )
        XCTAssertEqual(borrowed.family.root, "word")
        XCTAssertEqual(borrowed.family.node(for: "wording")?.translation, "措辞")
        XCTAssertEqual(borrowed.family.node(for: "sentential")?.translation, "句子的")
        XCTAssertTrue(
            borrowed.family.contains("wording"),
            "父词是字段名时也必须读得出子孙节点"
        )

        // ⚠️ 没有词族时「整段不出现」：`isEmpty` 必须把 family 算进去，
        // 否则详情页会挂一张只有标题的空卡片。
        let bare = DictionaryDetailRule.parse("word: hi\nphonetic: /haɪ/", fallbackWord: "hi")
        XCTAssertTrue(bare.family.isEmpty)
        XCTAssertTrue(DictionaryWordFamily().isEmpty)
    }

    func testFamilyBuilderNeverLoopsAndDeduplicates() {
        // 模型偶尔把 A 挂给 B、又把 B 挂给 A：这里必须**停住**而不是无限递归。
        let family = DictionaryFamilyBuilder.build(
            root: "root",
            rootMeaning: "根",
            branches: [["alpha"], ["beta"]],
            members: [["alpha", "beta"], ["beta", "alpha"], ["alpha", "alpha"]]
        )

        XCTAssertEqual(family.branches.count, 2)
        // 同一父节点下的重复行只留一份。
        XCTAssertEqual(family.branches.map(\.word), ["alpha", "beta"])
        XCTAssertFalse(family.branches.first { $0.word == "alpha" }!.children.isEmpty)
        // 一组号。
        XCTAssertEqual(family.wordCount, 2, "去重后树上应该只有 alpha / beta 两个词")

        // 空分支 → 空树（`isEmpty` 决定卡片出不出现）。
        XCTAssertTrue(
            DictionaryFamilyBuilder.build(root: "", rootMeaning: "", branches: [], members: []).isEmpty
        )
    }

    func testFamilyIgnoresUnrecognizedLines() {
        // 模型擅自加的字段（`mystery_key`）不能被当成内容吞进来 ——
        // 要么被认出来、要么被忽略，绝不能凭空出现一行「关联词」。
        let raw = """
        word: rival
        family_branch: rival | n. | 对手
        mystery_key: rival | n. | 这是模型自己加的一个词
        # 这是一句模型顺便写的解释
        """
        let detail = DictionaryDetailRule.parse(raw, fallbackWord: "rival")

        XCTAssertEqual(detail.family.branches.map(\.word), ["rival"], "未知键不能变成树上的分支")
        XCTAssertEqual(detail.family.branches.first?.translation, "对手")
        XCTAssertFalse(detail.family.allWords.contains("这是模型自己加的一个词"))
    }

    // MARK: - 需求三：划词（归一化 + 摆位）

    func testWordLookupNormalizesEdgesOnly() {
        XCTAssertEqual(WordLookupQuery.normalize("  snatch,  "), "snatch")
        XCTAssertEqual(WordLookupQuery.normalize("\"derive.\""), "derive")
        XCTAssertEqual(WordLookupQuery.normalize("（rival）"), "rival")
        // ⚠️ 中间的连字符 / 撇号是词的一部分，只能削两端。
        XCTAssertEqual(WordLookupQuery.normalize("state-of-the-art"), "state-of-the-art")
        XCTAssertEqual(WordLookupQuery.normalize("don't"), "don't")
        XCTAssertFalse(WordLookupQuery.isPhrase("don't"))
        XCTAssertTrue(WordLookupQuery.isPhrase("take a rain check"))
        XCTAssertEqual(WordLookupQuery.key("Snatch"), "snatch")
    }

    func testWordLookupFindsWordUnderCursor() {
        let sentence = "I'd like to check in."
        // 「check」的头一个字母。
        let start = sentence.distance(from: sentence.startIndex, to: sentence.range(of: "check")!.lowerBound)
        XCTAssertEqual(WordLookupQuery.word(in: sentence, at: start), "check")
        // 词中间的任意位置都要落在同一个词上（悬停不是整词对齐的）。
        XCTAssertEqual(WordLookupQuery.word(in: sentence, at: start + 2), "check")
        // 撇号算词的一部分：`I'd` 不能被切成 `I` + `d`。
        XCTAssertEqual(WordLookupQuery.word(in: sentence, at: 1), "I'd")
        // 光标压在标点 / 空格上 → 没有词（不该弹气泡）。
        XCTAssertEqual(WordLookupQuery.word(in: sentence, at: 0), "I'd")
        let period = sentence.count - 1
        XCTAssertEqual(WordLookupQuery.word(in: sentence, at: period), "")
        XCTAssertEqual(WordLookupQuery.word(in: sentence, at: 999), "")
    }

    func testBubbleStaysInsideVisibleSpace() {
        let space = WordLookupSpace(topLimit: 0, bottomLimit: 600, leftLimit: 0, rightLimit: 400)
        let bubble = CGSize(width: 268, height: 84)

        // 词贴在窗口底边（下方放不下）→ 翻到上方，且不能越过上边界。
        let bottom = WordBubblePlacement.origin(
            anchor: CGRect(x: 100, y: 560, width: 40, height: 16), bubble: bubble, space: space
        )
        XCTAssertLessThanOrEqual(bottom.y + bubble.height, space.bottomLimit, "气泡不能被下边界切掉")
        XCTAssertGreaterThanOrEqual(bottom.y, space.topLimit, "气泡不能被上边界切掉")

        // 词贴在左边界：以词为中心会把气泡推出屏幕左侧，必须夹回来。
        let left = WordBubblePlacement.origin(
            anchor: CGRect(x: 2, y: 200, width: 30, height: 16), bubble: bubble, space: space
        )
        XCTAssertGreaterThanOrEqual(left.x, space.leftLimit)

        // 词贴在右边界。
        let right = WordBubblePlacement.origin(
            anchor: CGRect(x: 380, y: 200, width: 30, height: 16), bubble: bubble, space: space
        )
        XCTAssertLessThanOrEqual(right.x + bubble.width, space.rightLimit)

        // 可视区比气泡还小：至少保证标题行看得见（贴上边界 / 左边界），不能飘出去。
        let tiny = WordLookupSpace(topLimit: 0, bottomLimit: 40, leftLimit: 0, rightLimit: 60)
        let squeezed = WordBubblePlacement.origin(
            anchor: CGRect(x: 10, y: 10, width: 20, height: 12), bubble: bubble, space: tiny
        )
        XCTAssertEqual(squeezed.y, tiny.topLimit + WordBubblePlacement.margin)
        XCTAssertEqual(squeezed.x, tiny.leftLimit + WordBubblePlacement.margin)

        // 常规情形：优先压在词的**下方**（不挡住刚划过的那一行）。
        let normal = WordBubblePlacement.origin(
            anchor: CGRect(x: 100, y: 100, width: 40, height: 16), bubble: bubble, space: space
        )
        XCTAssertEqual(normal.y, 100 + 16 + WordBubblePlacement.gap)
    }
}
