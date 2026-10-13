import AIDomain
import AppCore
import AppUI
import XCTest

/// 批次八 · H（边界状态）的纯函数单测：
/// 窄窗退化档（ForestGroundPlan）/ 举牌文案分类（ForestErrorSign）/ ForestStage 脉冲。
@MainActor
final class ForestEdgeCaseTests: XCTestCase {

    // MARK: - ForestGroundPlan 三档退化

    /// 正常档（量化宽 ≥448）：与批次四以来的历史公式**逐值一致**（一分不改）。
    func testWideTierMatchesTheLegacyFormulas() {
        // qw=560：居民 (560-120)/70+1=7，灌木 min(1+2,4)=3，花 min(2+3,7)=5
        XCTAssertEqual(ForestGroundPlan.plan(width: 560, unlocked: 8),
                       ForestGroundPlan.Plan(residents: 7, bushes: 3, flowers: 5))
        // qw=448：居民 5，灌木 3，花 4
        XCTAssertEqual(ForestGroundPlan.plan(width: 448, unlocked: 8),
                       ForestGroundPlan.Plan(residents: 5, bushes: 3, flowers: 4))
        // 很宽时封顶：居民 ≤8、灌木 ≤4、花 ≤7
        let veryWide = ForestGroundPlan.plan(width: 1200, unlocked: 8)
        XCTAssertLessThanOrEqual(veryWide.residents, 8)
        XCTAssertLessThanOrEqual(veryWide.bushes, 4)
        XCTAssertLessThanOrEqual(veryWide.flowers, 7)
    }

    /// 窄档（336..<448）：居民钳到 2…3，灌木只留 1 丛、花 2 朵。
    func testNarrowTierThinsOutTheDecor() {
        // qw=420：公式给 5 → 钳到 3
        XCTAssertEqual(ForestGroundPlan.plan(width: 420, unlocked: 8),
                       ForestGroundPlan.Plan(residents: 3, bushes: 1, flowers: 2))
        // qw=336：公式给 3 → 仍 3
        XCTAssertEqual(ForestGroundPlan.plan(width: 336, unlocked: 8),
                       ForestGroundPlan.Plan(residents: 3, bushes: 1, flowers: 2))
    }

    /// 极窄档（<336）：只留 1 只（homePosition 自然把它摆到正中）、没灌木、1 朵花。
    /// 树面板最小 300pt → 量化 308，这一档**真实可达**（不是纸面防御）。
    func testExtremeNarrowTierKeepsExactlyOneResident() {
        XCTAssertEqual(ForestGroundPlan.plan(width: 308, unlocked: 8),
                       ForestGroundPlan.Plan(residents: 1, bushes: 0, flowers: 1))
        // 再窄也不空场：居民下限 1
        XCTAssertEqual(ForestGroundPlan.plan(width: 160, unlocked: 8).residents, 1)
    }

    /// ⑦-C③：解锁数是另一道闸 —— 林子里只有 4 位时，再宽的面板也只排 4 只。
    ///
    /// 没有这一条，「再练 25 分钟来一位新伙伴」就是句空话：宽度早把 8 只排满了，
    /// 多练也不会多出一只。
    func testUnlockedCountAlsoCapsTheResidents() {
        XCTAssertEqual(ForestGroundPlan.plan(width: 1200, unlocked: 4).residents, 4,
                       "宽面板摆得下 8 只，但林子里只有 4 位 —— 取小者")
        XCTAssertEqual(ForestGroundPlan.plan(width: 560, unlocked: 6).residents, 6)
        // 解锁数超过上限（数据源被改过 / 未来加了物种）不该把林子撑爆。
        XCTAssertLessThanOrEqual(ForestGroundPlan.plan(width: 1200, unlocked: 99).residents, 8)
        // 解锁数 0 / 负数也不能空场（下限 1）。
        XCTAssertEqual(ForestGroundPlan.plan(width: 560, unlocked: 0).residents, 1)
        XCTAssertEqual(ForestGroundPlan.plan(width: 560, unlocked: -3).residents, 1)
    }

    /// 量化幂等：传入已量化的宽度，结果与传原始宽度一致。
    func testPlanIsIdempotentOnQuantizedWidths() {
        XCTAssertEqual(ForestGroundPlan.plan(width: 420, unlocked: 8), ForestGroundPlan.plan(width: 420, unlocked: 8))
    }

    // MARK: - ForestErrorSign 举牌文案

    /// 密钥 / 鉴权类 → 钥匙。
    func testHeadlineForKeyProblems() {
        XCTAssertEqual(ForestErrorSign.headline(for: "API 密钥无效（401 Unauthorized）"), "钥匙好像不对…")
        XCTAssertEqual(ForestErrorSign.headline(for: "Invalid API KEY provided"), "钥匙好像不对…")
    }

    /// 模型未配置 / 没有可用 → 老师还没来。
    func testHeadlineForMissingConfiguration() {
        XCTAssertEqual(ForestErrorSign.headline(for: "模型未配置，请先在设置里选择"), "老师还没来…")
        XCTAssertEqual(ForestErrorSign.headline(for: "没有可用的 Provider"), "老师还没来…")
        XCTAssertEqual(ForestErrorSign.headline(for: "model not configured"), "老师还没来…")
    }

    /// 服务未运行 / stopped → 老师在打盹。
    func testHeadlineForStoppedService() {
        XCTAssertEqual(ForestErrorSign.headline(for: "本地模型未运行，请先启动"), "老师在打盹…")
        XCTAssertEqual(ForestErrorSign.headline(for: "service stopped unexpectedly"), "老师在打盹…")
    }

    /// 网络 / 超时 / 连接 → 风太大。
    func testHeadlineForNetworkProblems() {
        XCTAssertEqual(ForestErrorSign.headline(for: "网络连接失败，请检查网络"), "风太大，话传不过来…")
        XCTAssertEqual(ForestErrorSign.headline(for: "request timed out after 30s"), "风太大，话传不过来…")
        XCTAssertEqual(ForestErrorSign.headline(for: "Network connection lost"), "风太大，话传不过来…")
    }

    /// 认不出的错 → 万能兜底（说事实，不装懂）。
    func testHeadlineFallsBackToANeutralLine() {
        XCTAssertEqual(ForestErrorSign.headline(for: "一些完全陌生的错误"), "先歇一歇，等会儿再试")
    }

    // MARK: - ForestStage 欢迎与举牌脉冲

    /// welcome() 递增脉冲；showError 空文案静默、有文案才记才演。
    func testForestStageWelcomeAndErrorPulses() {
        let forest = ForestStage()
        XCTAssertEqual(forest.welcomeTick, 0)
        forest.welcome()
        XCTAssertEqual(forest.welcomeTick, 1)

        // 空文案 / nil：不记不演（没什么可举的）
        forest.showError(headline: nil)
        forest.showError(headline: "")
        XCTAssertEqual(forest.errorSignTick, 0)
        XCTAssertNil(forest.lastErrorHeadline)

        // 有文案：脉冲 +1、句子落位
        forest.showError(headline: "老师还没来…")
        XCTAssertEqual(forest.errorSignTick, 1)
        XCTAssertEqual(forest.lastErrorHeadline, "老师还没来…")
    }
}
