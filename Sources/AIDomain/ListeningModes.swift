import Foundation

// MARK: - 听力板块的三种形式（#309）
//
// 同一批句子，三种问法，考的是「听懂」的三个层次：
//
//   ① **精听默写**（`.dictation`）—— 音 → 形：把整句写下来，逐词对原文。
//      要求最高，最能暴露「以为自己听懂了」；链路在 `ListeningDictation.swift`。
//   ② **关键词捕捉**（`.keyword`）—— 音 → 信息：只抓主干，不要求虚词与语序。
//      跳过拼写这一层，所以好上手；代价是它永远说不了「你到底漏了哪个音」。
//   ③ **听句选义**（`.meaning`）—— 音 → 义：四个释义挑一个。
//      最轻，适合碎片时间；但能靠排除法蒙，练多了会虚高。
//
// 三者**共用同一批句子**（今天的跟读素材）、同一套播放链路、同一本账本，
// 所以换模式练的是同一批句子，只是被问的东西不一样 —— 也正因为如此，
// 三个模式的成绩可以放在同一本账上比（见 `ListeningLog`）。
//
// 判分全在本文件与 `ListeningDictation.swift`（纯函数），三种形式都是**零请求**：
// 题干与答案由素材下发，比对在本地算。听力练习不该为「对个答案」付一次模型调用。

/// 听力板块的三种形式。
public enum ListeningMode: String, CaseIterable, Sendable, Identifiable, Hashable {

    case dictation
    case keyword
    case meaning

    public var id: String { rawValue }

    /// 侧栏式的短名（切换条与结算卡都用它，别再各写一份字面量）。
    public var title: String {
        switch self {
        case .dictation: return "精听默写"
        case .keyword: return "关键词捕捉"
        case .meaning: return "听句选义"
        }
    }

    public var symbol: String {
        switch self {
        case .dictation: return "square.and.pencil"
        case .keyword: return "tag.fill"
        case .meaning: return "list.bullet.rectangle.fill"
        }
    }

    /// 一句话说清这个模式练什么（切换条的 `.help` 与页头副标题共用同一份）。
    public var blurb: String {
        switch self {
        case .dictation: return "把听到的那句整句写下来，再逐词对原文"
        case .keyword: return "只听主干：写下你听到的关键信息词，不要求写全"
        case .meaning: return "只听意思：四个释义里挑一个，不考拼写"
        }
    }

    /// 输入框的引导语（`.meaning` 不写答案，所以是空串）。
    public var answerPlaceholder: String {
        switch self {
        case .dictation: return "把你听到的那句写下来"
        case .keyword: return "把你听到的关键词写下来，空格或逗号隔开"
        case .meaning: return ""
        }
    }

    /// 提交按钮的文案（`.meaning` 是**点选项即判**，没有提交这一步）。
    public var submitTitle: String {
        switch self {
        case .dictation: return "对照原文"
        case .keyword: return "看我抓住了几个"
        case .meaning: return ""
        }
    }

    /// 输入框的 `.help`（说清这个模式判分的口径，别让人猜「写几个词算对」）。
    public var inputHelp: String {
        switch self {
        case .dictation: return "写不全没关系，写出来才知道差在哪"
        case .keyword: return "写几个都行；只认主干词，虚词不算"
        case .meaning: return ""
        }
    }
}

// MARK: - ② 关键词捕捉

/// 一次「关键词捕捉」的结果。
public struct KeywordCapture: Sendable, Equatable, Identifiable {

    public var id: UUID
    public var drillID: String
    /// 参考句（**提交后**才允许显示）。
    public var reference: String
    /// 母语释义（提交后才允许显示）。
    public var translation: String
    /// 学员写下来的那些词（原样保留，用于回显他写了什么）。
    public var typedWords: [String]
    /// 这一句的「关键信息词」，由 `ListeningKeywordRule.keyWords(of:)` 纯函数挑出。
    public var keyWords: [String]
    /// 抓住了哪几个（保持 `keyWords` 的顺序 —— 屏幕上是从左到右读的）。
    public var caught: [String]
    /// 没抓住哪几个。
    public var missed: [String]
    /// 提交前这一句听了几遍。
    public var playCount: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        drillID: String,
        reference: String,
        translation: String = "",
        typedWords: [String],
        keyWords: [String],
        caught: [String],
        missed: [String],
        playCount: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.drillID = drillID
        self.reference = reference
        self.translation = translation
        self.typedWords = typedWords
        self.keyWords = keyWords
        self.caught = caught
        self.missed = missed
        self.playCount = max(playCount, 0)
        self.createdAt = createdAt
    }

    public var caughtCount: Int { caught.count }
    public var total: Int { keyWords.count }

    /// 命中率。⚠️ 这一句一个关键词都没挑出来时算 **0** 而不是 1：
    /// 那意味着这一句本来就出不了题（`keyWords` 为空），给满分会让平均分虚高。
    public var hitRatio: Double {
        guard total > 0 else { return 0 }
        return Double(caughtCount) / Double(total)
    }

    public var hitPercent: Int { Int((hitRatio * 100).rounded()) }

    /// 「抓住了 3 / 4」。
    public var scoreText: String { "抓住了 \(caughtCount) / \(total)" }
}

/// 关键词捕捉的规则（纯函数）。
public enum ListeningKeywordRule {

    /// 一句最多认几个关键词。
    ///
    /// 4 个：够覆盖「谁 + 做什么 + 关键细节」，再多就退化成默写了 ——
    /// 而默写已经有另一个模式专门在干这件事。
    public static let keyWordLimit = 4

    /// 补底线的下限：内容词不足这个数时，从被停用词挡掉的词里按长度往回补。
    public static let minimumKeyWords = 2

    /// 只认 **≥ 4 个字母**的词。`a` / `to` / `is` 这类不管在不在停用词表里，
    /// 都不是「关键信息点」，让人去听它们等于把练习变成默写。
    public static let minimumLength = 4

    /// 命中判定里**允许前缀匹配的最短长度**。
    ///
    /// 写 `coff` 认成 `coffee`（听清了但没写全，是听力练习该给的分），
    /// 写 `c` 不认（那只是碰巧）。
    public static let minimumPrefixMatch = 4

    /// 英文虚词表。
    ///
    /// ⚠️ 刻意**手写**而不是引一个 NLP 依赖：这份表要能被测试逐条钉住，
    /// 而且它直接决定「哪些词算关键信息」—— 悄悄换一份表就等于悄悄换了判分口径。
    public static let stopWords: Set<String> = [
        "about", "above", "after", "again", "against", "almost", "along", "already",
        "also", "although", "always", "among", "another", "anyone", "anything", "around",
        "back", "because", "been", "before", "being", "below", "beside", "besides", "between",
        "both", "call", "called", "cannot", "come", "comes", "could", "does", "doing", "done",
        "down", "during", "each", "either", "else", "enough", "even", "ever", "every",
        "everything", "from", "gets", "getting", "give", "goes", "going", "gone",
        "gonna", "gotta", "had", "has", "have", "having", "here", "hers", "herself",
        "himself", "however", "into", "itself", "just", "keep", "keeps", "kind", "know",
        "last", "least", "less", "lets", "like", "long", "made", "make", "makes", "making",
        "many", "maybe", "might", "mine", "more", "most", "much", "must", "myself",
        "near", "need", "needs", "never", "next", "none", "nothing", "often", "once",
        "only", "onto", "other", "others", "ours", "ourselves", "over", "perhaps", "please",
        "pretty", "quite", "rather", "really", "right", "said", "same", "says", "seem",
        "seems", "should", "since", "some", "someone", "something", "sometimes", "soon",
        "still", "such", "sure", "take", "takes", "taking", "than", "that", "their",
        "theirs", "them", "themselves", "then", "there", "these", "they", "thing",
        "things", "think", "this", "those", "though", "through", "thus", "till",
        "time", "times", "together", "too", "toward", "under", "until", "upon", "used",
        "using", "very", "want", "wants", "well", "were", "whatever", "when", "where",
        "whether", "which", "while", "whom", "whose", "will", "with", "within",
        "without", "would", "yeah", "yours", "yourself"
    ]

    /// 挑出这一句的「关键信息词」。
    ///
    /// 口径（三条，都能单独断言）：
    /// ① 只收纯字母、长度 ≥ `minimumLength` 的词，去重（按首次出现）；
    /// ② 先踢掉停用词，再从剩下的里按**长度降序**取前 `limit` 个 ——
    ///    长度是最省事又不骗人的「内容度」代理：实义词普遍比虚词长；
    /// ③ 取完再**按原句的出现顺序**排回去。屏幕上是要从左到右读的，
    ///    按长度排会让人以为是按重要度排的（它不是，它只是长度）。
    public static func keyWords(of sentence: String, limit: Int = keyWordLimit) -> [String] {
        let tokens = ShadowingScorer.words(sentence)
            .map { $0.lowercased() }
            .filter { isWord($0) && $0.count >= minimumLength }
        var seen = Set<String>()
        var order: [String: Int] = [:]
        var unique: [String] = []
        for token in tokens where seen.insert(token).inserted {
            order[token] = unique.count
            unique.append(token)
        }
        var content = unique.filter { !stopWords.contains($0) }
        // 短句兜底：内容词不足两个时，从被停用词挡掉的词里按长度往回补。
        // 少了这一条，「It is what it is.」这种句子会一个关键词都出不来 ——
        // 模式对短句直接失效，而屏幕上只会显得「这一句没题」。
        if content.count < minimumKeyWords {
            let rest = unique
                .filter { !content.contains($0) }
                .sorted { lhs, rhs in
                    lhs.count != rhs.count ? lhs.count > rhs.count : order[lhs, default: 0] < order[rhs, default: 0]
                }
            content.append(contentsOf: rest.prefix(minimumKeyWords - content.count))
        }
        let picked = content
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : order[lhs, default: 0] < order[rhs, default: 0]
            }
            .prefix(max(limit, 1))
        return picked.sorted { order[$0, default: 0] < order[$1, default: 0] }
    }

    /// 对照：学员写下的词命中了几成。
    public static func capture(
        drillID: String,
        reference: String,
        translation: String = "",
        typed: String,
        playCount: Int,
        limit: Int = keyWordLimit
    ) -> KeywordCapture {
        let keyWords = keyWords(of: reference, limit: limit)
        let typedWords = ShadowingScorer.words(typed).map { $0.lowercased() }.filter(isWord)
        let caught = keyWords.filter { key in
            typedWords.contains { matches(typed: $0, key: key) }
        }
        let missed = keyWords.filter { !caught.contains($0) }
        return KeywordCapture(
            drillID: drillID,
            reference: reference,
            translation: translation,
            typedWords: typedWords,
            keyWords: keyWords,
            caught: caught,
            missed: missed,
            playCount: playCount
        )
    }

    /// 学员写的一个词算不算命中了这个关键词。
    ///
    /// ⚠️ 匹配尺**复用 `FuzzyWordMatch`**（全应用唯一那把）：全等 → 命中；
    /// 前缀（`coff` → `coffee`）在长度够时也算命中 —— 听清了但没写全，是听力练习该给的分。
    /// **子串不算**（`offe` 落在 `coffee` 中间）：那不是「差几个字母」，那是没听清开头。
    static func matches(typed: String, key: String) -> Bool {
        guard let score = FuzzyWordMatch.score(word: key, translation: "", needle: typed) else {
            return false
        }
        if score == 0 { return true }
        return score == 1 && typed.count >= minimumPrefixMatch
    }

    static func isWord(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isLetter && $0.isASCII }
    }
}

// MARK: - ③ 听句选义

/// 一道「听句选义」的题。
///
/// ⚠️ 这个类型**不含参考句**：题干只有四个**释义**。
/// 原文只在答完之后由页面自己说出来（那时已经判完分了），
/// 这样「答题时屏幕上看不到英文原文」在类型层面就成立 —— 与精听模式的
/// `ListeningDrillCard` 是同一条纪律。
public struct MeaningQuestion: Sendable, Equatable {

    public var drillID: String
    /// 四个选项的**释义**（互不相同）。
    public var options: [String]
    /// 正确项的下标（选项顺序由句 id 派生，见 `ListeningMeaningRule.question`）。
    public var correctIndex: Int

    public init(drillID: String, options: [String], correctIndex: Int) {
        self.drillID = drillID
        self.options = options
        self.correctIndex = correctIndex
    }

    public var correctOption: String {
        options.indices.contains(correctIndex) ? options[correctIndex] : ""
    }

    public func isCorrect(_ index: Int?) -> Bool { index == correctIndex }
}

/// 听句选义的出题规则（纯函数，零请求）。
public enum ListeningMeaningRule {

    /// 几个选项。四选一：再少能靠猜蒙过去，再多读选项的时间会超过听的时间。
    public static let optionCount = 4

    /// 给某一句出题。
    ///
    /// 干扰项 = **同一轮里其它句子的释义**。刻意不用编造的假选项：
    /// 编得离谱的干扰项等于把答案直接指出来（三个都不像人话，剩下那个必然是对的），
    /// 而同批素材的释义天然同域、同难度，这才真的在考「听懂了哪一句」。
    ///
    /// 凑不满 `optionCount` 个**互不相同**的释义就返回 nil —— 这一句不出题、跳过，
    /// 绝不拿空串或重复项凑数（那会变成一道有白送答案的题）。
    public static func question(
        for drill: ShadowingDrill,
        in round: [ShadowingDrill],
        optionCount: Int = optionCount
    ) -> MeaningQuestion? {
        let correct = drill.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correct.isEmpty, optionCount >= 2 else { return nil }
        var pool: [String] = []
        for other in round where other.id != drill.id {
            let text = other.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != correct, !pool.contains(text) else { continue }
            pool.append(text)
        }
        guard pool.count >= optionCount - 1 else { return nil }
        // 干扰项与选项顺序都从**句 id 派生的种子**出 —— 同一天同一句每次进来出的题一模一样。
        // 不这么做的话，退出重进选项位置就换了，那次「重做」量的不是听力而是记忆。
        let seed = DailySeed.seed(for: drill.id, purpose: "listening-meaning")
        var generator = SeededRandomGenerator(seed: seed)
        // 抽 `optionCount - 1` 个干扰项：先把池子洗一遍再取前几个，
        // 保证每一句抽到的干扰项组合基本不同（固定取前几个会让所有题共用同一批干扰项）。
        var shuffledPool = pool
        shuffledPool.shuffle(using: &generator)
        var options = Array(shuffledPool.prefix(optionCount - 1)) + [correct]
        options.shuffle(using: &generator)
        guard let index = options.firstIndex(of: correct) else { return nil }
        return MeaningQuestion(drillID: drill.id, options: options, correctIndex: index)
    }

    /// 这一轮里**哪些句子出得了题**（释义齐全 + 干扰项够）。
    ///
    /// 页面据此决定「这一句出不了题时直接跳过」—— 让用户面对一道空题
    /// 比让他少做一句糟糕得多。
    public static func answerableIDs(in round: [ShadowingDrill]) -> Set<String> {
        Set(round.compactMap { question(for: $0, in: round)?.drillID })
    }
}
