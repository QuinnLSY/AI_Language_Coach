import Foundation

// MARK: - 段落级影子跟读（#232）
//
// 一句一练练的是「这一句对不对」，但真实对话是**一整段**。段落模式补的就是这一层：
// 听一整段示范 → 一口气跟读整段 → 把整段识别结果**回填到每一句**，逐句给分。
//
// 难点在回填：整段识别出来的是一长串词，得判断「哪几个词属于第 1 句、哪几个属于第 2 句」。
// 这里用**保序切分 DP**：把识别词序列切成 N 段（每段对应一个参考句，允许为空），
// 最大化各段 LCS 命中总数。顺序不颠倒（学员不会先读第 3 句再读第 1 句还指望得分），
// 因此只需在「切点」上搜索，不需要做全排列。
//
// 全部是**纯函数**：不碰模型、不碰 IO、不碰麦克风，可以脱机完整单测。

/// 一个跟读段落：同一情景下连续的几句。
public struct ShadowingPassage: Sendable, Equatable, Identifiable {

    public var id: String
    /// 段落标题（情景名），为空时 UI 用「第 N 段」兜底。
    public var title: String
    public var difficulty: Int
    public var drills: [ShadowingDrill]

    public init(id: String, title: String = "", difficulty: Int = 1, drills: [ShadowingDrill] = []) {
        self.id = id
        self.title = title
        self.difficulty = ShadowingDrill.clamp(difficulty)
        self.drills = drills
    }

    /// 逐句参考文本（顺序即学员应当跟读的顺序）。
    public var sentences: [String] { drills.map(\.text) }

    /// 整段连起来的示范文本（听整段示范 / 发音评测的参考文本都用它）。
    public var text: String { sentences.joined(separator: " ") }

    /// 整段参考词数（与逐句 `referenceCount` 之和一致，是段落总分的**分母**）。
    public var wordCount: Int { drills.reduce(0) { $0 + ShadowingScorer.words($1.text).count } }

    /// 母语释义（逐句拼起来，跟读前先看懂整段在说什么）。
    public var translation: String {
        drills.map(\.translation).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 发音要点（去重后拼起来）。
    public var focus: String {
        var seen: Set<String> = []
        var items: [String] = []
        for drill in drills where !drill.focus.isEmpty && !seen.contains(drill.focus) {
            seen.insert(drill.focus)
            items.append(drill.focus)
        }
        return items.joined(separator: "；")
    }
}

/// 段落切分规则（纯函数）。
public enum ShadowingPassageRule {

    /// 一句素材属于哪个段落。
    ///
    /// 每日生成的 id 形如 `daily-{情景序号}-{句序号}` —— **按情景序号切**，
    /// 不按情景名：两个情景同名（模型很容易生成重复的 topic）时按名切会并成一段。
    /// 内置素材没有这种 id，退回按 `topic` 归段。
    public static func passageKey(for drill: ShadowingDrill) -> String {
        let parts = drill.id.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[0] == "daily" {
            return "\(parts[0])-\(parts[1])"
        }
        return "topic:\(drill.topic)"
    }

    /// 把每日句子切成段落，**保持原有顺序**（不重排 —— 换了顺序「第 2 段」就指不到原来那段了）。
    public static func passages(from drills: [ShadowingDrill]) -> [ShadowingPassage] {
        guard !drills.isEmpty else { return [] }
        var order: [String] = []
        var buckets: [String: [ShadowingDrill]] = [:]
        for drill in drills {
            let key = passageKey(for: drill)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(drill)
        }
        return order.map { key in
            let items = buckets[key] ?? []
            return ShadowingPassage(
                id: key,
                title: items.first?.topic ?? "",
                difficulty: items.map(\.difficulty).max() ?? 1,
                drills: items
            )
        }
    }
}

/// 整段落一次跟读的结果。
public struct ShadowingPassageResult: Sendable, Equatable {

    public var passageID: String
    public var title: String
    /// 逐句结果（顺序与段落里的句子一致）。
    public var sentences: [ShadowingComparison]
    /// 整段匹配率 0...1 = 各句命中词数之和 / 各句参考词数之和。
    public var accuracy: Double
    public var verdict: ShadowingVerdict
    /// 最弱那一句的下标（并列取靠前；没有句子时为 nil）。
    public var weakestIndex: Int?
    /// 整段反馈（点名最弱的一句 —— 「继续加油」这种空话对学习者没有信息量）。
    public var hint: String

    public init(
        passageID: String,
        title: String = "",
        sentences: [ShadowingComparison],
        accuracy: Double,
        verdict: ShadowingVerdict,
        weakestIndex: Int?,
        hint: String
    ) {
        self.passageID = passageID
        self.title = title
        self.sentences = sentences
        self.accuracy = min(max(accuracy, 0), 1)
        self.verdict = verdict
        self.weakestIndex = weakestIndex
        self.hint = hint
    }

    public var accuracyPercent: Int { Int((accuracy * 100).rounded()) }

    /// 整段命中词数 / 参考词数（UI 显示「跟上 28 / 32 个词」）。
    public var matched: Int { sentences.reduce(0) { $0 + $1.matched } }
    public var referenceCount: Int { sentences.reduce(0) { $0 + $1.referenceCount } }

    /// 整段识别文本（各句回填片段按序拼回，用于「我听到的」那一行）。
    ///
    /// 不另存一份原始串：段落模式认的是**回填后的切分**，拼回来的就是这个切分看到的全部内容，
    /// 存两份迟早出现「上面显示的和下面评分的不是一个东西」。
    public var recognizedText: String {
        sentences.map(\.recognizedText).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// 一次段落跟读的完整结果：逐句文本对齐 +（录到音频时的）整段发音评测。
public struct ShadowingPassageEvaluation: Sendable, Equatable {
    public var result: ShadowingPassageResult
    public var pronunciation: PronunciationReport?

    public init(result: ShadowingPassageResult, pronunciation: PronunciationReport? = nil) {
        self.result = result
        self.pronunciation = pronunciation
    }
}

/// 段落级对齐与判定（纯函数）。
public enum ShadowingPassageScorer {

    /// 一整段识别最多认多少个词（**兜底上限**，防止 ASR 发疯时 DP 跑到天荒地老）。
    ///
    /// 真实段落 4 句 ≈ 40 个参考词，学员再怎么重复也到不了这个数；
    /// 超出的部分截断 —— 那种量级的结果已经没有评测意义了。
    ///
    /// 定 120 而不是更大：切分 DP 是 O(句数 × 词数²)，200 词时实测接近 2 秒，
    /// 而 120 词已经是真实段落的三倍，再往上纯属为不可能的输入付账。
    public static let maxRecognizedWords = 120

    /// 把整段识别结果回填到每个参考句，逐句出 `ShadowingComparison`。
    ///
    /// - Returns: 与 `sentences` 一一对应的比对结果（顺序不变）。
    public static func align(sentences: [String], recognized: String) -> [ShadowingComparison] {
        let refs = sentences.map { ShadowingScorer.words($0) }
        guard !refs.isEmpty else { return [] }
        var hyp = ShadowingScorer.words(recognized)
        if hyp.count > maxRecognizedWords { hyp = Array(hyp.prefix(maxRecognizedWords)) }
        let n = refs.count
        // 单句段落走原路径即可（省掉一次 DP，行为也与一句一练完全一致）。
        guard n > 1 else {
            return [ShadowingScorer.compare(reference: sentences[0], recognized: recognized)]
        }
        let m = hyp.count

        /// 第 `i` 句对上识别片段 `[from, to)` 能命中几个词。
        func hit(_ i: Int, _ from: Int, _ to: Int) -> Int {
            guard from < to else { return 0 }
            return ShadowingScorer.lcsMatchedCount(refs[i], Array(hyp[from..<to]))
        }

        // best[i][j]：从第 i 句起、识别词从第 j 个开始，最多能命中多少词。
        // choice[i][j]：达到最优时第 i 句吃到哪里（切点）。
        var best = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n)
        var choice = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n)

        // 最后一句吃掉剩余的**全部**词：多说的词要挂在最后一句上让用户看见，
        // 而不是被悄悄丢掉（丢掉的话用户以为自己没多说）。
        for j in 0...m {
            best[n - 1][j] = hit(n - 1, j, m)
            choice[n - 1][j] = m
        }
        for i in stride(from: n - 2, through: 0, by: -1) {
            for j in 0...m {
                var bestScore = -1
                var bestCut = j
                // ⚠️ 平局取**更大的切点**（`>=`）：多说的废词要记在它发生的那一句头上。
                // 反过来的话，学员把第 1 句连读三遍产生的几十个废词会被摊到第 2、3 句，
                // 反馈就变成「第 2 句最弱」—— 而人家根本还没读到第 2 句。
                for cut in j...m {
                    let score = hit(i, j, cut) + best[i + 1][cut]
                    if score >= bestScore {
                        bestScore = score
                        bestCut = cut
                    }
                }
                best[i][j] = bestScore
                choice[i][j] = bestCut
            }
        }

        // 回溯切点 → 逐句比对。
        var comparisons: [ShadowingComparison] = []
        comparisons.reserveCapacity(n)
        var start = 0
        for i in 0..<n {
            let end = min(max(choice[i][start], start), m)
            let spanText = start < end ? hyp[start..<end].joined(separator: " ") : ""
            comparisons.append(ShadowingScorer.compare(reference: sentences[i], recognized: spanText))
            start = end
        }
        return comparisons
    }

    /// 评一段：逐句比对 + 整段总分 + 点名最弱的一句。
    public static func evaluate(passage: ShadowingPassage, recognized: String) -> ShadowingPassageResult {
        let sentences = passage.sentences
        let comparisons = align(sentences: sentences, recognized: recognized)
        let referenceCount = comparisons.reduce(0) { $0 + $1.referenceCount }
        let accuracy = referenceCount == 0 ? 0 : Double(comparisons.reduce(0) { $0 + $1.matched }) / Double(referenceCount)
        let verdict = ShadowingScorer.verdict(for: accuracy)

        var weakest: Int?
        if !comparisons.isEmpty {
            var index = 0
            for i in 1..<comparisons.count where comparisons[i].accuracy < comparisons[index].accuracy {
                index = i
            }
            weakest = index
        }
        return ShadowingPassageResult(
            passageID: passage.id,
            title: passage.title,
            sentences: comparisons,
            accuracy: accuracy,
            verdict: verdict,
            weakestIndex: weakest,
            hint: hint(
                verdict: verdict,
                weakest: weakest,
                weakestAccuracy: weakest.map { comparisons[$0].accuracy },
                isSilent: ShadowingScorer.words(recognized).isEmpty,
                hasContent: referenceCount > 0
            )
        )
    }

    /// 整段反馈。**点名最弱的一句** —— 段落模式下「整体还行」是最没用的评价。
    public static func hint(
        verdict: ShadowingVerdict,
        weakest: Int?,
        weakestAccuracy: Double?,
        isSilent: Bool,
        hasContent: Bool
    ) -> String {
        guard hasContent else { return "这段素材没有可跟读的内容" }
        if isSilent { return "没有听到声音，凑近麦克风再把整段说一次吧" }
        guard let weakest, let accuracy = weakestAccuracy else {
            return "再听一遍整段示范，注意句与句之间的停顿"
        }
        let percent = Int((accuracy * 100).rounded())
        switch verdict {
        case .perfect:
            return "整段都跟上了，用这个状态再练下一段"
        case .great:
            return "整段很接近了，第 \(weakest + 1) 句（\(percent)%）再听一遍示范"
        case .keepGoing:
            return "第 \(weakest + 1) 句最弱（\(percent)%），先单独把这句练熟，再整段连起来"
        case .retry:
            return "这次和示范差得有点多，先分句听两遍，重点练第 \(weakest + 1) 句（\(percent)%）"
        }
    }
}
