import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 「点一下就滚到学习进度页的某张卡」这条跳转意图的状态机回归（2026-09-21 火苗徽章跳转）。
///
/// 意图机制本身很简单（`tick` + `pending` + 一次性消费），真正的坑在两处**静默失败**：
///
/// **① 意图的目标丢失。** 早先 `progressFocusPending` 是个 Bool —— 只能表达「有意图」，
/// 表达不了「去哪张卡」。黑板的小图标要滚到「今日任务」，侧栏火苗要滚到「年度记录」，
/// 收成一个枚举之后两条路共用一个消费口，且**不会再出现「多一个目标就多一处忘了复位」**。
///
/// **② 年度汇总被窗口汇总的重入锁饿死。** 这是最隐蔽的一条：开屏那一轮
/// `reloadProgress(includeAnnual: false)` **只查窗口**，而它把 `isLoadingProgress`
/// 占着；火苗徽章如果点得早，`openAnnualRecapInProgress` 走 `reloadProgress` 就会被那道
/// 重入保护**直接弹回** —— 年度汇总永远不跑，用户落在一张空网格上，而且没有任何东西
/// 会再来补。修法是给年度一条**自己的加载口**（`ensureAnnualRecapLoaded`，自带在途锁）。
/// → `testAnnualRecapLoadsEvenWhileWindowReloadIsInFlight`
///
/// ⚠️ 这条用例是**反证过**的：把 `openAnnualRecapInProgress` 改回
/// `reloadProgress(includeAnnual: true)`，它会变红（`hasAnnualRecap` 停在 false）。
@MainActor
final class ProgressFocusTests: XCTestCase {

    /// ⚠️ 配置一律写临时文件：`ConfigStore(fileURL: nil)` 落在用户的真实配置上，
    /// 测试不许碰（这条纪律与离屏渲染测试同款）。
    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("progress-focus-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    // MARK: - ① 目标要带得走、消费一次就该清掉

    /// 黑板那条路：意图是「今日任务卡」，且消费一次即清。
    func testDailyTasksFocusCarriesItsOwnTarget() {
        let state = makeState()
        XCTAssertNil(state.consumeProgressFocus(), "没有意图时必须是 nil（否则每次进页面都会莫名滚一屏）")

        state.openTodayTasksInProgress()

        XCTAssertTrue(state.showingProgress, "要切到学习进度页")
        XCTAssertEqual(state.consumeProgressFocus(), .dailyTasks)
        XCTAssertNil(state.consumeProgressFocus(), "同一份意图消费一次就该清掉")
    }

    /// 火苗那条路：意图是「年度记录卡」——**不能**和今日任务混成一个（那是两个不同的目标）。
    func testAnnualRecapFocusCarriesItsOwnTarget() async {
        let state = makeState()

        await state.openAnnualRecapInProgress()

        XCTAssertTrue(state.showingProgress, "要切到学习进度页")
        XCTAssertEqual(state.consumeProgressFocus(), .annualRecap)
        XCTAssertNil(state.consumeProgressFocus())
    }

    // MARK: - ② 年度汇总不许被窗口汇总的在途锁饿死

    /// 窗口汇总**正在跑**的时候点火苗，年度汇总仍须真的取回来。
    ///
    /// 撤掉修复（回到 `reloadProgress(includeAnnual: true)`）时这条会红：
    /// 那次调用被 `guard !isLoadingProgress else { return }` 弹回，
    /// `hasAnnualRecap` 停在 false，用户看到的是一张空网格。
    func testAnnualRecapLoadsEvenWhileWindowReloadIsInFlight() async {
        let state = makeState()

        // 制造「开屏那一轮还没跑完」这一拍：窗口汇总先起、跑到第一个挂起点。
        let windowOnly = Task { await state.reloadProgress(includeAnnual: false) }
        // `Task.yield()` 让出主 actor，那一个任务就会跑到 `isLoadingProgress = true`
        // 之后的第一个 `await`。用循环而不是只让一次：让出与调度不是同一拍，一次不保险。
        var spins = 0
        while !state.isLoadingProgress, spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(state.isLoadingProgress, "前提：窗口汇总这一轮确实还在飞")

        await state.openAnnualRecapInProgress()

        XCTAssertTrue(
            state.hasAnnualRecap,
            "窗口汇总占着锁时，年度汇总也必须照样取回来 —— 否则火苗点得早就只剩一张空网格"
        )
        await windowOnly.value

        // 空库也要能建出整年的网格（`dayCount` 才是「真的查了」的证据：
        // `AnnualRecap.empty()` 的 weeks 数同样是 53，拿它断言等于什么都没验）。
        XCTAssertGreaterThanOrEqual(state.annualRecap.dayCount, 365)
    }

    /// 已经在途 / 已经加载过时，再点火苗不该重复跑一遍全库汇总。
    func testAnnualRecapIsNotRefetchedOnEveryTap() async {
        let state = makeState()
        await state.openAnnualRecapInProgress()
        XCTAssertTrue(state.hasAnnualRecap)

        // 第二次：已有缓存，直接短路（`isLoadingAnnualRecap` 不会被占用）。
        await state.openAnnualRecapInProgress()
        XCTAssertFalse(state.isLoadingAnnualRecap, "第二次点击不该再起一轮加载")
        XCTAssertTrue(state.hasAnnualRecap)
    }
}
