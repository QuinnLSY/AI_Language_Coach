import Foundation

/// 基准度量的**纯函数集合**（Phase 28 / 路线图第 28 步）。
///
/// 这一层刻意不碰任何 I/O、不认识 Provider、也不认识模型：
/// 输入是「参考文本 / 假设文本 / 时间戳 / 计数」，输出是可断言的数字。
/// 这样基准口径（什么叫 WER、什么叫 RTF）只在这里定义一次，
/// Mock 用例与真机用例共用同一把尺子。
public enum BenchmarkMetrics {

    // MARK: - 文本归一

    /// 归一句子的**序**：小写、去标点、合并空白、去掉首尾。
    ///
    /// WER 对「Hello, world!」与「hello world」应当一视同仁，
    /// 否则标点与大小写会淹没真正的识别错误。
    public static func normalizedWords(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var cleaned = ""
        cleaned.reserveCapacity(lowered.count)
        for character in lowered {
            if character.isLetter || character.isNumber || character == "'" {
                // 保留缩写内的撇号（don't 保持 don't，而不是拆成 dont）。
                cleaned.append(character)
            } else {
                cleaned.append(" ")
            }
        }
        // 中文没有空格：按字切分，否则整句话会变成一个「词」，WER 恒为 0 或 1。
        var spaced = ""
        for character in cleaned {
            if Self.isCJK(character) {
                spaced.append(" ")
                spaced.append(character)
                spaced.append(" ")
            } else {
                spaced.append(character)
            }
        }
        return spaced.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 判断是否为 CJK 统一汉字（含扩展区 A）。
    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }

    // MARK: - 词错误率（ASR / 发音）

    public struct WordErrorRate: Sendable, Equatable {
        /// 参考文本与假设文本之间的词级编辑距离（替换/插入/删除各记 1）。
        public let editDistance: Int
        public let substitutions: Int
        public let insertions: Int
        public let deletions: Int
        /// 参考文本的词数（分母）。
        public let referenceWords: Int
        /// `editDistance / referenceWords`；参考为空时按约定返回 1.0（全错）或 0.0（两边都空）。
        public let rate: Double

        public init(editDistance: Int, substitutions: Int, insertions: Int, deletions: Int,
                    referenceWords: Int, rate: Double) {
            self.editDistance = editDistance
            self.substitutions = substitutions
            self.insertions = insertions
            self.deletions = deletions
            self.referenceWords = referenceWords
            self.rate = rate
        }

        /// 词级对齐后计算 WER。
        ///
        /// - Note: 只保留编辑距离与总数，不回溯完整对齐路径——
        ///   基准只需要「错得多不多」，不需要把每个错误指出来（那是纠错模块的活）。
        public init(reference: String, hypothesis: String) {
            let expected = normalizedWords(reference)
            let actual = normalizedWords(hypothesis)
            self.init(reference: expected, hypothesis: actual)
        }

        public init(reference: [String], hypothesis: [String]) {
            let alignment = BenchmarkMetrics.align(reference: reference, hypothesis: hypothesis)
            let denominator = reference.count
            let value = denominator == 0 ? (hypothesis.isEmpty ? 0.0 : 1.0)
                : Double(alignment.distance) / Double(denominator)
            self.init(
                editDistance: alignment.distance,
                substitutions: alignment.substitutions,
                insertions: alignment.insertions,
                deletions: alignment.deletions,
                referenceWords: denominator,
                rate: value
            )
        }
    }

    /// 词级 Levenshtein：返回距离与三类操作次数。
    ///
    /// 句子级序列很短（几十个词），直接用完整矩阵换取**可回溯的操作路径**——
    /// 基准不仅想知道错多少，还想知道错在替换还是漏词。
    static func align(reference: [String], hypothesis: [String])
        -> (distance: Int, substitutions: Int, insertions: Int, deletions: Int) {
        if reference.isEmpty {
            return (hypothesis.count, 0, hypothesis.count, 0)
        }
        if hypothesis.isEmpty {
            return (reference.count, 0, 0, reference.count)
        }

        // 操作码：0 = 匹配、1 = 替换、2 = 插入（假设多说了）、3 = 删除（漏词）
        let rows = reference.count + 1
        let columns = hypothesis.count + 1
        var cost = [[Int]](repeating: [Int](repeating: 0, count: columns), count: rows)
        var operations = [[UInt8]](repeating: [UInt8](repeating: 0, count: columns), count: rows)

        for row in 1..<rows {
            cost[row][0] = row
            operations[row][0] = 3
        }
        for column in 1..<columns {
            cost[0][column] = column
            operations[0][column] = 2
        }

        for row in 1..<rows {
            for column in 1..<columns {
                let substitutionCost = reference[row - 1] == hypothesis[column - 1] ? 0 : 1
                let substitute = cost[row - 1][column - 1] + substitutionCost
                let insert = cost[row][column - 1] + 1
                let delete = cost[row - 1][column] + 1
                let best = min(substitute, insert, delete)
                cost[row][column] = best
                if best == substitute {
                    operations[row][column] = substitutionCost == 0 ? 0 : 1
                } else if best == insert {
                    operations[row][column] = 2
                } else {
                    operations[row][column] = 3
                }
            }
        }

        var substitutions = 0
        var insertions = 0
        var deletions = 0
        var row = reference.count
        var column = hypothesis.count
        while row > 0 || column > 0 {
            if row == 0 {
                insertions += 1
                column -= 1
                continue
            }
            if column == 0 {
                deletions += 1
                row -= 1
                continue
            }
            switch operations[row][column] {
            case 1:
                substitutions += 1
                row -= 1
                column -= 1
            case 2:
                insertions += 1
                column -= 1
            case 3:
                deletions += 1
                row -= 1
            default:
                row -= 1
                column -= 1
            }
        }
        return (cost[reference.count][hypothesis.count], substitutions, insertions, deletions)
    }

    // MARK: - 时延

    /// 实时率：处理耗时 / 音频时长。< 1 表示「比实时快」。
    ///
    /// 音频时长为 0 或负数时返回 nil —— 除零不是 0，是「没法算」。
    public static func realTimeFactor(processingSeconds: Double, audioSeconds: Double) -> Double? {
        guard audioSeconds > 0, processingSeconds >= 0 else { return nil }
        return processingSeconds / audioSeconds
    }

    /// 首 token / 首帧时延（秒）。`first` 早于 `start` 时按 0 处理（时钟异常）。
    public static func timeToFirstTokenSeconds(start: Date, first: Date) -> Double {
        max(0, first.timeIntervalSince(start))
    }

    /// 吞吐（tokens/秒）。时长非正时返回 nil。
    public static func tokensPerSecond(tokens: Int, seconds: Double) -> Double? {
        guard seconds > 0, tokens >= 0 else { return nil }
        return Double(tokens) / seconds
    }

    // MARK: - 分布

    public struct LatencySummary: Sendable, Equatable {
        public let count: Int
        public let min: Double
        public let max: Double
        public let mean: Double
        public let p50: Double
        public let p95: Double

        public init(count: Int, min: Double, max: Double, mean: Double, p50: Double, p95: Double) {
            self.count = count
            self.min = min
            self.max = max
            self.mean = mean
            self.p50 = p50
            self.p95 = p95
        }
    }

    /// 线性插值百分位（与多数 APM 口径一致）。空数组返回 nil。
    public static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let clamped = min(max(fraction, 0), 1)
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = clamped * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }

    public static func latencySummary(_ seconds: [Double]) -> LatencySummary? {
        guard !seconds.isEmpty else { return nil }
        let mean = seconds.reduce(0, +) / Double(seconds.count)
        guard let p50 = percentile(seconds, fraction: 0.5),
              let p95 = percentile(seconds, fraction: 0.95),
              let min = seconds.min(),
              let max = seconds.max() else { return nil }
        return LatencySummary(count: seconds.count, min: min, max: max, mean: mean, p50: p50, p95: p95)
    }

    // MARK: - 稳定性

    public struct ScoreConsistency: Sendable, Equatable {
        public let count: Int
        public let mean: Double
        public let min: Double
        public let max: Double
        /// 与均值的最大偏离。
        public let maxDeviation: Double
        /// 样本标准差（n-1）；样本不足 2 个时为 0。
        public let standardDeviation: Double

        /// 是否稳定：所有样本与均值的偏离都落在容差内。
        public func isStable(within tolerance: Double) -> Bool {
            maxDeviation <= tolerance
        }
    }

    /// 同一输入多次评分的一致性（发音评测的「分数抖动」）。
    public static func scoreConsistency(_ scores: [Double]) -> ScoreConsistency? {
        guard !scores.isEmpty else { return nil }
        let mean = scores.reduce(0, +) / Double(scores.count)
        let maxDeviation = scores.map { abs($0 - mean) }.max() ?? 0
        let variance: Double
        if scores.count > 1 {
            variance = scores.map { pow($0 - mean, 2) }.reduce(0, +) / Double(scores.count - 1)
        } else {
            variance = 0
        }
        return ScoreConsistency(
            count: scores.count,
            mean: mean,
            min: scores.min() ?? mean,
            max: scores.max() ?? mean,
            maxDeviation: maxDeviation,
            standardDeviation: sqrt(variance)
        )
    }
}
