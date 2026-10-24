import Foundation

// MARK: - 埋点名

/// 耗时采集的埋点（#668）。
///
/// 为什么要有这张表：改前全仓**一处耗时打点都没有** —— 「启动慢 / 切页卡 / 老师回得慢」
/// 全是体感，优化只能靠猜，改完也不知道有没有真的变快（更可能只是换了台机器、换了心情）。
/// 名字收在这里而不是散成字符串字面量，是为了让「一共在量哪几件事」一眼看全，
/// 单测也才能钉住落点、防住「埋点被删了但没人发现」。
///
/// ⚠️ 只量**耗时与次数**，不量内容：样本里不许出现转写文本、学员发言、Prompt 正文
/// （与 `LogBus` 同一条隐私纪律，见 AGENTS.md §7）。
public enum PerfMark: String, Sendable, CaseIterable {

    /// App 构造 → 界面揭开（`isBooting` 翻 false 那一刻）。
    case launch = "launch"
    /// 切页：进 `go(to:)` → 这一页的数据就位（含 `open*()` 里顺带的那次取数）。
    case section = "section"
    /// 老师首字：请求发出 → 收到第一个正文增量。
    case firstToken = "firstToken"

    public var title: String {
        switch self {
        case .launch: return "启动到可交互"
        case .section: return "切页到就绪"
        case .firstToken: return "老师首字"
        }
    }

    /// 完整样本名。`subject` 是细分维度（切页就是目标页的 `rawValue`）。
    ///
    /// 汇总按**完整名**分组，所以「切到学习进度」与「切到词典」各自有一条 ——
    /// 「切页平均 300ms」这种平均数会正好把「某一页特别慢」抹平。
    public func sampleName(subject: String? = nil) -> String {
        guard let subject, !subject.isEmpty else { return rawValue }
        return rawValue + "." + subject
    }
}

// MARK: - 样本与汇总

/// 一次采样：哪件事、花了多久、什么时候。
public struct PerformanceSample: Sendable, Equatable, Identifiable {
    /// 单调递增的序号（同一毫秒内的两笔也能区分先后）。
    public let id: Int
    public let name: String
    public let seconds: Double
    public let at: Date

    public var milliseconds: Double { seconds * 1000 }
}

/// 同名样本的汇总（面板上一次读一行）。
public struct PerformanceSummary: Sendable, Equatable, Identifiable {
    /// 完整名（`mark[.subject]`）。
    public let name: String
    public let count: Int
    /// 最近一次。
    public let lastSeconds: Double
    /// 中位数（样本数为偶数时取**上中位** —— 看的是「通常要多久」，不是精确统计）。
    public let medianSeconds: Double
    public let maxSeconds: Double

    public var id: String { name }

    /// 名字前缀解析出来的埋点；名字不认识就是 nil。
    public var mark: PerfMark? {
        let head = name.split(separator: ".").first.map(String.init) ?? name
        return PerfMark(rawValue: head)
    }

    /// 细分维度（切页就是目标页的 `rawValue`）；没有就是 nil。
    public var subject: String? {
        let parts = name.split(separator: ".").map(String.init)
        return parts.count > 1 ? parts[1...].joined(separator: ".") : nil
    }

    /// 展示名：`埋点标题 · 细分`。
    ///
    /// 分段维度在这里留的是**原始值**（例如 `progress`）：把它翻成中文要认识
    /// `AppSection`，那是 `AIDomain` 的事 —— `AppCore` 不认得页面，界面自己翻。
    public var title: String {
        guard let mark else { return name }
        guard let subject else { return mark.title }
        return "\(mark.title) · \(subject)"
    }
}

// MARK: - 文案

public enum PerformanceText {
    /// 耗时文案：不到 1 秒走毫秒（"820 ms"），否则走秒（"1.24 s"）。
    ///
    /// 分档而不是一律毫秒：启动 32 秒打成 "32000 ms" 看不出量级，
    /// 一律秒又会把 12ms 打成 "0.01 s"（看着像没测到）。
    public static func seconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value < 1 { return "\(Int((value * 1000).rounded())) ms" }
        return String(format: "%.2f s", value)
    }
}

// MARK: - 采集器

/// 进程内耗时采集器：环形缓冲 + 按名汇总。
///
/// 设计取舍：
/// - **只住内存**（不落盘、不外发）：它记的是「哪件事花了多久」，退出即清空；
///   落盘就成了又一份要备份、要清理、要披露的用户数据，而收益只是跨启动对比 ——
///   那件事等真要优化时再说。
/// - **环形缓冲封顶**：一天聊几百轮、切几百次页，数组不封顶就单调增长
///   （不报错，只是慢慢吃掉内存，最典型的「没人发现」型问题）。
/// - **所有方法都是同步的**：`NSLock.lock()` 是 `noasync`，锁操作不能出现在
///   `async` 函数里（#S3 并发纪律）。锁只在这些同步方法内部加、加完立刻放。
public final class PerformanceTrace: @unchecked Sendable {

    public static let shared = PerformanceTrace()

    /// 环形缓冲容量（满了丢最旧的）。
    public let capacity: Int

    private let lock = NSLock()
    private var samples: [PerformanceSample] = []
    private var nextID = 0
    private var launchDate: Date?

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    // MARK: 写入

    /// 记下冷启动的起点（App 构造的那一刻）。
    public func markLaunch(now: Date = Date()) {
        lock.lock()
        launchDate = now
        lock.unlock()
    }

    /// 冷启动起点；没记过就是 nil。
    public var launch: Date? {
        lock.lock()
        defer { lock.unlock() }
        return launchDate
    }

    /// 记一笔耗时（秒）。
    ///
    /// ⚠️ 负数与非有限值一律丢：`Date()` 会回拨（改系统时间 / NTP 校正），
    /// 传错单位（把毫秒当秒）也会进来 —— 一条 -3s 会让中位数彻底失真，
    /// 而「数字不对」比「没有数字」更危险（照着它做优化）。
    public func record(name: String, seconds: Double, at date: Date = Date()) {
        guard seconds.isFinite, seconds >= 0 else { return }
        lock.lock()
        samples.append(PerformanceSample(id: nextID, name: name, seconds: seconds, at: date))
        nextID += 1
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        lock.unlock()
        // 顺手落一行日志：设置页之外（控制台 / 日志卡）也能读到。
        // 走 `.debug` —— 默认级别就是它，但用户把级别抬到 info 以上就自动安静。
        AppLog.debug("\(name) \(PerformanceText.seconds(seconds))", category: "perf")
    }

    /// 从 `start` 到 `now` 记一笔。
    ///
    /// ⚠️ `now` 是参数而不是在函数里再取一次 `Date()`：判据要能**喂**一个确定的
    /// 时刻。函数里自己取钟的话，测出来的其实是「机器此刻有多快」（时序型假闸）。
    public func record(name: String, since start: Date, now: Date = Date()) {
        record(name: name, seconds: now.timeIntervalSince(start), at: now)
    }

    /// 从冷启动起点记一笔。
    ///
    /// ⚠️ 没记过起点就**不记**：那种情况下记出来的数只是「从这个对象被建起到现在」，
    /// 一条来历不明的耗时比没有更误导。
    public func recordSinceLaunch(_ mark: PerfMark, now: Date = Date()) {
        guard let start = launch else { return }
        record(name: mark.sampleName(), seconds: now.timeIntervalSince(start), at: now)
    }

    // MARK: 读取

    /// 已存样本数（环形缓冲内）。
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// 最近 `limit` 条（按记录顺序，最早在前）。
    public func recent(limit: Int = 50) -> [PerformanceSample] {
        lock.lock()
        defer { lock.unlock() }
        return Array(samples.suffix(max(0, limit)))
    }

    /// 按完整名汇总：次数 / 最近 / 中位 / 最大。
    ///
    /// ⚠️ 顺序按**首次出现**，不按耗时排：面板上每切一页就重排一次的话，
    /// 人眼根本追不住哪一行是哪一页。
    public func summary() -> [PerformanceSummary] {
        lock.lock()
        let snapshot = samples
        lock.unlock()

        var order: [String] = []
        var grouped: [String: [Double]] = [:]
        for sample in snapshot {
            if grouped[sample.name] == nil { order.append(sample.name) }
            grouped[sample.name, default: []].append(sample.seconds)
        }
        return order.compactMap { name in
            guard let values = grouped[name], let last = values.last else { return nil }
            let sorted = values.sorted()
            return PerformanceSummary(
                name: name,
                count: values.count,
                lastSeconds: last,
                medianSeconds: sorted[sorted.count / 2],
                maxSeconds: sorted[sorted.count - 1]
            )
        }
    }

    public func clear() {
        lock.lock()
        samples.removeAll()
        launchDate = nil
        lock.unlock()
    }
}
