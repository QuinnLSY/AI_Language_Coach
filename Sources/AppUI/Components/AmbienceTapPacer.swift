import Foundation

/// 连点彩蛋的节拍器（批次六 · E，纯值类型、可单测）。
///
/// 「连点 N 次触发彩蛋」这件小事里藏着两个容易写错的判据：
/// ① 点击要落在**时间窗口内**才算连点（隔了半天点的两下不是连点）；
/// ② 凑满一次之后要从头数（不然 5 次触发一次后，第 9 次又莫名其妙触发一次）。
/// 收进一个纯值类型，这两个判据就是两条断言的事。
///
/// 判据由调用方传入时刻（不读 `Date()`），测试用固定时间线推演。
public struct AmbienceTapPacer: Sendable {

    /// 凑满几次算一次「连点」。
    public let requiredTaps: Int
    /// 窗口（秒）：相邻有效点击的最大间隔。
    public let window: TimeInterval

    private var stamps: [Date] = []

    public init(requiredTaps: Int = 5, window: TimeInterval = 2.0) {
        self.requiredTaps = max(requiredTaps, 1)
        self.window = window
    }

    /// 记一次点击；凑满 `requiredTaps` 次返回 `true` 并清零（下一次连点从头数）。
    public mutating func register(at date: Date) -> Bool {
        let windowStart = date.addingTimeInterval(-window)
        stamps = stamps.filter { $0 >= windowStart }
        stamps.append(date)
        guard stamps.count >= requiredTaps else { return false }
        stamps.removeAll()
        return true
    }
}
