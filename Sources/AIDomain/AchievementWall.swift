import Foundation

/// 一条成就（⑦-C②）。
///
/// 只有「数到几了」和「到几算达成」两件事，外加一个计数单位 —— 达成与否与进度
/// 都由这两个数算出来，界面上不许另有一套判据。
public struct Achievement: Sendable, Equatable, Identifiable {

    public let id: String
    /// 名字（「开口 50 句」）。数字插真值，不写死。
    public let title: String
    /// 计数单位（「句」/「分钟」/「个词」/「次」/「颗星」）—— 差多少要用它。
    public let unit: String
    public let current: Int
    public let target: Int

    public init(id: String, title: String, unit: String, current: Int, target: Int) {
        self.id = id
        self.title = title
        self.unit = unit
        self.current = current
        self.target = target
    }

    public var isUnlocked: Bool { current >= target }

    /// 完成度（0...1，超出按 1 计）。
    public var progress: Double {
        guard target > 0 else { return 0 }
        return min(max(Double(current) / Double(target), 0), 1)
    }

    /// 还差多少（已达成 = 0）。
    public var remaining: Int { max(target - current, 0) }

    /// 「还差 12 句」。已达成时返回 nil —— 那一格不该再写「还差 0 句」。
    public var remainingText: String? {
        isUnlocked ? nil : "还差 \(remaining) \(unit)"
    }
}

/// 成就墙（⑦-C②）。
///
/// 两条纪律：
///
/// 1. **只数累计量**（开口句数 / 累计时长 / 掌握词数 / 收词数 / 跟读次数 / 星星）。
///    刻意不含「连续 N 天」这类会回退的量 —— 断一天就把昨天亮着的格子打回灰色，
///    那是在惩罚用户，而墙的作用是让人想再来一次。
/// 2. **未达成的只摆最接近的那几条**（`previewLimit`）。一堵墙全是灰格子，
///    看了只会想关掉 App；把「差一点就到」的三条摆出来，才是下一次的理由。
public enum AchievementWall {

    /// 未达成最多摆几条。
    public static let previewLimit = 3

    /// 全部成就（固定 9 条，顺序稳定）。
    public static func all(snapshot: ProgressSnapshot) -> [Achievement] {
        let minutes = Int(snapshot.totalSeconds / 60)
        return [
            Achievement(id: "talk.50", title: "开口 50 句", unit: "句",
                        current: snapshot.totalMessages, target: 50),
            Achievement(id: "talk.500", title: "开口 500 句", unit: "句",
                        current: snapshot.totalMessages, target: 500),
            Achievement(id: "time.60", title: "练满 1 小时", unit: "分钟",
                        current: minutes, target: 60),
            Achievement(id: "time.600", title: "练满 10 小时", unit: "分钟",
                        current: minutes, target: 600),
            Achievement(id: "mastered.30", title: "掌握 30 个词", unit: "个词",
                        current: snapshot.vocabulary.mastered, target: 30),
            Achievement(id: "mastered.100", title: "掌握 100 个词", unit: "个词",
                        current: snapshot.vocabulary.mastered, target: 100),
            Achievement(id: "collected.100", title: "收下 100 个词", unit: "个词",
                        current: snapshot.vocabulary.total, target: 100),
            Achievement(id: "shadow.50", title: "跟读 50 次", unit: "次",
                        current: snapshot.shadowing.attempts, target: 50),
            Achievement(id: "star.30", title: "拿到 30 颗星", unit: "颗星",
                        current: snapshot.totalStars, target: 30)
        ]
    }

    /// 未达成里**最接近**的那几条（进度高在前；同进度按清单顺序，结果可复现）。
    public static func nearestLocked(
        snapshot: ProgressSnapshot,
        limit: Int = previewLimit
    ) -> [Achievement] {
        all(snapshot: snapshot)
            .enumerated()
            .filter { !$0.element.isUnlocked }
            .sorted { lhs, rhs in
                lhs.element.progress == rhs.element.progress
                    ? lhs.offset < rhs.offset
                    : lhs.element.progress > rhs.element.progress
            }
            .prefix(max(limit, 0))
            .map(\.element)
    }

    /// 墙上实际画的那几格：已达成**全部** + 未达成里最接近的几条。
    public static func display(snapshot: ProgressSnapshot) -> [Achievement] {
        let all = all(snapshot: snapshot)
        return all.filter(\.isUnlocked) + nearestLocked(snapshot: snapshot)
    }

    /// 墙头那一行（「3/9 项已解锁 · 下一个还差 12 句」）。
    ///
    /// ⚠️ 全解锁之后不再提「还差」—— 那句话会一直挂着，变成一句假预告。
    public static func headline(snapshot: ProgressSnapshot) -> String {
        let all = all(snapshot: snapshot)
        let done = all.filter(\.isUnlocked).count
        guard let next = nearestLocked(snapshot: snapshot).first else {
            return "\(done)/\(all.count) 项已解锁"
        }
        return "\(done)/\(all.count) 项已解锁 · 下一个 \(next.title)，还差 \(next.remaining) \(next.unit)"
    }
}
