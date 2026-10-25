import Foundation

/// 朗读音频缓存的**容量口径**（#672）。
///
/// 为什么不能只按「多少条」封顶：一条音频的体积跨度极大 ——
/// 单词一个字节几十 KB，云端整段朗读一段两千字的短文能把整段音频一次带回（数 MB）。
/// 只数条数的话，48 条短文就是上百兆常驻内存，而它涨上去的方式**不报错、也不卡顿**，
/// 只会在哪天机器内存紧张时被系统一并回收（表现为「朗读突然全部重新合成一遍」）。
///
/// 所以这里两条线一起收：
/// - **单条上限**：超过的干脆不进缓存（它本来也不太会被复读）；
/// - **总量上限**：按字节，FIFO 淘汰到装得下为止。
///
/// ⚠️ 纯函数、不碰 I/O：容量是能单测的东西，就该让它能被单测。
public enum SpeechAudioCachePolicy {

    /// 缓存里音频的总字节上限。
    ///
    /// 24 MB 的来由：常驻一段朗读音频是为了**复读同一句**不再重新合成，
    /// 而跟读 / 影子跟读一次最多来回十几句；24 MB 装得下几十句短文或几百个单词，
    /// 再大就是拿内存换一个几乎不会发生的命中。
    public static let totalByteLimit = 24 * 1024 * 1024

    /// 单条上限：超过它就不进缓存。
    public static let singleItemByteLimit = 4 * 1024 * 1024

    /// 这一份音频值不值得占缓存。
    public static func allowsCaching(bytes: Int) -> Bool {
        bytes > 0 && bytes <= singleItemByteLimit
    }

    /// 算出要淘汰哪些键，才能让「现有 + 新来的」不超总量。
    ///
    /// - Parameters:
    ///   - entries: 现有条目，**按从旧到新**排列（调用方维护的就是 FIFO 顺序）。
    ///   - incoming: 将要写入的这一条的体积。
    /// - Returns: 要删除的键，从旧到新。
    ///
    /// ⚠️ 单条超限（调用方应先过 `allowsCaching`）时这里会一路清到底 ——
    /// 那也比把总量撑破好；正常情况下它不该走到那一步。
    public static func evictionPlan(
        entries: [(key: String, bytes: Int)],
        incoming: Int
    ) -> [String] {
        var total = incoming
        for entry in entries { total += entry.bytes }
        guard total > totalByteLimit else { return [] }

        var victims: [String] = []
        for entry in entries {
            guard total > totalByteLimit else { break }
            victims.append(entry.key)
            total -= entry.bytes
        }
        return victims
    }
}
