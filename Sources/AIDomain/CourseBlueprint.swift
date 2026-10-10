import Foundation

// MARK: - AI 自动课程（V2：课程体系目前是静态 CEFR）
//
// 现状：课程体系 = `CurriculumLadder` 把 `Resources/Scenarios/*.json` 里那 10 个内置情景
// 按 CEFR 分档 —— 是一条**静态阶梯**，跟「这个学员现在差在哪」没有关系。
// `ScenarioDraftRule` 是**反向**的：用户写一句话 → 生成**一个**情景（一格，不成体系）。
// `LearningPlan` 只**聚合**已有真源，本身不生成任何内容。
//
// 缺的正是中间那一步：**由学员状态自动排出一条有序的课（N 节），一键就能开练**。
// 本文件把「学员状态」变成一条课程大纲 —— 每节与内置情景**完全同构**（一节课 = 一个
// `Scenario`），于是不需要任何新的练习链路：落盘沿用 `CustomScenarioStore` 那套形态，
// 分档沿用 `CurriculumLadder`，开练沿用现有情景练习。
//
// 硬边界：不碰模型、不碰 IO —— 只做输入清洗与输出解析，纯函数、可单测。

/// 一次排课的输入：学员状态。
///
/// 四项各自独立、都可能为空 —— 排课依据是它们的**并集**（一项都没有时见
/// `CourseBlueprintRule.inputIssue`）。
public struct CourseRequest: Sendable, Equatable {

    /// 学员当前档位（`PlacementEstimate.level`）。nil = 还没定位出来（新学员）。
    public var level: CEFRLevel?
    /// 反复错：学习记忆里**还没练掉**的错。「排课给靶子」，比泛泛的主题值钱。
    public var recurringErrors: [String]
    /// 顽固音素：已评够次数、错够次数的音标符号（如 `θ`）。排课时要求**每节课都带上它**。
    public var weakPhonemes: [String]
    /// 用户自填的主题 / 兴趣（「咖啡店点单」「面试」）。为空 = 只按状态排。
    public var topics: [String]

    public init(
        level: CEFRLevel? = nil,
        recurringErrors: [String] = [],
        weakPhonemes: [String] = [],
        topics: [String] = []
    ) {
        self.level = level
        self.recurringErrors = recurringErrors
        self.weakPhonemes = weakPhonemes
        self.topics = topics
    }

    /// 清洗后的副本（去空白 / 去重复 / 去结构符 / 截断到上限）。
    ///
    /// ⚠️ 只有清洗过的请求才该进 Prompt、才该算指纹 —— 否则同一份状态因为多了个空格、
    /// 多重复了一条错题，就会排出一条**新**课（旧课还留在树上）。
    public func sanitized() -> CourseRequest { CourseBlueprintRule.sanitized(self) }

    /// 有没有排课依据（一项信号都没有 → 没得排）。
    public var hasSignal: Bool {
        level != nil || !recurringErrors.isEmpty || !weakPhonemes.isEmpty || !topics.isEmpty
    }

    /// 排课依据的一句中文概括。
    ///
    /// ⚠️ **注入 Prompt 与卡片回显共用这一句**：学员看到的「照着这些排的」必须就是
    /// 模型当时拿到的那句话，各写一份迟早对不上（测试钉着两处用的是同一个值）。
    public var stateSummary: String {
        var parts: [String] = []
        if let level { parts.append("现在 \(level.code)") }
        if !recurringErrors.isEmpty {
            parts.append("\(recurringErrors.count) 处反复错（\(head(recurringErrors))）")
        }
        if !weakPhonemes.isEmpty {
            parts.append("\(weakPhonemes.count) 个顽固音素（\(head(weakPhonemes))）")
        }
        if !topics.isEmpty { parts.append("想练：\(topics.joined(separator: "、"))") }
        return parts.joined(separator: " · ")
    }

    /// 概括里最多列几项（列全了反而看不清重点）。
    private func head(_ values: [String]) -> String {
        let shown = values.prefix(3).joined(separator: "、")
        return values.count > 3 ? shown + " 等" : shown
    }
}

// MARK: - 排课规则（纯函数）

public enum CourseBlueprintRule {

    /// 一条课**最少**几节。
    ///
    /// 定在 2 是刻意的：只排 1 节的「课程」就是一次普通的情景练习，叫课是名不副实 ——
    /// 它还会占掉树上的一格、以「AI 排的课」的名义长期留在情景面板里。
    /// **少于这个数就整条作废**（宁可报错让用户重排，也不落一条看不出来是废物的课）。
    public static let minimumLessons = 2
    /// 一条课最多几节。再多，学员一看就放弃（与内置素材的句数同量级）。
    public static let maximumLessons = 6

    /// 喂给排课的反复错上限。
    ///
    /// 不设上限的话，练得越久这串越长，最后 Prompt 里全是错题、一节课都排不出来。
    /// 取 8：够说明「问题集中在哪里」，又不至于把指令淹掉。
    public static let maximumRecurringErrors = 8
    /// 顽固音素上限。
    public static let maximumWeakPhonemes = 6
    /// 用户自填主题上限。
    public static let maximumTopics = 3
    /// 单个主题的长度上限（超了就截 —— Prompt 不该被一段话撑爆）。
    public static let maximumTopicLength = 40

    /// 自定义课程的**分组名**。UI 只渲染这个字符串，不解释语义。
    ///
    /// 与 `ScenarioDraftRule.category`（「我的情景」）并列：情景面板按 `category` 分组，
    /// 于是「AI 排的课」自动就是一组，不必另立一套面板。
    public static let category = "AI 排的课"

    /// 课内情景的图标。
    ///
    /// 用 `map.fill`（一条路线）而与内置情景的对话气泡、一句话生成的 `sparkles` 区分开 ——
    /// 三者在卡片上一眼能认出是三种来源。
    public static let icon = "map.fill"

    /// 自填主题的示例（浮层里的「试试这些」）。
    ///
    /// 与 `ScenarioDraftRule.examples` 同一动机：用户最容易卡住的不是「怎么点」而是
    /// **「该写什么」**。而排课的输入是**主题**（比「一句话场景」短得多），所以给的都是短语。
    public static let examples: [String] = [
        "面试自我介绍",
        "在咖啡店点单",
        "跟房东谈维修",
    ]

    /// 每节课沿用 `ScenarioDraftRule` 的**同一把尺**（目标句下限 / 目标词上限 / 轮次上限）。
    ///
    /// 不在这里各定一套：一节课就是一次情景练习，标准不该有两个（改了上面那一处，
    /// 这里必须跟着变，所以是直接引用而不是抄一遍数字）。
    public static var minimumTargetSentences: Int { ScenarioDraftRule.minimumTargetSentences }
    public static var maximumTargetSentences: Int { ScenarioDraftRule.maximumTargetSentences }
    public static var maximumTargetVocabulary: Int { ScenarioDraftRule.maximumTargetVocabulary }
    public static var maxTurns: Int { ScenarioDraftRule.maxTurns }

    // MARK: - 输入清洗（纯函数）

    /// 清洗：逐项去空白 / 去结构符 / （主题还要）截断 / 去重，再截到各自上限。
    public static func sanitized(_ request: CourseRequest) -> CourseRequest {
        CourseRequest(
            level: request.level,
            recurringErrors: cleaned(request.recurringErrors, limit: maximumRecurringErrors),
            weakPhonemes: cleaned(request.weakPhonemes, limit: maximumWeakPhonemes),
            // 主题是用户自己敲的，长度不可控（另两项来自库，本来就短）。
            topics: cleaned(request.topics, limit: maximumTopics, transform: truncated(_:))
        )
    }

    public enum InputIssue: Equatable {
        /// 一条信号都没有：没定位、没错题、没顽固音素、也没写主题 —— 没有排课依据。
        case nothingToSchedule

        public var message: String {
            switch self {
            case .nothingToSchedule:
                "还没有可排课的依据：先练几局，或者写一个想练的主题"
            }
        }
    }

    /// 输入问题（nil = 可以拿去排课）。
    public static func inputIssue(for request: CourseRequest) -> InputIssue? {
        request.hasSignal ? nil : .nothingToSchedule
    }

    /// 逐项清洗：去首尾空白、把换行与 `|` 压成空格（`|` 是 Prompt 的字段分隔符，
    /// 留着它等于让用户输入注入结构）、把连续空白压成一个空格、按小写去重、截到 `limit` 项。
    ///
    /// ⚠️ `transform`（截断）必须发生在**去重之前**：两条只差尾巴的主题截完会变成同一个串，
    /// 顺序反了它们会双双留下 —— Prompt 里同一条指令说两遍。
    static func cleaned(
        _ values: [String],
        limit: Int,
        transform: (String) -> String = { $0 }
    ) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard result.count < limit else { break }
            // 把 `|` 换成空格后再按「空白段」切分重拼：一趟同时完成
            // 「压平换行 / 去掉结构符 / 收敛连续空白 / 去首尾空白」。
            let flattened = value
                .replacingOccurrences(of: "|", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            let text = transform(flattened).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            result.append(text)
        }
        return result
    }

    /// 截到 `maximumTopicLength` 个字符。
    static func truncated(_ text: String) -> String {
        text.count <= maximumTopicLength ? text : String(text.prefix(maximumTopicLength))
    }

    // MARK: - 稳定 id（纯函数）

    /// 同一次状态重复排课 = **同一条课 id**：重排是覆盖，不是在树上堆积。
    ///
    /// 与 `ScenarioDraftRule.stableID` 同一条纪律。想让模型换一套排法时，用户的动作是
    /// **改主题**（或状态本身变了）—— 那天然就是另一条课。
    public static func stableID(request: CourseRequest) -> String {
        StableFingerprint.hex(prefix: "course", of: signature(of: sanitized(request)))
    }

    /// 指纹原文：四项按固定顺序拼，空项用 `-` 占位（否则「只有主题」和「只有档位」
    /// 可能拼成同一个串）。
    static func signature(of request: CourseRequest) -> String {
        [
            request.level?.rawValue ?? "-",
            request.recurringErrors.joined(separator: ";"),
            request.weakPhonemes.joined(separator: ";"),
            request.topics.joined(separator: ";"),
        ].joined(separator: "|")
    }

    /// 一节课的 id（同时是 `scenario.id`）：`course-lesson-<8位hex>`。
    ///
    /// 由「课 id + 序号 + 标题」推出：同一条课重排时**同一节课还是同一个 id** ——
    /// 树上那一格、已经攒的星、已完成的进度都接得上；换了一节课则自动换一格。
    public static func lessonID(courseID: String, order: Int, title: String) -> String {
        StableFingerprint.hex(prefix: "course-lesson", of: "\(courseID)|\(order)|\(title)")
    }

    /// 去掉标题开头自报的编号：`1. 点单开场` → `点单开场`。
    ///
    /// ⚠️ 只在「数字 + 明确的分隔符」时才剥：`7 天入门口语` 这种真以数字开头的标题
    /// 不能被削掉。编号本身不采信（序号由解析顺序决定），留着它只会让树上多出一串 `.1.`
    /// 而且**破坏节 id 的稳定性**（换个编号方式就换一格）。
    static func strippingIndexPrefix(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let digits = text.prefix { $0.isNumber }.count
        guard digits > 0, digits < text.count else { return text }
        let rest = text.dropFirst(digits)
        guard let separator = rest.first, ".)、,，:：-－".contains(separator) else { return text }
        return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 难度与档位（纯函数）

    /// 档位 → 期望难度区间。
    ///
    /// ⚠️ 与 `ScenarioDraftRule.cefrBand`（难度 → 档位字符串）是**一对反向映射**，
    /// 两处必须一起改：对不上时学员会看到「A2 的课，练起来按 B2 的标准判」。
    public static func difficultyBand(for level: CEFRLevel) -> ClosedRange<Int> {
        switch level {
        case .a1: 1...2
        case .a2: 2...3
        case .b1: 3...4
        case .b2: 4...5
        }
    }

    /// 把模型给的难度**夹进学员档位**对应的区间。
    ///
    /// 排课的全部意义就是「按你的水平排」：给 B2 学员排一节 A1 难度的课，这条课就白排了 ——
    /// 而模型偶尔会一律给 3（`scenario_draft.txt` 里专门提醒过别这么干）。
    /// 没定位出档位时不夹（只保证落在 1...5）。
    public static func clampedDifficulty(_ raw: Int, for level: CEFRLevel?) -> Int {
        guard let level else { return min(max(raw, 1), 5) }
        let band = difficultyBand(for: level)
        return min(max(raw, band.lowerBound), band.upperBound)
    }

    /// 一节课的 CEFR 档位字符串。
    ///
    /// ⚠️ **档位已知时用学员自己的档位**，不用 `cefrBand(难度)` 反推 ——
    /// 难度只有 5 档、映射很粗（B1 学员拿到难度 4 会被反推成 `B1-B2`，而 `primaryLevel`
    /// 取区间低档 → 变成 B1；拿到难度 3 就退成 A2 的标准了）。排课的前提是「就按你的档练」，
    /// 每节课都必须拿学员的档位判定，否则同一节课的门槛会随模型的随手一填而漂。
    /// 难度只管展示（圆点）与课内由易到难的排序。
    public static func levelString(for difficulty: Int, learnerLevel: CEFRLevel?) -> String {
        learnerLevel?.code ?? ScenarioDraftRule.cefrBand(for: difficulty)
    }

    // MARK: - 解析（与 `Prompts/course_blueprint.txt` 是一对，改一处必须改另一处）

    /// 模型输出 → 一条课。
    ///
    /// 逐行读，`lesson:` 开一节（同 `scenario_draft.txt` 的 `title:` 之于一个情景）。
    /// 每节沿用那个模板的 `scene:` / `sentence:` / `vocabulary:` / `quest:` 四把键 ——
    /// **同一套键在两个地方含义相同**，模型不必学两套语法，解析器也不必写两份。
    ///
    /// 校验分两层，界线是**「缺了它还能不能判定练习结果」**：
    /// - 缺 `lesson` 标题 / `scene`（AI 角色 + 开场白）/ 目标句不足两句 → **这一节作废**；
    /// - 作废后不足 `minimumLessons` 节 → **整条作废**，返回 nil，由调用方报错让用户重排。
    ///   宁可让用户再来一次，也不落一份「练到一半发现没法判定」的半成品 ——
    ///   它会以「AI 排的课」的名义长期留在面板上、还占着树上的一格，比一次失败难收拾得多。
    /// - 反过来，缺课名 / 缺 `focus` 这类**展示用**的顶层标签只做兜底，不作废：
    ///   为一行标签丢掉整次生成不划算。
    public static func parse(
        _ raw: String,
        request: CourseRequest,
        createdAt: Date = Date()
    ) -> CourseBlueprint? {
        let cleaned = sanitized(request)
        let courseID = stableID(request: request)

        var courseTitle = ""
        var courseTitleZh = ""
        var focus = ""
        var builders: [LessonBuilder] = []

        let lines = raw
            .replacingOccurrences(of: "```", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let key = KeyValueLine.normalizedKey(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            let fields = KeyValueLine.fields(value)

            switch key {
            case "course", "title", "标题", "课程", "课程标题":
                // `title:` 在开课之前是课名、开课之后是这一节的名字 ——
                // 模型两种写法都会出现，按「当前有没有开着的节」判，不猜。
                let titled = fields.titleFields
                if builders.isEmpty {
                    courseTitle = titled.first ?? ""
                    if titled.count > 1 { courseTitleZh = titled[1] }
                } else {
                    builders[builders.count - 1].title = titled.first ?? ""
                    if titled.count > 1 { builders[builders.count - 1].titleZh = titled[1] }
                }

            case "focus", "重点", "排课依据":
                if focus.isEmpty { focus = fields.first ?? "" }

            case "lesson", "课时", "课", "第":
                builders.append(LessonBuilder(title: fields.titleFields.first ?? ""))

            case "scene", "scenario", "情景", "场景", "场景设定":
                guard !builders.isEmpty else { break }
                // 子字段自带标签的情况很常见（`AI Role: barista | Learner Role: customer`），
                // 统一剥一层 —— 与 `ScenarioDraftRule.parse` 同一把尺。
                let parts = fields.map(KeyValueLine.stripLabel)
                builders[builders.count - 1].applyScene(parts)

            case "quest", "mainquest", "主线", "任务", "主线任务":
                guard !builders.isEmpty, builders[builders.count - 1].mainQuest.isEmpty else { break }
                builders[builders.count - 1].mainQuest = fields.first ?? ""

            case "sentence", "sentences", "目标句", "句子":
                guard !builders.isEmpty,
                      let sentence = fields.first, !sentence.isEmpty,
                      builders[builders.count - 1].sentences.count < maximumTargetSentences
                else { break }
                builders[builders.count - 1].sentences.append(sentence)

            case "vocabulary", "word", "words", "生词", "单词", "目标词":
                guard !builders.isEmpty,
                      let word = fields.first, !word.isEmpty,
                      builders[builders.count - 1].words.count < maximumTargetVocabulary
                else { break }
                builders[builders.count - 1].words.append(MaterialWord(
                    word: word,
                    partOfSpeech: fields.count > 1 ? fields[1] : "",
                    meaning: fields.count > 2 ? fields[2] : "",
                    example: fields.count > 3 ? fields[3] : ""
                ))

            default:
                break
            }
        }

        // 坏节跳过。
        let valid = builders.filter(\.isValid)
        // 保底不足 → 整条作废（宁可让用户重排，也不落一条废物）。
        guard valid.count >= minimumLessons else { return nil }
        // ⚠️ 上限在这里才截，不在收集时截：先截的话，开头一节写坏就会白白吃掉末尾一节的名额。
        // ⚠️ 序号按**留下来的那几节**连续重排（不是原始位置），否则中间坏一节会让树上出现空号；
        // 节 id 由序号推出，所以必须先定序号再建节 —— 反了就会得到「序号 2 但 id 写着 3」的节。
        let capped = valid.prefix(maximumLessons).enumerated().map { offset, builder in
            builder.makeLesson(courseID: courseID, order: offset + 1, learnerLevel: cleaned.level)
        }

        // 课名缺了只做兜底、不作废（展示用的顶层标签）。
        let base = capped[0]
        let resolvedTitle = courseTitle.isEmpty ? base.title : courseTitle
        let resolvedTitleZh = courseTitleZh.isEmpty
            ? (courseTitle.isEmpty ? base.displayTitle : courseTitle)
            : courseTitleZh

        return CourseBlueprint(
            id: courseID,
            title: resolvedTitle,
            titleZh: resolvedTitleZh,
            focus: focus.isEmpty ? cleaned.stateSummary : focus,
            targetLevel: cleaned.level,
            rationale: cleaned.stateSummary,
            createdAt: createdAt,
            lessons: capped
        )
    }

    /// 一节课在解析过程中的临时收集器（键值行是流式的，先攒后建）。
    ///
    /// 单独一个类型而不是就地用一堆元组：`scene:` 一行要拆出 5 个字段，
    /// 摊在循环里会让「哪一行填了哪个字段」看不出来。
    private struct LessonBuilder {
        var title: String
        var titleZh = ""
        var aiRole = ""
        var learnerRole = ""
        var goal = ""
        var difficulty = 3
        var opening = ""
        var mainQuest = ""
        var sentences: [String] = []
        var words: [MaterialWord] = []

        /// `scene: AI 角色 | 学员角色 | 学习目标 | 难度1-5 | 开场白`。
        mutating func applyScene(_ parts: [String]) {
            aiRole = parts.count > 0 ? parts[0] : ""
            learnerRole = parts.count > 1 ? parts[1] : ""
            goal = parts.count > 2 ? parts[2] : ""
            if parts.count > 3, let parsed = Int(parts[3]), (1...5).contains(parsed) {
                difficulty = parsed
            }
            opening = parts.count > 4 ? parts[4] : ""
        }

        /// 这一节够不够格留下。
        ///
        /// 判据是「缺了它还能不能**判定练习结果**」：没有标题就没法在树上标出这一格、
        /// 没法当卡片标题；没有 AI 角色 / 开场白，老师不知道演谁、也没第一句话；
        /// 目标句不足两句，练完没法逐句核对说没说到。
        /// 反过来，难度乱填、目标词为空、主线缺失都**不作废** —— 那些有兜底或可推导。
        var isValid: Bool {
            !title.isEmpty
                && !aiRole.isEmpty
                && !opening.isEmpty
                && sentences.count >= CourseBlueprintRule.minimumTargetSentences
        }

        /// 建一节（`order` 由调用方按留下来的顺序给，见 `parse` 里的说明）。
        func makeLesson(courseID: String, order: Int, learnerLevel: CEFRLevel?) -> CourseLesson {
            let difficulty = CourseBlueprintRule.clampedDifficulty(difficulty, for: learnerLevel)
            let level = CourseBlueprintRule.levelString(for: difficulty, learnerLevel: learnerLevel)
            let id = CourseBlueprintRule.lessonID(courseID: courseID, order: order, title: title)
            let resolvedTitleZh = titleZh.isEmpty ? title : titleZh

            let scenario = Scenario(
                id: id,
                title: title,
                titleZh: resolvedTitleZh,
                category: CourseBlueprintRule.category,
                difficulty: difficulty,
                level: level,
                objective: goal.isEmpty ? mainQuest : goal,
                aiRole: aiRole,
                learnerRole: learnerRole.isEmpty ? "yourself" : learnerRole,
                opening: opening,
                targetVocabulary: words.map(\.word),
                targetGrammar: [],
                targetSentences: sentences,
                // 留空 → `ScenarioQuestRule.plan` 从目标句自动切主线步骤（带 anchors）。
                // 不在这里另生成一份步骤：那是同一件事的第二份真相。
                mainQuest: mainQuest,
                questSteps: [],
                maxTurns: CourseBlueprintRule.maxTurns,
                correctionMode: .balanced,
                icon: CourseBlueprintRule.icon,
                origin: .course
            )

            return CourseLesson(
                id: id,
                order: order,
                title: title,
                titleZh: resolvedTitleZh,
                goal: goal,
                scenario: scenario,
                words: words
            )
        }
    }
}

private extension Array where Element == String {

    /// 标题字段：先丢掉「纯数字的独立字段」（`lesson: 1 | 点单开场`），
    /// 再剥掉标题开头自带的编号（`lesson: 1. 点单开场`）。模型的两种写法都见过。
    var titleFields: [String] {
        var parts: [String] = (count > 1 && Int(self[0]) != nil) ? Array(dropFirst()) : self
        guard let head = parts.first else { return parts }
        parts[0] = CourseBlueprintRule.strippingIndexPrefix(head)
        return parts
    }
}

// MARK: - 落盘单元

/// 一节课（= 一个 `Scenario` + 它的目标词表）。
public struct CourseLesson: Codable, Sendable, Equatable, Identifiable {

    /// `course-lesson-<8位hex>`，同时是 `scenario.id` —— 这一节能按 id 被查回来。
    public let id: String
    /// 在这条课里的序号（1 起）。
    public var order: Int
    /// 学习语言标题。
    public var title: String
    /// 母语标题（UI 主标题）。
    public var titleZh: String
    /// 这一节练成什么（学习语言）。
    public var goal: String
    /// 与内置情景同构 —— 直接进现有练习链路。
    public var scenario: Scenario
    /// 目标词表（词性 / 释义 / 例句）：自动进词汇本，也就顺带进了每日推荐词源。
    public var words: [MaterialWord]

    public init(
        id: String,
        order: Int,
        title: String,
        titleZh: String,
        goal: String,
        scenario: Scenario,
        words: [MaterialWord] = []
    ) {
        self.id = id
        self.order = max(order, 1)
        self.title = title
        self.titleZh = titleZh
        self.goal = goal
        self.scenario = scenario
        self.words = words
    }

    /// UI 主标题（母语优先）。
    public var displayTitle: String { titleZh.isEmpty ? title : titleZh }

    /// 「第 3 节」。
    public var orderText: String { "第 \(order) 节" }
}

/// 一条 AI 排出来的课（= 一个 JSON 文件，形状对齐 `ScenarioDraft`）。
public struct CourseBlueprint: Codable, Sendable, Equatable, Identifiable {

    /// `course-<8位hex>`（由排课依据推出）。
    public let id: String
    /// 课名（学习语言）。
    public var title: String
    /// 课名（母语）。
    public var titleZh: String
    /// 这条课盯什么（母语；模型没给时兜底为 `rationale`）。
    public var focus: String
    /// 排课时的目标档（nil = 当时还没定位出来）。
    public var targetLevel: CEFRLevel?
    /// 排课依据（`CourseRequest.stateSummary` 原样留底）。
    ///
    /// 单独留一份而不是只靠 `focus`：`focus` 是**模型写的**「这条课盯什么」，
    /// `rationale` 是**学员状态**（「照着什么排的」）。卡片上要回答的是后一个问题。
    public var rationale: String
    /// 排课时间（展示用，不参与逻辑）。
    public var createdAt: Date
    /// 有序的几节（`order` 从 1 连续）。
    public var lessons: [CourseLesson]

    public init(
        id: String,
        title: String,
        titleZh: String,
        focus: String,
        targetLevel: CEFRLevel?,
        rationale: String,
        createdAt: Date = Date(),
        lessons: [CourseLesson]
    ) {
        self.id = id
        self.title = title
        self.titleZh = titleZh
        self.focus = focus
        self.targetLevel = targetLevel
        self.rationale = rationale
        self.createdAt = createdAt
        self.lessons = lessons
    }

    /// UI 主标题（母语优先）。
    public var displayTitle: String { titleZh.isEmpty ? title : titleZh }

    public var lessonCount: Int { lessons.count }

    /// 这条课的全部情景（按课内顺序）—— 面板与大树都从这里取。
    public var scenarios: [Scenario] { lessons.map(\.scenario) }

    /// 这节课在这条课里的下一节（最后一节为 nil）。
    ///
    /// 排课的意义就在「有序」：学员练完一节自然要知道下一节是哪节。
    public func nextLesson(after lessonID: String) -> CourseLesson? {
        guard let index = lessons.firstIndex(where: { $0.id == lessonID }) else { return nil }
        let next = index + 1
        return next < lessons.count ? lessons[next] : nil
    }

    /// 「6 节课 · B1」。
    public var summary: String {
        targetLevel.map { "\(lessonCount) 节课 · \($0.code)" } ?? "\(lessonCount) 节课"
    }
}
