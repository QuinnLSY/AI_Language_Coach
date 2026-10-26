import Foundation

/// 「哪些附件还在被引用」这个事实的两种形态。
///
/// ⚠️ 刻意做成枚举而不是 `Set<String>`：清理 = 把用户的文件扔进废纸篓，而**取不到引用**时
/// 空集合恰恰是最顺手的默认值 —— 一旦那样写，「读库失败」就会被下游解释成
/// 「一个附件都没被引用」，于是全部在用素材被当孤儿清掉。
/// 枚举逼着调用方显式承认「我确实不知道」，这里不存在「失败即等于零」的默认值。
public enum AttachmentReferenceIndex: Sendable, Equatable {
    /// 引用表读到了，就是这些（可以是空集合 —— 真的一个附件都没发过）。
    case verified(Set<String>)
    /// 引用表没读到：此时**禁止**做任何删除判定，只能收手。
    case unavailable(reason: String)

    /// 引用个数（`unavailable` 时为 nil：不知道 ≠ 0）。
    public var count: Int? {
        switch self {
        case .verified(let names): names.count
        case .unavailable: nil
        }
    }
}

/// 目录里一个待判定的候选文件。
public struct AttachmentOrphanCandidate: Sendable, Equatable {
    /// 存储名（裸文件名，不带 `attachments/` 前缀）。
    public var name: String
    /// 最后修改时间，用来做「新鲜保护」。
    public var modifiedAt: Date
    public var bytes: Int64

    public init(name: String, modifiedAt: Date, bytes: Int64) {
        self.name = name
        self.modifiedAt = modifiedAt
        self.bytes = bytes
    }
}

/// 一次孤儿清扫的判定结果。
public struct AttachmentOrphanPlan: Sendable, Equatable {
    /// 判定可回收的**存储名**（由调用方翻译成 URL）。
    public var removable: Set<String>
    /// 还在被消息引用而留下的。
    public var keptReferenced: Int
    /// 因为太新鲜而留下的（刚进来、可能还没落库）。
    public var keptRecent: Int
    /// 本进程刚复制进来、还没来得及被引用就撞上清扫的。
    public var keptInFlight: Int
    /// 预计释放的字节。
    public var freedBytes: Int64
    /// 非空 = 这一轮根本没资格判定，调用方必须**一个文件都不动**。
    public var blockReason: String?

    public init(
        removable: Set<String> = [],
        keptReferenced: Int = 0,
        keptRecent: Int = 0,
        keptInFlight: Int = 0,
        freedBytes: Int64 = 0,
        blockReason: String? = nil
    ) {
        self.removable = removable
        self.keptReferenced = keptReferenced
        self.keptRecent = keptRecent
        self.keptInFlight = keptInFlight
        self.freedBytes = freedBytes
        self.blockReason = blockReason
    }
}

/// 孤儿附件回收策略（纯函数）。
///
/// 为什么需要这一趟：清缓存会按时间清走会话流水，而它们引用过的图片早已**复制**进
/// `attachments/` —— 删掉的是目录里的引用，文件本体留在磁盘上，慢慢攒成一座谁也说不清的堆
/// （本机实测：6 个文件 9.5 MB，其中两张是同一张图存了两遍）。
///
/// ⚠️ 这里的每一条规则都偏保守，因为判错的方向是**不可逆**的：把一个还在用的素材判成孤儿，
/// 用户看到的是某条旧消息里的图突然成了空白框。宁可留着，不可错杀。
public enum AttachmentOrphanPolicy {

    /// 新鲜保护窗口：24 小时。
    ///
    /// 三条理由，缺一不可：
    /// ① 覆盖「复制进目录 → 消息落库」这段在途时间（哪怕中途崩一次再起来，也不至于把还没被引用的素材扫掉）；
    /// ② 给用户留出「到废纸篓里捞回来」的时间窗；
    /// ③ 兜住系统时钟回拨 / 时区切换那类会让「现在」突然变小的情况。
    public static let graceInterval: TimeInterval = 24 * 60 * 60

    /// - Parameters:
    ///   - candidates: 目录里扫到的候选文件。
    ///   - references: 引用表。**取不到必须传 `.unavailable`**。
    ///   - inFlight: 本进程刚复制进来、还在等待被消息引用的存储名。
    public static func plan(
        candidates: [AttachmentOrphanCandidate],
        references: AttachmentReferenceIndex,
        inFlight: Set<String> = [],
        now: Date
    ) -> AttachmentOrphanPlan {
        switch references {
        case .unavailable(let reason):
            // ⚠️ fail-closed：引用不明时零删除。这条是本文件的核心，拆了它整份保护就没了。
            return AttachmentOrphanPlan(blockReason: "引用不明，这一轮不清理：\(reason)")
        case .verified(let referencedRaw):
            // 引用表里可能混着带 `attachments/` 前缀的写法：统一取末段再比。
            // 不归一的话，调用方只要传错一格，全部在用素材都会被判成孤儿。
            let referenced = Set(referencedRaw.map { AttachmentReferenceKey.bare($0) })
            let cutoff = now.addingTimeInterval(-Self.graceInterval)

            var removable: Set<String> = []
            var freed: Int64 = 0
            var keptReferenced = 0
            var keptRecent = 0
            var keptInFlight = 0

            for candidate in candidates {
                if referenced.contains(candidate.name) {
                    keptReferenced += 1
                    continue
                }
                if inFlight.contains(candidate.name) {
                    keptInFlight += 1
                    continue
                }
                if candidate.modifiedAt > cutoff {
                    keptRecent += 1
                    continue
                }
                removable.insert(candidate.name)
                freed += candidate.bytes
            }

            return AttachmentOrphanPlan(
                removable: removable,
                keptReferenced: keptReferenced,
                keptRecent: keptRecent,
                keptInFlight: keptInFlight,
                freedBytes: freed
            )
        }
    }
}

/// 引用入库 / 比对时的唯一口径：只认裸文件名。
///
/// 落库的 `storedPath` 带 `attachments/` 前缀是为了自解释（`AttachmentStore`），
/// 比对时两边都要归一 —— 抽出成一处是为了让「到底按什么比」不会因为某处忘了处理而漂移。
public enum AttachmentReferenceKey {
    public static func bare(_ storedPath: String) -> String {
        (storedPath as NSString).lastPathComponent
    }
}

/// 一次清扫的结果（供调用方落日志 / 将来给 UI 展示释放量）。
public struct AttachmentSweepSummary: Sendable, Equatable {
    /// 实际删掉的数量。
    public var removed: Int
    /// 实际释放的字节（只统计真的进了废纸篓的那些）。
    public var freedBytes: Int64
    /// 因为还在被引用而留下的数量。
    public var keptReferenced: Int
    /// 因为太新鲜而留下的数量。
    public var keptRecent: Int
    /// 非空 = 整轮被跳过（引用不明），一个文件都没动。
    public var skippedReason: String?

    public init(
        removed: Int = 0,
        freedBytes: Int64 = 0,
        keptReferenced: Int = 0,
        keptRecent: Int = 0,
        skippedReason: String? = nil
    ) {
        self.removed = removed
        self.freedBytes = freedBytes
        self.keptReferenced = keptReferenced
        self.keptRecent = keptRecent
        self.skippedReason = skippedReason
    }

    public static let nothing = AttachmentSweepSummary()
}
