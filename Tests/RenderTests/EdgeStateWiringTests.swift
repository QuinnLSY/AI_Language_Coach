import XCTest

/// 批次八 · H（边界状态）的**接线哨兵**。
///
/// 为什么用源码扫描：欢迎判据 / 错误举牌的接线是「启动时序 + 用户看不见的后备路径」，
/// 离屏渲染拼不出「没配置模型时会不会举牌」—— 能钉住的只有源码本身。
final class EdgeStateWiringTests: XCTestCase {

    /// 仓库根：Tests/RenderTests/本文件.swift → 上溯三级。
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - 首次进入欢迎

    /// 欢迎判据两件套：配置记名 **且** 进度全新，缺一件老用户就会被吵一次。
    func testWelcomeIsGatedByConfigFlagAndFreshProgress() throws {
        let appState = try source("Sources/AppUI/AppState.swift")
        XCTAssertTrue(
            appState.contains("!product.forestWelcomed, progress.totalStars == 0"),
            "欢迎判据必须是「配置没记过 + 进度全新」两件同时成立 —— 缺一件，"
                + "有进度的老用户升级后会被无端欢迎一次"
        )
        XCTAssertTrue(
            appState.contains("product.forestWelcomed = true"),
            "演过必须落库记名，否则每次启动都演一遍"
        )
    }

    /// 消费必须在视图到场后：MainView 盯 isBooting 翻 false 时 consume。
    func testWelcomeIsConsumedAfterBootCompletes() throws {
        let main = try source("Sources/AppUI/Views/MainView.swift")
        XCTAssertTrue(
            main.contains(".task(id: state.isBooting)"),
            "脉冲发在地面带上屏前 onChange 收不到第一拍 —— 必须由视图侧在 boot 完成后消费"
        )
        XCTAssertTrue(
            main.contains("state.consumeForestWelcome()"),
            "待演标记没人消费，欢迎就永远不演"
        )
        // 消费端要真的把脉冲发进舞台（防「记了名、没人演」的空转）。
        // ⚠️ 用「赋值 + 调用」的代码序列匹配：单查 "forest.welcome()" 会被文档注释
        // 里的同名字样骗过（反证时抓出来的假绿 —— 注释匹配 = 没匹配）。
        let appState = try source("Sources/AppUI/AppState.swift")
        XCTAssertTrue(
            appState.contains("pendingForestWelcome = false\n        forest.welcome()"),
            "consumeForestWelcome 里必须先撤标记再调 forest.welcome()，否则待演标记只是被丢弃"
        )
    }

    // MARK: - 错误举牌

    /// 错误 → 举牌的整条链：MainView 盯 chat.errorMessage，ForestErrorSign 分类。
    func testErrorSignChainIsWiredInMainView() throws {
        let main = try source("Sources/AppUI/Views/MainView.swift")
        XCTAssertTrue(
            main.contains(".onChange(of: state.chat.errorMessage)"),
            "错误横幅出现的同一时刻，林子里得有人举牌 —— 这条 onChange 是唯一的桥"
        )
        XCTAssertTrue(
            main.contains("ForestErrorSign.headline(for:"),
            "举牌文案必须走纯函数分类，不许在视图里手写关键词"
        )
        XCTAssertTrue(
            main.contains("errorHeadline: state.forest.lastErrorHeadline"),
            "ForestGroundBand 没接到牌子内容，举牌永远空白"
        )
        // 地面带侧要真的接住脉冲（onChangeListener 被删 = 牌子永远不举）。
        let tree = try source("Sources/AppUI/Components/TreeCanvas.swift")
        XCTAssertTrue(
            tree.contains(".onChange(of: errorSignTick)"),
            "ForestGroundBand 必须监听 errorSignTick —— 没有它，举牌脉冲到得了却没人接"
        )
    }

    // MARK: - 窄窗退化

    /// 退化档必须走纯函数：内联公式删掉后不许悄悄长回来。
    func testGroundBandUsesForestGroundPlanInsteadOfInlineFormulas() throws {
        let tree = try source("Sources/AppUI/Components/TreeCanvas.swift")
        XCTAssertTrue(
            tree.contains("ForestGroundPlan.plan(width:"),
            "居民 / 灌木 / 小花的数量必须走 ForestGroundPlan 三档退化"
        )
        XCTAssertFalse(
            tree.contains("private func residentCount("),
            "旧的内联居民公式（只看宽度、下限 3）已删除 —— 不许长回来"
        )
    }
}
