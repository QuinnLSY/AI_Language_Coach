import CoreGraphics

/// 窄窗口的森林退化档位（批次八 · H 边界状态）。
///
/// 地面带（`ForestGroundBand`）的高度是钉死的（`TreeViewport.groundBandHeight`），
/// 拖矮窗口挤不到它 —— 会出问题的是**宽度**：分割线拖到底（树面板最小 300pt）时，
/// 历史公式的居民下限是 3 只，会叠在一起，花草也挤成一团。
/// 这里把「多宽该有多少动物 / 灌木 / 小花」收成一个纯函数，三档退化：
///
/// - **正常档**（量化宽 ≥448）：沿用批次四以来的公式，行为一分不改；
/// - **窄档**（336..<448）：居民收敛到 2–3 只，灌木只留 1 丛、花 2 朵；
/// - **极窄档**（<336）：只留 1 只居民（`homePosition` 自然把它摆到正中），
///   灌木清空、花 1 朵 —— 林子不能空，但也不再拥挤。
public enum ForestGroundPlan {

    public struct Plan: Equatable {
        /// 在场居民数（下限 1：再窄也不能空场）。
        public let residents: Int
        /// 灌木上限。
        public let bushes: Int
        /// 小花上限。
        public let flowers: Int

        public init(residents: Int, bushes: Int, flowers: Int) {
            self.residents = residents
            self.bushes = bushes
            self.flowers = flowers
        }
    }

    /// - `width`：面板宽（内部按 `step` 量化）。
    /// - `unlocked`：**已解锁的伙伴数**（⑦-C③，`ForestUnlock.companions`）。
    ///   宽度决定「这个面板摆得下几只」，解锁决定「林子里现有几位」，取小者 ——
    ///   不然「再练 25 分钟来一位新伙伴」就是句空话（宽度早就把 8 只排满了）。
    /// - `step`：量化档宽（与 `ForestGroundBand` 同一步长）——一切离散决策只在档位上变化，
    ///   拖动分割线时才不会逐帧重排。传入已量化的宽度时结果是幂等的。
    ///
    /// ⚠️ `unlocked` **刻意不给默认值**：漏传就会静默沿用旧行为（只按宽度排），
    /// 而「森林随练习长起来」这件事会无声失效。
    public static func plan(width: CGFloat, unlocked: Int, step: CGFloat = 28) -> Plan {
        let qw = (width / step).rounded() * step
        let cap = max(unlocked, 1)
        if qw < 336 {
            return Plan(residents: min(1, cap), bushes: 0, flowers: 1)
        }
        // 窄档：历史公式在 336…448 会给 3–5 只；为避免拖过边界时 5→2 的跳变，
        // 只把公式**钳**到 2…3（灌木与花才是这一档真正让路的东西）。
        if qw < 448 {
            let residents = min(max(Int((qw - 120) / 70) + 1, 2), 3)
            return Plan(residents: min(residents, cap), bushes: 1, flowers: 2)
        }
        return Plan(
            residents: min(min(max(Int((qw - 120) / 70) + 1, 3), 8), cap),
            bushes: min(1 + Int(qw / 190), 4),
            flowers: min(2 + Int(qw / 150), 7)
        )
    }
}
