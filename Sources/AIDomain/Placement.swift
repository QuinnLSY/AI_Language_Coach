import Foundation

// MARK: - 能力定位（placement，#229）
//
// 「我现在是 B1 吗」——这不是课程进度能回答的问题：
// 课程阶梯（`CurriculumLadder`）说的是「练过哪些关卡」，能力定位说的是
// 「凭你真实的输出（对话、词汇、发音），老师估你现在站在哪一档」。
// 两件事必须分开，而且**都必须是纯函数**：估算口径全部写在本文件里，UI 只展示。
//
// 设计取舍：
// - **轻量估算，不做考试**。placement 测试是重流程，与「随手打开进度页看一眼」的
//   使用场景不匹配；先用使用数据估，将来要正式定位再加自测。
// - **不确定就说不确定**。样本太少时 `level == nil`，UI 显示「还在观察中」——
//   硬给一个档位比没有档位更伤信任。
// - 各维度口径与 `ProgressAggregator.skillScores` **同一份**（语法 = 批注密度、
//   发音 = 评测均分……），不另立一套尺子，否则进度页会出现两个「语法水平」。

/// 能力定位的估算结果。
public struct PlacementEstimate: Sendable, Equatable {

    /// 估算出的当前档位；**nil = 样本不足，还在观察中**。
    public var level: CEFRLevel?
    /// 0...1 的综合分（只用来挑档位，UI 不把它当「考试分数」展示）。
    public var score: Double
    /// 样本是否足以给出档位。
    public var isConfident: Bool
    /// 估算依据（每条一句话，口径透明，UI 直接展示）。
    public var signals: [String]
    /// 距下一档最该补的事（按最弱的维度排，最多两三条）。
    public var gaps: [String]
    /// 下一档（已到 B2 则为 nil）。
    public var nextLevel: CEFRLevel?

    public init(
        level: CEFRLevel?,
        score: Double,
        isConfident: Bool,
        signals: [String],
        gaps: [String],
        nextLevel: CEFRLevel?
    ) {
        self.level = level
        self.score = min(max(score, 0), 1)
        self.isConfident = isConfident
        self.signals = signals
        self.gaps = gaps
        self.nextLevel = nextLevel
    }
}

public enum PlacementEstimator {

    // MARK: 样本门槛（低于任何一条都只「观察」，不给档位）

    /// 至少聊过多少轮。
    public static let minMessages = 25
    /// 至少用过多少天（不连续也行）。
    public static let minActiveDays = 3
    /// 词汇本至少收录多少词。
    public static let minVocabulary = 20

    // MARK: 各维度到下一档的「量尺」（各档的常见门槛，分段线性）

    /// 词汇量刻度：收录多少词大致对应哪一档（receptive 词量，含只认不会用的）。
    static let vocabularyScale: [(words: Int, score: Double)] = [
        (0, 0), (120, 0.25), (350, 0.5), (800, 0.75), (1500, 1)
    ]

    /// 开口轮次刻度：累计多少轮对话大致对应哪一档。
    static let messageScale: [(words: Int, score: Double)] = [
        (0, 0), (20, 0.25), (60, 0.5), (120, 0.75), (220, 1)
    ]

    /// 综合分到档位的分界线。
    static let levelThresholds: [(score: Double, level: CEFRLevel)] = [
        (0.22, .a1), (0.42, .a2), (0.62, .b1), (1.01, .b2)
    ]

    /// 估算能力定位。全部输入都来自 `ProgressSnapshot` 与词汇本统计 —— 不碰模型、不碰 IO。
    ///
    /// - Parameters:
    ///   - skills: 进度快照的五维技能分（语法 / 词汇 / 发音 / 跟读 / 流利度，带样本数）。
    ///   - totalMessages: 累计对话轮次。
    ///   - activeDays: 有练习的天数。
    ///   - vocabularyCount: 词汇本收录（去重）词数。
    ///   - masteredCount: 其中已掌握的词数。
    public static func estimate(
        skills: [SkillScore],
        totalMessages: Int,
        activeDays: Int,
        vocabularyCount: Int,
        masteredCount: Int
    ) -> PlacementEstimate {
        func skill(_ kind: SkillKind) -> SkillScore? {
            skills.first { $0.kind == kind }
        }

        // --- 各分量（0...1）；没有数据的维度**不参与加权**，而不是按 0 分拖累总评 ---
        var components: [(weight: Double, value: Double, signal: String, gap: String?)] = []

        // 语法：批注密度（skillScores 的同一口径：0.4 处/轮 = 0 分）。
        if let grammar = skill(.grammar), grammar.sampleCount > 0 {
            components.append((
                weight: 3,
                value: grammar.score,
                signal: "对话 \(grammar.sampleCount) 轮 · 每轮 \(String(format: "%.2f", (1 - grammar.score) * 0.4)) 处批注",
                gap: grammar.score < 0.6
                    ? "语法：批注还密 —— 每轮压到 0.2 处以内再谈上一档"
                    : nil
            ))
        }

        // 词汇：规模（55%）+ 掌握与释义覆盖（45%）。
        if vocabularyCount > 0 {
            let scale = piecewise(vocabularyScale, value: vocabularyCount)
            let quality = skill(.vocabulary)?.score ?? 0
            let nextWords = nextScaleValue(in: vocabularyScale.map { Double($0.words) }, current: vocabularyCount)
            components.append((
                weight: 3,
                value: 0.55 * scale + 0.45 * quality,
                signal: "词汇本 \(vocabularyCount) 词 · 已掌握 \(max(masteredCount, 0))",
                gap: scale < 0.7
                    ? "词汇：量还不够 —— 下一档常见量在 \(nextWords) 词上下"
                    : nil
            ))
        }

        // 开口量：累计轮次（聊得少，别的分都不足以定性）。
        if totalMessages > 0 {
            let volume = piecewise(messageScale, value: totalMessages)
            let nextTurns = nextScaleValue(in: messageScale.map { Double($0.words) }, current: totalMessages)
            components.append((
                weight: 2,
                value: volume,
                signal: "累计开口 \(totalMessages) 轮",
                gap: volume < 0.6 ? "开口：轮次还少 —— 下一档前希望攒到 \(nextTurns) 轮" : nil
            ))
        }

        // 口语输出：发音 + 流利度（都有样本才加权平均）。
        let pronunciation = skill(.pronunciation)
        let fluency = skill(.fluency)
        let outputSamples = (pronunciation?.sampleCount ?? 0) + (fluency?.sampleCount ?? 0)
        if outputSamples > 0 {
            let value = Self.weighted(pronunciation?.score, fluency?.score)
            components.append((
                weight: 2,
                value: value,
                signal: outputSamples == pronunciation?.sampleCount
                    ? "发音平均 \(Int((pronunciation!.score * 100).rounded())) 分（\(pronunciation!.sampleCount) 次）"
                    : "发音 / 流利度平均 \(Int((value * 100).rounded())) 分",
                gap: value < 0.5 ? "发音与流利度：多做几次跟读评测，把这一项撑起来" : nil
            ))
        }
        if outputSamples == 0 {
            // 完全没录过跟读 → 明确说出来，别让它静默缺席。
            // ⚠️ weight = 0：没数据不参与加权（按 0 分计会冤枉没录过音的学员），
            // 只作为「依据」与「差距」出现。
            components.append((weight: 0, value: 0, signal: "还没有跟读评测", gap: "发音与流利度：先录几次跟读，我才能听得出差距"))
        }

        // --- 汇总 ---
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        let score = totalWeight > 0 ? components.reduce(0) { $0 + $1.weight * $1.value } / totalWeight : 0
        var signals = components.map(\.signal)
        // 所有分量都拿不出真实数据（全是「还没有…」）时，给一句总述。
        if signals.allSatisfy({ $0.hasPrefix("还没有") }) {
            signals.append("还没有练习数据")
        }

        let confident = totalMessages >= minMessages
            && activeDays >= minActiveDays
            && vocabularyCount >= minVocabulary
        var level: CEFRLevel?
        if confident {
            level = levelThresholds.first { score < $0.score }?.level ?? .b2
        }

        // 距下一档：取分量顺序里最先冒出来的两条建议（语法 / 词汇 / 开口 / 发音）。
        let gaps = components.compactMap(\.gap).prefix(2)
        let target = level?.nextLevel ?? (confident ? CEFRLevel.b2.nextLevel : CEFRLevel.a1)
        return PlacementEstimate(
            level: level,
            score: score,
            isConfident: confident,
            signals: Array(signals.prefix(5)),
            gaps: Array(gaps),
            nextLevel: target
        )
    }

    // MARK: 内部

    /// 刻度里比 `current` 大的下一个节点值（向上取整到整数）；已在顶端则返回顶端值。
    static func nextScaleValue(in scale: [Double], current: Int) -> Int {
        let value = Double(current)
        if let next = scale.first(where: { $0 > value }) {
            return Int(next)
        }
        return Int(scale.last ?? value)
    }

    /// 分段线性映射（`scale` 按 value 升序）。
    static func piecewise(_ scale: [(words: Int, score: Double)], value: Int) -> Double {
        let points = scale.map { (value: Double($0.words), score: $0.score) }
        guard let first = points.first, let last = points.last else { return 0 }
        if Double(value) <= first.value { return first.score }
        if Double(value) >= last.value { return last.score }
        for (lower, upper) in zip(points, points.dropFirst()) {
            if Double(value) < upper.value {
                let t = (Double(value) - lower.value) / max(upper.value - lower.value, 1)
                return lower.score + t * (upper.score - lower.score)
            }
        }
        return last.score
    }

    /// 两个可选分数的平均（只有一个就取那一个；都为 nil 返回 0）。
    static func weighted(_ a: Double?, _ b: Double?) -> Double {
        switch (a, b) {
        case let (x?, y?): return (x + y) / 2
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return 0
        }
    }
}

// MARK: - 档位小工具

extension CEFRLevel {

    /// 下一档（B2 之上没有 —— C1 不是本产品要解决的问题）。
    public var nextLevel: CEFRLevel? {
        switch self {
        case .a1: .a2
        case .a2: .b1
        case .b1: .b2
        case .b2: nil
        }
    }
}
