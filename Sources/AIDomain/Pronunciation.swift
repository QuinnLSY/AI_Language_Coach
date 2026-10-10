import Foundation

// MARK: - 发音评测（Pronunciation Engine，第 23 步）
//
// 设计依据：Implementation Plan §23「Pronunciation Engine」。
//
// 计划里有一条硬要求：**首版不得依赖任何单一发音模型**。所以这里的打分只建立在
// 「录音里量得出来、且换个模型也依然成立」的东西上：
//
//   文本层   → 词准确度（复用 `ShadowingScorer` 的逐词对齐，全项目一份口径）
//   声学层   → 语速（有声时长里的每分钟词数）、停顿次数与最长停顿、有声占比、
//              音高起伏（自相关基频 → 半音）、音量起伏（重音节奏的代理量）
//
// 音素级打分（`PhonemeRating`）留成一个**可选输入**：将来接上 GOP / wav2vec 之类的
// 音素模型，只要把结果喂进 `PronunciationScorer.report(...)`，其余链路一字不改。
//
// 本文件全是纯函数与纯数据：不碰模型、不碰 IO、不碰 UI，因此可以脱机单测。

/// 发音评测的维度。UI 只负责渲染，文案集中在这里维护。
public enum PronunciationDimension: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {

    /// 词准确度：跟上 / 漏词 / 换词（文本层，无需模型）。
    case wordAccuracy
    /// 音准：音素级得分（需要音素模型，首版可为空）。
    case phonemeAccuracy
    /// 语速：有声时长里的每分钟词数。
    case speakingSpeed
    /// 停顿：句中停顿次数与最长停顿。
    case pauses
    /// 流利度：有声占比 + 填充词。
    case fluency
    /// 重音节奏：音量起伏是否够「有轻有重」。
    case stress
    /// 语调起伏：音高变化的幅度是否够自然。
    case intonation

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wordAccuracy: "词准确度"
        case .phonemeAccuracy: "音准"
        case .speakingSpeed: "语速"
        case .pauses: "停顿"
        case .fluency: "流利度"
        case .stress: "重音节奏"
        case .intonation: "语调起伏"
        }
    }

    public var symbol: String {
        switch self {
        case .wordAccuracy: "text.badge.checkmark"
        case .phonemeAccuracy: "waveform.badge.mic"
        case .speakingSpeed: "speedometer"
        case .pauses: "pause.circle"
        case .fluency: "drop.fill"
        case .stress: "metronome"
        case .intonation: "waveform.path.ecg"
        }
    }
}

/// 音素级得分（可选输入）。值域 0...1。
public struct PhonemeRating: Codable, Sendable, Equatable {
    public var phoneme: String
    public var score: Double

    public init(phoneme: String, score: Double) {
        self.phoneme = phoneme
        self.score = min(max(score, 0), 1)
    }
}

/// 从录音里量出来的声学事实。**全部可复算**，不含任何主观判断。
public struct SpeechMetrics: Codable, Sendable, Equatable {

    /// 录音总时长（秒）。
    public var duration: Double
    /// 有声时长（秒）。
    public var speechDuration: Double
    /// 句中静音总时长（秒）。首尾静音不算 —— 那只是「按下录音键到开口」的延迟。
    public var pauseDuration: Double
    /// 句中停顿次数（≥ `SpeechAnalyzer.minPause` 的静音段）。
    public var pauseCount: Int
    /// 最长的一次句中停顿（秒）。
    public var longestPause: Double
    /// 有声占比 = 有声时长 / 总时长。
    public var speakingRatio: Double
    /// 基频起伏幅度（半音，p90 − p10）。无浊音帧时为 0。
    public var pitchRange: Double
    /// 基频波动（半音，标准差）。无浊音帧时为 0。
    public var pitchVariation: Double
    /// 音量起伏（有声帧 RMS 的变异系数）。重音节奏的代理量。
    public var energyVariation: Double
    /// 采到基频的帧数（0 = 这次没测到语调）。
    public var voicedFrames: Int

    public init(
        duration: Double = 0,
        speechDuration: Double = 0,
        pauseDuration: Double = 0,
        pauseCount: Int = 0,
        longestPause: Double = 0,
        speakingRatio: Double = 0,
        pitchRange: Double = 0,
        pitchVariation: Double = 0,
        energyVariation: Double = 0,
        voicedFrames: Int = 0
    ) {
        self.duration = duration
        self.speechDuration = speechDuration
        self.pauseDuration = pauseDuration
        self.pauseCount = pauseCount
        self.longestPause = longestPause
        self.speakingRatio = speakingRatio
        self.pitchRange = pitchRange
        self.pitchVariation = pitchVariation
        self.energyVariation = energyVariation
        self.voicedFrames = voicedFrames
    }

    public static let empty = SpeechMetrics()

    /// 有没有量到「说得成句」的语音。太短的杂音不足以评测。
    public var hasSpeech: Bool { speechDuration >= 0.3 }
}

// MARK: - 声学分析（纯 DSP）

/// 录音 → `SpeechMetrics`。
///
/// 全部自己算：能量分帧 → 噪声底 → 语音段 / 停顿 → 基频（自相关）→ 起伏统计。
/// **不引入任何模型**，因此任何 runtime 换掉了都不影响这一层。
public enum SpeechAnalyzer {

    /// 分帧长度（秒）。25ms 是语音处理的惯用窗。
    public static let frameDuration = 0.025
    /// 帧移（秒）。
    public static let hopDuration = 0.01
    /// 短于此的静音不算停顿（换气级的小间隙）。
    public static let minPause = 0.2
    /// 短于此的「有声段」当抖动丢掉（爆音、咔哒声）。
    public static let minSpeech = 0.06
    /// 低于此绝对能量视为环境噪声（-46 dBFS 左右）。
    public static let absoluteFloor: Float = 0.005
    /// 基频搜索区间（人声）。
    public static let pitchRange: ClosedRange<Double> = 70...350
    /// 自相关归一化峰值下限：低于它认为这一帧没有稳定基频（清音 / 噪声）。
    public static let voicedness: Double = 0.4

    public static func analyze(samples: [Float], sampleRate: Double) -> SpeechMetrics {
        guard !samples.isEmpty, sampleRate > 0 else { return .empty }
        let duration = Double(samples.count) / sampleRate
        let frameLength = max(Int(sampleRate * frameDuration), 2)
        let hop = max(Int(sampleRate * hopDuration), 1)
        guard samples.count >= frameLength else {
            // 短到连一帧都凑不齐：只报时长，不硬编分数。
            return SpeechMetrics(duration: duration)
        }

        let energies = frameEnergies(samples, frameLength: frameLength, hop: hop)
        guard let peak = energies.max(), peak > absoluteFloor else {
            return SpeechMetrics(duration: duration)
        }
        // 阈值三选其大：噪声底之上、峰值的一个比例之上、绝对底噪之上。
        // 再整体封顶在峰值的 20%：**连续说话的录音里没有静音可参考**，
        // 20 分位本身就是语音，直接乘 3 会把整段都判成静音（实测踩过的坑）。
        let threshold = min(max(noiseFloor(energies) * 3, peak * 0.08, absoluteFloor), peak * 0.2)
        let mask = smooth(energies.map { $0 > threshold }, minSpeechFrames: max(Int(minSpeech / hopDuration), 1))
        let segments = speechSegments(mask: mask, hop: hop, sampleRate: sampleRate)

        let speechDuration = segments.reduce(0) { $0 + ($1.end - $1.start) }
        let pauses = pauseStats(segments: segments)
        let energyVariation = energyVariation(energies: energies, mask: mask)
        let pitch = pitchStats(
            samples: samples, sampleRate: sampleRate,
            frameLength: frameLength, hop: hop, mask: mask
        )

        return SpeechMetrics(
            duration: duration,
            speechDuration: speechDuration,
            pauseDuration: pauses.total,
            pauseCount: pauses.count,
            longestPause: pauses.longest,
            speakingRatio: duration > 0 ? min(speechDuration / duration, 1) : 0,
            pitchRange: pitch.range,
            pitchVariation: pitch.variation,
            energyVariation: energyVariation,
            voicedFrames: pitch.frames
        )
    }

    // MARK: - 分帧能量

    /// 每帧 RMS。
    static func frameEnergies(_ samples: [Float], frameLength: Int, hop: Int) -> [Float] {
        guard samples.count >= frameLength else { return [] }
        var result: [Float] = []
        result.reserveCapacity(samples.count / hop + 1)
        var start = 0
        while start + frameLength <= samples.count {
            var sum = 0.0
            for index in start..<(start + frameLength) {
                let value = Double(samples[index])
                sum += value * value
            }
            result.append(Float((sum / Double(frameLength)).squareRoot()))
            start += hop
        }
        return result
    }

    /// 噪声底：取能量的 20 分位。用均值会被语音段抬高，用最小值又太敏感。
    static func noiseFloor(_ energies: [Float]) -> Float {
        guard !energies.isEmpty else { return 0 }
        let sorted = energies.sorted()
        let index = min(Int(Double(sorted.count) * 0.2), sorted.count - 1)
        return sorted[index]
    }

    /// 形态学清理：补上单帧的「破洞」、丢掉过短的孤立有声段。
    /// 不做这一步，阈值附近的抖动会被数成几十次停顿。
    static func smooth(_ mask: [Bool], minSpeechFrames: Int) -> [Bool] {
        guard !mask.isEmpty else { return mask }
        var result = mask
        // 1. 补洞：两侧都是有声的孤立静音帧 → 改判有声。
        if result.count > 2 {
            for index in 1..<(result.count - 1) where !result[index] {
                if result[index - 1] && result[index + 1] { result[index] = true }
            }
        }
        // 2. 去毛刺：连续有声短于 minSpeechFrames → 改判静音。
        var index = 0
        while index < result.count {
            guard result[index] else { index += 1; continue }
            var end = index
            while end < result.count, result[end] { end += 1 }
            if end - index < minSpeechFrames {
                for position in index..<end { result[position] = false }
            }
            index = end
        }
        return result
    }

    /// 连续有声帧 → 时间轴上的语音段。
    static func speechSegments(mask: [Bool], hop: Int, sampleRate: Double) -> [VADSpan] {
        var segments: [VADSpan] = []
        var index = 0
        while index < mask.count {
            guard mask[index] else { index += 1; continue }
            var end = index
            while end < mask.count, mask[end] { end += 1 }
            // 段尾补一帧：最后一帧的能量其实覆盖到 start+frameLength，这里用帧数近似即可。
            segments.append(VADSpan(start: Double(index * hop) / sampleRate,
                                    end: Double(end * hop) / sampleRate))
            index = end
        }
        return segments
    }

    /// 句中停顿：相邻语音段之间的静音（首尾静音不计）。
    static func pauseStats(segments: [VADSpan]) -> (count: Int, total: Double, longest: Double) {
        guard segments.count > 1 else { return (0, 0, 0) }
        var count = 0
        var total: Double = 0
        var longest: Double = 0
        for index in 1..<segments.count {
            let gap = segments[index].start - segments[index - 1].end
            guard gap >= minPause else { continue }
            count += 1
            total += gap
            longest = max(longest, gap)
        }
        return (count, total, longest)
    }

    /// 有声帧的音量起伏（变异系数）：太平 = 没有轻重音，太大 = 忽大忽小。
    static func energyVariation(energies: [Float], mask: [Bool]) -> Double {
        let values = energies.enumerated().compactMap { mask[$0.offset] ? Double($0.element) : nil }
        guard values.count >= 3 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot() / mean
    }

    // MARK: - 基频（自相关）

    /// 基频统计：起伏幅度（p90−p10）与波动（标准差），单位半音。
    ///
    /// 用自相关而不是零交叉：清音（s / f / θ）零交叉数很高，会被误当成高音。
    static func pitchStats(
        samples: [Float],
        sampleRate: Double,
        frameLength: Int,
        hop: Int,
        mask: [Bool]
    ) -> (range: Double, variation: Double, frames: Int) {
        // 降采样到 ~8kHz 再算自相关：精度对基频足够，耗时降到 1/4。
        let factor = max(Int((sampleRate / 8_000).rounded()), 1)
        let pitchFrame = max(frameLength / factor, 8)
        var track: [Double] = []
        var frameIndex = 0
        // 每 2 帧取一次：基频变化比 10ms 慢得多，省一半时间。
        while frameIndex < mask.count {
            if mask[frameIndex] {
                let start = frameIndex * hop
                let end = start + frameLength
                if end <= samples.count {
                    var decimated = [Float]()
                    decimated.reserveCapacity(pitchFrame)
                    var position = start
                    while position + factor <= end, decimated.count < pitchFrame {
                        var sum = 0.0
                        for offset in 0..<factor { sum += Double(samples[position + offset]) }
                        decimated.append(Float(sum / Double(factor)))
                        position += factor
                    }
                    if let hz = fundamentalFrequency(
                        decimated, sampleRate: sampleRate / Double(factor),
                        frameLength: pitchFrame
                    ) {
                        track.append(hz)
                    }
                }
            }
            frameIndex += 2
        }
        guard track.count >= 3 else { return (0, 0, track.count) }

        // 换成半音再统计：人对音高的感知是对数的（100Hz 与 200Hz 是「一个八度」，不是「差 100」）。
        let reference = median(track)
        guard reference > 0 else { return (0, 0, track.count) }
        let semitones = track.map { 12 * log2($0 / reference) }
        let sorted = semitones.sorted()
        let low = percentile(sorted, 0.1)
        let high = percentile(sorted, 0.9)
        let mean = semitones.reduce(0, +) / Double(semitones.count)
        let variance = semitones.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(semitones.count)
        return (high - low, variance.squareRoot(), track.count)
    }

    /// 单帧基频：归一化自相关峰值对应的滞后。峰值太低 = 没有稳定基频。
    static func fundamentalFrequency(
        _ frame: [Float], sampleRate: Double, frameLength: Int
    ) -> Double? {
        guard frame.count >= 16, sampleRate > 0 else { return nil }
        let count = min(frameLength, frame.count)
        let mean = frame.prefix(count).reduce(0) { $0 + Double($1) } / Double(count)
        var windowed = [Double](repeating: 0, count: count)
        var energy: Double = 0
        for index in 0..<count {
            // 汉明窗：削掉两端截断带来的频谱泄漏，否则自相关峰会被假峰盖过。
            let window = 0.54 - 0.46 * cos(2 * Double.pi * Double(index) / Double(max(count - 1, 1)))
            let value = (Double(frame[index]) - mean) * window
            windowed[index] = value
            energy += value * value
        }
        guard energy > 1e-9 else { return nil }

        let minLag = max(Int(sampleRate / Self.pitchRange.upperBound), 1)
        let maxLag = min(Int(sampleRate / Self.pitchRange.lowerBound), count - 2)
        guard maxLag > minLag else { return nil }

        var bestLag = 0
        var best: Double = 0
        for lag in minLag...maxLag {
            var sum = 0.0
            for index in 0..<(count - lag) { sum += windowed[index] * windowed[index + lag] }
            let normalized = sum / energy
            if normalized > best {
                best = normalized
                bestLag = lag
            }
        }
        guard best >= Self.voicedness, bestLag > 0 else { return nil }
        return sampleRate / Double(bestLag)
    }

    // MARK: - 小工具

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return percentile(values.sorted(), 0.5)
    }

    /// 分位数（线性插值）。`values` 必须已升序。
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}

/// 一段有声区间（秒）。与 `AIInterfaces.VADSegment` 同形，但这一层不认识 provider 协议。
public struct VADSpan: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

// MARK: - 评测结果

/// 一个维度的得分与依据。
public struct PronunciationScoreLine: Codable, Sendable, Equatable, Identifiable {
    public var dimension: PronunciationDimension
    /// 0...100。
    public var score: Double
    /// 这个分数从哪来的（「每分钟 132 词」这种可核对的说法，不是形容词）。
    public var detail: String
    /// 是否只是估算（例如没有音素模型时的近似）。UI 据此弱化显示。
    public var isEstimated: Bool

    public var id: String { dimension.rawValue }

    public init(
        dimension: PronunciationDimension,
        score: Double,
        detail: String,
        isEstimated: Bool = false
    ) {
        self.dimension = dimension
        self.score = min(max(score, 0), 100)
        self.detail = detail
        self.isEstimated = isEstimated
    }
}

/// 总分分档。
public enum PronunciationVerdict: String, Codable, Sendable, Equatable, CaseIterable {
    case excellent
    case good
    case fair
    case needsWork

    public var displayName: String {
        switch self {
        case .excellent: "发音漂亮"
        case .good: "不错，再打磨"
        case .fair: "基本能听懂"
        case .needsWork: "重点练一练"
        }
    }

    public var symbol: String {
        switch self {
        case .excellent: "star.circle.fill"
        case .good: "hand.thumbsup.fill"
        case .fair: "equal.circle.fill"
        case .needsWork: "exclamationmark.circle.fill"
        }
    }
}

/// 音素得分的来源。**必须如实标注**：推断不等于实测，读者有权知道自己看的是什么。
public enum PhonemeSource: String, Codable, Sendable, Equatable, CaseIterable {
    /// 没有音素结果（既没有发音模型，也没有可对齐的文本）。
    case none
    /// 推断：参考句与识别结果各自的音素序列做加权对齐（无需发音模型）。
    case inference
    /// 实测：发音模型 / 云端发音评估给出的声学音素得分。
    case acoustic

    /// 卡片上的小标签（nil = 不显示）。
    public var displayName: String? {
        switch self {
        case .none: nil
        case .inference: "规则推断"
        case .acoustic: "声学实测"
        }
    }

    /// 说明这句话能信到什么程度。
    public var explanation: String? {
        switch self {
        case .none: nil
        case .inference: "按发音部位与方式推算，用来定位「哪个音不对」，不是录音实测"
        case .acoustic: "来自发音模型的逐音素声学打分"
        }
    }
}

/// 一次发音评测的完整结果（可 JSON 落库）。
public struct PronunciationReport: Codable, Sendable, Equatable {
    public var referenceText: String
    public var recognizedText: String
    /// 总分 0...100（按维度权重加权，缺的维度自动重新归一）。
    public var overall: Double
    public var verdict: PronunciationVerdict
    /// 各维度明细（按权重从大到小，UI 直接顺序渲染）。
    public var lines: [PronunciationScoreLine]
    /// 声学事实。
    public var metrics: SpeechMetrics
    /// 最弱的一维（没有可评维度时为 nil）。
    public var weakest: PronunciationDimension?
    /// 针对性建议（点名数字，不讲空话）。
    public var tips: [String]
    public var createdAt: Date
    /// 逐词音素明细（PRD §12.1 的音素条）。没有音素能力时为空。
    public var phonemeWords: [PhonemeWordAssessment]
    /// 音素得分来源（推断 / 实测 / 无）。
    public var phonemeSource: PhonemeSource
    /// 韵律 / 连读 / 词级重音（④）。**没有词级数据时为 nil**（老记录 / runtime 不支持）。
    public var prosody: ProsodyAnalysis?

    public init(
        referenceText: String,
        recognizedText: String,
        overall: Double,
        verdict: PronunciationVerdict,
        lines: [PronunciationScoreLine],
        metrics: SpeechMetrics,
        weakest: PronunciationDimension?,
        tips: [String],
        createdAt: Date = Date(),
        phonemeWords: [PhonemeWordAssessment] = [],
        phonemeSource: PhonemeSource = .none,
        prosody: ProsodyAnalysis? = nil
    ) {
        self.referenceText = referenceText
        self.recognizedText = recognizedText
        self.overall = overall
        self.verdict = verdict
        self.lines = lines
        self.metrics = metrics
        self.weakest = weakest
        self.tips = tips
        self.createdAt = createdAt
        self.phonemeWords = phonemeWords
        self.phonemeSource = phonemeSource
        self.prosody = prosody
    }

    // 老记录里没有音素字段（v6 之前落库的报告）：缺就降级成「无音素」，
    // 绝不能因为读了旧 JSON 就让整条跟读记录报废。
    private enum CodingKeys: String, CodingKey {
        case referenceText, recognizedText, overall, verdict, lines
        case metrics, weakest, tips, createdAt, phonemeWords, phonemeSource
        case prosody
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        referenceText = try container.decode(String.self, forKey: .referenceText)
        recognizedText = try container.decodeIfPresent(String.self, forKey: .recognizedText) ?? ""
        overall = try container.decodeIfPresent(Double.self, forKey: .overall) ?? 0
        verdict = try container.decodeIfPresent(PronunciationVerdict.self, forKey: .verdict) ?? .needsWork
        lines = try container.decodeIfPresent([PronunciationScoreLine].self, forKey: .lines) ?? []
        metrics = try container.decodeIfPresent(SpeechMetrics.self, forKey: .metrics)
            ?? SpeechMetrics.empty
        weakest = try container.decodeIfPresent(PronunciationDimension.self, forKey: .weakest)
        tips = try container.decodeIfPresent([String].self, forKey: .tips) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        phonemeWords = try container.decodeIfPresent([PhonemeWordAssessment].self, forKey: .phonemeWords) ?? []
        phonemeSource = try container.decodeIfPresent(PhonemeSource.self, forKey: .phonemeSource) ?? .none
        // ⚠️ 老记录里没有这一项 → nil（不是「零分」）。零分会被 UI 画成「你一句连读都没做对」，
        // 而事实是「这份报告诞生时还没有这个维度」。
        prosody = try container.decodeIfPresent(ProsodyAnalysis.self, forKey: .prosody)
    }

    /// 韵律加分（0...10）。**不计入 `overall`** —— 见 `ProsodyBonus` 的口径说明。
    public var prosodyBonus: Double { ProsodyBonus.score(prosody) }

    public var overallPercent: Int { Int(overall.rounded()) }

    public func line(_ dimension: PronunciationDimension) -> PronunciationScoreLine? {
        lines.first { $0.dimension == dimension }
    }

    /// 有可展示的音素条吗（UI 据此决定要不要画那一块）。
    public var hasPhonemeBreakdown: Bool {
        !phonemeWords.filter { $0.status != .extra && !$0.phonemes.isEmpty }.isEmpty
    }
}

// MARK: - 打分（纯函数）

/// 从「文本对齐 + 声学事实」算出发音评分。**不依赖任何发音模型**。
public enum PronunciationScorer {

    /// 维度权重。各维度按可用性重新归一，所以权重和不必凑满 1。
    ///
    /// 词准确度最重：初学阶段「说对词」比「说得漂亮」重要；
    /// 音素级排第二（一旦接了音素模型就该它说话）；重音/语调各 5%——它们是打磨项，不是门槛。
    public static let weights: [PronunciationDimension: Double] = [
        .wordAccuracy: 0.30,
        .phonemeAccuracy: 0.20,
        .fluency: 0.15,
        .speakingSpeed: 0.15,
        .pauses: 0.10,
        .stress: 0.05,
        .intonation: 0.05,
    ]

    /// 理想发音速率（每分钟词数，按**有声时长**计）：以**正常英语交流语速**为准。
    ///
    /// 日常对话普遍在每分钟 130–190 词（播音/ TED 约 150–170），110 以下已是慢速朗读。
    /// 2026-09-19 用户反馈旧标准「理想 110–170」下限太慢：跟读按正常节奏说反而被判慢。
    public static let idealSpeed: ClosedRange<Double> = 190...240
    /// 语速至少要有这么多词、这么久，才算得准 —— 两个词的一句话折成 WPM 毫无意义。
    public static let speedMinimumWords = 4
    public static let speedMinimumSpeech: Double = 1.2
    /// 停顿的宽容度：平均每 4 秒允许一次换气式停顿，再密就算「卡」。
    ///
    /// 不用「次数/10 秒」：短句会让这个比值爆炸，一句 2.5 秒的话里换一次气就被判 30 分，
    /// 而学习者只是喘了口气。
    public static let pauseAllowanceSeconds = 4.0
    /// 最长的一次停顿（秒）。
    public static let idealLongestPause: ClosedRange<Double> = 0...0.9
    /// 有声占比：朗读一句完整的话，通常七成以上时间在出声。
    public static let idealSpeakingRatio: ClosedRange<Double> = 0.6...0.95
    /// 填充词占比（uh / um / er / ah）。
    public static let idealFillerRatio: ClosedRange<Double> = 0...0.05
    /// 音量起伏（变异系数）：太平均 = 没有轻重音。
    public static let idealEnergyVariation: ClosedRange<Double> = 0.35...0.85
    /// 基频波动（半音，标准差）：太平 = 语调单调。
    public static let idealPitchVariation: ClosedRange<Double> = 1.2...4.0
    /// 基频起伏（半音，p90−p10）。
    public static let idealPitchRange: ClosedRange<Double> = 4...14

    /// 分档阈值（总分）。
    public static let excellentThreshold = 90.0
    public static let goodThreshold = 78.0
    public static let fairThreshold = 62.0

    /// 打一次分。
    ///
    /// - Parameters:
    ///   - phonemes: 音素级得分。为空则**不显示**音准维度（而不是拿别的维度冒充）。
    ///   - phonemeWords: 逐词音素明细（含来源）。传了它就可以不传扁平的 `phonemes`——
    ///     本函数会自己摊平，保证「音准分」与「音素条」永远同源，不会各算各的。
    ///   - phonemeSource: 音素得分来源。`.inference` 会把音准维度标成「估算」。
    ///   - comparison: 词准确度的来源。显式传入是为了让调用方拿到与跟读页完全一致的结论。
    public static func report(
        reference: String,
        recognized: String,
        metrics: SpeechMetrics,
        phonemes: [PhonemeRating] = [],
        phonemeWords: [PhonemeWordAssessment] = [],
        phonemeSource: PhonemeSource = .none,
        comparison: ShadowingComparison? = nil,
        prosody: ProsodyAnalysis? = nil,
        createdAt: Date = Date()
    ) -> PronunciationReport {
        let alignment = comparison ?? ShadowingScorer.compare(reference: reference, recognized: recognized)
        let recognizedWords = ShadowingScorer.words(recognized)

        // 音素来源只有一个：明细在就以明细为准（两者都传时明细赢，避免不同步）。
        let ratings = phonemeWords.isEmpty ? phonemes : PhonemeAssessment.flatRatings(phonemeWords)
        let source: PhonemeSource = ratings.isEmpty ? .none : (phonemeSource == .none ? .inference : phonemeSource)

        var lines: [PronunciationScoreLine] = []
        lines.append(wordAccuracyLine(alignment))
        if let phonemeLine = phonemeAccuracyLine(ratings, isEstimated: source == .inference) {
            lines.append(phonemeLine)
        }
        if let speed = speakingSpeedLine(words: recognizedWords.count, metrics: metrics) { lines.append(speed) }
        if let pauses = pausesLine(metrics: metrics) { lines.append(pauses) }
        if let fluency = fluencyLine(words: recognizedWords, metrics: metrics) { lines.append(fluency) }
        if let stress = stressLine(metrics: metrics) { lines.append(stress) }
        if let intonation = intonationLine(metrics: metrics) { lines.append(intonation) }

        // 按权重从大到小排：UI 不用再排一次，读者也从最重要的看起。
        lines.sort { lhs, rhs in
            let l = weights[lhs.dimension] ?? 0
            let r = weights[rhs.dimension] ?? 0
            if l != r { return l > r }
            return lhs.dimension.rawValue < rhs.dimension.rawValue
        }

        let overall = weightedScore(lines)
        let weakest = lines
            .filter { !$0.isEstimated }
            .min { $0.score < $1.score }?
            .dimension

        return PronunciationReport(
            referenceText: reference,
            recognizedText: recognized,
            overall: overall,
            verdict: verdict(for: overall),
            lines: lines,
            metrics: metrics,
            weakest: weakest,
            tips: tips(for: lines),
            createdAt: createdAt,
            phonemeWords: phonemeWords,
            phonemeSource: source,
            prosody: prosody
        )
    }

    public static func verdict(for overall: Double) -> PronunciationVerdict {
        if overall >= excellentThreshold { return .excellent }
        if overall >= goodThreshold { return .good }
        if overall >= fairThreshold { return .fair }
        return .needsWork
    }

    /// 加权总分：只对**可用**维度加权并重新归一（缺音准模型不该拖低总分）。
    public static func weightedScore(_ lines: [PronunciationScoreLine]) -> Double {
        var sum = 0.0
        var total = 0.0
        for line in lines {
            let weight = weights[line.dimension] ?? 0
            guard weight > 0 else { continue }
            sum += line.score * weight
            total += weight
        }
        guard total > 0 else { return 0 }
        return sum / total
    }

    /// 落在理想区间给满分；越界按容差线性扣分，最低 30 分。
    ///
    /// 不做一票否决：语速慢一点、语调平一点，都不是「发音差」。
    public static func bandScore(_ value: Double, ideal: ClosedRange<Double>, tolerance: Double) -> Double {
        if ideal.contains(value) { return 100 }
        let deviation = value < ideal.lowerBound ? ideal.lowerBound - value : value - ideal.upperBound
        guard tolerance > 0 else { return 30 }
        let penalty = min(deviation / tolerance, 1) * 70
        return max(30, 100 - penalty)
    }

    // MARK: - 各维度

    static func wordAccuracyLine(_ comparison: ShadowingComparison) -> PronunciationScoreLine {
        PronunciationScoreLine(
            dimension: .wordAccuracy,
            score: comparison.accuracy * 100,
            detail: comparison.referenceCount > 0
                ? "跟上 \(comparison.matched) / \(comparison.referenceCount) 个词"
                : "这句没有可跟读的内容"
        )
    }

    static func phonemeAccuracyLine(
        _ phonemes: [PhonemeRating],
        isEstimated: Bool = false
    ) -> PronunciationScoreLine? {
        guard !phonemes.isEmpty else { return nil }
        let average = phonemes.map(\.score).reduce(0, +) / Double(phonemes.count)
        let worst = phonemes.sorted { $0.score < $1.score }.prefix(2)
            .map { "\(PhonemeDisplay.ipa(for: $0.phoneme)) \(Int(($0.score * 100).rounded()))" }
        let head = worst.isEmpty ? "音素得分 \(Int((average * 100).rounded()))" : "最弱的音：\(worst.joined(separator: "、"))"
        return PronunciationScoreLine(
            dimension: .phonemeAccuracy,
            score: average * 100,
            // 推断来的分数必须自报家门，否则用户会以为这是录音实测。
            detail: isEstimated ? "\(head)（规则推断）" : head,
            isEstimated: isEstimated
        )
    }

    static func speakingSpeedLine(words: Int, metrics: SpeechMetrics) -> PronunciationScoreLine? {
        guard words >= speedMinimumWords, metrics.speechDuration >= speedMinimumSpeech else { return nil }
        let perMinute = Double(words) / (metrics.speechDuration / 60)
        // 容差 60：有声时长口径会把 WPM 系统性偏高（停顿不计时 + ASR 可能多认词），
        // 偏快一侧要宽恕一些 —— 233 词/分（旧标准下 30 分）按交流语速只是「偏快」，不是「差」。
        return PronunciationScoreLine(
            dimension: .speakingSpeed,
            score: bandScore(perMinute, ideal: idealSpeed, tolerance: 60),
            detail: "每分钟 \(Int(perMinute.rounded())) 词 · 理想 \(Int(idealSpeed.lowerBound))–\(Int(idealSpeed.upperBound))"
        )
    }

    static func pausesLine(metrics: SpeechMetrics) -> PronunciationScoreLine? {
        guard metrics.hasSpeech else { return nil }
        let allowed = max(1, Int(ceil(metrics.speechDuration / pauseAllowanceSeconds)))
        let excess = max(0, metrics.pauseCount - allowed)
        let countScore = max(30, 100 - Double(excess) * 20)
        let longestScore = bandScore(metrics.longestPause, ideal: idealLongestPause, tolerance: 1.0)
        return PronunciationScoreLine(
            dimension: .pauses,
            score: countScore * 0.55 + longestScore * 0.45,
            detail: metrics.pauseCount == 0
                ? "一口气说完，没有卡顿"
                : "句中停顿 \(metrics.pauseCount) 次 · 最长 \(String(format: "%.1f", metrics.longestPause)) 秒"
        )
    }

    static func fluencyLine(words: [String], metrics: SpeechMetrics) -> PronunciationScoreLine? {
        guard metrics.hasSpeech else { return nil }
        let ratioScore = bandScore(metrics.speakingRatio, ideal: idealSpeakingRatio, tolerance: 0.35)
        let fillers = words.filter { Self.fillers.contains($0) }.count
        let fillerRatio = words.isEmpty ? 0 : Double(fillers) / Double(words.count)
        let fillerScore = bandScore(fillerRatio, ideal: idealFillerRatio, tolerance: 0.12)
        return PronunciationScoreLine(
            dimension: .fluency,
            score: ratioScore * 0.6 + fillerScore * 0.4,
            detail: fillers == 0
                ? "有声占比 \(Int((metrics.speakingRatio * 100).rounded()))%"
                : "有声占比 \(Int((metrics.speakingRatio * 100).rounded()))% · 填充词 \(fillers) 个"
        )
    }

    static func stressLine(metrics: SpeechMetrics) -> PronunciationScoreLine? {
        guard metrics.hasSpeech, metrics.energyVariation > 0 else { return nil }
        return PronunciationScoreLine(
            dimension: .stress,
            score: bandScore(metrics.energyVariation, ideal: idealEnergyVariation, tolerance: 0.45),
            detail: "音量起伏 \(String(format: "%.2f", metrics.energyVariation))"
        )
    }

    static func intonationLine(metrics: SpeechMetrics) -> PronunciationScoreLine? {
        guard metrics.voicedFrames >= 3 else { return nil }
        let variationScore = bandScore(metrics.pitchVariation, ideal: idealPitchVariation, tolerance: 2.2)
        let rangeScore = bandScore(metrics.pitchRange, ideal: idealPitchRange, tolerance: 6)
        return PronunciationScoreLine(
            dimension: .intonation,
            score: variationScore * 0.5 + rangeScore * 0.5,
            detail: "音高起伏 \(String(format: "%.1f", metrics.pitchRange)) 半音"
        )
    }

    /// 填充词表（数据驱动的语义，不放 UI 层）。
    public static let fillers: Set<String> = ["uh", "um", "er", "ah", "eh", "hmm", "mmm"]

    // MARK: - 建议

    /// 针对性的建议：只对**分数不理想**的维度开口，且必须带上数字。
    ///
    /// 「多加练习」这种话对学习者零信息量；「语速偏慢（每分钟 96 词），先跟着示范读两遍」才有用。
    public static func tips(for lines: [PronunciationScoreLine], limit: Int = 3) -> [String] {
        lines
            .filter { $0.score < 85 }
            .sorted { $0.score < $1.score }
            .prefix(limit)
            .compactMap { tip(for: $0) }
    }

    static func tip(for line: PronunciationScoreLine) -> String? {
        switch line.dimension {
        case .wordAccuracy:
            return line.score < 85 ? "有词没跟上（\(line.detail)），先听两遍示范，再逐词慢读一遍" : nil
        case .phonemeAccuracy:
            guard line.score < 85 else { return nil }
            // 推断来的音素结论语气要更软：它指向的是「这里值得复读一遍」，不是「你读错了」。
            return line.isEstimated
                ? "这几个音可能没到位（\(line.detail)），把它们单独读十遍，再整句回读一次"
                : "个别音不准（\(line.detail)），把这个音单独拉出来读十遍"
        case .speakingSpeed:
            return line.score < 85 ? "语速不在舒服的区间（\(line.detail)），跟着示范的节奏读，别抢也别拖" : nil
        case .pauses:
            return line.score < 85 ? "停顿偏多（\(line.detail)），先小声连读两遍，把句子串起来再录" : nil
        case .fluency:
            return line.score < 85 ? "中间空了太久或带了口头语（\(line.detail)），试着一次说完，卡住也别停" : nil
        case .stress:
            return line.score < 85
                ? "轻重不够分明（\(line.detail)），实词读重、虚词读轻，句子才有节奏"
                : nil
        case .intonation:
            return line.score < 85
                ? "语调偏平（\(line.detail)），句尾降下来、疑问句升上去，模仿示范的起伏"
                : nil
        }
    }
}
