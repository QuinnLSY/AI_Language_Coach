import Foundation

/// 坏库隔离目录的保留策略（纯函数，便于单测与审计）。
///
/// 隔离的意义是「**留证据**」：库坏掉那一刻绝不删文件，用户还有机会找回里面的会话。
/// 但它是**只进不出**的 —— 每坏一次就多一份（主库 + WAL + SHM），一份动辄 1 MB 以上，
/// 攒上几年就是几百 MB，而存储面板还在报「1 MB」，没人看得见（#674）。
///
/// 口径与备份包同款（留最近几份 + 超龄的不再留），但有两条硬边界：
/// 1. **最近那份永远不碰** —— 它是上一次的抢救现场，最可能还有用；
/// 2. 只清**超出保留窗口**的老副本，且进废纸篓而不是直接删。
public enum QuarantineRetention {

    /// 最多保留几份（按修改时间从新到旧数）。
    public static let maxKeptCopies = 3

    /// 超过这个天数的副本不再保留。
    public static let maxAgeDays = 60

    /// 隔离目录里的一个副本。
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var modifiedAt: Date

        public init(name: String, modifiedAt: Date) {
            self.name = name
            self.modifiedAt = modifiedAt
        }
    }

    /// 应当被回收的副本名（**纯函数**：给同样的输入永远给同样的输出）。
    ///
    /// - Parameters:
    ///   - entries: 隔离目录里的全部副本（名字 + 修改时间）。
    ///   - now: 现在（注入是为了让测试不依赖真实时钟）。
    public static func prunePlan(entries: [Entry], now: Date = Date()) -> [String] {
        // 从新到旧：保留窗口是按「最近」算的，顺序错了就会清掉刚坏的那一份。
        let sorted = entries.sorted { $0.modifiedAt > $1.modifiedAt }
        let cutoff = now.addingTimeInterval(-Self.maxAgeSeconds)

        var keep: Set<String> = []
        for (index, entry) in sorted.enumerated() {
            if index == 0 {
                keep.insert(entry.name) // 最近那份：无条件留着
                continue
            }
            if index < maxKeptCopies, entry.modifiedAt >= cutoff {
                keep.insert(entry.name)
            }
        }
        return sorted.filter { !keep.contains($0.name) }.map(\.name)
    }

    private static var maxAgeSeconds: TimeInterval {
        TimeInterval(maxAgeDays) * 24 * 60 * 60
    }
}
