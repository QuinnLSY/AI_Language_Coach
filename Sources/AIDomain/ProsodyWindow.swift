import Foundation

// MARK: - 逐词开窗（④ 的声学侧）
//
// `SpeechAnalyzer` 算的是**整句**一个数（能量起伏、基频起伏）。
// 这里把同一套分帧与自相关**按词的时间戳再切一遍**，得到逐词的能量与基频。
//
// ⚠️ 为什么不改 `SpeechAnalyzer`、也不在服务层重写一遍：
// `frameEnergies` / `fundamentalFrequency` / `median` 都是 AIDomain 的 **internal** 函数，
// 同模块这里直接调用 —— **分帧参数与基频算法只有一份**，不另立真相。
// （服务层拿不到它们：它们不是 public。）

/// 一句话的韵律分析结果。
public struct ProsodyAnalysis: Codable, Sendable, Equatable {

    /// **这一遍念下来的词序列**（`ASRWord` 的顺序，未过滤）。
    ///
    /// ⚠️ 为什么要把「词本身」也存一份（`stress` 里其实也有词）：`stress` 是
    /// **过滤掉静音词之后**的子集，`linking` 又只有「该连读的**词对**」——
    /// 两者都不是完整序列。逐词标注要在**句子原本的词序**上把重音与连读并起来，
    /// 光靠这两份拼不出来（少词的那一处会静默错位，界面看不出来，指向的是错的那个词）。
    public var words: [String]
    /// 逐词重音（可信度不够时为空）。
    public var stress: [WordStressMark]
    /// 韵律轮廓（够不上条件时为 nil）。
    public var contour: IntonationContour?
    /// 连读候选与实际是否连上。
    public var linking: [LinkingSpan]

    public init(
        words: [String] = [],
        stress: [WordStressMark] = [],
        contour: IntonationContour? = nil,
        linking: [LinkingSpan] = []
    ) {
        self.words = words
        self.stress = stress
        self.contour = contour
        self.linking = linking
    }

    // `words` 是后加的字段：老 JSON 里没有它 → 空序列（不叫「零分」，也不该让整份读不出来）。
    private enum CodingKeys: String, CodingKey {
        case words, stress, contour, linking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        words = try container.decodeIfPresent([String].self, forKey: .words) ?? []
        stress = try container.decodeIfPresent([WordStressMark].self, forKey: .stress) ?? []
        contour = try container.decodeIfPresent(IntonationContour.self, forKey: .contour)
        linking = try container.decodeIfPresent([LinkingSpan].self, forKey: .linking) ?? []
    }

    /// 连读候选里连上了几处（nil = 没有候选，别显示「0/0」）。
    public var linkedCount: Int? { LinkingHeuristic.linkedCount(linking) }

    /// 有没有任何东西可展示。
    public var isEmpty: Bool { stress.isEmpty && contour == nil && linking.isEmpty }
}

/// 把录音按词切开，逐词填上能量与基频，并给出韵律分析。
public enum ProsodyWindowAnalyzer {

    /// 逐词分析：**时间戳不可信就返回 nil**。
    ///
    /// - Parameters:
    ///   - words: 带 `start` / `end` 的词（`energy` / `pitch` 会被覆盖）。
    ///   - pcm: 录音采样（与 `SpeechAnalyzer.analyze` 同一份）。
    ///   - sampleRate: 采样率。
    /// - Returns: nil = 时间戳不可信 / 数据不足 / 静音 —— **宁可不给也不给假结论**。
    public static func analysis(
        words: [ProsodyWordSample],
        pcm: [Float],
        sampleRate: Double
    ) -> ProsodyAnalysis? {
        let annotated = annotate(words, pcm: pcm, sampleRate: sampleRate)
        // ⚠️ 判可信度用的是**原始时间戳**（`words`），不是切完之后的 ——
        // 切完的 energy/pitch 不影响时间戳本身，但顺序写反会让人以为判的是别的。
        guard WordTimelineTrust.canAnalyze(words) else { return nil }
        let result = ProsodyAnalysis(
            words: annotated.map(\.word),
            // 底噪阈值只有一个真源：`SpeechAnalyzer.absoluteFloor`。
            stress: WordStressAnalyzer.analyze(annotated, minimumEnergy: Double(SpeechAnalyzer.absoluteFloor)),
            contour: IntonationAnalyzer.contour(annotated),
            linking: LinkingHeuristic.spans(annotated)
        )
        return result.isEmpty ? nil : result
    }

    /// 逐词填上 `energy` 与 `pitch`（纯函数；时间戳非法时原样返回，不猜）。
    public static func annotate(
        _ words: [ProsodyWordSample],
        pcm: [Float],
        sampleRate: Double
    ) -> [ProsodyWordSample] {
        guard !words.isEmpty, !pcm.isEmpty, sampleRate > 0 else { return words }
        let frameLength = max(Int(sampleRate * SpeechAnalyzer.frameDuration), 2)
        let hop = max(Int(sampleRate * SpeechAnalyzer.hopDuration), 1)
        guard pcm.count >= frameLength else { return words }

        let energies = SpeechAnalyzer.frameEnergies(pcm, frameLength: frameLength, hop: hop)
        guard !energies.isEmpty else { return words }
        // 逐帧基频：一次算全（词之间不重叠，切片即可）。
        //
        // ⚠️ **必须带能量闸**：`fundamentalFrequency` 只看归一化自相关峰，
        // 振幅 1e-3 的纯正弦照样能找到完美的峰 → 静音段会被判成「有基频」。
        // 整句那条路是靠 `mask`（能量阈值）限定「哪些帧算有声」才没这个问题
        // （见 `analyze()`），逐帧这里必须**自己补上那道闸**，否则静音词会拿到基频。
        let pitches: [Double?] = (0..<energies.count).map { index in
            let lower = index * hop
            guard lower + frameLength <= pcm.count else { return nil }
            guard energies[index] > SpeechAnalyzer.absoluteFloor else { return nil }
            return SpeechAnalyzer.fundamentalFrequency(
                Array(pcm[lower..<(lower + frameLength)]),
                sampleRate: sampleRate,
                frameLength: frameLength
            )
        }

        return words.map { word in
            var copy = word
            let range = frameRange(
                start: word.start, end: word.end,
                frameCount: energies.count, hop: hop, sampleRate: sampleRate
            )
            guard !range.isEmpty else { return copy }
            let slice = energies[range]
            copy.energy = Double(slice.reduce(0, +)) / Double(slice.count)
            let voiced = range.compactMap { pitches[$0] }
            copy.pitch = voiced.isEmpty ? nil : SpeechAnalyzer.median(voiced)
            return copy
        }
    }

    /// 词的时间区间 → 帧下标区间（按**帧中心**落在区间内判定）。
    static func frameRange(
        start: Double, end: Double,
        frameCount: Int, hop: Int, sampleRate: Double
    ) -> Range<Int> {
        guard end > start, frameCount > 0, hop > 0, sampleRate > 0 else { return 0..<0 }
        let frameDuration = Double(hop) / sampleRate
        let half = frameDuration / 2
        let lower = max(Int(((start - half) / frameDuration).rounded(.up)), 0)
        let upper = min(Int(((end - half) / frameDuration).rounded(.down)), frameCount)
        return lower..<max(upper, lower)
    }
}