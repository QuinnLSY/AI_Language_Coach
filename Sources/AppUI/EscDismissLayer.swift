import SwiftUI

// MARK: - 浮层叠放的 Esc 仲裁（#S2-1）
//
// ⚠️ 这里曾写着「浮层是条件渲染的，同屏最多一个 ESC 挂载点」—— **前提是错的**。
// 实测：`openMaterialUpload()` / `openScenarioComposer()` 的唯一入口就在情景面板头部，
// 两个函数都**只置位自己、不关 `showingScenarios`**，所以「情景面板 + 上传材料」是**每次点击必现**
// 的共存；设置页还有第 5 个挂载点（它右上角 × 用原生 `keyboardShortcut(.escape)`）。
//
// 后果：`escCloses` 挂的隐形按钮彼此**毫不知情、地位平等**，同屏几个就有几个同抢
// `.escape` 的键等价项，谁被命中交给 SwiftUI 内部顺序（**仓库源码里判定不了，也不该依赖**）。
// 实测最坏情况：一次 Esc 关掉**底下**那层，顶层还挂着，用户得再按一次。
//
// 现在改成**栈顶仲裁**：只有叠在最上面的那一层挂 Esc，其余层一个键等价项都不注册。

/// 可以被 Esc 关闭的浮层。
///
/// 顺序即叠放顺序（`topmost` 的判定依据）：
/// - `globalSearch` 挂在根 ZStack **闭合之后**的 `.overlay` 里 → 永远最上层；
/// - `materialUpload` / `scenarioComposer` 是从情景面板头部竖起来的，压在情景面板之上
///   （`MainView` 里 zIndex 20 vs 情景面板 18）；两者之间由全屏遮罩互斥，不会同时出现；
/// - `settings` 与上面两层同为 zIndex 20 但**声明更早**（`MainView:88`）→ 同屏时在它们下面；
/// - `scenarios`（zIndex 18）垫底。
public enum EscDismissLayer: String, Hashable, Sendable, CaseIterable {
    case globalSearch
    case scenarioComposer
    case materialUpload
    case settings
    case scenarios

    /// 当前该响应 Esc 的那一层；nil = 没有浮层。
    ///
    /// 纯函数（不碰 `@Observable` 状态）→ 32 种组合都能直接单测，不必渲染。
    public static func topmost(
        settings: Bool,
        scenarios: Bool,
        materialUpload: Bool,
        scenarioComposer: Bool,
        globalSearch: Bool
    ) -> EscDismissLayer? {
        if globalSearch { return .globalSearch }
        if scenarioComposer { return .scenarioComposer }
        if materialUpload { return .materialUpload }
        if settings { return .settings }
        if scenarios { return .scenarios }
        return nil
    }
}