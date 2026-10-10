import Foundation

// MARK: - 韵律 / 连读 / 词级重音（④）
//
// 现状（`Pronunciation.swift`）：`stress` 与 `intonation` 两个维度**已经存在**，权重各 5%，
// 声学代理量也已经算出来了（`energyVariation` / `pitchRange` / `pitchVariation`）。
// 但它们给出的是**整句一个分数** —— 「这句有没有轻重音」「起伏够不够大」。
//
// 这里补的是三样更细的：
//   ① 词级重音：**哪个词**该重读而没重读（整句 → 逐词）
//   ② 韵律轮廓：起伏的**形状**（末句该降却升、通篇平读），不是幅度
//   ③ 连读启发式：哪里**该**连读、读出来连上了没有（只提示，不扣分）
//
// 硬边界：不碰 IO、不碰 ASR、不碰 UI —— 输入是「一组已经采好的词采样」，
// 由服务层把 `ASRWord` + 本地能量/基频分析映射过来。宁可少一层依赖，也不要再造第二份真源。

/// 一个词的一次采样：词本身 + 它在音频里的位置 + 那里的能量与基频。
///
/// ⚠️ 自带采样类型而不是直接用 `AIInterfaces.ASRWord`：`AIDomain` 不依赖 `AIInterfaces`，
/// 而且词时间戳的**可信度**由 `WordTimelineTrust` 单独判 —— 不该让「时间戳」这个数据
/// 悄悄混进领域层（记忆里的老坑：能力位为 true ≠ 数据可信）。
public struct ProsodyWordSample: Sendable, Equatable {
    /// 词（学习语言）。
    public var word: String
    /// 起始秒。
    public var start: Double
    /// 结束秒。
    public var end: Double
    /// 该词时段的平均能量（RMS，已归一到 0...1）。
    public var energy: Double
    /// 该词中点的基频（Hz）。没采到浊音帧为 nil（清辅音词本来就该是 nil）。
    public var pitch: Double?

    public init(word: String, start: Double, end: Double, energy: Double = 0, pitch: Double? = nil) {
        self.word = word
        self.start = start
        self.end = end
        self.energy = energy
        self.pitch = pitch
    }

    /// 时长（秒）；结束早于开始时为 0（不当负数用 —— 那种数据本身就不该进来）。
    public var duration: Double { max(end - start, 0) }
}

// MARK: - 词时间戳可信度（④ 的地基）

/// **词级分析能不能做** —— 先判这件事，再谈分析结果。
///
/// ⚠️ 为什么要单独判（`ASRWord` 自己的注释里写着）：`start` / `end` 的含义取决于 runtime，
/// 有的给的是**词级对齐**，有的只是把段级区间**按字符均摊**出来的估计值，
/// 并且明说「调用方不得把它当成精确对齐去打分」。
///
/// 拿均摊值当真对齐的后果不是「分数偏一点」，而是**结论是错的**：
/// "I want to **order** a **latte**" 里，按均摊切出来的 "order" 那一段恰好跨在重音上，
/// 于是我们会告诉学员「你的重音位置不对」—— 他改完真的会把重音改坏。
/// **给出假结论比不给更糟**，所以不可信时一律退化，不产出词级标记。
public enum WordTimelineTrust {

    /// 「时长 ÷ 字符数」的变异系数低于此值 ⇒ 判定为按字符均摊的估计。
    ///
    /// 取 0.12：均摊的残差基本是 0（cv < 0.02）；真对齐的时长长短不一，
    /// 即便是一句念得极匀的话，cv 也在 0.3 以上。
    public static let uniformRatioThreshold = 0.12

    /// 最少几个词才判得了（两个词看不出规律）。
    public static let minimumWords = 2

    public enum Verdict: Sendable, Equatable {
        /// 可信：是真正的词级对齐，可以做词级分析。
        case trusted
        /// 不可信：看起来是按字符均摊的估计值 → **一律退化**。
        case estimated
        /// 根本没法用（数据非法：时长为负、逆序、空）。
        case unusable
    }

    /// 判一次。
    public static func assess(_ samples: [ProsodyWordSample]) -> Verdict {
        guard samples.count >= minimumWords else { return .unusable }
        // 非法数据先出局：时长非正、或不是按时间递增 —— 这两种切片切出来的能量毫无意义。
        for (index, sample) in samples.enumerated() {
            guard sample.end > sample.start, sample.start.isFinite, sample.end.isFinite else {
                return .unusable
            }
            if index > 0, sample.start < samples[index - 1].start { return .unusable }
        }

        // 时长 ÷ 字符数：均摊估计里这个比值几乎是常数。
        let ratios = samples.map { sample -> Double in
            let characters = Double(max(sample.word.count, 1))
            return sample.duration / characters
        }
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        guard mean > 0 else { return .unusable }
        let variance = ratios.reduce(0) { $0 + pow($1 - mean, 2) } / Double(ratios.count)
        let cv = sqrt(variance) / mean
        return cv < uniformRatioThreshold ? .estimated : .trusted
    }

    /// 能不能做词级分析（等价于 `assess(...) == .trusted`，换个说法给调用点读）。
    public static func canAnalyze(_ samples: [ProsodyWordSample]) -> Bool {
        assess(samples) == .trusted
    }
}

// MARK: - 词级重音（④）

/// 一个词的重音判定。
public struct WordStressMark: Codable, Sendable, Equatable, Identifiable {

    /// 重音档位。
    public enum Level: String, Codable, Sendable, Equatable, CaseIterable {
        /// 该重读而重读了。
        case stressed
        /// 正常（既不重也不弱）。
        case normal
        /// 该弱而弱了 —— 「读成每个词一样重」是最常见的语调问题。
        case reduced

        public var displayName: String {
            switch self {
            case .stressed: "重读"
            case .normal: "正常"
            case .reduced: "弱读"
            }
        }
    }

    public var word: String
    public var level: Level
    /// 相对句内中位数的强度比（1 = 与中位持平）。
    public var ratio: Double

    public var id: String { word + "\u{1}" + level.rawValue }

    public init(word: String, level: Level, ratio: Double) {
        self.word = word
        self.level = level
        self.ratio = ratio
    }
}

/// 逐词重音：把「整句一个音量起伏数」换成「哪个词重、哪个词轻」。
public enum WordStressAnalyzer {

    /// 判「重读」的倍数（相对句内中位数）。
    public static let stressedRatio = 1.35
    /// 判「弱读」的倍数。
    public static let reducedRatio = 0.70
    /// 少于这么多词不做逐词判定（两三个词没有「重读分布」可言）。
    public static let minimumWords = 3

    /// 逐词重音的**绝对**能量下限：低于它算静音、不参与判定。
    ///
    /// ⚠️ 必须有这道绝对闸（而不只是 `energy > 0`）：录音里总有一点底噪，
    /// 振幅 1e-3 的「静音段」能量也大于 0，只判 `> 0` 会把一片寂静判成
    /// 「三个词读得一样重」。真正的底噪阈值只有一个真源（`SpeechAnalyzer.absoluteFloor`），
    /// 由开窗那层传进来。
    public static let minimumEnergyFloor = 0.005

    public static func analyze(
        _ samples: [ProsodyWordSample],
        minimumEnergy: Double = WordStressAnalyzer.minimumEnergyFloor
    ) -> [WordStressMark] {
        guard samples.count >= minimumWords else { return [] }
        // 低于绝对底噪的帧不算「这个词」（不等于整句静音，也不等于这个词没发声）。
        let voiced = samples.filter { $0.energy > minimumEnergy }
        guard voiced.count >= minimumWords else { return [] }

        let energies = voiced.map(\.energy)
        let median = Self.median(energies)
        guard median > 0 else { return [] }

        return voiced.map { sample in
            let ratio = sample.energy / median
            let level: WordStressMark.Level
            if ratio >= stressedRatio {
                level = .stressed
            } else if ratio <= reducedRatio {
                level = .reduced
            } else {
                level = .normal
            }
            return WordStressMark(word: sample.word, level: level, ratio: ratio)
        }
    }

    /// 中位数（**不用平均**：一句里一个特别响的词会把平均拉高，其余全被误判成弱读）。
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

// MARK: - 韵律轮廓（④）

/// 一句话的音高形状。
public struct IntonationContour: Codable, Sendable, Equatable {

    public enum Shape: String, Codable, Sendable, Equatable, CaseIterable {
        /// 降调（陈述句的常态）。
        case falling
        /// 升调。
        case rising
        /// 平读（起伏过小 —— 听起来像在念稿）。
        case flat

        public var displayName: String {
            switch self {
            case .falling: "降调"
            case .rising: "升调"
            case .flat: "平读"
            }
        }
    }

    public var shape: Shape
    /// 首尾斜率（半音 / 词）。正 = 升，负 = 降。
    public var slope: Double
    /// 轮廓点（每词中点的相对音高，单位半音，相对首词）。
    public var points: [Double]

    public init(shape: Shape, slope: Double, points: [Double]) {
        self.shape = shape
        self.slope = slope
        self.points = points
    }
}

/// 韵律轮廓：起伏的**形状**，不是幅度。
public enum IntonationAnalyzer {

    /// 少于这么多词不给轮廓（两三个词看不出走向）。
    public static let minimumWords = 3
    /// 斜率绝对值小于此值算「平」。
    public static let flatSlope = 0.6
    /// 首尾落差（半音）小于此值也算「平」—— 斜率平但整体起伏大的，仍算有起伏。
    public static let flatSpread = 2.0

    /// 轮廓（够不上条件时返回 nil —— **宁可不给，也不要给一个假的**）。
    public static func contour(_ samples: [ProsodyWordSample]) -> IntonationContour? {
        guard samples.count >= minimumWords else { return nil }
        let voiced = samples.compactMap { sample -> (index: Int, hz: Double)? in
            guard let pitch = sample.pitch, pitch > 0, pitch.isFinite else { return nil }
            return (samples.firstIndex(of: sample) ?? 0, pitch)
        }
        // 至少要有两个点才谈得上「走向」；清音词（the / a）没基频是正常的。
        guard voiced.count >= 2 else { return nil }

        let sorted = voiced.sorted { $0.index < $1.index }
        let semitones = sorted.map { 12 * log2($0.hz) }
        guard let first = semitones.first, let last = semitones.last else { return nil }
        let points = semitones.map { $0 - first }
        let span = max(semitones.count - 1, 1)
        let slope = (last - first) / Double(span)
        let spread = (semitones.max() ?? 0) - (semitones.min() ?? 0)

        let shape: IntonationContour.Shape
        if abs(slope) < flatSlope, spread < flatSpread {
            shape = .flat
        } else {
            shape = slope > 0 ? .rising : .falling
        }
        return IntonationContour(shape: shape, slope: slope, points: points)
    }
}

// MARK: - 韵律加分（④，不进总分）

/// 韵律加分（0...10）。
///
/// ⚠️ **刻意不计入 `PronunciationReport.overall`**（用户 2026-10-10 拍板「提一点」时定的口径）：
/// 七个维度与权重**一个都不动**。理由是历史可比 —— 一改权重，同一段录音的分数就会变，
/// 用户看到的是「我什么都没做，成绩掉了」。
/// 独立加分项既给了正反馈，又不破坏任何历史口径。
public enum ProsodyBonus {

    /// 加分上限。
    public static let maximum = 10.0
    /// 连读占的分（按连上的比例）。
    public static let linkingShare = 3.0
    /// 韵律占的分（非平读即得满）。
    public static let contourShare = 3.0
    /// 重音占的分（既有重读、也有弱读 = 有轻重层次）。
    public static let stressShare = 4.0

    /// 加分（0...10）。**只加不扣** —— 连读过判也只提示（见 `LinkingHeuristic`）。
    public static func score(_ analysis: ProsodyAnalysis?) -> Double {
        guard let analysis else { return 0 }
        var result = 0.0

        if let linked = analysis.linkedCount, !analysis.linking.isEmpty {
            result += linkingShare * Double(linked) / Double(analysis.linking.count)
        }
        if let contour = analysis.contour, contour.shape != .flat {
            result += contourShare
        }
        let hasStressed = analysis.stress.contains { $0.level == .stressed }
        let hasReduced = analysis.stress.contains { $0.level == .reduced }
        if hasStressed, hasReduced {
            result += stressShare
        }
        return min(result, maximum)
    }

    /// 一句话说明这个加分是怎么来的（UI 展示用；nil = 没有可说的）。
    public static func reason(_ analysis: ProsodyAnalysis?) -> String? {
        guard let analysis, !analysis.isEmpty else { return nil }
        var parts: [String] = []
        if let contour = analysis.contour { parts.append("语调\(contour.shape.displayName)") }
        let stressed = analysis.stress.filter { $0.level == .stressed }.count
        let reduced = analysis.stress.filter { $0.level == .reduced }.count
        if stressed + reduced > 0 { parts.append("重读 \(stressed) 个、弱读 \(reduced) 个") }
        if let linked = analysis.linkedCount, !analysis.linking.isEmpty {
            parts.append("连读 \(linked)/\(analysis.linking.count) 处")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - 连读启发式（④）

/// 一处「该连读」的位置。
public struct LinkingSpan: Codable, Sendable, Equatable, Identifiable {

    /// 前一个词。
    public var firstWord: String
    /// 后一个词。
    public var secondWord: String
    /// 两词之间的间隙（秒）。
    public var gap: Double
    /// 读出来时**连上了**没有（间隙小于阈值）。
    public var didLink: Bool

    /// 一对词的键。ⓘ `id` 与逐词展示的查表**共用这一个拼法** ——
    /// 两处各写一次的话，改了其中一处就会静默查不到（表现为「连读标记整条不显示」）。
    public static func key(firstWord: String, secondWord: String) -> String {
        firstWord + "\u{1}" + secondWord
    }

    public var id: String { Self.key(firstWord: firstWord, secondWord: secondWord) }

    public init(firstWord: String, secondWord: String, gap: Double, didLink: Bool) {
        self.firstWord = firstWord
        self.secondWord = secondWord
        self.gap = gap
        self.didLink = didLink
    }
}

/// 连读候选：文本层「该连」＋声学层「连没连」。
///
/// ⚠️ **这是启发式，不是连读识别**（用户 2026-10-10 拍板）：真正的连读要 forced alignment
/// 与音素模型。这里判的是「按英语习惯这里该连读」＋「你读出来中间断开了吗」，
/// **只提示、不扣分** —— 判错一次的代价不能是扣分。
public enum LinkingHeuristic {

    /// 间隙小于此值（秒）算「读连上了」。
    public static let linkedGap: Double = 0.06

    /// 元音字母（词首判元音用）。
    public static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// 哪些连读位置**该**连（纯文本层：前词辅音结尾 + 后词元音开头）。
    ///
    /// 例：`pick it up` / `an apple` / `not at all`。
    public static func isLinkingPair(_ lhs: String, _ rhs: String) -> Bool {
        endsWithConsonant(lhs) && startsWithVowel(rhs)
    }

    /// 从采样里找出所有「该连读」的位置，并判断读出来连没连。
    public static func spans(_ samples: [ProsodyWordSample]) -> [LinkingSpan] {
        guard samples.count >= 2 else { return [] }
        var result: [LinkingSpan] = []
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            guard isLinkingPair(previous.word, current.word) else { continue }
            let gap = max(current.start - previous.end, 0)
            result.append(LinkingSpan(
                firstWord: previous.word,
                secondWord: current.word,
                gap: gap,
                didLink: gap < linkedGap
            ))
        }
        return result
    }

    /// 该连读的处数里，连上了几处（`nil` = 一个候选都没有，别显示「0/0」）。
    public static func linkedCount(_ spans: [LinkingSpan]) -> Int? {
        guard !spans.isEmpty else { return nil }
        return spans.filter(\.didLink).count
    }

    /// 词尾是辅音吗（只看最后一个字母，忽略标点）。
    public static func endsWithConsonant(_ word: String) -> Bool {
        guard let last = word.last(where: { $0.isLetter }) else { return false }
        guard let scalar = last.lowercased().first, scalar.isLetter else { return false }
        return !vowels.contains(scalar)
    }

    /// 词首是元音吗。`y` 按辅音处理 —— "you" 开头在英语里确实读 /j/ 辅音。
    public static func startsWithVowel(_ word: String) -> Bool {
        guard let first = word.first(where: { $0.isLetter }) else { return false }
        guard let scalar = first.lowercased().first, scalar.isLetter else { return false }
        return vowels.contains(scalar)
    }
}

// MARK: - 逐词展示行（④ 的 UI 侧数据）

/// 一个词在「逐词标注」里的完整样子：词 + 重音档位 + 与**后一个词**之间的连读。
///
/// 为什么要在领域层把三份数据并成一行（而不是让 UI 自己拼）：
/// ① 对齐是**有判据的**（`stress` 是 `words` 的**顺序子集**，按游标走而不是按名字查），
///    写错的表现是「重音标在隔壁那个词上」——界面看不出错，但学员照着改就改错了；
/// ② 并成纯函数之后单测能直接钉「第 i 行是不是那个词、后面有没有连读」，
///    离屏渲染只管「画出来没有」，两层各管一件事。
public struct ProsodyRow: Sendable, Equatable, Identifiable {

    /// 在句子里的位次（也是 `id` —— 同一个词可以在一句里出现两次，词本身不能当 id）。
    public var index: Int
    public var word: String
    /// 重音档位。`nil` = 这一个词没量到（整词静音 / 被绝对底噪滤掉了），
    /// **不许画成「正常」** —— 那是把「没量到」谎报成「读得刚好」。
    public var level: WordStressMark.Level?
    /// 与后一个词之间的「该连读」位置（没有就是 nil）。
    public var linkAfter: LinkingSpan?

    public var id: Int { index }

    public init(
        index: Int,
        word: String,
        level: WordStressMark.Level? = nil,
        linkAfter: LinkingSpan? = nil
    ) {
        self.index = index
        self.word = word
        self.level = level
        self.linkAfter = linkAfter
    }

    /// 读屏一句话：先说词、再说重音、再说连读提示。
    public var accessibilityLabel: String {
        var line = word
        if let level { line += "，\(level.displayName)" }
        if let link = linkAfter {
            line += link.didLink ? "，与后一个词连读" : "，与后一个词可以连读"
        }
        return line
    }
}

extension ProsodyAnalysis {

    /// 逐词展示行：把「词序列 + 重音 + 连读」并成一条 UI 能直接画的序列。
    ///
    /// - 词序列取 `words`；老数据里 `words` 为空时退回 `stress` 的词（那时至少还有重音可画）。
    /// - 重音按**顺序子集**对齐：`stress` 是 `words` 滤掉静音词后的结果，
    ///   所以逐词比对、游标只在词对得上时才前进 —— 静音词留在行里、档位是 `nil`。
    /// - 连读挂在**前一个词**上（`linkAfter`），这样它永远跟着前一个词换行，不会孤立跑到下一行。
    public var rows: [ProsodyRow] {
        let sequence = words.isEmpty ? stress.map(\.word) : words
        guard !sequence.isEmpty else { return [] }

        var links: [String: LinkingSpan] = [:]
        for span in linking { links[span.id] = span }

        var cursor = 0
        return sequence.enumerated().map { index, word in
            var level: WordStressMark.Level?
            if cursor < stress.count, stress[cursor].word == word {
                level = stress[cursor].level
                cursor += 1
            }
            let linkAfter: LinkingSpan? = index + 1 < sequence.count
                ? links[LinkingSpan.key(firstWord: word, secondWord: sequence[index + 1])]
                : nil
            return ProsodyRow(index: index, word: word, level: level, linkAfter: linkAfter)
        }
    }
}