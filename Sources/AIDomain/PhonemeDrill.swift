import Foundation

// MARK: - 顽固音素 · 最小对立对专项（第 ③ 条进阶）
//
// 动机：`PhonemeAssessment` 已经做到音素级（DP 对齐、漏读不标红），每次跟读的
// 逐音素得分也都落了库（`ShadowingAttempt.pronunciation`）。但这些数据一直只是
// 「这一次念得怎么样」，从来没有被**跨次聚合**过 —— 学员看不到「我哪个音老发错」，
// 练习也就永远停在泛泛跟读上。
//
// 中文母语者的发音问题高度集中在少数几个音上（θ/s、r/l、v/w…），
// 针对这几个音做**最小对立对**（minimal pair）训练，提分远快于泛读。
//
// 本文件全是纯函数与纯数据：不碰模型、不碰 IO、不碰 UI，可脱机单测。

// MARK: - 顽固音素

/// 一个「老发错」的音。
public struct PhonemeWeakness: Sendable, Equatable, Identifiable {

    /// ARPAbet **基音素**（去过重音数字，如 `TH`）；用它做 id，同一个音的重读/弱读算一处。
    public let phoneme: String
    /// 念错的次数（`PhonemeMark.poor`）。
    public var missCount: Int
    /// 这个音总共被评过多少次。
    public var sampleCount: Int
    /// 平均分 0...1。
    public var averageScore: Double

    public var id: String { phoneme }

    /// 展示用 IPA（`TH` → `θ`）。
    public var display: String { PhonemeDisplay.ipa(for: phoneme) }

    /// 错率 0...1。
    public var missRate: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(missCount) / Double(sampleCount)
    }

    public init(phoneme: String, missCount: Int, sampleCount: Int, averageScore: Double) {
        self.phoneme = phoneme
        self.missCount = missCount
        self.sampleCount = sampleCount
        self.averageScore = min(max(averageScore, 0), 1)
    }
}

// MARK: - 聚合

/// 把多次跟读的音素得分聚成「顽固音素」。
public enum PhonemeWeaknessAnalyzer {

    /// 一个音至少被评过这么多次才下判断。
    ///
    /// 只出现一两次就下结论是噪声：那可能只是那一次没录清楚。
    public static let minSamples = 3
    /// 至少错这么多次才算「顽固」—— 错一次只是失手。
    public static let minMisses = 2

    /// 从若干次发音报告里挑出最该练的几个音。
    ///
    /// - Parameters:
    ///   - reports: 历史发音报告（含逐词音素明细）；没有音素能力的那些报告自然被跳过。
    ///   - includeEstimated: 是否采纳**推断**音素（`.inferred`）。
    ///     推断通道不依赖发音模型，是多数用户唯一拿得到的音素数据，默认采纳；
    ///     关掉它就只剩云端实测，数据会更准但也更少。
    ///   - limit: 最多返回几个（UI 只放得下两三行）。
    /// - Returns: 按「错得多 + 分得低」排序的顽固音素；一条都不够格时返回空数组。
    public static func weaknesses(
        from reports: [PronunciationReport],
        includeEstimated: Bool = true,
        limit: Int = 3
    ) -> [PhonemeWeakness] {
        guard limit > 0 else { return [] }

        // 累积：基音素 → (错次, 样本数, 得分总和)
        var misses: [String: Int] = [:]
        var samples: [String: Int] = [:]
        var totals: [String: Double] = [:]

        for report in reports {
            if !includeEstimated, report.phonemeSource == .inference { continue }
            for word in report.phonemeWords {
                // ⚠️ 只统计**配上对**的词：
                // 漏读（missing）是「没读出来」，多说（extra）是「说了别的话」，
                // 两者都不是「这个音没发对」—— 算进来会把没开口诬陷成发音差。
                guard word.status == .aligned else { continue }
                for rating in word.phonemes {
                    let base = PhonemeFeatures.base(rating.phoneme)
                    guard !base.isEmpty else { continue }
                    samples[base, default: 0] += 1
                    totals[base, default: 0] += rating.score
                    if PhonemeMark.from(score: rating.score) == .poor {
                        misses[base, default: 0] += 1
                    }
                }
            }
        }

        let candidates = samples.compactMap { phoneme, count -> PhonemeWeakness? in
            let miss = misses[phoneme] ?? 0
            guard count >= minSamples, miss >= minMisses else { return nil }
            return PhonemeWeakness(
                phoneme: phoneme,
                missCount: miss,
                sampleCount: count,
                averageScore: (totals[phoneme] ?? 0) / Double(count)
            )
        }

        // 排序口径：**错得多**优先（那才是「顽固」的定义），同错次再看**分得低**，
        // 两者都相同就取样本多的（证据更足）。
        return candidates.sorted { lhs, rhs in
            if lhs.missCount != rhs.missCount { return lhs.missCount > rhs.missCount }
            if lhs.averageScore != rhs.averageScore { return lhs.averageScore < rhs.averageScore }
            return lhs.sampleCount > rhs.sampleCount
        }.prefix(limit).map { $0 }
    }
}

// MARK: - 最小对立对

/// 一对只差一个音的词（`think` / `sink`）。
///
/// 之所以用「只差一个音」的词对：练的是**分辨与发出那一个音**，
/// 句子里别的变量都被压到最小，进步才看得出来。
public struct MinimalPair: Sendable, Equatable, Identifiable {

    public var left: String
    public var right: String
    /// 左词的母语释义。
    public var leftMeaning: String
    /// 右词的母语释义。
    public var rightMeaning: String
    /// 左词里被练的那个音素（ARPAbet 基音素）。
    public var leftPhoneme: String
    /// 右词里被练的那个音素。
    public var rightPhoneme: String

    public var id: String { "\(left)-\(right)" }

    /// 这一对在比哪两个音（IPA，展示用）。
    public var contrastDisplay: String {
        "\(PhonemeDisplay.ipa(for: leftPhoneme)) / \(PhonemeDisplay.ipa(for: rightPhoneme))"
    }

    public init(
        left: String,
        right: String,
        leftMeaning: String,
        rightMeaning: String,
        leftPhoneme: String,
        rightPhoneme: String
    ) {
        self.left = left
        self.right = right
        self.leftMeaning = leftMeaning
        self.rightMeaning = rightMeaning
        self.leftPhoneme = leftPhoneme
        self.rightPhoneme = rightPhoneme
    }

    /// 给定的音素是不是这对里的成员（左右任一）。
    public func involves(_ phoneme: String) -> Bool {
        let base = PhonemeFeatures.base(phoneme)
        return base == leftPhoneme || base == rightPhoneme
    }
}

/// 内置的最小对立对词表（中文母语者的高频难点）。
///
/// ⚠️ 顺序即**教学顺序**：同一个音素命中多对时取靠前那一对，所以把最典型、
/// 最容易听出差别的一对放前面。
///
/// ⚠️ 这些音素标注是人工标的，**不是从词库算出来的** —— 词库（`lexicon.json`）
/// 只收录本项目素材里出现过的词，think / sink 这类不一定在里面。
/// 正确性由测试用 `PhonemeFeatures.distance` 兜住：每一对必须是「近音但不同音」。
public enum MinimalPairCatalog {

    public static let pairs: [MinimalPair] = [
        MinimalPair(left: "think", right: "sink",
                    leftMeaning: "思考", rightMeaning: "水槽",
                    leftPhoneme: "TH",
                    rightPhoneme: "S"),
        MinimalPair(left: "three", right: "tree",
                    leftMeaning: "三", rightMeaning: "树",
                    leftPhoneme: "TH",
                    rightPhoneme: "T"),
        MinimalPair(left: "right", right: "light",
                    leftMeaning: "右边 / 正确", rightMeaning: "灯光 / 轻的",
                    leftPhoneme: "R",
                    rightPhoneme: "L"),
        MinimalPair(left: "very", right: "wary",
                    leftMeaning: "非常", rightMeaning: "警惕的",
                    leftPhoneme: "V",
                    rightPhoneme: "W"),
        MinimalPair(left: "sheep", right: "ship",
                    leftMeaning: "绵羊", rightMeaning: "船",
                    leftPhoneme: "IY",
                    rightPhoneme: "IH"),
        MinimalPair(left: "bed", right: "bad",
                    leftMeaning: "床", rightMeaning: "坏的",
                    leftPhoneme: "EH",
                    rightPhoneme: "AE"),
        MinimalPair(left: "sin", right: "sing",
                    leftMeaning: "罪", rightMeaning: "唱歌",
                    leftPhoneme: "N",
                    rightPhoneme: "NG"),
        MinimalPair(left: "food", right: "foot",
                    leftMeaning: "食物", rightMeaning: "脚",
                    leftPhoneme: "UW",
                    rightPhoneme: "UH"),
        MinimalPair(left: "see", right: "she",
                    leftMeaning: "看见", rightMeaning: "她",
                    leftPhoneme: "S",
                    rightPhoneme: "SH"),
        MinimalPair(left: "zip", right: "sip",
                    leftMeaning: "拉链", rightMeaning: "小口喝",
                    leftPhoneme: "Z",
                    rightPhoneme: "S"),
        MinimalPair(left: "they", right: "day",
                    leftMeaning: "他们", rightMeaning: "白天",
                    leftPhoneme: "DH",
                    rightPhoneme: "D"),
    ]

    /// 能练到某个音素的词对（保持词表顺序）。
    public static func pairs(for phoneme: String) -> [MinimalPair] {
        pairs.filter { $0.involves(phoneme) }
    }
}

// MARK: - 出题

/// 把一个「顽固音素」翻译成一轮可以跟读的练习。
public enum MinimalPairDrill {

    /// 一轮出几个词对（太多会变成机械重复，太少练不出分辨力）。
    public static let pairCount = 2

    /// 针对一个顽固音素生成跟读素材。
    ///
    /// 每个词单独一句：句子里塞进别的词会引入别的音素噪声，
    /// 这一轮要盯的**就是那一个音**。
    ///
    /// - Returns: 词对 × 2 条（`左词`、`右词`）；这个词素没有可用词对时返回空数组。
    public static func drills(
        for weakness: PhonemeWeakness,
        pairs: [MinimalPair] = MinimalPairCatalog.pairs,
        pairCount: Int = MinimalPairDrill.pairCount
    ) -> [ShadowingDrill] {
        let matched = pairs
            .filter { $0.involves(weakness.phoneme) }
            .prefix(max(pairCount, 1))

        var drills: [ShadowingDrill] = []
        for pair in matched {
            drills.append(
                ShadowingDrill(
                    id: "phoneme-\(weakness.phoneme.lowercased())-\(pair.left)",
                    text: pair.left.capitalized,
                    translation: pair.leftMeaning,
                    topic: "最小对立对 · \(pair.contrastDisplay)",
                    difficulty: 2,
                    focus: "留意 \(PhonemeDisplay.ipa(for: pair.leftPhoneme))"
                        + " —— 与 \(pair.right) 只差这一个音。"
                )
            )
            drills.append(
                ShadowingDrill(
                    id: "phoneme-\(weakness.phoneme.lowercased())-\(pair.right)",
                    text: pair.right.capitalized,
                    translation: pair.rightMeaning,
                    topic: "最小对立对 · \(pair.contrastDisplay)",
                    difficulty: 2,
                    focus: "留意 \(PhonemeDisplay.ipa(for: pair.rightPhoneme))"
                        + " —— 与 \(pair.left) 只差这一个音。"
                )
            )
        }
        return drills
    }
}
