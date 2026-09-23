import Foundation

// MARK: - 情景动态生成（一句话 → 一个能反复练、且自带题目的情景）
//
// 现状：情景是 `Resources/Scenarios/*.json` 里写死的 10 个，练完就没有了 ——
// 「数据驱动、不硬编码」早做到了，缺的是**运行时新增**。
//
// 本文件把「一句话描述」变成与内置情景**完全同构**的 `Scenario`，并额外带上目标词表
// （拿去收进词汇本）。「自动出题」就是这里的产物本身：
// 目标句进 `targetSentences`、主线步骤由 `ScenarioQuestRule.plan` 从目标句派生
// （不另存一份步骤，免得两份真相迟早对不上）、目标词顺带进词汇本与每日推荐。
//
// 硬边界：不碰模型、不碰 IO —— 只做输入校验与输出解析，纯函数、可单测。

/// 一句话生成情景：输入校验 + 模型输出解析。
public enum ScenarioDraftRule {

    /// 描述下限：再短（「练口语」）模型只能瞎编，生成出来也不是你要的。
    public static let minimumLength = 4
    /// 描述上限：超过它就不是「一句话」了，纯属白烧 token。
    public static let maximumLength = 200
    /// 目标句**下限**：少于两句就不叫「自动出题」—— 练完没法逐句核对说没说到。
    public static let minimumTargetSentences = 2
    /// 目标句上限（与内置素材的 4–6 句同量级）。
    public static let maximumTargetSentences = 6
    /// 目标词上限。
    public static let maximumTargetVocabulary = 10
    /// 期望轮次上限（与内置情景的中位数量级一致）。
    public static let maxTurns = 10

    /// 自定义情景的分组名。UI 只渲染这个字符串，不解释语义。
    public static let category = "我的情景"

    /// 输入示例（浮层里的「试试这些」）。
    ///
    /// 用户最容易卡住的不是「怎么点」而是**「该怎么说」** —— 给三个不同类型的样板
    /// （消费场景 / 沟通求助 / 职场），比一句冷冰冰的「请输入描述」有用得多。
    ///
    /// 放在领域层而不是 View 里：它们是**输入的样例**，不是场景数据本身
    /// （内置场景数据那条铁律管的是「场景从 Resources/Scenarios 读」，这里不受它管，
    /// 但同样不该散落在 View 里）。
    public static let examples: [String] = [
        "在咖啡店点一杯拿铁，想换成燕麦奶",
        "跟房东说明厨房水管漏水，约时间上门修",
        "面试开场做自我介绍，说说上一份工作",
    ]

    // MARK: - 输入校验（纯函数）

    public enum InputIssue: Equatable {
        case empty
        case tooShort(actual: Int)
        case tooLong(actual: Int)
    }

    /// 清洗输入：统一换行、去首尾空白（内部换行保留 —— 用户可能写两三行补充说明）。
    public static func sanitized(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 输入问题（nil = 可以拿去生成）。
    public static func inputIssue(for raw: String) -> InputIssue? {
        let text = sanitized(raw)
        if text.isEmpty { return .empty }
        if text.count < minimumLength { return .tooShort(actual: text.count) }
        if text.count > maximumLength { return .tooLong(actual: text.count) }
        return nil
    }

    // MARK: - 稳定 id（纯函数）

    /// 同一个描述重复生成 = **同一个 id**：重生成是覆盖，不是在「我的情景」里堆积。
    public static func stableID(prompt: String) -> String {
        StableFingerprint.hex(prefix: "custom-scenario", of: sanitized(prompt))
    }

    // MARK: - 解析（与 `Prompts/scenario_draft.txt` 是一对，改一处必须改另一处）

    /// 模型输出 → 草稿。
    ///
    /// 缺 `title` / `scene`（AI 角色 + 开场白）/ 目标句不足两句 → **返回 nil**，
    /// 由调用方报错让用户重试。宁可让用户再来一次，也不落一份「练到一半发现没法判定」的
    /// 半成品 —— 它会以「我的情景」的名义长期留在列表里，比一次失败难收拾得多。
    public static func parse(_ raw: String, prompt: String) -> ScenarioDraft? {
        var title = ""
        var titleZh = ""
        var aiRole = ""
        var learnerRole = ""
        var objective = ""
        var difficulty = 3
        var opening = ""
        var mainQuest = ""
        var targets: [String] = []
        var words: [MaterialWord] = []

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
            case "title", "标题":
                title = fields.first ?? ""
                if fields.count > 1 { titleZh = fields[1] }

            case "scene", "scenario", "情景", "场景", "场景设定":
                // 子字段自带标签的情况很常见（`AI Role: barista | Learner Role: customer`），
                // 统一剥一层 —— 与材料出题同一把尺。
                let cleaned = fields.map(KeyValueLine.stripLabel)
                aiRole = cleaned.count > 0 ? cleaned[0] : ""
                learnerRole = cleaned.count > 1 ? cleaned[1] : ""
                objective = cleaned.count > 2 ? cleaned[2] : ""
                if cleaned.count > 3, let parsed = Int(cleaned[3]), (1...5).contains(parsed) {
                    difficulty = parsed
                }
                opening = cleaned.count > 4 ? cleaned[4] : ""

            case "quest", "mainquest", "主线", "任务", "主线任务":
                if mainQuest.isEmpty { mainQuest = fields.first ?? "" }

            case "sentence", "sentences", "目标句", "句子":
                guard let sentence = fields.first, !sentence.isEmpty,
                      targets.count < maximumTargetSentences else { break }
                targets.append(sentence)

            case "vocabulary", "word", "words", "生词", "单词", "目标词":
                guard let word = fields.first, !word.isEmpty,
                      words.count < maximumTargetVocabulary else { break }
                words.append(MaterialWord(
                    word: word,
                    partOfSpeech: fields.count > 1 ? fields[1] : "",
                    meaning: fields.count > 2 ? fields[2] : "",
                    example: fields.count > 3 ? fields[3] : ""
                ))

            default:
                break
            }
        }

        guard !title.isEmpty,
              !aiRole.isEmpty,
              !opening.isEmpty,
              targets.count >= minimumTargetSentences
        else { return nil }

        let id = stableID(prompt: prompt)
        let scenario = Scenario(
            id: id,
            title: title,
            titleZh: titleZh.isEmpty ? title : titleZh,
            category: category,
            difficulty: difficulty,
            level: cefrBand(for: difficulty),
            objective: objective.isEmpty ? mainQuest : objective,
            aiRole: aiRole,
            learnerRole: learnerRole.isEmpty ? "yourself" : learnerRole,
            opening: opening,
            targetVocabulary: words.map(\.word),
            targetGrammar: [],
            targetSentences: targets,
            // 留空 → `ScenarioQuestRule.plan` 从目标句自动切主线步骤（带 anchors）。
            // 不在这里另生成一份步骤：那是同一件事的第二份真相。
            mainQuest: mainQuest,
            questSteps: [],
            maxTurns: maxTurns,
            correctionMode: .balanced,
            icon: "sparkles",
            origin: .custom
        )
        return ScenarioDraft(
            id: id,
            prompt: sanitized(prompt),
            scenario: scenario,
            words: words
        )
    }

    /// 难度 → CEFR 区间。
    ///
    /// 生成的场景没人手标档位，按难度推一个：`primaryLevel` 从 `level` 解析，
    /// 而**过关标准按主档位走** —— 标宽了门槛就失真。
    public static func cefrBand(for difficulty: Int) -> String {
        switch difficulty {
        case ..<3: "A1-A2"
        case 3: "A2-B1"
        case 4: "B1-B2"
        default: "B2-C1"
        }
    }
}

// MARK: - 落盘单元

/// 一句话生成的一份情景草稿（= 一个 JSON 文件）。
///
/// 与 `MaterialKit` 同构：id 稳定（同一句话重复生成是覆盖）、带上生词表、
/// 一份草稿对应「我的情景」里的一张卡片。
public struct ScenarioDraft: Codable, Sendable, Equatable, Identifiable {

    /// `custom-scenario-<8位hex>`，同时是 `scenario.id` —— 场景能按 id 被查回来。
    public let id: String
    /// 用户当初那句话（卡片上回显「你要练的是什么」，也是重生成去重的依据）。
    public var prompt: String
    /// 生成时间（展示用，不参与逻辑）。
    public var createdAt: Date
    /// 生成好的情景（与内置情景同构，直接进练习链路）。
    public var scenario: Scenario
    /// 目标词表（词性 / 释义 / 例句）：自动收进词汇本，也就顺带进了每日推荐词源。
    public var words: [MaterialWord]

    public init(
        id: String,
        prompt: String,
        createdAt: Date = Date(),
        scenario: Scenario,
        words: [MaterialWord] = []
    ) {
        self.id = id
        self.prompt = prompt
        self.createdAt = createdAt
        self.scenario = scenario
        self.words = words
    }
}
