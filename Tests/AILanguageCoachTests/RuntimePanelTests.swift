import XCTest

@testable import AIInfrastructure
@testable import AIServices
@testable import AppUI

/// 设置页「运行环境 / 本地测速 / 每日目标」三块的判据。
///
/// 这一组要钉的是**「建好了但界面上没有」**这类缺口：三条链路（语义索引状态、
/// 本地测速、每日目标）在配置层或服务层早就有了，缺的是把它们接到界面上。
/// 判据分两种：纯函数（文案与格式化）+ 源码哨兵（接线有没有真的落上）。
final class RuntimePanelTests: XCTestCase {

    // MARK: - 语义记忆索引状态

    func testSemanticMemoryHeadlineShowsDimensions() {
        let ready = SemanticMemoryStatus(isEnabled: true, dimensions: 768)
        XCTAssertTrue(ready.headline.contains("已接通"))
        XCTAssertTrue(ready.headline.contains("768"), "接通时要报出维度：光说「已接通」回答不了「用的哪个索引」")
        XCTAssertFalse(ready.detail.isEmpty)
    }

    func testSemanticMemoryDisabledExplainsNextStep() {
        let off = SemanticMemoryStatus(isEnabled: false, dimensions: 0)
        XCTAssertTrue(off.headline.contains("未接通"))
        // 没接通时副行要给「下一步做什么」，而不是只重复一遍状态。
        XCTAssertTrue(off.detail.contains("nomic-embed-text"), "未接通要指一个具体可做的动作")
        // 语义检索是增强，不是故障：不许把它说成「应用坏了」。
        XCTAssertTrue(off.detail.contains("不影响练习"))
    }

    func testSemanticMemoryNegativeDimensionsClamped() {
        // 维度为负说明上游算错了，静默改成 0 会让「已接通但 0 维」看起来正常。
        XCTAssertEqual(SemanticMemoryStatus(isEnabled: true, dimensions: -3).dimensions, 0)
        XCTAssertEqual(SemanticMemoryStatus.unknown.isEnabled, false)
    }

    // MARK: - 测速结果格式化

    func testBenchmarkSecondsUsesReadableUnits() {
        XCTAssertEqual(BenchmarkText.seconds(0.918), "918 ms")
        XCTAssertEqual(BenchmarkText.seconds(2.3456), "2.35 s")
        XCTAssertEqual(BenchmarkText.seconds(34.56), "34.6 s")
        // 不是数字（NaN / 负数）不许显示成数字。
        XCTAssertEqual(BenchmarkText.seconds(.nan), "—")
        XCTAssertEqual(BenchmarkText.seconds(-1), "—")
    }

    func testBenchmarkSnapshotNilWhenNothingSampled() {
        let empty = LocalLLMBenchmark.Result(model: "qwen3:8b", endpoint: "http://127.0.0.1:11434", samples: [])
        XCTAssertNil(BenchmarkSnapshot(result: empty),
                     "一项都没采到时返回 nil：摆一整列「—」会让用户以为测过了")
    }

    func testBenchmarkSnapshotFormatsMedians() {
        var samples: [BenchmarkSample] = []
        for index in 1...4 {
            samples.append(
                BenchmarkSample(
                    dimension: .llm,
                    name: "generate#1-\(index)",
                    durationSeconds: Double(index) * 0.5,   // 0.5 / 1.0 / 1.5 / 2.0
                    timeToFirstEventSeconds: 0.25,
                    metrics: ["tokens_per_second": Double(index) * 10]
                )
            )
        }
        let snapshot = BenchmarkSnapshot(
            result: LocalLLMBenchmark.Result(model: "qwen3:8b", endpoint: "e", samples: samples)
        )
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.model, "qwen3:8b")
        // 中位：4 个样本 0.5/1.0/1.5/2.0 → p50 = 1.25
        XCTAssertEqual(snapshot?.generateText, "1.25 s")
        XCTAssertEqual(snapshot?.firstTokenText, "250 ms")
        XCTAssertEqual(snapshot?.throughputText, "25.0 tok/s")
        XCTAssertTrue(snapshot?.sampleText.contains("4 次") == true)
    }

    func testMemoryTextSwitchesUnitUnderOneGigabyte() {
        XCTAssertEqual(MemoryText.available(3_221_225_472), "3.0 GB 可用")
        XCTAssertEqual(MemoryText.available(600 * 1_048_576), "600 MB 可用")
    }

    // MARK: - 接线哨兵（源码级：这些是「界面上没有」的根因）

    /// 测速的在途标记必须 `defer` 复位：这条路径会抛错（没配本地供应商 / runtime 没起），
    /// 只在成功分支复位的话，失败一次按钮就永久转圈。
    func testBenchmarkFlagResetsOnEveryExitPath() throws {
        let lines = try codeLines(of: "Sources/AppUI/AppState+Maintenance.swift")
        XCTAssertTrue(lines.contains { $0.contains("defer { isRunningBenchmark = false }") },
                      "runLocalBenchmark 必须 defer 复位在途标记")
        // 挡住重复点击：不挡的话连点会并发跑两轮基准。
        XCTAssertTrue(lines.contains { $0.contains("guard !isRunningBenchmark else { return }") })
    }

    /// 设置页打开时要刷语义索引与内存 —— 不刷就永远停在 unknown / 空串。
    func testSettingsRefreshesRuntimePanels() throws {
        let lines = try codeLines(of: "Sources/AppUI/Views/SettingsView.swift")
        XCTAssertTrue(lines.contains { $0.contains("await state.refreshSemanticMemory()") })
        XCTAssertTrue(lines.contains { $0.contains("await state.refreshMemoryPressure()") })
    }

    /// 每日目标控件必须**两页共用同一个组件**：各写一份必然漂移（一边改口径、另一边不跟）。
    func testDailyGoalControlsSharedByBothPages() throws {
        let progress = try codeLines(of: "Sources/AppUI/Views/LearningProgressView.swift")
        let settings = try codeLines(of: "Sources/AppUI/Views/SettingsView.swift")
        XCTAssertTrue(progress.contains { $0.contains("DailyGoalControls(state: state)") })
        XCTAssertTrue(settings.contains { $0.contains("DailyGoalControls(state: state)") })
        // 旧的私有副本必须已经删掉（留着就是两份实现）。
        XCTAssertFalse(progress.contains { $0.contains("private var goalModePicker") })
        XCTAssertFalse(progress.contains { $0.contains("private var goalStepper") })
    }

    // MARK: - 辅助

    /// 读源码并去掉注释行：注释里出现同样的字样会让扫描型哨兵假绿。
    private func codeLines(of relativePath: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AILanguageCoachTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
}
