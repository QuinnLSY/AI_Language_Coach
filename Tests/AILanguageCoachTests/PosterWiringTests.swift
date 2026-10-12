import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import XCTest

@testable import AIDomain
@testable import AppUI

/// ⑦-D 今日战绩海报的**接线**：海报上的每个数字都得来自真快照，不许有一处写死。
///
/// 反证方式：把 `AppState.dailyPoster` 里的 `progressSnapshot.today` 换成一个写死的
/// `DailyActivity`，`testPosterReadsTodayFromTheSnapshot` 必须变红。
@MainActor
final class PosterWiringTests: XCTestCase {

    // MARK: - ① 没练就不出海报

    func testNothingPracticedTodayMeansNoPoster() {
        let state = makeState()
        state.progressSnapshot = Self.snapshot(seconds: 0, messages: 0)
        XCTAssertNil(state.dailyPoster, "今天空着就不该有那张卡（海报上的数字都是承诺）")
    }

    // MARK: - ② 数字取自真快照

    func testPosterReadsTodayFromTheSnapshot() throws {
        let state = makeState()
        state.progressSnapshot = Self.snapshot(seconds: 780, messages: 8, streakDays: 4)

        let poster = try XCTUnwrap(state.dailyPoster)
        XCTAssertEqual(poster.headline, "今天练了 13 分 0 秒", "时长必须是快照里那一格的真值")
        XCTAssertEqual(poster.metrics.first?.value, "8 轮")
        XCTAssertEqual(poster.subhead, "连续练习 4 天")
    }

    /// 换一份快照 → 海报跟着换（钉的是「读真值」而不是「写死一句」）。
    func testAnotherSnapshotDrawsAnotherPoster() {
        let state = makeState()
        state.progressSnapshot = Self.snapshot(seconds: 780, messages: 8, streakDays: 4)
        let first = state.dailyPoster

        state.progressSnapshot = Self.snapshot(seconds: 150, messages: 2, streakDays: 1)
        let second = state.dailyPoster

        XCTAssertNotNil(first)
        XCTAssertNotEqual(first?.headline, second?.headline)
        XCTAssertEqual(second?.headline, "今天练了 2 分 30 秒")
    }

    /// 目标分钟数取自快照：`goalMinutes` 改了，收尾那句话里的数字必须跟着改。
    func testGoalMinutesComesFromTheSnapshot() {
        let state = makeState()
        // 15 分钟目标、练满 20 分钟 → 达标。
        state.progressSnapshot = Self.snapshot(seconds: 20 * 60, messages: 1, streakDays: 9, goalMinutes: 15)
        XCTAssertEqual(state.dailyPoster?.closing, "今天的目标（15 分钟）达成了")

        state.progressSnapshot = Self.snapshot(seconds: 20 * 60, messages: 1, streakDays: 9, goalMinutes: 30)
        XCTAssertEqual(state.dailyPoster?.closing, "已经连续 9 天，节奏稳住了",
                       "目标提到 30 分钟就没达标了 —— 收尾那句话也得跟着变")
    }

    // MARK: - ③ 导出回执

    /// ⚠️ 源码哨兵：非 `.app` 进程里**绝不能**弹保存面板。
    ///
    /// 真实教训：一次反证（把 `dailyPoster` 改成恒非 nil）让这条用例走到了
    /// `NSSavePanel.runModal()`，那一刻 xctest 进程 **0% CPU 挂死 20 分钟**，
    /// 套件既不失败也不结束。所以判据必须钉在源码里，不能只靠「测试恰好没走到那儿」。
    func testExportPanelIsGuardedOutsideThePackedApp() throws {
        let raw = try Self.code("Sources/AppUI/ReportExporter.swift")
        let normalized = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(
            normalized.contains("guard AppKitHost.isPackedApp else { return .cancelled }"),
            "导出面板少了 .app 闸 —— 测试进程里 runModal 会永久阻塞"
        )
    }

    /// 今天没练就按导出：给的是一句「先练两句」，不是一条「导出失败」。
    ///
    /// ⚠️ 这条用例能跑通的前提是 `dailyPoster` 为 nil → 在弹面板**之前**就返回了。
    /// 哪天它变成红牌而不是绿牌，先看这条前提还在不在（别让它变成挂死）。
    func testExportWithoutPracticeExplainsInsteadOfFailing() {
        let state = makeState()
        state.progressSnapshot = Self.snapshot(seconds: 0, messages: 0)

        state.exportDailyPoster(theme: ForestThemeResolver.resolve(mode: .day, systemIsDark: false))

        XCTAssertEqual(state.posterNotice?.text, "今天还没开口，先练两句再发")
        state.dismissPosterNotice()
        XCTAssertNil(state.posterNotice)
    }

    // MARK: - 工装

    private static func snapshot(
        seconds: TimeInterval,
        messages: Int,
        streakDays: Int = 1,
        goalMinutes: Int = 10
    ) -> ProgressSnapshot {
        ProgressSnapshot(
            today: DailyActivity(day: Date(), seconds: seconds, messages: messages),
            streakDays: streakDays,
            goalMinutes: goalMinutes
        )
    }

    /// 读源码做哨兵（去掉纯注释行，避免注释里的同款字串造成假绿）。
    private static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-poster-\(UUID().uuidString).json")
        )
        // ⚠️ 必须 `:memory:`：裸 `CoachServices()` 的库路径是 nil，会落到真实学习库上。
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }
}
