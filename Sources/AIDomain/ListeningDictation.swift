import Foundation

// MARK: - 无文本听力（精听 / 听写，进阶 ④）
//
// 跟读是「听 + 说」，这里是「只听 + 写」：屏幕上**不出现任何文字**，学员把听到的
// 那句打出来，再和原文逐词对。之所以值得单开一条链路：跟读页把句子摊在眼前，
// 练的其实是「看着念」——耳朵分不到多少注意力，而「听不懂」这件事永远不会暴露。
//
// 三条规则（全是纯函数，可脱机单测）：
//
// 1. **提交前不给原文**。连译文、连「这句里有 gate 这个词」这类提示都不给。
//    `promptStrings` 把「此刻屏幕上会出现哪些字」摊成一份数据，供断言逐条检查 ——
//    否则这种退化只会以「怎么感觉变简单了」的形式被用户察觉（见 `leaksReference`）。
// 2. **重听次数是核心指标**。听力进步首先体现在「需要的遍数在下降」，
//    所以每次提交都记 `playCount`，并按它分档（一遍听懂 / 重听后听懂 / 还没听清）。
// 3. **没听出来的词要落到手上**。逐句看着可惜，跨句汇总成一排词才用得上
//    （一条出口：收进词汇本）。

/// 一次听写完的档位。
public enum ListeningStep: String, Sendable, Equatable, CaseIterable {

    /// 一遍就写对了（听力训练真正想要的状态）。
    case firstPass
    /// 听懂了（写对大半，但要么听了不止一遍、要么还不够准）。
    case understood
    /// 还没听清。
    case notYet

    public var displayName: String {
        switch self {
        case .firstPass: "一遍听懂"
        case .understood: "听懂了"
        case .notYet: "还没听清"
        }
    }

    public var symbol: String {
        switch self {
        case .firstPass: "checkmark.seal.fill"
        case .understood: "checkmark.circle.fill"
        case .notYet: "ear.trianglebadge.exclamationmark"
        }
    }

    /// 下一个一步做什么（对着人说话，不是评分术语）。
    public var advice: String {
        switch self {
        case .firstPass: "耳朵已经跟得上了，直接下一句"
        case .understood: "听清了就好；下一句试着只听一遍就下笔"
        case .notYet: "先别急着写：再听两遍，抓住主干词再补细节"
        }
    }
}

/// 一次听写（参考句 vs 学员自己写下来的那句）。
public struct ListeningAttempt: Sendable, Equatable, Identifiable {

    public var id: UUID
    public var drillID: String
    /// 参考句（提交后才允许显示）。
    public var reference: String
    /// 母语释义（提交后才允许显示）。
    public var translation: String
    /// 学员写下来的。
    public var typed: String
    /// 逐词对齐结果 —— 与跟读**同一把尺**（`ShadowingScorer`）。
    ///
    /// 刻意复用而不是另写一套比对：同一个「命中 / 漏词 / 多词」的口径，
    /// 学员在跟读页看到的绿红橙和这里才是同一个意思。
    public var comparison: ShadowingComparison
    /// 提交前这一句听了几遍。
    public var playCount: Int
    /// 是否用过慢速播放。
    public var usedSlowRate: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        drillID: String,
        reference: String,
        translation: String = "",
        typed: String,
        comparison: ShadowingComparison,
        playCount: Int,
        usedSlowRate: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.drillID = drillID
        self.reference = reference
        self.translation = translation
        self.typed = typed
        self.comparison = comparison
        self.playCount = max(playCount, 0)
        self.usedSlowRate = usedSlowRate
        self.createdAt = createdAt
    }

    public var accuracy: Double { comparison.accuracy }
    public var accuracyPercent: Int { comparison.accuracyPercent }
    public var missedWords: [String] { comparison.missedWords }
    public var step: ListeningStep {
        ListeningRule.step(playCount: playCount, accuracy: accuracy)
    }
}

/// 一轮听力的结算。
///
/// ⚠️ **三种形式共用这一个类型**（#309）：`mode` 决定 `headline` / `verdict` 怎么说。
/// 拆成三个类型的话，结算卡要么写三份、要么退化成三个几乎一样的结构，
/// 而三者的共同项（做了几句、平均多少、哪些词要收拾）本来就是同一件事。
public struct ListeningSummary: Sendable, Equatable {

    /// 这一轮练的是哪种形式。
    public var mode: ListeningMode
    public var attempted: Int
    /// 三种形式各自的「平均分」：精听 = 准确率，关键词 = 命中率，听句选义 = 正确率。
    public var averageAccuracy: Double
    /// 一遍就听懂（不用重听）的句数 —— 这一项比平均分更能说明听力（精听模式用）。
    public var firstPassCount: Int
    public var averagePlays: Double
    /// 听句选义答对的句数（其余两种模式恒为 0）。
    public var correctCount: Int
    /// 跨句汇总的「没听出来的词」（按出现次数降序）。
    public var missedWords: [String]

    public init(
        attempted: Int,
        averageAccuracy: Double,
        firstPassCount: Int,
        averagePlays: Double,
        missedWords: [String],
        mode: ListeningMode = .dictation,
        correctCount: Int = 0
    ) {
        self.mode = mode
        self.attempted = max(attempted, 0)
        self.averageAccuracy = min(max(averageAccuracy, 0), 1)
        self.firstPassCount = max(firstPassCount, 0)
        self.averagePlays = max(averagePlays, 0)
        self.correctCount = max(correctCount, 0)
        self.missedWords = missedWords
    }

    /// ⚠️ 空的**精听**结算（`mode` 写死 `.dictation`）。三种形式各自的空结算请走
    /// `empty(mode:)`，别图省事用它 —— 标签会张冠李戴。
    public static let empty = ListeningSummary(
        attempted: 0, averageAccuracy: 0, firstPassCount: 0, averagePlays: 0, missedWords: []
    )

    public var accuracyPercent: Int { Int((averageAccuracy * 100).rounded()) }
    public var isFirstPassPerfect: Bool { attempted > 0 && firstPassCount == attempted }
    public var hasAttempts: Bool { attempted > 0 }

    /// 「8 句 · 平均 78% · 3 句一遍听懂」。
    public var headline: String {
        guard hasAttempts else { return "这一轮一句都没写" }
        switch mode {
        case .dictation:
            return ["\(attempted) 句", "平均 \(accuracyPercent)%", "\(firstPassCount) 句一遍听懂"]
                .joined(separator: " · ")
        case .keyword:
            return ["\(attempted) 句", "平均抓住 \(accuracyPercent)% 的关键词"].joined(separator: " · ")
        case .meaning:
            return ["\(attempted) 句", "答对 \(correctCount) 句（\(accuracyPercent)%）"].joined(separator: " · ")
        }
    }

    /// 一句话总评（对着人说话）。
    public var verdict: String {
        guard hasAttempts else { return "下次试着写完一轮，我才能看出你的耳朵卡在哪。" }
        switch mode {
        case .dictation:
            let firstPassRatio = Double(firstPassCount) / Double(attempted)
            if firstPassRatio >= 0.8 { return "耳朵已经很松了：绝大多数句子一遍就过。" }
            if averageAccuracy >= 0.85 { return "听得很准，只是还需要多听一遍才敢下笔。" }
            if averageAccuracy >= 0.6 { return "大意抓住了，丢的多是功能词和词尾 —— 这正是听力的第一个坎。" }
            return "别灰心，这一轮先当摸底：把下面这些词认下来，下一轮会明显不一样。"
        case .keyword:
            if averageAccuracy >= 0.85 { return "主干抓得很稳 —— 换精听默写试试，把细节也抠下来。" }
            if averageAccuracy >= 0.6 { return "方向对：漏掉的多是句尾那几个词，听的时候留一段注意力给结尾。" }
            return "这一轮先别追细节：每一句只问自己「谁、做了什么」，抓住了再往下听。"
        case .meaning:
            let ratio = Double(correctCount) / Double(attempted)
            if ratio >= 0.85 { return "意思听得明白。接下来该练的是「听清」而不只是「听懂」—— 换默写模式。" }
            if ratio >= 0.6 { return "大意在，但选项之间容易混：多半是几个词没听清就顺着上下文猜了。" }
            return "四个选项像是因为句子本身没听完整。先回关键词模式，把主干听稳再回来。"
        }
    }

    /// 从一次听写记录汇总（约定为**新→旧**或任意顺序，口径与顺序无关）。
    public static func from(_ attempts: [ListeningAttempt]) -> ListeningSummary {
        guard !attempts.isEmpty else { return empty(mode: .dictation) }
        let accuracies = attempts.map(\.accuracy)
        let plays = attempts.map { Double($0.playCount) }
        return ListeningSummary(
            attempted: attempts.count,
            averageAccuracy: accuracies.reduce(0, +) / Double(accuracies.count),
            firstPassCount: attempts.filter { $0.step == .firstPass }.count,
            averagePlays: plays.reduce(0, +) / Double(plays.count),
            missedWords: rankMissedWords(attempts.map(\.missedWords)),
            mode: .dictation
        )
    }

    /// 空结算（这一轮一句都没交）。
    ///
    /// ⚠️ **必须带上模式**：结算卡的标签随模式变（「一遍听懂」/「整句全抓住」/「答对句数」）。
    /// 一律返回那个写死 `mode: .dictation` 的 `.empty` 的话，「关键词模式一句没交」
    /// 的结算卡会顶着默写的说法 —— 用户根本没在默写。
    static func empty(mode: ListeningMode) -> ListeningSummary {
        ListeningSummary(
            attempted: 0, averageAccuracy: 0, firstPassCount: 0,
            averagePlays: 0, missedWords: [], mode: mode
        )
    }

    /// 关键词捕捉的结算（漏词 = 没抓住的关键词）。
    public static func keyword(from captures: [KeywordCapture]) -> ListeningSummary {
        guard !captures.isEmpty else { return empty(mode: .keyword) }
        let ratios = captures.map(\.hitRatio)
        return ListeningSummary(
            attempted: captures.count,
            averageAccuracy: ratios.reduce(0, +) / Double(ratios.count),
            // 「一遍就听懂」在关键词模式下的对应物 = **整句全抓住**的句数。
            // 同一条口径（一次做对，不用返工），只是换了个说法。
            firstPassCount: captures.filter { $0.total > 0 && $0.caughtCount == $0.total }.count,
            averagePlays: captures.map { Double($0.playCount) }.reduce(0, +) / Double(captures.count),
            missedWords: rankMissedWords(captures.map(\.missed)),
            mode: .keyword
        )
    }

    /// 听句选义的结算（漏词 = 答错那些句子的关键词，交给词汇本收着）。
    public static func meaning(correct: [Bool], missedWords: [String], averagePlays: Double) -> ListeningSummary {
        guard !correct.isEmpty else { return empty(mode: .meaning) }
        let right = correct.filter { $0 }.count
        return ListeningSummary(
            attempted: correct.count,
            averageAccuracy: Double(right) / Double(correct.count),
            // 复用 `firstPassCount` 放「答对句数」：结算卡那两个数字的位置是同一处，
            // 只是标签随模式变（见 `ListeningSummaryCard`）。
            firstPassCount: right,
            averagePlays: averagePlays,
            missedWords: rankMissedWords([missedWords]),
            mode: .meaning,
            correctCount: right
        )
    }

    /// 跨句汇总漏词：出现次数多的在前；同次数的**保持首次出现的顺序**
    /// （并列时先错的那个更可能是同一条规律，先练它）。
    static func rankMissedWords(_ groups: [[String]]) -> [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for group in groups {
            for word in group {
                let key = word.lowercased()
                if counts[key] == nil { order.append(key) }
                counts[key, default: 0] += 1
            }
        }
        return order.sorted { lhs, rhs in
            let left = counts[lhs] ?? 0
            let right = counts[rhs] ?? 0
            if left != right { return left > right }
            return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
        }
    }
}

// MARK: - 当天账本

/// 当天听写账本（按句留最好的一次）。
///
/// 落 UserDefaults 而不是建表：一份 `dayKey + [句 id: 最佳准确率]`，
/// 几十字节、只读当前这一天，为它加一张表 + 一次迁移不划算。
public struct ListeningLog: Codable, Sendable, Equatable {

    /// 天键（`2026-09-22`）—— 与跟读素材同一把尺（`ShadowingDailyRule.dayKey`）。
    public var dayKey: String
    /// 句 id → 最佳准确率。
    public var best: [String: Double]

    public init(dayKey: String, best: [String: Double] = [:]) {
        self.dayKey = dayKey
        self.best = best
    }

    public static let empty = ListeningLog(dayKey: "")

    /// 今天的账本（跨天自动归零 —— 昨天写对的句子不该算进今天的进度）。
    public static func today(_ date: Date = Date(), calendar: Calendar = .current) -> ListeningLog {
        ListeningLog(dayKey: ShadowingDailyRule.dayKey(date, calendar: calendar))
    }

    /// 换天就清空。加载持久化数据时必须过一道 —— 否则「昨天练了 6 句」会一直挂着。
    public func rolledOver(to date: Date = Date(), calendar: Calendar = .current) -> ListeningLog {
        let key = ShadowingDailyRule.dayKey(date, calendar: calendar)
        return dayKey == key ? self : ListeningLog(dayKey: key)
    }

    /// 记一次成绩（只留更好的那次：同一句写两遍不该把成绩拉低）。
    ///
    /// `at` 显式传入而不是在里面读 `Date()`：跨天归零这一步必须能被测到
    /// （「昨天写对的句子挂进今天的进度」是最容易被忽略的那种错），
    /// 而偷偷读一次系统时钟的纯函数是测不了的。
    public func recording(
        drillID: String,
        accuracy: Double,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> ListeningLog {
        let value = min(max(accuracy, 0), 1)
        var next = self
        // 应用跨天开着不关时，内存里那份账本还是昨天的 —— 这一笔要算在今天，
        // 不能并进昨天的桶里（否则「今天的平均分」会把昨天的句子拌进来）。
        let key = ShadowingDailyRule.dayKey(date, calendar: calendar)
        if next.dayKey != key { next = ListeningLog(dayKey: key) }
        next.best[drillID] = max(next.best[drillID] ?? 0, value)
        return next
    }

    /// 今天写过的句数。
    public var resolvedCount: Int { best.count }

    /// 今天写过的这些句子的平均准确率（一句都没写 = nil）。
    public var averageAccuracy: Double? {
        guard !best.isEmpty else { return nil }
        let values = Array(best.values)
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - 规则（纯函数）

public enum ListeningRule {

    /// 一轮几句。**刻意不是 20 句**：听写要逐字打出来，20 句是负担不是训练；
    /// 8 句刚好是一次能坐下来做完、又够看出规律的量。
    public static let roundSize = 8

    /// 「一遍听懂」的准确率门槛。
    public static let firstPassAccuracy = 0.85

    /// 「听懂了」的门槛（低于它算没听清）。
    public static let understoodAccuracy = 0.6

    /// 慢速播放的语速倍数。
    ///
    /// 刻意**只降到 0.7**：再慢（0.5）会把连读和弱读都拆散，学员听清了「每个词」，
    /// 却再也听不出真实的语流 —— 而精听要练的恰恰是语流。
    public static let slowRateFactor: Float = 0.7

    /// 分档。
    ///
    /// ⚠️ 「一遍听懂」必须**同时**满足两件事：只听了一遍 **且** 写得够准
    /// （`firstPassAccuracy`）。只按遍数判会出现「只听一遍、写对一半也叫一遍听懂」——
    /// 那是把一个还没听懂的状态贴上了最好听的标签，比不给标签更误导。
    /// 反过来，只按分数判又会把「听了五遍才凑对」算成听懂。
    public static func step(playCount: Int, accuracy: Double) -> ListeningStep {
        if accuracy < understoodAccuracy { return .notYet }
        if playCount <= 1 && accuracy >= firstPassAccuracy { return .firstPass }
        return .understood
    }

    /// 今天这一轮听哪几句。
    ///
    /// 与跟读素材的选法同构（按日期轮转）：同一天稳定、相邻两天不重样 ——
    /// 否则「今天练的永远是素材里的前 8 句」会让后半批句子永远没人练。
    public static func round(
        from drills: [ShadowingDrill],
        date: Date = Date(),
        calendar: Calendar = .current,
        pick: Int = roundSize
    ) -> [ShadowingDrill] {
        guard !drills.isEmpty else { return [] }
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let start = ((dayOfYear - 1) % drills.count + drills.count) % drills.count
        let take = min(max(pick, 1), drills.count)
        return (0..<take).map { drills[(start + $0) % drills.count] }
    }

    // MARK: 无文本

    /// 听写会话里**会出现在屏幕上**的全部文案（不含题目本身）。
    ///
    /// ⚠️ 为什么把文案抽成一份数据，而不是散在 View 里：这是「无文本听力」这条规则
    /// 唯一可断言的地方。卡片只读 `id` / `translation`（且都在提交后），但页面上的说明
    /// 文案是有人会随手加的地方 —— 一句「提示：这句里有 check-in」就能把训练变成听写
    /// 开卷考，而它只会以「怎么感觉变简单了」的形式被用户察觉。
    /// 把文案收到这里 + `leaksReference` 逐条检查，这种退化会在测试里立刻变红。
    public struct ListeningChrome: Sendable, Equatable {
        public var title: String
        public var subtitle: String
        public var counterText: String
        public var playsText: String
        public var playButton: String
        public var replayButton: String
        public var stopButton: String
        public var slowLabel: String
        public var fastLabel: String
        public var answerPlaceholder: String
        public var submitButton: String
        /// 提交按钮的 `.help`：说清「为什么必须先写再看」。
        public var submitHelp: String
        public var cancelHelp: String

        /// 逐条列出来（断言用）。
        public var all: [String] {
            [
                title, subtitle, counterText, playsText, playButton, replayButton,
                stopButton, slowLabel, fastLabel, answerPlaceholder, submitButton,
                submitHelp, cancelHelp
            ]
        }
    }

    /// 组装这一刻的界面文案。**入参只有句序、遍数、语速档与模式** ——
    /// 没有任何与原文有关的输入，所以「文案里不可能带出原文」在类型层面就成立，
    /// 下面的断言只是把这条不变量钉死。
    ///
    /// ⚠️ `mode` 只影响**怎么称呼这件事**（标题 / 输入框引导语 / 提交按钮），
    /// 不影响「屏幕上不会出现原文」这条不变量 —— 三种形式都不给原文（听句选义给的是**释义**，
    /// 而释义本来就是那道题的选项）。
    public static func chrome(
        index: Int,
        total: Int,
        playCount: Int,
        slow: Bool,
        mode: ListeningMode = .dictation
    ) -> ListeningChrome {
        ListeningChrome(
            title: mode.title,
            subtitle: mode.blurb,
            counterText: "第 \(index + 1) / \(total) 句",
            playsText: playCount == 0 ? "先听，再答" : "已经听了 \(playCount) 遍",
            playButton: "听这一句",
            replayButton: "重新听一遍",
            stopButton: "停止播放",
            slowLabel: slow ? "慢速" : "原速",
            fastLabel: slow ? "切回原速" : "切到慢速",
            answerPlaceholder: mode.answerPlaceholder,
            submitButton: mode.submitTitle,
            submitHelp: mode == .keyword
                ? "写完再看这一句里有哪几个关键信息词 —— 先看就等于开卷"
                : "写完再看原文，顺序反过来就不算听写了",
            cancelHelp: "退出这一轮（今天的成绩已经记下了，下次接着来）"
        )
    }

    /// 屏幕上这些文案里，有没有泄露参考句的词。
    ///
    /// 只比 **≥ 3 个字母**的词：英语里的 `a` / `I` / `to` 之类会撞进任意文案
    /// （`at` 撞 `that`），拿它们当判据只会得到一堆假阳性。
    ///
    /// ⚠️ 连字符要**再拆一层**：`check-in` 与 `check` 是同一个词根的两种写法，
    /// 拿整串去比会让「这句里有 check-in」这种泄露漏过去（两边拆法一致，不会引入假阳性）。
    public static func leaksReference(chrome: [String], reference: String) -> Bool {
        let secret = Set(probeWords(reference))
        guard !secret.isEmpty else { return false }
        for line in chrome {
            if !Set(probeWords(line)).isDisjoint(with: secret) { return true }
        }
        return false
    }

    /// 比对用的词：与 `ShadowingScorer.words` 同源，再把连字符拆开、丢掉短词。
    private static func probeWords(_ text: String) -> [String] {
        ShadowingScorer.words(text)
            .flatMap { $0.split(separator: "-").map(String.init) }
            .filter { $0.count >= 3 }
            .map { $0.lowercased() }
    }
}
