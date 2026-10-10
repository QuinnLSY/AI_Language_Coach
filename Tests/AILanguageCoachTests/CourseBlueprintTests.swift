import AIDomain
@testable import AIDomain
@testable import AIInfrastructure
import Foundation
import XCTest

/// ③ AI 自动课程：排课纯函数（输入清洗 / 稳定 id / 难度夹档 / 输出解析）。
///
/// 这一层不碰模型、不碰 IO，所以能逐条钉死：
/// - 四项输入各自独立、都可能为空；**一项都没有时不排课**（没有依据可排）。
/// - 同一次状态 → 同一条课 id（重排是覆盖，不是在树上堆积）。
/// - 档位已知时**每节课都按学员自己的档位判定**，难度只夹进他的区间。
/// - 坏节跳过；留下的节不够保底 → **整条作废**（宁可让用户重排，也不落废物）。
final class CourseBlueprintTests: XCTestCase {

    // MARK: - 夹具

    /// 一段「模型输出」（键值行）。默认两节，都齐全。
    private func output(
        courseTitle: String? = "咖啡馆口语 | 咖啡店口语",
        focus: String? = "盯住时态与 /θ/ 音",
        lessons: [(title: String, difficulty: String, sentences: [String])] = [
            ("点单开场", "3", ["I'd like a latte, please.", "Could I get that with oat milk?"]),
            ("结账收尾", "4", ["Can I pay by card?", "Keep the change."]),
        ]
    ) -> String {
        var lines: [String] = []
        if let courseTitle { lines.append("course: \(courseTitle)") }
        if let focus { lines.append("focus: \(focus)") }
        for (title, difficulty, sentences) in lessons {
            lines.append("lesson: \(title)")
            lines.append("scene: barista | customer | 学会礼貌点单 | \(difficulty) | Good morning! What can I get for you?")
            for sentence in sentences { lines.append("sentence: \(sentence)") }
            lines.append("vocabulary: latte | n. | 拿铁 | I'd like a latte, please.")
            lines.append("quest: 完成这一节的对话")
        }
        return lines.joined(separator: "\n")
    }

    private func request(
        level: CEFRLevel? = .b1,
        errors: [String] = ["过去时混用"],
        phonemes: [String] = ["θ"],
        topics: [String] = []
    ) -> CourseRequest {
        CourseRequest(level: level, recurringErrors: errors, weakPhonemes: phonemes, topics: topics)
    }

    // MARK: - 输入：信号与清洗

    func testEmptyRequestHasNoSignalAndCannotBeScheduled() {
        let empty = CourseRequest()
        XCTAssertFalse(empty.hasSignal, "四项全空 → 没有排课依据")
        XCTAssertEqual(CourseBlueprintRule.inputIssue(for: empty), .nothingToSchedule)
        XCTAssertEqual(CourseBlueprintRule.inputIssue(for: empty)?.message, "还没有可排课的依据：先练几局，或者写一个想练的主题")
    }

    func testAnySingleSignalIsEnoughToSchedule() {
        XCTAssertNil(CourseBlueprintRule.inputIssue(for: request(level: .b1, errors: [], phonemes: [])))
        XCTAssertNil(CourseBlueprintRule.inputIssue(for: request(level: nil, errors: ["时态"], phonemes: [])))
        XCTAssertNil(CourseBlueprintRule.inputIssue(for: request(level: nil, errors: [], phonemes: ["θ"])))
        XCTAssertNil(CourseBlueprintRule.inputIssue(for: request(level: nil, errors: [], phonemes: [], topics: ["咖啡店点单"])))
    }

    func testSanitizingDropsBlanksFlattensStructureAndDeduplicates() {
        let cleaned = CourseBlueprintRule.sanitized(CourseRequest(
            topics: ["  咖啡店点单 ", "咖啡店点单", "", "   ", "面试\n开场 | 自我介绍"]
        ))
        XCTAssertEqual(cleaned.topics, ["咖啡店点单", "面试 开场 自我介绍"],
                       "空白项丢弃、重复项合并、换行与 `|` 压平")
    }

    func testSanitizingCapsEveryBucket() {
        let cleaned = CourseBlueprintRule.sanitized(CourseRequest(
            recurringErrors: (1...20).map { "错\($0)" },
            weakPhonemes: (1...20).map { "p\($0)" },
            topics: (1...10).map { "主题\($0)" }
        ))
        XCTAssertEqual(cleaned.recurringErrors.count, CourseBlueprintRule.maximumRecurringErrors)
        XCTAssertEqual(cleaned.weakPhonemes.count, CourseBlueprintRule.maximumWeakPhonemes)
        XCTAssertEqual(cleaned.topics.count, CourseBlueprintRule.maximumTopics)
    }

    func testLongTopicsAreTruncatedBeforeDeduplication() {
        let shared = String(repeating: "a", count: CourseBlueprintRule.maximumTopicLength)
        let cleaned = CourseBlueprintRule.sanitized(CourseRequest(topics: [shared + "尾巴一", shared + "尾巴二"]))
        XCTAssertEqual(cleaned.topics.count, 1,
                       "两条只差尾巴的主题截断后是同一个串 → 必须在去重之前截，否则两条都留下")
    }

    // MARK: - 稳定 id

    func testSameStateYieldsTheSameCourseID() {
        let a = CourseBlueprintRule.stableID(request: request(topics: ["咖啡店点单"]))
        let b = CourseBlueprintRule.stableID(request: request(topics: ["  咖啡店点单  "]))
        XCTAssertEqual(a, b, "清洗过的同一份状态 → 同一条课（重排是覆盖）")
        XCTAssertTrue(a.hasPrefix("course-"), "id 前缀固定，便于与情景 id 区分")
    }

    func testDifferentSignalYieldsADifferentCourseID() {
        let base = request(topics: ["咖啡店点单"])
        XCTAssertNotEqual(CourseBlueprintRule.stableID(request: base),
                          CourseBlueprintRule.stableID(request: request(topics: ["面试"])))
        XCTAssertNotEqual(CourseBlueprintRule.stableID(request: base),
                          CourseBlueprintRule.stableID(request: request(level: .a2, topics: ["咖啡店点单"])))
    }

    func testSignatureDistinguishesWhichBucketCarriesTheSignal() {
        // 只有档位 vs 只有主题：不占位的话两者可能拼出同一个串。
        let levelOnly = CourseBlueprintRule.signature(of: CourseRequest(level: .b1))
        let topicOnly = CourseBlueprintRule.signature(of: CourseRequest(topics: ["b1"]))
        XCTAssertNotEqual(levelOnly, topicOnly)
    }

    func testStateSummaryListsEverySignal() {
        let summary = request(level: .a2, errors: ["时态", "冠词"], phonemes: ["θ"], topics: ["咖啡店点单"]).stateSummary
        XCTAssertTrue(summary.contains("现在 A2"), summary)
        XCTAssertTrue(summary.contains("2 处反复错（时态、冠词）"), summary)
        XCTAssertTrue(summary.contains("1 个顽固音素（θ）"), summary)
        XCTAssertTrue(summary.contains("想练：咖啡店点单"), summary)
    }

    // MARK: - 难度与档位

    func testDifficultyBandMatchesEveryLevel() {
        XCTAssertEqual(CourseBlueprintRule.difficultyBand(for: .a1), 1...2)
        XCTAssertEqual(CourseBlueprintRule.difficultyBand(for: .a2), 2...3)
        XCTAssertEqual(CourseBlueprintRule.difficultyBand(for: .b1), 3...4)
        XCTAssertEqual(CourseBlueprintRule.difficultyBand(for: .b2), 4...5)
    }

    func testClampedDifficultyPullsAMisjudgedModelBackIntoTheLearnersBand() {
        XCTAssertEqual(CourseBlueprintRule.clampedDifficulty(1, for: .b1), 3, "给 B1 学员排 A1 难度的课等于白排")
        XCTAssertEqual(CourseBlueprintRule.clampedDifficulty(5, for: .a1), 2)
        XCTAssertEqual(CourseBlueprintRule.clampedDifficulty(3, for: .b2), 4)
        XCTAssertEqual(CourseBlueprintRule.clampedDifficulty(4, for: nil), 4, "没定位出档位时不夹")
        XCTAssertEqual(CourseBlueprintRule.clampedDifficulty(0, for: nil), 1)
        XCTAssertEqual(CourseBlueprintRule.clampedDifficulty(9, for: nil), 5)
    }

    func testLessonLevelUsesTheLearnersOwnLevel() {
        XCTAssertEqual(CourseBlueprintRule.levelString(for: 4, learnerLevel: .b1), "B1",
                       "档位已知 → 就按他的档判定，不由难度反推（反推只有 5 档、映射很粗）")
        XCTAssertEqual(CourseBlueprintRule.levelString(for: 4, learnerLevel: nil), "B1-B2",
                       "档位未知 → 退回按难度推区间")
    }

    // MARK: - 解析：正常路径

    func testParsesTwoLessonsWithEveryField() throws {
        let blueprint = try XCTUnwrap(CourseBlueprintRule.parse(output(), request: request(), createdAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(blueprint.title, "咖啡馆口语")
        XCTAssertEqual(blueprint.titleZh, "咖啡店口语")
        XCTAssertEqual(blueprint.displayTitle, "咖啡店口语")
        XCTAssertEqual(blueprint.focus, "盯住时态与 /θ/ 音")
        XCTAssertEqual(blueprint.targetLevel, .b1)
        XCTAssertEqual(blueprint.lessonCount, 2)
        XCTAssertEqual(blueprint.summary, "2 节课 · B1")

        let first = blueprint.lessons[0]
        XCTAssertEqual(first.order, 1)
        XCTAssertEqual(first.title, "点单开场")
        XCTAssertEqual(first.orderText, "第 1 节")
        XCTAssertEqual(first.scenario.aiRole, "barista")
        XCTAssertEqual(first.scenario.learnerRole, "customer")
        XCTAssertEqual(first.scenario.opening, "Good morning! What can I get for you?")
        XCTAssertEqual(first.scenario.targetSentences.count, 2)
        XCTAssertEqual(first.scenario.targetVocabulary, ["latte"])
        XCTAssertEqual(first.scenario.maxTurns, CourseBlueprintRule.maxTurns)
        XCTAssertEqual(first.scenario.difficulty, 3)
        XCTAssertEqual(first.words.first?.meaning, "拿铁")
    }

    func testLessonScenarioIsShapedLikeABuiltInOne() throws {
        let blueprint = try XCTUnwrap(CourseBlueprintRule.parse(output(), request: request()))
        for lesson in blueprint.lessons {
            XCTAssertEqual(lesson.scenario.origin, .course, "来源是数据，不是靠分组名比较")
            XCTAssertEqual(lesson.scenario.category, CourseBlueprintRule.category)
            XCTAssertEqual(lesson.scenario.icon, CourseBlueprintRule.icon)
            XCTAssertEqual(lesson.scenario.id, lesson.id)
            XCTAssertEqual(lesson.scenario.targetVocabulary, lesson.words.map(\.word))
            XCTAssertFalse(lesson.scenario.questPlan.steps.isEmpty,
                           "主线步骤由目标句自动推导 —— 这一节必须直接能进现有练习链路")
        }
    }

    func testLessonIdentifiersAreStableAndCarryTheOrder() throws {
        let request = request()
        let first = try XCTUnwrap(CourseBlueprintRule.parse(output(), request: request))
        let second = try XCTUnwrap(CourseBlueprintRule.parse(output(), request: request))
        XCTAssertEqual(first.id, second.id, "同一份状态重排 → 同一条课")
        XCTAssertEqual(first.lessons.map(\.id), second.lessons.map(\.id), "每节课的 id 也必须稳定（树上那一格才接得上）")
        for lesson in first.lessons {
            XCTAssertEqual(lesson.id,
                           CourseBlueprintRule.lessonID(courseID: first.id, order: lesson.order, title: lesson.title))
        }
        XCTAssertNotEqual(first.lessons[0].id, first.lessons[1].id)
    }

    func testDifferentCourseYieldsDifferentLessonIdentifiers() throws {
        let a = try XCTUnwrap(CourseBlueprintRule.parse(output(), request: request(topics: ["咖啡店"])))
        let b = try XCTUnwrap(CourseBlueprintRule.parse(output(), request: request(topics: ["面试"])))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.lessons[0].id, b.lessons[0].id)
    }

    func testNextLessonFollowsTheCourseOrder() throws {
        let blueprint = try XCTUnwrap(CourseBlueprintRule.parse(output(), request: request()))
        XCTAssertEqual(blueprint.nextLesson(after: blueprint.lessons[0].id)?.id, blueprint.lessons[1].id)
        XCTAssertNil(blueprint.nextLesson(after: blueprint.lessons[1].id), "最后一节没有下一节")
        XCTAssertNil(blueprint.nextLesson(after: "course-lesson-00000000"), "不认识的 id 返回 nil，不崩")
    }

    // MARK: - 解析：坏节与保底

    func testASingleLessonIsNotACourse() {
        let raw = output(lessons: [("唯一一节", "3", ["I'd like a latte, please.", "Could I get that with oat milk?"])])
        XCTAssertNil(CourseBlueprintRule.parse(raw, request: request()),
                     "一节的「课」就是一次普通情景练习 —— 整条作废，别占树上的一格")
    }

    func testBadLessonIsSkippedAndTheRestIsRenumbered() throws {
        let raw = """
        course: 咖啡馆口语 | 咖啡店口语
        lesson: 点单开场
        scene: barista | customer | 点单 | 3 | Good morning!
        sentence: I'd like a latte, please.
        sentence: Could I get that with oat milk?
        lesson: 少了场景的这一节
        sentence: Can I pay by card?
        sentence: Keep the change.
        lesson: 结账收尾
        scene: cashier | customer | 结账 | 4 | That'll be five dollars.
        sentence: Can I pay by card?
        sentence: Keep the change.
        """
        let blueprint = try XCTUnwrap(CourseBlueprintRule.parse(raw, request: request()))
        XCTAssertEqual(blueprint.lessons.map(\.title), ["点单开场", "结账收尾"])
        XCTAssertEqual(blueprint.lessons.map(\.order), [1, 2], "序号按留下来的节连续重排，不留空号")
        for lesson in blueprint.lessons {
            XCTAssertEqual(lesson.id,
                           CourseBlueprintRule.lessonID(courseID: blueprint.id, order: lesson.order, title: lesson.title),
                           "节 id 由序号推出 → 必须与重排后的序号一致")
        }
    }

    func testLessonWithTooFewSentencesIsDiscarded() throws {
        let raw = """
        lesson: 只有一句
        scene: barista | customer | 点单 | 3 | Good morning!
        sentence: I'd like a latte, please.
        lesson: 齐全的一节
        scene: barista | customer | 点单 | 3 | Good morning!
        sentence: I'd like a latte, please.
        sentence: Could I get that with oat milk?
        lesson: 也齐全的一节
        scene: barista | customer | 点单 | 3 | Good morning!
        sentence: Can I pay by card?
        sentence: Keep the change.
        """
        let blueprint = try XCTUnwrap(CourseBlueprintRule.parse(raw, request: request()))
        XCTAssertEqual(blueprint.lessons.count, 2, "目标句不足两句 → 练完没法逐句核对，这一节作废")
        XCTAssertFalse(blueprint.lessons.contains { $0.title == "只有一句" })
    }

    func testLessonWithFencedCodeBlocksAndNumberedTitlesStillParses() throws {
        let raw = """
        ```
        course: 1 | 咖啡馆口语 | 咖啡店口语
        focus: 盯住时态
        lesson: 1. 点单开场
        scene: AI Role: barista | Learner Role: customer | Goal: 点单 | Difficulty: 3 | Hi there!
        sentence: I'd like a latte, please.
        sentence: Could I get that with oat milk?
        lesson: 2. 结账收尾
        scene: cashier | customer | 结账 | 4 | That'll be five dollars.
        sentence: Can I pay by card?
        sentence: Keep the change.
        ```
        """
        let blueprint = try XCTUnwrap(CourseBlueprintRule.parse(raw, request: request()))
        XCTAssertEqual(blueprint.titleZh, "咖啡店口语", "course 行多带了一个序号 → 丢掉纯数字字段")
        XCTAssertEqual(blueprint.lessons.map(\.title), ["点单开场", "结账收尾"], "lesson 行的序号不采信，序号由解析顺序定")
        XCTAssertEqual(blueprint.lessons[0].scenario.aiRole, "barista", "子字段自带的 `AI Role:` 标签要剥掉")
        XCTAssertEqual(blueprint.lessons[0].scenario.learnerRole, "customer")
    }

    func testTitleIndexPrefixIsStrippedOnlyWhenAMarkerFollows() {
        XCTAssertEqual(CourseBlueprintRule.strippingIndexPrefix("1. 点单开场"), "点单开场")
        XCTAssertEqual(CourseBlueprintRule.strippingIndexPrefix("2) 结账收尾"), "结账收尾")
        XCTAssertEqual(CourseBlueprintRule.strippingIndexPrefix("3、换料追加"), "换料追加")
        XCTAssertEqual(CourseBlueprintRule.strippingIndexPrefix("第 4 节"), "第 4 节", "不是「数字 + 分隔符」就不动")
        XCTAssertEqual(CourseBlueprintRule.strippingIndexPrefix("7 天入门口语"), "7 天入门口语",
                       "真以数字开头的标题不能被削掉")
        XCTAssertEqual(CourseBlueprintRule.strippingIndexPrefix("点单开场"), "点单开场")
        XCTAssertEqual(CourseBlueprintRule.strippingIndexPrefix("1"), "1", "整串都是数字时原样保留")
    }

    func testTitleAfterLessonHeaderNamesThatLesson() throws {
        let raw = """
        lesson: 占位标题
        title: 真正的标题 | 真正的标题中文
        scene: barista | customer | 点单 | 3 | Good morning!
        sentence: I'd like a latte, please.
        sentence: Could I get that with oat milk?
        lesson: 第二节
        scene: cashier | customer | 结账 | 3 | That'll be five dollars.
        sentence: Can I pay by card?
        sentence: Keep the change.
        """
        let blueprint = try XCTUnwrap(CourseBlueprintRule.parse(raw, request: request()))
        XCTAssertEqual(blueprint.lessons[0].title, "真正的标题")
        XCTAssertEqual(blueprint.lessons[0].titleZh, "真正的标题中文")
    }

    func testCourseTitleFallsBackToTheFirstLesson() throws {
        let blueprint = try XCTUnwrap(CourseBlueprintRule.parse(output(courseTitle: nil), request: request()))
        XCTAssertEqual(blueprint.title, "点单开场",
                       "课名是展示用的顶层标签 → 缺了只兜底，不为一行标签丢掉整次生成")
        XCTAssertEqual(blueprint.titleZh, "点单开场")
    }

    func testFocusFallsBackToTheStateSummary() throws {
        let request = request(topics: ["咖啡店点单"])
        let blueprint = try XCTUnwrap(CourseBlueprintRule.parse(output(focus: nil), request: request))
        XCTAssertEqual(blueprint.focus, request.sanitized().stateSummary,
                       "兜底用的是**注入 Prompt 的同一句**，不是另写一句")
        XCTAssertEqual(blueprint.rationale, request.sanitized().stateSummary)
    }

    func testLessonCountIsCappedWithoutEatingTheTailSlot() throws {
        let many = (1...9).map { index in
            ("第\(index)节", "3", ["Sentence one \(index).", "Sentence two \(index)."])
        }
        let blueprint = try XCTUnwrap(CourseBlueprintRule.parse(output(lessons: many), request: request()))
        XCTAssertEqual(blueprint.lessons.count, CourseBlueprintRule.maximumLessons)
        XCTAssertEqual(blueprint.lessons.map(\.order), Array(1...CourseBlueprintRule.maximumLessons))
    }

    func testLessonDifficultyIsClampedIntoTheLearnersBand() throws {
        let oneHard = output(lessons: [
            ("太容易的一节", "1", ["I'd like a latte, please.", "Could I get that with oat milk?"]),
            ("正常的一节", "3", ["Can I pay by card?", "Keep the change."]),
        ])
        let forB1 = try XCTUnwrap(CourseBlueprintRule.parse(oneHard, request: request(level: .b1)))
        XCTAssertEqual(forB1.lessons.map(\.scenario.difficulty), [3, 3])
        XCTAssertEqual(forB1.lessons.map(\.scenario.level), ["B1", "B1"])

        let withoutLevel = try XCTUnwrap(CourseBlueprintRule.parse(oneHard, request: request(level: nil)))
        XCTAssertEqual(withoutLevel.lessons.map(\.scenario.difficulty), [1, 3], "没定位出档位时不夹，保留模型的判断")
        XCTAssertEqual(withoutLevel.lessons.map(\.scenario.level), ["A1-A2", "A2-B1"])
    }

    // MARK: - Prompt 与解析器是同一套键

    /// 模板**文件**本身也必须声明全部键。
    ///
    /// ⚠️ 单看 `PromptBuilder` 的输出是不够的：模板文件读不到时会**静默**退回代码里那份
    /// 内嵌兜底，于是文件里键名写错也照样「全绿」—— 只有真打包出去才失效。
    /// 所以这里直接读文件，并额外确认发出去的**就是**文件内容（内嵌兜底是英文的）。
    func testPromptTemplateFileDeclaresEveryKey() throws {
        let url = try XCTUnwrap(
            AppResourceBundle.url(forResource: "Prompts/course_blueprint", withExtension: "txt"),
            "模板文件必须在资源包里 —— 读不到就会静默退回内嵌兜底，文件坏了没人知道"
        )
        let template = try String(contentsOf: url, encoding: .utf8)
        for key in ["course:", "focus:", "lesson:", "scene:", "sentence:", "vocabulary:", "quest:"] {
            XCTAssertTrue(template.contains(key), "模板文件里必须有 `\(key)` —— 否则解析器永远读不到这一节")
        }

        let prompt = PromptBuilder.courseBlueprintPrompt(
            request: request(), learningLanguage: "English", nativeLanguage: "中文"
        )
        XCTAssertTrue(prompt.contains("你是这位语言学习者的老师"),
                      "发出去的必须是真的模板文件，不是代码里那份内嵌兜底")
    }

    func testPromptDeclaresEveryKeyTheParserReads() {
        let prompt = PromptBuilder.courseBlueprintPrompt(
            request: request(topics: ["咖啡店点单"]),
            learningLanguage: "English",
            nativeLanguage: "中文"
        )
        for key in ["course:", "focus:", "lesson:", "scene:", "sentence:", "vocabulary:", "quest:"] {
            XCTAssertTrue(prompt.contains(key), "模板里必须有 `\(key)` —— 否则解析器永远读不到这一节")
        }
        XCTAssertFalse(prompt.contains("{"), "占位符必须全部替换掉，不能把 `{level}` 原样发给模型")
    }

    func testPromptCarriesStateTopicsAndLevelBand() {
        let prompt = PromptBuilder.courseBlueprintPrompt(
            request: request(level: .b1, errors: ["时态混用"], phonemes: ["θ"], topics: ["咖啡店点单"]),
            learningLanguage: "English",
            nativeLanguage: "中文"
        )
        XCTAssertTrue(prompt.contains("现在 B1"), prompt)
        XCTAssertTrue(prompt.contains("1 处反复错（时态混用）"), prompt)
        XCTAssertTrue(prompt.contains("1 个顽固音素（θ）"), prompt)
        XCTAssertTrue(prompt.contains("想练：咖啡店点单"), prompt)
        XCTAssertTrue(prompt.contains("落在 3-4 之间"), "档位已知时必须告诉模型难度区间：\(prompt)")
    }

    func testPromptDropsTheTopicLineWhenThereIsNoTopic() {
        let prompt = PromptBuilder.courseBlueprintPrompt(
            request: request(level: nil, errors: ["时态混用"], phonemes: [], topics: []),
            learningLanguage: "English",
            nativeLanguage: "中文"
        )
        XCTAssertFalse(prompt.contains("自己想练的主题"),
                       "没主题时整行消失 —— 留个空槽位会让模型硬凑一个主题")
        XCTAssertTrue(prompt.contains("还没定位出他属于哪个档位"), "档位未知时也要给一句明确的话，不能留空括号")
    }
}
