import Foundation

// MARK: - 每日短文阅读理解（#231）
//
// 与写作同三条铁律的变体：
//
// 1. **一次阅读 = 一次模型请求**。文章主题走内置题库按 `dayKey` 轮换（出题零请求），
//    文章 + 题目 + 答案 + 溯源句 + 解析 + 错因，一发请求全部拿回。
// 2. **判分纯本地、零请求**。正确答案生成时就已知 —— 提交只做对错标记，
//    不存在「批改请求」这一环（四选一的批改没有模型发挥空间）。
// 3. **解析宁缺毋滥**。选项不足 4 个、答案越界、溯源句不在原文里的题目照常展示
//    （溯源句找不到就不高亮），但绝不发明一个答案。

/// 一道阅读理解题（四选一）。
public struct ReadingQuestion: Sendable, Equatable, Identifiable, Codable {

    /// 题干（英文）。
    public var prompt: String
    /// 恰好 4 个选项（不足 4 个的题在解析阶段被丢弃）。
    public var options: [String]
    /// 正确选项下标（0–3）。
    public var correctIndex: Int
    /// 支撑答案的原文句（**逐字**摘自文章，用于溯源高亮；模型没照抄也可能定位不到）。
    public var quote: String
    /// 为什么选它（中文，含相关英语知识）。
    public var explain: String
    /// 其余选项错在哪 / 易错点（中文；错题复盘用）。
    public var trap: String

    public var id: String { prompt }

    public init(
        prompt: String,
        options: [String],
        correctIndex: Int,
        quote: String = "",
        explain: String = "",
        trap: String = ""
    ) {
        self.prompt = prompt
        self.options = options
        self.correctIndex = correctIndex
        self.quote = quote
        self.explain = explain
        self.trap = trap
    }

    /// 在原文里定位溯源句（大小写不敏感；定位不到返回 nil —— 照样展示，只是不高亮）。
    public func quoteOffset(in passage: String) -> Int? {
        WritingReviewRule.locate(quote, in: passage)
    }
}

/// 一篇每日短文（带题）。
public struct ReadingPassage: Sendable, Equatable, Codable {

    public var title: String
    public var text: String
    public var questions: [ReadingQuestion]
    /// 生成当天的 dayKey（同一天恒定的口径参照）。
    public var dayKey: Int

    public init(title: String, text: String, questions: [ReadingQuestion], dayKey: Int) {
        self.title = title
        self.text = text
        self.questions = questions
        self.dayKey = dayKey
    }

    /// 空段落兜底：模型没生成出任何题目也给出可渲染的结构。
    public var isEmpty: Bool { text.isEmpty || questions.isEmpty }
}

// MARK: - 主题库（出题零请求）

/// 每日短文的**主题**按天轮换（文章本身由模型现写，同一天重进应用会换一篇新文章，
/// 但主题恒定 —— 主题是「今天读什么」的锚）。
public enum ReadingThemeLibrary {

    public static let themes: [String] = [
        "a lighthouse keeper who trains gulls to deliver messages",
        "the last video rental shop in a small town",
        "a city that only opens its museums at night",
        "an unexpected friendship between a cat and a delivery robot",
        "a student who plant-sits for the whole apartment building",
        "a bakery that bakes bread following the weather",
        "a train that stops at stations that no longer exist",
        "a grandmother teaching her granddaughter to fix old radios",
        "a football team made up of night-shift workers",
        "a library where you borrow people instead of books",
        "a beekeeper in the middle of a busy city",
        "a map drawn by a traveller who never took the same road twice",
        "a small shop that repairs everything except phones",
        "a garden growing on the roof of an old factory",
        "a ferry captain who knows every seal by name",
        "a photographer who only takes pictures of doors",
    ]

    /// 今天的主题（dayKey 轮换；题库为空时兜底）。
    public static func theme(for date: Date, calendar: Calendar = .current) -> String {
        let key = WritingTopicPicker.dayKey(for: date, calendar: calendar)
        guard !themes.isEmpty else { return "an ordinary day told in an unusual way" }
        return themes[key % themes.count]
    }
}

// MARK: - 生成结果解析

public enum ReadingReviewRule {

    /// 从模型输出解析短文与题目。
    ///
    /// 键值行格式（与写作批改同一套约定）：
    /// `title / passage / q / opt / answer / quote / explain / trap`。
    /// `passage` 多行（到第一个 `q:` 为止）；`trap` 可省略；题与题之间由下一个 `q:` 开启。
    public static func parse(_ raw: String, dayKey: Int) -> ReadingPassage {
        var title = ""
        var passageLines: [String]?
        var questions: [ReadingQuestion] = []

        var currentPrompt = ""
        var currentOptions: [String] = []
        var currentAnswer = -1
        var currentQuote = ""
        var currentExplain = ""
        var currentTrap = ""

        // 一道题收尾：把凑齐的题压进结果。
        func flush() {
            defer {
                currentPrompt = ""
                currentOptions = []
                currentAnswer = -1
                currentQuote = ""
                currentExplain = ""
                currentTrap = ""
            }
            guard !currentPrompt.isEmpty, currentOptions.count == 4,
                  (0...3).contains(currentAnswer) else { return }
            questions.append(
                ReadingQuestion(
                    prompt: currentPrompt,
                    options: currentOptions,
                    correctIndex: currentAnswer,
                    quote: currentQuote,
                    explain: currentExplain,
                    trap: currentTrap
                )
            )
        }

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                passageLines?.append("")
                continue
            }
            if let value = key("title", in: trimmed) {
                title = value
                continue
            }
            if let value = key("passage", in: trimmed) {
                // 正文可能就从「passage:」同一行开始 —— 丢了首句文章就读不通。
                passageLines = value.isEmpty ? [] : [value]
                continue
            }
            if let value = key("q", in: trimmed) {
                // 新题开始：先收上一题。
                flush()
                currentPrompt = value
                continue
            }
            if let value = key("opt", in: trimmed) {
                let parts = value.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
                // 宁缺毋滥：模型手滑给了 5 个也只收前 4 个；不足 4 个让 flush 丢弃整题。
                currentOptions = Array(parts.prefix(4))
                continue
            }
            if let value = key("answer", in: trimmed) {
                let digits = value.prefix { $0.isNumber }
                currentAnswer = Int(digits).flatMap { (0...3).contains($0) ? $0 : -1 } ?? -1
                continue
            }
            if let value = key("quote", in: trimmed) {
                currentQuote = value
                continue
            }
            if let value = key("explain", in: trimmed) {
                currentExplain = value
                continue
            }
            if let value = key("trap", in: trimmed) {
                currentTrap = value
                continue
            }
            // 未知行：在文章正文里就保留（正文不该被解析器吃掉）。
            passageLines?.append(trimmed)
        }
        flush()

        let text = (passageLines ?? [])
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ReadingPassage(title: title, text: text, questions: questions, dayKey: dayKey)
    }

    /// 行首的键值（键名大小写不敏感；键与冒号之间容忍空格）——与写作批改同一条实现。
    static func key(_ name: String, in line: String) -> String? {
        WritingReviewRule.key(name, in: line)
    }
}

// MARK: - 本地判分（纯函数，零请求）

public enum ReadingGrader {

    /// 提交后的判分结果：每题 对 / 错（未答按错计）。
    public static func grade(_ passage: ReadingPassage, choices: [Int: Int]) -> [Bool] {
        passage.questions.enumerated().map { index, question in
            choices[index] == question.correctIndex
        }
    }

    /// 「答对 N / M」里的 N。
    public static func correctCount(_ passage: ReadingPassage, choices: [Int: Int]) -> Int {
        grade(passage, choices: choices).filter { $0 }.count
    }
}

// MARK: - 落库形态（#233：当天多篇固定展示，重启不丢）

/// 一篇**已生成**的短文连同作答进度 —— 持久化与「当天回看」共用这一份结构。
///
/// 题目/答案/解析随文整体存 JSON：阅读没有「单独改某一题」的场景，
/// 整篇读写最简单，也永远不会出现「文章是新的、答案是旧的」这种错位。
public struct StoredReading: Sendable, Equatable, Identifiable {

    public var id: UUID
    public var passage: ReadingPassage
    /// 每题的选择：题目下标 → 选项下标。
    public var choices: [Int: Int]
    /// 是否已交卷（交卷后锁定选项、标对错）。
    public var isReviewed: Bool
    /// 生成时间（当天多篇按它排序编号）。
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        passage: ReadingPassage,
        choices: [Int: Int] = [:],
        isReviewed: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.passage = passage
        self.choices = choices
        self.isReviewed = isReviewed
        self.createdAt = createdAt
    }

    /// 交卷后的判分（本地零请求，口径与 `ReadingGrader` 同一把尺）。
    public func correctCount() -> Int {
        ReadingGrader.grade(passage, choices: choices).filter { $0 }.count
    }
}
