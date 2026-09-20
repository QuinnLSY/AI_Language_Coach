import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import Foundation
import XCTest

/// `AppState.init(services:)` 手写恢复逻辑的看门狗。
///
/// ⚠️ 为什么专门要这一份测试：`init(services:)` 是**手写**的，而它要恢复的持久化字段
/// 原先在声明处都带着默认值（`[:]` / `nil` / `0`）—— 把 init 里那行加载删掉，
/// 编译器一声不响，只有用户会发现「昨天点过的『认识』今天全没了」、
/// 设置页的「上次已学 x / y 词」永远是空。
///
/// 已经把其中两个（`dailyRecognitions` / `dailyProgressResetLearned`）的默认值
/// 摘掉，让漏加载直接变成**编译错误**；但 `dailyProgressResetAt` 是 Optional，
/// Swift 天然给它 nil，编译器这条退路堵不上 —— 只能靠测试看着。
/// 两条防线一起，撤掉 init 里任意一行加载：要么编不过，要么这里的用例变红。
///
/// ⚠️ 用的是 `UserDefaults.standard`，也就是**真实用户数据所在的那几个键**。
/// 所以每个用例都在方法内 `defer` 原样放回去（原本没有就删掉），
/// 绝不能留测试写入的假数据污染用户的学习记录。
@MainActor
final class AppStatePersistenceTests: XCTestCase {

    // ⚠️ 纯常量要标 nonisolated：测试类整体是 @MainActor，这些静态常量会被连坐成
    // 主 actor 隔离，从非隔离处（XCTest 的生命周期钩子）一读就是 45 条 Swift 6 警告。
    private nonisolated static let recognitionsKey = "vocabulary.dailyRecognitions"
    private nonisolated static let resetAtKey = "vocabulary.dailyProgressResetAt"
    private nonisolated static let resetLearnedKey = "vocabulary.dailyProgressResetLearned"
    private nonisolated static let allKeys = [recognitionsKey, resetAtKey, resetLearnedKey]

    /// 拍下这几个键当前的值，交给 `restoreDefaults(_:)` 还原。
    ///
    /// ⚠️ 不走 `setUp`/`tearDown`：它们是**非隔离**上下文，碰主 actor 隔离的实例属性
    /// 会让 Swift 6 刷屏警告。改成测试方法里显式 `defer`，隔离边界干净。
    private func snapshotDefaults() -> [String: Any] {
        var snapshot: [String: Any] = [:]
        for key in Self.allKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                snapshot[key] = value
            }
        }
        return snapshot
    }

    private func restoreDefaults(_ snapshot: [String: Any]) {
        for key in Self.allKeys {
            if let value = snapshot[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private func makeState() -> AppState {
        AppState(services: CoachServices(
            config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("persist-\(UUID().uuidString).json")),
            databasePath: ":memory:"))
    }

    // MARK: - 每日推荐的「认识」计数

    func testDailyRecognitionsAreRestoredOnConstruction() throws {
        let savedDefaults = snapshotDefaults()
        defer { restoreDefaults(savedDefaults) }

        UserDefaults.standard.set(
            try JSONEncoder().encode(["penguin": 2, "forest": 3]),
            forKey: Self.recognitionsKey)

        let state = makeState()

        XCTAssertEqual(state.dailyRecognitions["penguin"], 2)
        XCTAssertEqual(state.dailyRecognitions["forest"], 3)
    }

    /// 反证：没有上面那条，第一条即使恒真也看不出来。
    /// 清掉存储后必须是空的 —— 顺带确认「空」不是因为键名写错。
    func testDailyRecognitionsAreEmptyWhenNothingWasPersisted() {
        let savedDefaults = snapshotDefaults()
        defer { restoreDefaults(savedDefaults) }

        UserDefaults.standard.removeObject(forKey: Self.recognitionsKey)

        let state = makeState()

        XCTAssertTrue(state.dailyRecognitions.isEmpty)
    }

    /// 数据坏了不能崩、也不能把应用卡在启动阶段：解码失败就当没学过。
    func testCorruptedRecognitionsDataFallsBackToEmpty() {
        let savedDefaults = snapshotDefaults()
        defer { restoreDefaults(savedDefaults) }

        UserDefaults.standard.set(Data([0xFF, 0xFE, 0x00]), forKey: Self.recognitionsKey)

        let state = makeState()

        XCTAssertTrue(state.dailyRecognitions.isEmpty)
    }

    // MARK: - 上次重置进度的时间与已学词数

    func testDailyProgressResetStampIsRestoredOnConstruction() {
        let savedDefaults = snapshotDefaults()
        defer { restoreDefaults(savedDefaults) }

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        UserDefaults.standard.set(stamp.timeIntervalSince1970, forKey: Self.resetAtKey)
        UserDefaults.standard.set(7, forKey: Self.resetLearnedKey)

        let state = makeState()

        XCTAssertEqual(
            state.dailyProgressResetAt?.timeIntervalSince1970 ?? -1,
            stamp.timeIntervalSince1970,
            accuracy: 0.001)
        XCTAssertEqual(state.dailyProgressResetLearned, 7)
    }

    /// 反证：同上，先把存储清空，确认默认值确实是 nil / 0。
    func testDailyProgressResetStampIsNilWhenNothingWasPersisted() {
        let savedDefaults = snapshotDefaults()
        defer { restoreDefaults(savedDefaults) }

        UserDefaults.standard.removeObject(forKey: Self.resetAtKey)
        UserDefaults.standard.removeObject(forKey: Self.resetLearnedKey)

        let state = makeState()

        XCTAssertNil(state.dailyProgressResetAt)
        XCTAssertEqual(state.dailyProgressResetLearned, 0)
    }

    // MARK: - 开屏即「模型都在跑」

    /// 界面快照的初值：应用一打开，所有能力都按「启动」显示 ——
    /// 后面才由 `start()` 拿真源覆盖。漏了这一步，开屏一瞬间整页都是「未启动」。
    func testAllModelsStartRunningByDefault() {
        let savedDefaults = snapshotDefaults()
        defer { restoreDefaults(savedDefaults) }

        let state = makeState()

        XCTAssertEqual(state.modelRunStates.count, AIProviderKind.allCases.count)
        XCTAssertTrue(
            state.modelRunStates.values.allSatisfy { $0 },
            "开屏时所有模型都应是「启动」")
    }
}
