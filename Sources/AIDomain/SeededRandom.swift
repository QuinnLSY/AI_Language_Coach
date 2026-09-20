import Foundation

// MARK: - 确定性随机（「按天恒定」这类需求的基础设施）
//
// 为什么需要它：每日推荐、每日跟读这类「一天给一批东西」的功能，**同一天必须拿到同一批**
// （用户练到第 7 个词去泡了杯茶，回来不该发现整批都换了）。
// 用 `SystemRandomNumberGenerator` 就做不到 —— 每次启动抽出来的都不一样。
//
// 取而代之：把「日期 + 语言」压成一个**整数种子**，再用确定性算法打乱。
// 好处是**纯函数、不落盘、不需要缓存失效逻辑**，还能脱机单测。

/// 由整数种子推出的确定性随机源（splitmix64）。
///
/// 选 splitmix64 的理由：只有几行、输出质量足够做「打乱数组」这种用途，
/// 且不依赖任何外部库（AIDomain 不 import 第三方）。
public struct SeededRandomGenerator: RandomNumberGenerator {

    private var state: UInt64

    public init(seed: UInt64) {
        // 0 号种子会让 splitmix64 头几个输出偏弱，换一个非零常量起步。
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// 按天（或任何稳定标识）派生种子的规则。
public enum DailySeed {

    /// 由「用途 + 日期键 + 语言」推出一个跨进程稳定的种子。
    ///
    /// - ⚠️ **绝不能用 `Hasher`**：它是每进程随机种子的，跨启动算出来不一样
    ///   （与 `MaterialKit.stableID` 同款理由）。这里走 FNV-1a 64。
    /// - 语言进种子：换学习语言就该换一批（`ShadowingDailyRule` 同款口径 ——
    ///   每日跟读是换语言即作废）。
    /// - `purpose` 进种子：以后别的「按天轮换」功能各走各的序列，互不牵连。
    public static func seed(
        dayKey: String,
        language: String = "",
        purpose: String = "daily-words"
    ) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func feed(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        for byte in "\(purpose)\u{1}\(dayKey)\u{1}\(language)".utf8 {
            feed(byte)
        }
        return hash
    }
}
