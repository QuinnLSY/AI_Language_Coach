import Foundation

// MARK: - 上传材料自动出题（材料 → 情景 + 跟读句 + 生词表）
//
// 设计依据：第三梯队 #208。学员手里最常见的素材是一篇课文 / 一篇文章，
// 但要把「读懂」变成「练过」，得有人把它拆成三样东西：
//   ① 一个情景对话（拿去跟老师练）
//   ② 一批跟读句（拿去跟读页逐句磨嘴）
//   ③ 一张生词表（拿去词汇本复习）
// 本体只定义「拆出来的结果长什么样」与「怎么拆」，不碰模型、不碰 IO。

/// 材料里拆出来的一个生词。
public struct MaterialWord: Codable, Sendable, Equatable, Identifiable {

    /// 单词（原型）。
    public var word: String
    /// 词性缩写（n. / v. / adj. …），可为空。
    public var partOfSpeech: String
    /// 母语释义。
    public var meaning: String
    /// 材料语境里的例句（学习语言）。可为空。
    public var example: String

    public var id: String { word }

    public init(word: String, partOfSpeech: String = "", meaning: String = "", example: String = "") {
        self.word = word
        self.partOfSpeech = partOfSpeech
        self.meaning = meaning
        self.example = example
    }
}

/// 一份材料拆出来的整套练习（也是落盘单元，一份材料一个 JSON）。
public struct MaterialKit: Codable, Sendable, Equatable, Identifiable {

    /// 稳定标识（`material-<8位指纹>`）。同一份材料重复生成是**同一个 id**：
    /// 重生成 = 覆盖旧结果，而不是在「我的材料」里无限堆积。
    public let id: String
    /// 材料标题（学习语言；生成不出时用文件名 / 首行）。
    public var title: String
    /// 生成时间（展示用，不参与逻辑）。
    public var createdAt: Date
    /// 材料原文的前几百字（卡片上给学员确认「这是哪份材料」）。
    public var excerpt: String
    /// 拆出来的情景（解析失败时为 nil —— 情景拆不出来，另两样也没法跟练）。
    public var scenario: Scenario?
    /// 生词表（可能为空：材料太简单时模型可以不给）。
    public var words: [MaterialWord]
    /// 跟读句。
    public var drills: [ShadowingDrill]

    public init(
        id: String,
        title: String,
        createdAt: Date = Date(),
        excerpt: String = "",
        scenario: Scenario?,
        words: [MaterialWord],
        drills: [ShadowingDrill]
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.excerpt = excerpt
        self.scenario = scenario
        self.words = words
        self.drills = drills
    }
}

public enum MaterialKitRule {

    /// 输入下限：比这更短的文字撑不起「一个情景 + 一批句子」。
    public static let minimumLength = 60
    /// 输入上限：再长模型也读不完整篇，超出部分截掉（提示用户已截断）。
    public static let maximumLength = 20_000
    /// 生词表上限（材料出题不是背整本词典）。
    public static let maxWords = 15
    /// 跟读句上限。
    public static let maxDrills = 12

    // MARK: 输入校验（纯函数）

    /// 清洗后的输入：压掉多余空白、截到上限。
    public static func sanitized(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maximumLength else { return collapsed }
        return String(collapsed.prefix(maximumLength))
    }

    /// 输入问题（nil = 可以拿去生成）。
    public enum InputIssue: Equatable {
        case empty
        case tooShort(actual: Int)
    }

    public static func inputIssue(for raw: String) -> InputIssue? {
        let text = sanitized(raw)
        if text.isEmpty { return .empty }
        if text.count < minimumLength { return .tooShort(actual: text.count) }
        return nil
    }

    // MARK: 稳定 id（纯函数）

    /// 材料指纹：FNV-1a（跨进程稳定 —— `Hasher` 是每进程随机种子的，绝不能用它生成持久 id）。
    /// 指纹取「标题 + 原文前 2000 字」：同一份材料重复生成同一个 id；改了内容才算新材料。
    ///
    /// 实现搬到 `StableFingerprint`（情景生成也要用同一套）：这里只负责**取哪几个字**
    /// 参与指纹 —— 那个决定材料身份的取舍留在本类型里。
    public static func stableID(title: String, text: String) -> String {
        StableFingerprint.hex(prefix: "material", of: title + "\u{1}" + String(text.prefix(2000)))
    }

    // MARK: 模型输出解析（与 material_kit.txt 模板是一对，改一处必须改另一处）

    /// `title` 子字段：学习语言标题 | 母语标题。
    /// `scenario` 子字段：AI 角色 | 学员角色 | 学习目标 | 难度(1-5) | 老师开场白。
    /// 缺 `title` 或 `scenario` 行 → 整份解析失败（返回 nil，由调用方报错重试）；
    /// 其余单行坏了只丢那一行。
    ///
    /// 对真实模型输出的**容错**（实测会犯的错，全都要接得住）：
    /// - 键别名：`AI Role:` / `角色:` 等也算 scenario 行；子字段里自带的
    ///   `Learner Role:` / `Goal:` 标签要剥掉。
    /// - 整份漏键：一行键都不写时按字段数猜类型 —— 首个 2–3 字段行当标题、
    ///   4 字段行当生词、5 字段以上行当情景、其余 2–3 字段行当跟读句。
    public static func parse(
        _ raw: String,
        text: String,
        now: Date = Date()
    ) -> MaterialKit? {
        var title = ""
        var titleZh = ""
        var aiRole = ""
        var learnerRole = ""
        var objective = ""
        var difficulty = 3
        var opening = ""
        var words: [MaterialWord] = []
        var drills: [ShadowingDrill] = []
        // 是否已经出现过认识键的行：漏键行只在「开头、且没有任何内容」时才有资格当标题。
        var sawKnownKey = false

        // 情景字段统一入口（带键与漏键的行都走这里，保证难度尺与标签清洗一致）。
        func applyScenario(_ rawFields: [String]) {
            let fields = rawFields.map(stripEmbeddedLabel)
            aiRole = fields.count > 0 ? fields[0] : ""
            learnerRole = fields.count > 1 ? fields[1] : ""
            objective = fields.count > 2 ? fields[2] : ""
            if fields.count > 3, let parsed = Int(fields[3]), (1...5).contains(parsed) {
                difficulty = parsed
            }
            opening = fields.count > 4 ? fields[4] : ""
        }
        func appendWord(_ fields: [String]) {
            guard let word = fields.first, !word.isEmpty, words.count < maxWords else { return }
            words.append(MaterialWord(
                word: word,
                partOfSpeech: fields.count > 1 ? fields[1] : "",
                meaning: fields.count > 2 ? fields[2] : "",
                example: fields.count > 3 ? fields[3] : ""
            ))
        }
        func appendDrill(_ fields: [String]) {
            guard let text0 = fields.first, !text0.isEmpty, drills.count < maxDrills else { return }
            drills.append(ShadowingDrill(
                id: "mk-\(drills.count)",
                text: text0,
                translation: fields.count > 1 ? fields[1] : "",
                topic: "",
                difficulty: difficulty,
                focus: fields.count > 2 ? fields[2] : ""
            ))
        }

        let lines = raw
            .replacingOccurrences(of: "```", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
                // 漏键行兜底：真实模型（实测 agnes）会整份不写键名，按字段数猜类型。
                let fields = splitFields(line)
                switch fields.count {
                case 2...3:
                    if title.isEmpty, !sawKnownKey, words.isEmpty, drills.isEmpty,
                       fields[0].count <= 80 {
                        title = fields[0]
                        if fields.count > 1 { titleZh = fields[1] }
                    } else {
                        appendDrill(fields)
                    }
                case 4:
                    appendWord(fields)
                case 5...:
                    if aiRole.isEmpty {
                        applyScenario(fields)
                    } else if drills.count < maxDrills {
                        appendDrill(Array(fields.prefix(3)))
                    }
                default:
                    break
                }
                continue
            }
            let key = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            let fields = splitFields(value)

            switch key {
            case "title", "材料标题", "标题":
                sawKnownKey = true
                if let first = fields.first { title = first }
                if fields.count > 1 { titleZh = fields[1] }
            case "scenario", "情景", "场景", "airole", "角色", "场景设定":
                sawKnownKey = true
                applyScenario(fields)
            case "vocabulary", "word", "words", "生词", "单词", "生词表":
                sawKnownKey = true
                appendWord(fields)
            case "sentence", "sentences", "drill", "drills", "跟读句", "句子", "跟读":
                sawKnownKey = true
                appendDrill(fields)
            default:
                break
            }
        }

        guard !title.isEmpty, !aiRole.isEmpty, !opening.isEmpty, !drills.isEmpty else { return nil }

        let id = stableID(title: title, text: text)
        let scenario = Scenario(
            id: id,
            title: title,
            titleZh: titleZh.isEmpty ? title : titleZh,
            category: "我的材料",
            difficulty: difficulty,
            level: "A2-B1",
            objective: objective.isEmpty ? "Practice talking about: \(title)" : objective,
            aiRole: aiRole,
            learnerRole: learnerRole.isEmpty ? "yourself" : learnerRole,
            opening: opening,
            targetVocabulary: words.map(\.word),
            targetGrammar: [],
            // 目标句就是跟读句：练完一局能逐句核对「哪几句真的说出来了」。
            targetSentences: Array(drills.prefix(6).map(\.text)),
            mainQuest: "",
            maxTurns: 10,
            correctionMode: .balanced,
            icon: "doc.text.fill"
        )

        return MaterialKit(
            id: id,
            title: title,
            createdAt: now,
            excerpt: String(sanitized(text).prefix(160)),
            scenario: scenario,
            words: words,
            drills: drills
        )
    }

    /// 按 `|` 切子字段：去首尾空白、丢空段（词典 / 跟读同一把尺）。
    /// 实现见 `KeyValueLine.fields` —— 情景生成走的是同一把尺，别在这里另写一份。
    private static func splitFields(_ value: String) -> [String] {
        KeyValueLine.fields(value)
    }

    /// 剥掉模型在子字段里自带的标签（实测会写 `Learner Role: xxx`、`Goal: xxx`）。
    /// 实现见 `KeyValueLine.stripLabel`。
    private static func stripEmbeddedLabel(_ field: String) -> String {
        KeyValueLine.stripLabel(field)
    }
}
