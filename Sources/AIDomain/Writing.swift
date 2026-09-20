import Foundation

// MARK: - 写作练习与批改（#230）
//
// 全库原本没有任何写作功能 —— 这是产品最大的空白。设计三条铁律：
//
// 1. **一次写作 = 一次模型请求**。题目不走模型：内置题库按 `dayKey` 轮换
//    （同一天同一题，与每日推荐 12 词的恒定口径一致）；批改一次请求出全部结果。
// 2. **批改是键值行**。模型输出 `SCORE / ADVICE / FIX / REWRITE / WORD` 五个键，
//    `||` 分隔子字段 —— 与词典查词、跟读日练同一套约定。解析在
//    `WritingReviewRule`，与模板是**一对**，改一处必须改另一处。
// 3. **diff 只对齐、不发明**。改写对比用词级 LCS 对齐（`WritingDiff`），
//    没被改动的词绝不标红 —— 「漏改不误报」是验收硬要求。

// MARK: - 题目

public enum WritingTopicKind: String, CaseIterable, Sendable, Identifiable {

    /// 写一封邮件（请假 / 投诉 / 咨询……有明确的收件人与目的）。
    case email
    /// 写一篇日记 / 记叙（讲一件发生过的事）。
    case diary
    /// 写一段观点（对一个说法站队并给理由）。
    case opinion

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .email: "邮件"
        case .diary: "日记"
        case .opinion: "观点"
        }
    }

    public var systemImage: String {
        switch self {
        case .email: "envelope.fill"
        case .diary: "book.fill"
        case .opinion: "lightbulb.fill"
        }
    }
}

/// 一道写作题。
public struct WritingTopic: Sendable, Equatable, Identifiable {

    public var kind: WritingTopicKind
    /// 英文题干（学员直接照着写）。
    public var title: String
    /// 中文提示（可以写哪些点，给卡壳时递一把梯子）。
    public var hint: String
    /// 题目对应的 dayKey（同一天同一题）。
    public var dayKey: Int

    public var id: String { "\(dayKey)-\(kind.rawValue)" }

    /// 词数要求（所有题统一 80–120 词，题库里不再各自声明）。
    public var minWords: Int { 80 }
    public var maxWords: Int { 120 }

    public init(kind: WritingTopicKind, dayKey: Int, title: String, hint: String) {
        self.kind = kind
        self.title = title
        self.hint = hint
        self.dayKey = dayKey
    }
}

/// 内置题库：每种类型 8 题，按 dayKey 轮换。**纯数据**，出题零请求。
public enum WritingTopicLibrary {

    static let topics: [WritingTopicKind: [WritingTopic]] = [
        .email: [
            WritingTopic(
                kind: .email, dayKey: 0,
                title: "Write an email to your landlord about a broken heater in your apartment. Explain the problem, how long it has lasted, and ask for a repair.",
                hint: "可以说：暖气坏了多久、晚上有多冷、你已经试过什么办法、希望对方哪天之前来修。"
            ),
            WritingTopic(
                kind: .email, dayKey: 0,
                title: "Write an email to a colleague inviting them to co-present a project with you next month. Say what the project is and why you want them.",
                hint: "可以说：项目主题、为什么找他（他的强项）、大概要花多少时间、等他回复。"
            ),
            WritingTopic(
                kind: .email, dayKey: 0,
                title: "Write an email to a hotel where you stayed last week. One thing was great, one thing was disappointing. Mention both and suggest a fix.",
                hint: "可以说：先谢对方，夸一项服务，再说不满意的那件事，最后给一个具体的补偿建议。"
            ),
            WritingTopic(
                kind: .email, dayKey: 0,
                title: "Write an email to your city council suggesting one change that would make your neighbourhood better for families.",
                hint: "可以说：现在的问题、你想加的东西（斑马线 / 公园 / 图书角）、对家庭的好处、愿意联名支持。"
            ),
            WritingTopic(
                kind: .email, dayKey: 0,
                title: "Write an email to your professor asking for a one-week extension on an assignment. Give an honest reason and propose a new date.",
                hint: "可以说：承认时间紧、说明真实原因（别编病）、保证质量、提出具体的新交稿日期。"
            ),
            WritingTopic(
                kind: .email, dayKey: 0,
                title: "Write an email to an online shop about a package that arrived damaged. Describe the damage and say what you want them to do.",
                hint: "可以说：订单号和到货时间、坏在哪里、拍了照片、想换货还是退款。"
            ),
            WritingTopic(
                kind: .email, dayKey: 0,
                title: "Write an email to a friend who just moved to your city, suggesting a weekend plan to show them around.",
                hint: "可以说：欢迎来新城市、推荐两三个地方、定个大概时间、问他想吃什么。"
            ),
            WritingTopic(
                kind: .email, dayKey: 0,
                title: "Write an email to a volunteer organisation applying to help at a weekend event. Say what you can do and when you are available.",
                hint: "可以说：为什么想参加、有什么技能（外语 / 搬东西 / 拍照）、哪几天有空。"
            ),
        ],
        .diary: [
            WritingTopic(
                kind: .diary, dayKey: 0,
                title: "Write a diary entry about a small mistake that turned out to be lucky. Describe what happened and what you learned.",
                hint: "可以说：当时做了什么错事、结果意外变好了、你的心情变化、以后会怎么想。"
            ),
            WritingTopic(
                kind: .diary, dayKey: 0,
                title: "Write a diary entry about the best meal you have ever had. Where was it, who were you with, and why was it special?",
                hint: "可以说：在哪儿吃的、和谁一起、那道菜的味道、为什么记到现在。"
            ),
            WritingTopic(
                kind: .diary, dayKey: 0,
                title: "Write a diary entry about a time you were late for something important. What caused it, and how did it end?",
                hint: "可以说：为什么迟到、路上有多着急、到了之后怎样、以后怎么避免。"
            ),
            WritingTopic(
                kind: .diary, dayKey: 0,
                title: "Write a diary entry describing your city on a rainy day. Use what you saw, heard and smelled.",
                hint: "可以说：雨声、伞的颜色、路面反光、路人怎么躲雨、你在哪儿躲雨。"
            ),
            WritingTopic(
                kind: .diary, dayKey: 0,
                title: "Write a diary entry about a conversation you had with a stranger. What did you talk about, and what surprised you?",
                hint: "可以说：在哪儿认识的、聊了什么、对方哪句话让你意外、你会再见他吗。"
            ),
            WritingTopic(
                kind: .diary, dayKey: 0,
                title: "Write a diary entry about something you practised for a long time and finally got right.",
                hint: "可以说：练了多久、失败过几次、成功那一刻的感觉、谁帮了你。"
            ),
            WritingTopic(
                kind: .diary, dayKey: 0,
                title: "Write a diary entry about a quiet Sunday. Do nothing dramatic — capture the small details of the day.",
                hint: "可以说：几点醒的、早饭吃了什么、下午做了什么小事、天黑时的感觉。"
            ),
            WritingTopic(
                kind: .diary, dayKey: 0,
                title: "Write a diary entry about a promise you made and kept. Why was it hard, and why did it matter?",
                hint: "可以说：答应了谁、做到有多难、中间想放弃吗、完成后对方什么反应。"
            ),
        ],
        .opinion: [
            WritingTopic(
                kind: .opinion, dayKey: 0,
                title: "\"Learning a language is easier with a teacher than with an app.\" Do you agree? Give two reasons and one example.",
                hint: "可以说：亮明立场、两个理由、举一次自己的经历、承认对方有一点道理。"
            ),
            WritingTopic(
                kind: .opinion, dayKey: 0,
                title: "Should students be allowed to use phones in class? Take a side and defend it with two arguments.",
                hint: "可以说：立场先行、理由一（查资料 / 分心）、理由二、给一条折中规则更显成熟。"
            ),
            WritingTopic(
                kind: .opinion, dayKey: 0,
                title: "\"Money can buy happiness.\" Write your opinion with one supporting example and one counter-example.",
                hint: "可以说：先说金钱能买到什么、再说买不到什么、各举一例、最后给你的结论。"
            ),
            WritingTopic(
                kind: .opinion, dayKey: 0,
                title: "Is it better to live in a big city or a small town? Choose one and explain with two reasons.",
                hint: "可以说：机会 / 交通 / 房价 / 邻里关系里挑两点、联系你自己的生活方式。"
            ),
            WritingTopic(
                kind: .opinion, dayKey: 0,
                title: "\"Homework should be banned in primary school.\" Do you agree? Give reasons and suggest an alternative.",
                hint: "可以说：立场、对孩子时间 / 习惯的影响、给一个替代方案（亲子阅读等）。"
            ),
            WritingTopic(
                kind: .opinion, dayKey: 0,
                title: "Should everyone learn to cook before leaving home? Write your opinion with examples from your own life.",
                hint: "可以说：省钱 / 健康 / 独立三个角度挑两个、讲一次你自己做饭的经历。"
            ),
            WritingTopic(
                kind: .opinion, dayKey: 0,
                title: "\"Social media does more harm than good to friendships.\" Agree or disagree, with two reasons.",
                hint: "可以说：联系方便 vs 表面点赞、举一个真实场景、给出你自己的使用建议。"
            ),
            WritingTopic(
                kind: .opinion, dayKey: 0,
                title: "Is it ever OK to tell a lie? Write your opinion and give one example where it might be.",
                hint: "可以说：多数时候要诚实、什么情况例外（善意的谎言）、例子里当事人会怎么想。"
            ),
        ],
    ]

    /// 题库为空时的最后兜底（不该发生，但 UI 不能拿到 nil）。
    static let fallback = WritingTopic(
        kind: .diary,
        dayKey: 0,
        title: "Write a diary entry about your day so far. What happened, and how do you feel about it?",
        hint: "自由发挥：今天遇到的一个人、一件事、一点感受。"
    )
}

public enum WritingTopicPicker {

    /// dayKey 锚点：2026-01-01。恒定一天一题（与每日推荐 12 词同口径）。
    static let anchorYear = 2026

    /// 距锚点日的天数（同一天内恒定；锚点之前按 0 计）。
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> Int {
        let anchor = calendar.date(from: DateComponents(year: anchorYear, month: 1, day: 1)) ?? date
        let start = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: anchor), to: start).day ?? 0
        return max(days, 0)
    }

    /// 今天的题目：类型按天轮换、题库内按天推进（同一天内任何时刻都拿到同一题）。
    public static func topic(for date: Date, calendar: Calendar = .current) -> WritingTopic {
        let key = dayKey(for: date, calendar: calendar)
        let kinds = WritingTopicKind.allCases
        let kind = kinds[key % kinds.count]
        let pool = WritingTopicLibrary.topics[kind] ?? []
        guard !pool.isEmpty else { return WritingTopicLibrary.fallback }
        let index = (key / kinds.count) % pool.count
        let item = pool[index]
        return WritingTopic(kind: item.kind, dayKey: key, title: item.title, hint: item.hint)
    }
}

// MARK: - 批改结果与解析

/// 一处批改：原文片段 → 改正 → 为什么。
public struct WritingFix: Sendable, Equatable {

    /// 原文片段（模型引用的错处；尽量逐字引用，方便在原文里定位高亮）。
    public var original: String
    /// 改正后的写法。
    public var corrected: String
    /// 一句中文解释。
    public var note: String
    /// 在原文中的字符起点（大小写不敏感的逐字匹配才定位；定位不到为 nil —— 照样展示，只是不高亮）。
    public var offset: Int?

    public init(original: String, corrected: String, note: String, offset: Int? = nil) {
        self.original = original
        self.corrected = corrected
        self.note = note
        self.offset = offset
    }
}

/// 批改时建议记进单词本的词。
public struct WritingWord: Sendable, Equatable, Identifiable {

    public var word: String
    public var pos: String
    public var meaning: String

    public var id: String { word.lowercased() }

    public init(word: String, pos: String, meaning: String) {
        self.word = word
        self.pos = pos
        self.meaning = meaning
    }
}

/// 一份完整批改。
public struct WritingReview: Sendable, Equatable {

    /// 0–100；模型没给分就是 nil（不编一个默认分）。
    public var score: Int?
    /// **一条**重点建议（中文）。
    public var advice: String
    public var fixes: [WritingFix]
    /// 整段改写。
    public var rewrite: String
    /// 值得记进单词本的词。
    public var words: [WritingWord]

    public init(
        score: Int? = nil,
        advice: String = "",
        fixes: [WritingFix] = [],
        rewrite: String = "",
        words: [WritingWord] = []
    ) {
        self.score = score
        self.advice = advice
        self.fixes = fixes
        self.rewrite = rewrite
        self.words = words
    }

    /// 模型是否真的给出了任何内容（全空 = 请求失败 / 输出跑飞）。
    public var isEmpty: Bool {
        score == nil && advice.isEmpty && fixes.isEmpty && rewrite.isEmpty && words.isEmpty
    }
}

public enum WritingReviewRule {

    /// 从模型输出解析批改，并在**原文**里定位每处批改。
    ///
    /// 容错原则：**宁缺毋滥** —— 缺分隔符 / 空字段的 FIX 行直接丢弃（漏改不误报）；
    /// REWRITE 之后到下一个已知键之前的所有行都属于改写正文（改写可以多行）。
    public static func parse(_ raw: String, original: String) -> WritingReview {
        var review = WritingReview()
        var rewriteLines: [String]?
        var sawRewrite = false

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                // 空行：改写正文里的段落分隔保留下来。
                rewriteLines?.append("")
                continue
            }
            if let value = key("score", in: trimmed) {
                let digits = value.prefix { $0.isNumber }
                review.score = Int(digits.prefix(3)).flatMap { (0...100).contains($0) ? $0 : nil }
                continue
            }
            if let value = key("advice", in: trimmed) {
                review.advice = value
                continue
            }
            if let value = key("rewrite", in: trimmed) {
                sawRewrite = true
                rewriteLines = value.isEmpty ? [] : [value]
                continue
            }
            if let value = key("fix", in: trimmed) {
                let parts = value.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
                // 宁缺毋滥：缺分隔符 / 空字段的批改行直接丢弃（漏改不误报）。
                guard parts.count >= 2, let wrong = parts.first, !wrong.isEmpty,
                      !parts[1].isEmpty else { continue }
                review.fixes.append(
                    WritingFix(
                        original: wrong,
                        corrected: parts[1],
                        note: parts.count >= 3 ? parts[2] : "",
                        offset: locate(wrong, in: original)
                    )
                )
                continue
            }
            if let value = key("word", in: trimmed) {
                let parts = value.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let word = parts.first, !word.isEmpty else { continue }
                review.words.append(
                    WritingWord(
                        word: word,
                        pos: parts.count >= 2 ? parts[1] : "",
                        meaning: parts.count >= 3 ? parts[2] : ""
                    )
                )
                continue
            }
            // 未知行：在改写正文里就保留（改写不该被解析器吃掉）；否则丢弃。
            rewriteLines?.append(trimmed)
        }

        if sawRewrite, let lines = rewriteLines {
            let text = lines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { review.rewrite = text }
        }
        return review
    }

    /// 行首的键值（键名大小写不敏感；键与冒号之间容忍空格）；不是这些键返回 nil。
    static func key(_ name: String, in line: String) -> String? {
        guard line.lowercased().hasPrefix(name) else { return nil }
        var rest = line.dropFirst(name.count)
        rest = rest.drop { $0 == " " }
        guard rest.first == ":" else { return nil }
        return rest.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// 在原文里定位片段（大小写不敏感；匹配不到返回 nil）。
    public static func locate(_ snippet: String, in text: String) -> Int? {
        let needle = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return nil }
        let loweredText = text.lowercased()
        let loweredNeedle = needle.lowercased()
        guard let range = loweredText.range(of: loweredNeedle) else { return nil }
        return loweredText.distance(from: loweredText.startIndex, to: range.lowerBound)
    }
}

// MARK: - 改写对比（词级 diff，纯函数）

/// diff 的一段。`removed` = 原文有、改写里没了；`added` = 改写新增。
public enum WritingDiffSegment: Equatable, Sendable {

    case same(String)
    case removed(String)
    case added(String)

    public var text: String {
        switch self {
        case .same(let text), .removed(let text), .added(let text): text
        }
    }

    public var isSame: Bool { if case .same = self { return true }; return false }
}

public enum WritingDiff {

    /// 把原文与改写对齐成段序列（词级 LCS，比较大小写不敏感）。
    ///
    /// 分词**按空白切**（标点跟着词走）：渲染时段与段之间补一个空格，
    /// 词内部原样保留 —— 这样「has go → went」的边界正好落在词上，
    /// 不会出现半个词被染色的碎片段。
    public static func align(original: String, revised: String) -> [WritingDiffSegment] {
        let left = tokenize(original)
        let right = tokenize(revised)
        guard !left.isEmpty || !right.isEmpty else { return [] }
        if left.isEmpty { return [.added(right.joined(separator: " "))] }
        if right.isEmpty { return [.removed(left.joined(separator: " "))] }

        // LCS 长度表（120 词 × 120 词 = 14k 格，纯本地，开销可忽略）。
        var table = [[Int]](repeating: [Int](repeating: 0, count: right.count + 1), count: left.count + 1)
        for i in 1...left.count {
            for j in 1...right.count {
                if left[i - 1].lowercased() == right[j - 1].lowercased() {
                    table[i][j] = table[i - 1][j - 1] + 1
                } else {
                    // ⚠️ 不匹配也要继承两侧的最优子解，否则表是断的、回溯会乱配对。
                    table[i][j] = max(table[i - 1][j], table[i][j - 1])
                }
            }
        }

        // 回溯出操作序列，再合并成段。
        var ops: [WritingDiffSegment] = []
        var i = left.count, j = right.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, left[i - 1].lowercased() == right[j - 1].lowercased() {
                ops.append(.same(left[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || table[i][j - 1] >= table[i - 1][j] {
                ops.append(.added(right[j - 1]))
                j -= 1
            } else {
                ops.append(.removed(left[i - 1]))
                i -= 1
            }
        }
        ops.reverse()

        // 相邻同类段合并（段内用空格连接；段与段之间的空格由渲染方负责）。
        var merged: [WritingDiffSegment] = []
        for op in ops {
            if let last = merged.last, sameKind(last, op) {
                merged[merged.count - 1] = join(last, op)
            } else {
                merged.append(op)
            }
        }
        return merged
    }

    // MARK: 内部

    /// 切词：按空白切，标点跟着词走（`school.` 是一个词）。
    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func sameKind(_ a: WritingDiffSegment, _ b: WritingDiffSegment) -> Bool {
        switch (a, b) {
        case (.same, .same), (.removed, .removed), (.added, .added): true
        default: false
        }
    }

    static func join(_ a: WritingDiffSegment, _ b: WritingDiffSegment) -> WritingDiffSegment {
        let text = a.text + " " + b.text
        switch a {
        case .same: return .same(text)
        case .removed: return .removed(text)
        case .added: return .added(text)
        }
    }
}
