import Foundation

// MARK: - 发音跨次对比（④ 的纵向那一半）
//
// ④ 做的是「这一次」：一次跟读给出逐音素、逐词的反馈。但学员真正想知道的是
// **「我有没有变好」** —— 单次报告永远回答不了这个问题（它只看得见一次开口）。
//
// 本文件补的就是纵向那一半：把最近的跟读记录按**前后两段**比一比。
//
// 三条硬边界：
//
// 1. **样本不够就不下结论**（< 4 次返回 nil）。两次开口的分数差异几乎必然是噪声，
//    拿它当「进步了 / 退步了」的说法是拿噪声当结论 —— 与 `pronunciationSlope` 同口径。
// 2. **比的是均值，不是首尾两次**：中间夹一次特别好或特别差的，不该把结论整个翻过来。
// 3. **韵律只在量到的时候比**：老记录没有 `prosody`（④ 之前落的库），
//    那一维就直接不出现 —— 没有数据的一行写「0%」等于谎报。

/// 一次跟读里拿去对比的那几个量。
///
/// ⚠️ 不直接吃 `ShadowingAttempt`：那是落库形态（还带着参考文本与识别文本），
/// 而对比只需要这几个数 —— 中间隔一层，测试不必造一整条记录。
public struct PronunciationSample: Sendable, Equatable {

    /// 发音总分（0...100）。
    public var overall: Double
    /// 有轻重层次的词占比（0...1）；那次没量到重音为 nil。
    public var stressedRatio: Double?
    /// 该连读的地方连上了多少（0...1）；那次没有连读候选为 nil。
    public var linkedRatio: Double?
    /// 语调不是「平读」的比例（0 或 1）；那次没量出轮廓为 nil。
    public var variedContour: Double?

    public init(
        overall: Double,
        stressedRatio: Double? = nil,
        linkedRatio: Double? = nil,
        variedContour: Double? = nil
    ) {
        self.overall = overall
        self.stressedRatio = stressedRatio
        self.linkedRatio = linkedRatio
        self.variedContour = variedContour
    }

    /// 从一次跟读记录里取出可比的那几个量。
    ///
    /// ⚠️ `PronunciationReport` 里其余字段（音素、维度分）也能比，但**一次比四样**是上限：
    /// 再多就变成一张没人看的表。这四样正是 ④ 新加的能力（重音 / 连读 / 语调）+ 总分。
    public init(_ report: PronunciationReport) {
        self.overall = report.overall
        self.stressedRatio = Self.ratio(report.prosody?.stress.map { $0.level == .stressed })
        self.linkedRatio = Self.ratio(report.prosody?.linking.map(\.didLink))
        self.variedContour = report.prosody?.contour.map { $0.shape == .flat ? 0 : 1 }
    }

    /// 一堆布尔的均值（空数组返回 nil —— 没量到就是没量到，不是 0%）。
    private static func ratio(_ flags: [Bool]?) -> Double? {
        guard let flags, !flags.isEmpty else { return nil }
        return Double(flags.filter { $0 }.count) / Double(flags.count)
    }
}

/// 发音的「最近 vs 之前」。
public struct PronunciationComparison: Sendable, Equatable {

    /// 一行对比。
    public struct Row: Sendable, Equatable, Identifiable {

        public var title: String
        /// 之前那一段的均值。
        public var before: Double
        /// 最近那一段的均值。
        public var after: Double
        /// 单位（「分」/「%」）。
        public var unit: String
        /// 这一行是不是百分比（0...1 → 显示时乘 100）。
        public var isPercent: Bool

        public init(title: String, before: Double, after: Double, unit: String, isPercent: Bool = false) {
            self.title = title
            self.before = before
            self.after = after
            self.unit = unit
            self.isPercent = isPercent
        }

        public var id: String { title }

        /// 变化量（显示单位下的差）。
        public var delta: Double { (after - before) * (isPercent ? 100 : 1) }

        /// 显示用的两个数（百分比已经乘过 100）。
        public var beforeText: String { Self.text(before, isPercent) }
        public var afterText: String { Self.text(after, isPercent) }

        /// 变化量那句（「+7」/「−3」/「没变」/「+30 个百分点」）。
        ///
        /// ⚠️ 百分比行必须带单位：`0% → 100%` 旁边只写 `+100` 会被读成「涨了一倍」，
        /// 而实际是**涨了 100 个百分点**（比例确实翻倍，措辞不能骗人）。
        public var deltaText: String {
            let value = delta
            if abs(value) < 1 { return "没变" }
            let rounded = Int(value.rounded())
            let sign = rounded > 0 ? "+" : ""
            return isPercent ? "\(sign)\(rounded) 个百分点" : "\(sign)\(rounded)"
        }

        /// 是不是变好了（±1 以内算没变 —— 1 分的抖动说明不了任何事）。
        public var isBetter: Bool { delta >= 1 }
        public var isWorse: Bool { delta <= -1 }

        private static func text(_ value: Double, _ percent: Bool) -> String {
            percent ? "\(Int((value * 100).rounded()))%" : "\(Int(value.rounded()))"
        }
    }

    /// 各行（总分 + 量到的那几样韵律）。
    public var rows: [Row]
    /// 参与对比的次数（前后两段合计）。
    public var sampleCount: Int
    /// 最近那一段有几次。
    public var recentCount: Int

    public init(rows: [Row], sampleCount: Int, recentCount: Int) {
        self.rows = rows
        self.sampleCount = sampleCount
        self.recentCount = recentCount
    }

    /// 一句话结论（「最近 6 次比之前 6 次：总分 78 → 85」）。
    ///
    /// ⚠️ 只说**总分**那一行：四行全塞进一句话就没人读了，而总分是学员唯一在追的数。
    public var headline: String? {
        guard let overall = rows.first else { return nil }
        let base = "最近 \(recentCount) 次 vs 之前 \(sampleCount - recentCount) 次：总分 \(overall.beforeText) → \(overall.afterText)"
        switch (overall.isBetter, overall.isWorse) {
        case (true, _): return base + "（\(overall.deltaText) 分）"
        case (_, true): return base + "（\(overall.deltaText) 分）"
        case (false, false): return base + "（基本持平）"
        }
    }
}

public enum PronunciationComparisonRule {

    /// 少于这么多次就不对比。
    ///
    /// 与 `AdaptivePathRule.pronunciationSlope` 同口径（< 4 点不下结论）：
    /// 两三次开口的分数差几乎必然是噪声，拿它当「进步了」是拿噪声当结论。
    public static let minimumSamples = 4

    /// 把最近的一批跟读按前后两段比一比（样本不够返回 nil）。
    ///
    /// - Parameter samples: **按时间升序**（旧 → 新）的取样。传倒序的话前后两段会互换，
    ///   结论正好反过来 —— 调用点（`ShadowingService.recentAttempts` 是新 → 旧）必须自己反序。
    public static func compare(_ samples: [PronunciationSample]) -> PronunciationComparison? {
        guard samples.count >= minimumSamples else { return nil }
        let half = samples.count / 2
        let earlier = Array(samples.prefix(half))
        let later = Array(samples.suffix(samples.count - half))
        guard !earlier.isEmpty, !later.isEmpty else { return nil }

        var rows: [PronunciationComparison.Row] = [
            PronunciationComparison.Row(
                title: "总分",
                before: mean(earlier.map(\.overall)),
                after: mean(later.map(\.overall)),
                unit: "分"
            )
        ]
        rows.append(contentsOf: [
            row("重音层次", keyPath: \.stressedRatio, earlier: earlier, later: later),
            row("连读", keyPath: \.linkedRatio, earlier: earlier, later: later),
            row("语调起伏", keyPath: \.variedContour, earlier: earlier, later: later),
        ].compactMap { $0 })

        return PronunciationComparison(
            rows: rows,
            sampleCount: samples.count,
            recentCount: later.count
        )
    }

    /// 某一维前后两段的均值（**只算量到过它的那些次** —— 没量到的次不进分母）。
    private static func row(
        _ title: String,
        keyPath: KeyPath<PronunciationSample, Double?>,
        earlier: [PronunciationSample],
        later: [PronunciationSample]
    ) -> PronunciationComparison.Row? {
        let before = mean(earlier.compactMap { $0[keyPath: keyPath] })
        let after = mean(later.compactMap { $0[keyPath: keyPath] })
        // 两段里有一段完全没量到 → 这一行不出现（写「0%」是谎报）。
        guard earlier.contains(where: { $0[keyPath: keyPath] != nil }),
              later.contains(where: { $0[keyPath: keyPath] != nil }) else { return nil }
        return PronunciationComparison.Row(
            title: title,
            before: before,
            after: after,
            unit: "%",
            isPercent: true
        )
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
