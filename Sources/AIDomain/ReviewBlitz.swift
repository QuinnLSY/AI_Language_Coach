import Foundation

/// 复习的「限时连击」（⑦-C①）。
///
/// 复习本身是间隔重复：一个词下次什么时候再见，由 `ReviewScheduler` 的间隔规则定 ——
/// **这一件绝不动它**（动它等于把记忆曲线改了，用户背的东西就白背了）。
/// 加的这一层只覆盖「这一轮复习的过程」：开一个 60 秒的窗口，看能连对几个。
///
/// 判词照旧落库、照旧走同一把尺子；连击只是「这一轮手顺不顺」的说法，
/// 它改不了任何一次见面的时间。
public struct ReviewBlitz: Sendable, Equatable {

    /// 一轮窗口的秒数。
    ///
    /// 60 秒是照着一轮复习的节奏定的：一张卡「先自己想 → 翻面 → 判一下」大约 6–10 秒，
    /// 60 秒容得下 6–10 张 —— 正好是一轮（最多 20 张）的前半程。再长就不是「抢时间」，
    /// 再短则第一张还没翻面就到点了。
    public static let windowSeconds = 60

    public let startedAt: Date
    /// 当前连对了几个（答错清零）。
    public private(set) var combo: Int = 0
    /// 这一轮的最高连击（不看当前断没断）。
    public private(set) var bestCombo: Int = 0
    /// 记住的个数（**含超时之后判的**）。
    public private(set) var correct: Int = 0
    /// 忘了的个数（**含超时之后判的**）。
    public private(set) var missed: Int = 0

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    /// 已经判过的张数。
    public var graded: Int { correct + missed }

    // MARK: - 计时（一律走墙钟）

    /// 已经过去的秒数。
    ///
    /// ⚠️ 刻意不累加 tick：机器睡一会儿、App 切到后台、主线程卡一下，
    /// 累加出来的时间都会漂。「我在 60 秒内连对 7 个」这句话必须以墙钟为准，
    /// 否则纪录一文不值。
    public func elapsedSeconds(now: Date = Date()) -> Int {
        Int(max(now.timeIntervalSince(startedAt), 0).rounded(.down))
    }

    /// 还剩几秒（**下限 0**：倒计时不许出现负数）。
    public func remainingSeconds(now: Date = Date()) -> Int {
        max(Self.windowSeconds - elapsedSeconds(now: now), 0)
    }

    /// 时间条该画多满（1 = 刚开始，0 = 到点）。
    public func timeFraction(now: Date = Date()) -> Double {
        guard Self.windowSeconds > 0 else { return 0 }
        return min(max(Double(remainingSeconds(now: now)) / Double(Self.windowSeconds), 0), 1)
    }

    public func isExpired(now: Date = Date()) -> Bool {
        remainingSeconds(now: now) == 0
    }

    // MARK: - 判一张

    /// 判一张。返回 **这一张有没有计入连击**。
    ///
    /// ⚠️ 超时之后判的词**照常计数**（`correct` / `missed` 都记 —— 它真的复习过了），
    /// 但**不再往连击上记**：否则会出现「明明早到点了，数字还在跳」，
    /// 那条连击也就不值钱了。返回值让调用方知道要不要刷新纪录。
    @discardableResult
    public mutating func grade(remembered: Bool, now: Date = Date()) -> Bool {
        guard !isExpired(now: now) else {
            if remembered { correct += 1 } else { missed += 1 }
            return false
        }
        if remembered {
            correct += 1
            combo += 1
            bestCombo = max(bestCombo, combo)
        } else {
            missed += 1
            combo = 0
        }
        return true
    }

    // MARK: - 文案

    /// 倒计时那一行（「还剩 42 秒」/ 到点后「这一轮到点了」）。
    public func countdownText(now: Date = Date()) -> String {
        Self.countdownText(remaining: remainingSeconds(now: now))
    }

    /// 同一个说法的**无时钟版本**：倒计时由状态源每秒写一次（`reviewBlitzRemaining`），
    /// 界面拿到的是「还剩几秒」这个数，不该再自己抓一次 `Date()` —— 否则界面上的秒数
    /// 和刚判完那一张卡用的不是同一个时刻，会出现「判完显示还剩 1 秒，下一拍又变 2 秒」。
    public static func countdownText(remaining: Int) -> String {
        remaining > 0 ? "还剩 \(max(remaining, 0)) 秒" : "这一轮到点了"
    }

    /// 连击那一行。**连击是 0 的时候不写「连对 0」** —— 那是把「还没开始」
    /// 说成「刚开始就失败了」；这时候该说的是怎么起连击。
    public var comboText: String {
        combo > 0 ? "连对 \(combo) 个" : "答对一个就起连击"
    }

    /// 到点之后那句结算（一张卡上写不下第二行时用它）。
    ///
    /// ⚠️ 一张都没判就到点（比如开了复习就走开）**不写「答对 0/0」**：
    /// 那是在给一次没发生过的事打分。
    ///
    /// ⚠️ 报连击的门槛是 **2** 而不是 1：连对一个只叫「答对了一个」，
    /// 报「最高连击 1」是在把一件普通的事说成成绩。
    public var summaryText: String {
        guard graded > 0 else { return "这一轮还没开始判" }
        guard bestCombo >= 2 else { return "答对 \(correct)/\(graded) 个，这轮还没连起来" }
        return "答对 \(correct)/\(graded) 个 · 最高连击 \(bestCombo)"
    }
}

// MARK: - 纪录

/// 连击的**历史纪录**（跨轮、跨启动）。
///
/// 纪录本身存哪儿是接线层的事（UserDefaults）；这里只有那条判断，
/// 保证「什么时候算破纪录」在全仓只有一处说法。
public enum ReviewBlitzRecord {

    /// 这一轮是不是破了纪录。
    ///
    /// ⚠️ 连击 0 不算破纪录 —— 第一次打开复习就弹「新纪录！」是在笑人。
    /// ⚠️ **必须在纪录被改写之前问**：`best` 一旦更新成这一轮的成绩，
    /// 再问就是「自己跟自己比」，永远不成立。
    public static func isNewRecord(best: Int, combo: Int) -> Bool {
        combo > 0 && combo > best
    }

    /// 破纪录那枚徽章上的字。
    ///
    /// 判断与文案分开：徽章画不画由**那一刻**的决定说了算（状态源已经结过账），
    /// 界面不该拿「更新之后的纪录」再判一次 —— 那会永远判成没破。
    public static let badgeTitle = "新纪录"
}
