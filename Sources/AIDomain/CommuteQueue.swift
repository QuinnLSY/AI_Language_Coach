import Foundation

/// 通勤连播（⑦-D）：把今天这批句子一句接一句放下去，手不用碰。
///
/// 跟读页原本每句都要按一次「听示范」，通勤路上 / 做饭时根本腾不出手 ——
/// 连播把「按 N 次」压成「按一次」，中间那段留白就是留给学员跟读的。
///
/// ⚠️ 队列里只放**句子**（`ShadowingDrill`），不做段落连播：段落本身就是连着读的
/// （`ShadowingService.playPassage` 一次读完一整段），再叠一层连播是重复盖楼。
public struct CommuteQueue: Sendable, Equatable {

    /// 每句示范之后留给学员跟读的静默秒数。
    ///
    /// 6 秒：一句八到十个词的示范约 4 秒，跟着复述一遍差不多也是这个量 ——
    /// 给少了句子还没说完下一句就进来了。
    public static let defaultGapSeconds: Double = 6

    /// 示范朗读的语速（词/分钟）。句子短、字字清楚，比日常对话慢。
    public static let wordsPerMinute: Double = 110

    public var drills: [ShadowingDrill]
    public var index: Int
    public var gapSeconds: Double

    public init(
        drills: [ShadowingDrill],
        index: Int = 0,
        gapSeconds: Double = Self.defaultGapSeconds
    ) {
        self.drills = drills
        // ⚠️ 夹取而不是原样收下：`index` 来自「练到第几句」，素材重生成后句数会变少，
        // 越界的下标会让 `currentDrill` 一直 nil、连播按下去什么都不放。
        self.index = min(max(index, 0), max(drills.count - 1, 0))
        self.gapSeconds = max(gapSeconds, 0)
    }

    /// 排一条连播队列。没有句子 → nil（UI 据此不画那张卡）。
    public static func build(
        drills: [ShadowingDrill],
        from index: Int = 0,
        gapSeconds: Double = Self.defaultGapSeconds
    ) -> CommuteQueue? {
        guard !drills.isEmpty else { return nil }
        return CommuteQueue(drills: drills, index: index, gapSeconds: gapSeconds)
    }

    /// 当前该放的那一句（放完了 nil）。
    public var currentDrill: ShadowingDrill? {
        guard drills.indices.contains(index) else { return nil }
        return drills[index]
    }

    public var count: Int { drills.count }
    public var isFinished: Bool { index >= drills.count }

    /// 「第 3 / 10 句」。
    public var progressText: String { "第 \(index + 1) / \(count) 句" }

    /// 还剩几句（不含正在放的这句）。
    public var remainingText: String { "还剩 \(max(count - index - 1, 0)) 句" }

    /// 前进一句。返回 false = 已经放完最后一句（调用方据此收尾，别再空转一轮）。
    @discardableResult
    public mutating func advance() -> Bool {
        index += 1
        return !isFinished
    }

    // MARK: 时长估算

    /// 单句朗读时长估算（秒）：按词数折算，最少 1 秒（空句也要占一位，不能算出 0）。
    public static func speakingSeconds(_ text: String) -> Double {
        let words = max(ShadowingScorer.words(text).count, 1)
        return max(1, (Double(words) / wordsPerMinute) * 60)
    }

    /// 从**当前这句**起到最后的总时长（秒）。
    ///
    /// 已经放过的那几句不计入：连播可以从中间接着放，报总数会虚高。
    public var estimatedSeconds: Int {
        let total = drills.enumerated().reduce(0.0) { partial, pair in
            guard pair.offset >= index else { return partial }
            return partial + Self.speakingSeconds(pair.element.text) + gapSeconds
        }
        return Int(total.rounded())
    }

    /// 「约 3 分 20 秒」（复用 `ProgressAggregator`，与界面其它时长同一把尺）。
    public var estimateText: String { ProgressAggregator.durationText(Double(estimatedSeconds)) }

    /// 「共 10 句 · 约 3 分 20 秒」。
    public var summaryText: String { "共 \(count) 句 · 约 \(estimateText)" }
}
