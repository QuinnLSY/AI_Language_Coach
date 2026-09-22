import Foundation

// MARK: - 入学定级（placement test，进阶 ⑤）
//
// 「我该从哪一档开始」——这件事课程进度答不了（第 0 天没有任何进度），
// `PlacementEstimator`（能力定位）也答不了（它要 25 轮对话 + 3 天 + 20 个词才肯开口）。
// 新用户打开应用面对的第一件事恰恰就是它：一上来练 A1 太浅、练 B2 太深，
// 都会让人以为「这东西不适合我」。所以要有一次**十分钟以内的摸底**。
//
// 三条口径（纯函数，可脱机单测）：
//
// 1. **离线出卷、零请求**。题库随包发布（`Resources/Placement/questions.json`），
//    4 档 × 5 题，每档抽 3 题（`seed` 决定抽哪几道，重测换一批）。
//    十几道选择题全在本地判分 —— 不能出现「摸底要先联网、还得等模型」。
// 2. **定级看「哪一档没过」，不看「最高过了哪一档」**。
//    每档只 3 题，猜对两题的概率有 15%，取「最高达标档」会系统性地高估。
//    走阶梯：从低到高找**第一个不达标的档**，定在它下面一档；最低档就不过 → A1。
// 3. **结果要说出下一步**。只给一个字母（「你是 B1」）对用户毫无用处，
//    所以要给「从哪类情景开始练」＋ 一份逐档明细（哪档过了、哪档没过）。

/// 题型。
public enum PlacementQuestionKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// 认词：给英文词选中文义。
    case vocabulary
    /// 语法：选正确的形式填进句子。
    case grammar

    public var displayName: String {
        switch self {
        case .vocabulary: "词汇"
        case .grammar: "语法"
        }
    }
}

/// 一道定级题。
public struct PlacementQuestion: Sendable, Equatable, Identifiable, Codable {

    public var id: String
    public var level: CEFRLevel
    public var kind: PlacementQuestionKind
    /// 题干（词汇题就是那个词；语法题是一句带空格的句子）。
    public var prompt: String
    public var options: [String]
    /// 正确选项下标。
    public var answer: Int
    /// 一句解释（做完之后看，不是做题时的提示）。
    public var explain: String

    public init(
        id: String,
        level: CEFRLevel,
        kind: PlacementQuestionKind,
        prompt: String,
        options: [String],
        answer: Int,
        explain: String = ""
    ) {
        self.id = id
        self.level = level
        self.kind = kind
        self.prompt = prompt
        self.options = options
        self.answer = answer
        self.explain = explain
    }

    private enum CodingKeys: String, CodingKey {
        case id, level, kind, prompt, options, answer, explain
    }

    /// ⚠️ 手写解码只为了一件事：`level` 在 JSON 里写的是 `"A1"`，而 `CEFRLevel`
    /// 的 rawValue 是小写。少这一步就会静默丢光整份题库（`try?` 一吞，页面上
    /// 只是「没有题」——最难查的那种空白）。缺 `id` / `prompt` / `options` 直接抛。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        prompt = try container.decode(String.self, forKey: .prompt)
        options = try container.decode([String].self, forKey: .options)
        answer = try container.decode(Int.self, forKey: .answer)
        explain = try container.decodeIfPresent(String.self, forKey: .explain) ?? ""
        kind = PlacementQuestionKind(
            rawValue: try container.decode(String.self, forKey: .kind)
        ) ?? .vocabulary
        let rawLevel = try container.decode(String.self, forKey: .level)
        guard let parsed = CEFRLevel(rawValue: rawLevel.lowercased()) else {
            throw DecodingError.dataCorruptedError(
                forKey: .level, in: container, debugDescription: "未知档位：\(rawLevel)"
            )
        }
        level = parsed
    }

    /// 这道题能不能用：4 个**互不相同**的选项，且答案下标落在范围内。
    ///
    /// 题库是手写的，写错 one-of 这类东西很容易（答案下标写成 4、两个选项重复），
    /// 而坏题在考场上只会表现成「怎么选都不对」。出卷前一律过这道闸，坏题直接跳过。
    public var isPlayable: Bool {
        options.count == Self.optionCount
            && Set(options).count == options.count
            && options.indices.contains(answer)
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
            && options.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 定级题固定四选一（界面按四行排，选项数不一致会让页面跳）。
    public static let optionCount = 4

    public var answerText: String { options.indices.contains(answer) ? options[answer] : "" }
}

/// 一份卷子。
public struct PlacementPaper: Sendable, Equatable {

    public var questions: [PlacementQuestion]
    /// 抽题用的种子（重测换一批；也存进结果里，便于回看「当时抽的是哪套」）。
    public var seed: UInt64

    public init(questions: [PlacementQuestion], seed: UInt64) {
        self.questions = questions
        self.seed = seed
    }

    public static let empty = PlacementPaper(questions: [], seed: 0)

    public var isEmpty: Bool { questions.isEmpty }
    public var questionCount: Int { questions.count }

    /// 覆盖到的档位（升序、去重）。
    public var levels: [CEFRLevel] {
        CEFRLevel.allCases.filter { level in questions.contains { $0.level == level } }
    }

    public func question(at index: Int) -> PlacementQuestion? {
        questions.indices.contains(index) ? questions[index] : nil
    }

    /// 这一档有几题。
    public func count(of level: CEFRLevel) -> Int {
        questions.count { $0.level == level }
    }
}

// MARK: - 结果

/// 单档明细。
public struct PlacementLevelScore: Codable, Sendable, Equatable {
    public var level: CEFRLevel
    public var correct: Int
    public var total: Int
    /// 这一档是否达标（`correct / total >= passRatio`）。
    public var isPassed: Bool

    public init(level: CEFRLevel, correct: Int, total: Int, isPassed: Bool) {
        self.level = level
        self.correct = correct
        self.total = total
        self.isPassed = isPassed
    }

    /// 「A2 2/3」。
    public var text: String { "\(level.code) \(correct)/\(total)" }
}

/// 一次摸底的结果（落 UserDefaults，跨启动保留）。
public struct PlacementResult: Codable, Sendable, Equatable {

    /// 定下来的起点档位。
    public var level: CEFRLevel
    public var correct: Int
    public var total: Int
    public var takenAt: Date
    /// 当时抽题的种子。
    public var seed: UInt64
    /// 逐档明细（升序）。
    public var perLevel: [PlacementLevelScore]

    public init(
        level: CEFRLevel,
        correct: Int,
        total: Int,
        takenAt: Date = Date(),
        seed: UInt64 = 0,
        perLevel: [PlacementLevelScore] = []
    ) {
        self.level = level
        self.correct = max(correct, 0)
        self.total = max(total, 0)
        self.takenAt = takenAt
        self.seed = seed
        self.perLevel = perLevel
    }

    public var accuracyPercent: Int {
        guard total > 0 else { return 0 }
        return Int((Double(correct) / Double(total) * 100).rounded())
    }

    /// 「12 题对 8 题」。
    public var headline: String { "\(total) 题对 \(correct) 题" }

    /// 没过的那一档（用来解释「为什么定在这」；全过 / 都没过时为 nil）。
    public var firstFailedLevel: CEFRLevel? {
        perLevel.first { !$0.isPassed }?.level
    }
}

public extension CEFRLevel {

    /// 定级之后建议从哪类情景开始练（人话，不是教学术语）。
    var placementAdvice: String {
        switch self {
        case .a1: "从最基础的日常问答开始：问候、点单、问路。这一档进步最快，练几轮就能往上走。"
        case .a2: "从「把日常小事说完整」的情景开始：约时间、讲经历、办事。"
        case .b1: "从需要讲理由的情景开始：解释、协商、表达看法。"
        case .b2: "起点已经很高：直接去即兴表达、辩论这类情景，我按 B2 的标准要求你。"
        }
    }
}

// MARK: - 出卷与判分（纯函数）

public enum EntrancePlacementRule {

    /// 每档抽几题。**3 题是刻意压低的**：摸底要能在十分钟内做完，
    /// 而档位判定靠的是「哪一档没过」这条阶梯，不靠题量堆精度。
    public static let questionsPerLevel = 3

    /// 这一档答对多少比例算过。
    public static let passRatio = 0.6

    /// 这一档要答对几题（向上取整，至少 1 题）。
    public static func passThreshold(total: Int) -> Int {
        max(Int((Double(max(total, 1)) * passRatio).rounded(.up)), 1)
    }

    /// 出卷：按档位分组、每档抽 `perLevel` 题，`seed` 决定从哪儿开始取。
    ///
    /// 坏题（`isPlayable == false`）先剔掉 —— 宁可就少一道，也不让「怎么选都不对」
    /// 的题出现在考场上。某一档一道可用的都没有时跳过去，不让整份卷子作废。
    public static func paper(
        from bank: [PlacementQuestion],
        seed: UInt64 = 0,
        perLevel: Int = questionsPerLevel
    ) -> PlacementPaper {
        let usable = bank.filter(\.isPlayable)
        guard !usable.isEmpty else { return .empty }
        var picked: [PlacementQuestion] = []
        for level in CEFRLevel.allCases {
            let pool = usable.filter { $0.level == level }.sorted { $0.id < $1.id }
            guard !pool.isEmpty else { continue }
            let start = Int(seed % UInt64(pool.count))
            let take = min(max(perLevel, 1), pool.count)
            for offset in 0..<take {
                picked.append(pool[(start + offset) % pool.count])
            }
        }
        return PlacementPaper(questions: picked, seed: seed)
    }

    /// 下一次重测用哪颗种子。
    ///
    /// 每次 +1：同一档的 5 道题会逐次轮换，用户不会连着两次看到同一张卷子；
    /// 而同一个种子永远出同一份卷子（可复现，出问题时能照着重现）。
    public static func nextSeed(after previous: UInt64?) -> UInt64 {
        (previous ?? 0) &+ 1
    }

    /// 判分 + 定级。没作答的题按错算（不猜也是选择，但不给分）。
    public static func result(
        paper: PlacementPaper,
        answers: [String: Int],
        takenAt: Date = Date()
    ) -> PlacementResult {
        let scores: [PlacementLevelScore] = paper.levels.compactMap { level in
            let group = paper.questions.filter { $0.level == level }
            guard !group.isEmpty else { return nil }
            let correct = group.count { answers[$0.id] == $0.answer }
            return PlacementLevelScore(
                level: level,
                correct: correct,
                total: group.count,
                isPassed: correct >= passThreshold(total: group.count)
            )
        }
        return PlacementResult(
            level: level(from: scores),
            correct: scores.reduce(0) { $0 + $1.correct },
            total: paper.questionCount,
            takenAt: takenAt,
            seed: paper.seed,
            perLevel: scores
        )
    }

    /// 定级：从低到高找**第一个没过的档**，定在它下面一档。
    ///
    /// ⚠️ 刻意**不用**「最高的达标档」：每档只有 3 题，四选一蒙对两题的概率约 15%，
    /// 取最高值会把一部分人系统性地抬高一档 —— 而抬高起点比压低起点伤害更大
    /// （内容太难会直接劝退）。阶梯判定还有个好处：结果能解释得清
    /// （「A2 没过，所以定在 A1」），而不是一个说不清的字母。
    public static func level(from scores: [PlacementLevelScore]) -> CEFRLevel {
        var current: CEFRLevel = .a1
        var hasPassedAny = false
        for score in scores.sorted(by: { $0.level < $1.level }) {
            guard score.isPassed else {
                // 第一档就不过 → A1；后面某档不过 → 停在它下面那一档。
                return hasPassedAny ? current : .a1
            }
            current = score.level
            hasPassedAny = true
        }
        // 全过 → 最高的那一档（题库到 B2 为止）。
        return hasPassedAny ? current : .a1
    }
}
