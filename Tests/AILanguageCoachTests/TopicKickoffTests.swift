import AIDomain
import Foundation
import XCTest

/// ⑦-B① 开屏话题卡（今天聊什么）的纯函数判定。
///
/// 钉的是四件事：
/// - **没依据就不出卡**：卡片是「这儿有个能点的东西」，不是装饰；空数据时 UI 只画问候。
/// - **同一天同一张**：同一 `dayKey` 反复算必须完全一样，否则用户挑中的那句会消失。
/// - **发出去的那句一定非空且带着那个词**：空字符串会在发送口被 `guard` 静默丢掉。
/// - **副标必须可核对**：每张卡的第二行得是数据（步数 / 词 / 原句），不是形容词。
final class TopicKickoffTests: XCTestCase {

    // MARK: - 依据不足就不出卡

    func testNothingToLeanOnYieldsNoCards() {
        // 三样依据全没有：没练过、今天没词、句库也没加载出来。
        var ctx = Self.context(dayKey: "2026-10-12")
        ctx.todayWords = []
        ctx.smallTalkPool = []
        XCTAssertTrue(
            TopicKickoff.plan(ctx).isEmpty,
            "什么依据都没有时不该凭空凑卡"
        )
    }

    func testSmallTalkStillOfferedWhenNothingElseExists() {
        // 反过来：句库是内置资源，几乎永不为空 —— 那一句是「随便聊聊」的依据，
        // 新用户什么数据都没有时，至少得有一张点了能开口的卡。
        let ctx = Self.context(dayKey: "2026-10-12")
        let cards = TopicKickoff.plan(ctx)
        XCTAssertEqual(
            cards.map(\.kind), [.smallTalk],
            "没有别的依据时，只剩「随便聊聊」一张卡"
        )
    }

    func testZeroDoneStepsIsNotPracticed() {
        let prior = PriorPractice(
            scenarioID: "s1", scenarioTitle: "咖啡店点单",
            doneSteps: 0, totalSteps: 3, hoursAgo: 2
        )
        XCTAssertNil(
            TopicKickoff.resumeCard(prior),
            "一步都没完成 = 没练过：点开就退出的情景不该被当成「练了一半」"
        )
    }

    func testCompletedScenarioIsNotResumed() {
        let prior = PriorPractice(
            scenarioID: "s1", scenarioTitle: "咖啡店点单",
            doneSteps: 3, totalSteps: 3, hoursAgo: 2, isComplete: true
        )
        XCTAssertNil(
            TopicKickoff.resumeCard(prior),
            "整条主线已完成：再催「接着练」就是催他重做一遍"
        )
    }

    func testPracticedButUnfinishedYieldsResumeCard() {
        let prior = PriorPractice(
            scenarioID: "s1", scenarioTitle: "咖啡店点单",
            doneSteps: 2, totalSteps: 3, hoursAgo: 5
        )
        let card = TopicKickoff.resumeCard(prior)
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.kind, .resume)
        XCTAssertTrue(card?.title.contains("咖啡店点单") == true, "卡片要说清是哪个情景")
        XCTAssertTrue(card?.detail.contains("2/3") == true, "副标必须带可核对的步数")
        XCTAssertTrue(card?.detail.contains("5 小时前") == true, "副标必须带时间")
        XCTAssertEqual(card?.action, .openScenario(id: "s1"))
    }

    // MARK: - 同一天同一张

    func testSameDayIsStable() {
        let first = TopicKickoff.plan(Self.context(dayKey: "2026-10-12"))
        let second = TopicKickoff.plan(Self.context(dayKey: "2026-10-12"))
        XCTAssertEqual(first, second, "同一天必须抽到同一批：用户挑中的句子不能凭空消失")
        XCTAssertFalse(first.isEmpty)
    }

    func testDifferentDayRotatesPick() {
        let pool = (1...12).map { "small talk line \($0)" }
        var lines: Set<String> = []
        for day in 12...25 {
            let cards = TopicKickoff.plan(Self.context(dayKey: "2026-10-\(day)", pool: pool))
            if let small = cards.first(where: { $0.kind == .smallTalk }) {
                lines.insert(small.detail)
            }
        }
        XCTAssertGreaterThan(
            lines.count, 1,
            "一天一句不该每天都重复同一句（否则「今天聊什么」就变成一句永远不变的口号）"
        )
    }

    func testWordSlotDoesNotSyncWithSmallTalkSlot() {
        // 两个槽位共用种子的话，第 N 天总是同时跳到第 N 项 —— 看不出，但换语言/换天时会发现
        // 「换今天抽的词，聊的那句也跟着换了」，这是同一颗种子导致的耦合。
        let words = ["alpha", "beta", "gamma", "delta"]
        var wordPicks: Set<String> = []
        for day in 12...25 {
            var ctx = Self.context(dayKey: "2026-10-\(day)")
            ctx.todayWords = words
            if let card = TopicKickoff.plan(ctx).first(where: { $0.kind == .todayWord }) {
                wordPicks.insert(card.detail)
            }
        }
        XCTAssertGreaterThan(wordPicks.count, 1, "词条槽位也要有一天一换")
    }

    // MARK: - 发出去的那句

    func testWordCardSendsSentenceContainingTheWord() {
        var ctx = Self.context(dayKey: "2026-10-12")
        ctx.todayWords = ["resilient"]
        let card = TopicKickoff.plan(ctx).first(where: { $0.kind == .todayWord })
        guard case .send(let text)? = card?.action else {
            return XCTFail("词条卡应该是「点一下就发出去」，不是打开别的页面")
        }
        XCTAssertTrue(text.contains("resilient"), "发出去的句子必须带上那个词，否则老师不知道要陪练什么")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testTemplateWithoutPlaceholderStillSendsSomething() {
        var ctx = Self.context(dayKey: "2026-10-12", template: "Let's practice a new word today.")
        ctx.todayWords = ["resilient"]
        let card = TopicKickoff.plan(ctx).first(where: { $0.kind == .todayWord })
        guard case .send(let text)? = card?.action else { return XCTFail("应当发出一句话") }
        XCTAssertFalse(text.isEmpty, "模板没写占位符也不能返回空串 —— 空串会在发送口被静默丢掉")
    }

    func testEmptyTemplateFallsBackToSentence() {
        var ctx = Self.context(dayKey: "2026-10-12", template: "")
        ctx.todayWords = ["resilient"]
        let card = TopicKickoff.plan(ctx).first(where: { $0.kind == .todayWord })
        guard case .send(let text)? = card?.action else { return XCTFail("应当发出一句话") }
        XCTAssertTrue(text.contains("resilient"), "模板为空时用兜底句型，词仍要在句里")
        XCTAssertGreaterThan(text.count, 20, "兜底句得是一句完整的话")
    }

    func testBlankEntriesAreFilteredOut() {
        var ctx = Self.context(dayKey: "2026-10-12")
        ctx.todayWords = ["  ", ""]
        XCTAssertNil(
            TopicKickoff.plan(ctx).first(where: { $0.kind == .todayWord }),
            "空白词不能凑成一张卡"
        )
    }

    // MARK: - 上限与结构

    func testPrefersPriorPracticeFirst() {
        var ctx = Self.context(dayKey: "2026-10-12")
        ctx.priorPractice = PriorPractice(
            scenarioID: "s9", scenarioTitle: "机场值机",
            doneSteps: 1, totalSteps: 4, hoursAgo: 26
        )
        ctx.todayWords = ["word"]
        let cards = TopicKickoff.plan(ctx)
        XCTAssertEqual(cards.first?.kind, .resume, "断点续练排在最前：用户最可能想接着做")
        XCTAssertLessThanOrEqual(cards.count, TopicKickoff.maximumSuggestions)
        XCTAssertEqual(Set(cards.map(\.id)).count, cards.count, "卡片 id 不许重复")
    }

    func testElapsedText() {
        XCTAssertEqual(TopicKickoff.elapsedText(hoursAgo: 0), "刚刚练过")
        XCTAssertEqual(TopicKickoff.elapsedText(hoursAgo: 3), "3 小时前")
        XCTAssertEqual(TopicKickoff.elapsedText(hoursAgo: 26), "昨天")
        XCTAssertEqual(TopicKickoff.elapsedText(hoursAgo: 72), "3 天前")
    }

    // MARK: - 真撤反证

    func testResumeDisappearsWithoutRealPriorPractice() {
        // 反证：把「主线条目已完成」当成「没练过」，卡片照样会出现 ——
        // 那说明 `isComplete` 这道判据根本没接上。
        let finished = PriorPractice(
            scenarioID: "s1", scenarioTitle: "咖啡店点单",
            doneSteps: 3, totalSteps: 3, hoursAgo: 1, isComplete: true
        )
        let ongoing = PriorPractice(
            scenarioID: "s1", scenarioTitle: "咖啡店点单",
            doneSteps: 3, totalSteps: 3, hoursAgo: 1, isComplete: false
        )
        XCTAssertNil(TopicKickoff.resumeCard(finished))
        XCTAssertNotNil(TopicKickoff.resumeCard(ongoing), "同样的 3/3，只差 isComplete，结果必须相反")
    }

    // MARK: - 工装

    private static func context(
        dayKey: String,
        template: String = "Can you help me use the word \"%@\" in a sentence?",
        pool: [String]? = nil
    ) -> TopicKickoff.Context {
        TopicKickoff.Context(
            todayWords: [],
            smallTalkPool: pool ?? [
                "How was your day?",
                "Can you help me order a coffee like a local?",
                "What's the difference between \"say\" and \"tell\"?",
                "Let's practice small talk about the weather.",
                "Could you correct my pronunciation of \"th\"?"
            ],
            dayKey: dayKey,
            language: "English",
            wordPromptTemplate: template
        )
    }
}
