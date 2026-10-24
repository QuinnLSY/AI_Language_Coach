import SwiftUI
import AIDomain

// #661 自 TreeCanvas.swift 拆出（2026-10-24）：原文件 2812 行、21 个类型混居，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

// MARK: - 年轮徽记（#418-B：树 × 年度回顾联动）

/// 年度回顾的轻量摘要：树根年轮徽记只吃这两个数。
///
/// 由 `AppState` 从已加载的 `AnnualRecap` 里折出来（`init(recap:)`），
/// 树是纯渲染层，不自己去找年度数据。
public struct TreeAnnualSummary: Sendable, Equatable {

    /// 近一年练过的天数。
    public var practicedDays: Int
    /// 这一年里最长的一段连续练习。
    public var longestStreak: Int

    public init(practicedDays: Int = 0, longestStreak: Int = 0) {
        self.practicedDays = practicedDays
        self.longestStreak = longestStreak
    }

    /// 从整张年度记录折出摘要（只取徽记需要的两个字段）。
    public init(recap: AnnualRecap) {
        self.init(practicedDays: recap.practicedDays, longestStreak: recap.longestStreak)
    }

    /// 空摘要（年度数据还没加载 / 全年没练过）。
    public static func empty() -> Self { Self() }
}

/// 年轮徽记的判据（纯函数，便于单测）：把「近一年练了多少」物化进风景。
///
/// 圈 = 练满 30 天长一圈（封顶 6 圈 —— 再多就糊成一团了）；
/// 中心的「火苗」= 最长连续 ≥ 3 天（用 `streak` 色，与打卡徽章同一支红）。
/// 什么都没练就不画徽记（树根干干净净，等第一天）。
public enum TreeRings {

    public static let daysPerRing = 30
    public static let maxRings = 6
    /// 最长连续多少天以上点亮中心的火苗。
    public static let flameStreakThreshold = 3

    public static func showsEmblem(practicedDays: Int) -> Bool { practicedDays > 0 }

    /// 徽记中心的 y（画布坐标）—— **必须落在林间地面带之上**。
    ///
    /// 为什么不是「画布底往上一点」（2026-10-01 修）：那 150pt 的 `ForestGroundBand`
    /// 是钉在**视口**底部的固定层（草坡不透明），画布能滚到的最后一屏里，底部 150pt
    /// 永远被它压住。徽记原先画在坡面直线上，正好在压住区里 ——
    /// 而第一圈年轮要练满 30 天才出现，那必然爬得够高、视口停在半空，
    /// 结果就是「练了一整年，树根什么都没有」。
    /// 这里用与 `learnerTargetY` 同一套常量（林带高 + 一个呼吸位）定位；
    /// 林带高本身读 `ForestSceneGeometry.groundBandHeight`（P0-C 起同源）。
    public static func emblemY(canvasHeight: CGFloat) -> CGFloat {
        canvasHeight - TreeViewport.groundBandHeight - TreeViewport.clearance
    }

    public static func ringCount(practicedDays: Int) -> Int {
        guard practicedDays > 0 else { return 0 }
        return min(practicedDays / daysPerRing, maxRings)
    }

    public static func showsFlame(longestStreak: Int) -> Bool {
        longestStreak >= flameStreakThreshold
    }

    /// 读屏文案（practicedDays 为 0 时返回 nil = 整个徽记不存在）。
    public static func accessibilityLabel(practicedDays: Int, longestStreak: Int) -> String? {
        guard practicedDays > 0 else { return nil }
        var parts = ["近一年练习 \(practicedDays) 天"]
        if longestStreak > 0 { parts.append("最长连续 \(longestStreak) 天") }
        return parts.joined(separator: " · ")
    }
}

/// 树根的年轮徽记：一圈圈同心圆（颜色随日夜档走 `foliageDeep`），
/// 中心是「最长连续 ≥ 3 天」的火苗点（`streak` 色，与打卡徽章同一支红）。
/// 判据全在 `TreeRings`，这里只照着画。
struct TreeRingEmblem: View {

    let theme: ForestTheme
    let summary: TreeAnnualSummary

    var body: some View {
        let rings = TreeRings.ringCount(practicedDays: summary.practicedDays)
        ZStack {
            ForEach(0..<rings, id: \.self) { index in
                let side = CGFloat(14 + index * 8)
                Circle()
                    .stroke(theme.foliageDeep.opacity(0.7), lineWidth: 2)
                    .frame(width: side, height: side)
            }
            // 中心点：有火苗亮火苗（streak 红），没有就一颗素净的叶心。
            if TreeRings.showsFlame(longestStreak: summary.longestStreak) {
                Circle()
                    .fill(theme.streak)
                    .frame(width: 9, height: 9)
            } else {
                Circle()
                    .fill(theme.foliageDeep.opacity(0.7))
                    .frame(width: 6, height: 6)
            }
        }
    }
}
