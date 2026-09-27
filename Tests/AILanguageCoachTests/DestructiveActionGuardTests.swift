import XCTest

/// 破坏性操作的**交互安全哨兵**（2026-09-27 全仓库健康审查）。
///
/// 这一组盯的是「一点就没、且无法恢复」的入口有没有拦一道。
/// 拦的方式在本应用里已经有两种既成写法（学习记忆卡、素材卡）：**两步确认 + 就地取消**。
/// 它们断了不崩溃、不报错，只是让用户某天手滑一下就丢掉自己攒的东西，所以只能扫源码。
///
/// ⚠️ 与 `VoiceInputWiringTests` 同样的两条纪律：
/// 被扫的字符串不能出现在注释里（假绿），反证必须**真删**而不是注释掉。
final class DestructiveActionGuardTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 源码的**非注释行**（`//` / `///` 开头的整行去掉），行号保留（第 1 行 = index 0）。
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            return (index + 1, line)
        }
    }

    private func firstLine(_ needle: String, in lines: [(number: Int, text: String)]) -> Int? {
        lines.first { $0.text.contains(needle) }?.number
    }

    // MARK: - ① 删除自建情景：不能点一下就真删

    /// 自建情景是用户自己生成的内容（连同目标句），删掉之后要再花一次模型请求才造得回来。
    /// 原先「删除」一点就发 `deleteCustomScenario`，与「删一条气泡还要弹确认」的口径相反。
    func testDeletingCustomScenarioNeedsTwoSteps() throws {
        let lines = codeLines(try source("AppUI/Views/ScenarioPickerView.swift"))
        guard let deleteLine = firstLine("await state.deleteCustomScenario(id: scenario.id)", in: lines) else {
            return XCTFail("找不到删除调用")
        }
        // 真删那一下必须落在「确认中」的分支里：往上找最近的 `if confirming {`。
        let before = lines.filter { $0.number < deleteLine }.suffix(8).map(\.text).joined(separator: "\n")
        XCTAssertTrue(before.contains("if confirming {"),
                      "删除必须先经过确认态（第 \(deleteLine) 行之前要有 if confirming）")
        XCTAssertTrue(before.contains("pendingDeleteScenarioID = nil"),
                      "真删的同一分支里要把确认态清掉，否则确认条会一直挂着")
    }

    /// 第一下只进确认态、不调删除。
    ///
    /// ⚠️ 单看「文件里有没有 deleteCustomScenario」是假绿：一步删也满足。
    /// 所以这里钉的是 `else { pendingDeleteScenarioID = scenario.id }` 这个 **else** 分支。
    func testFirstTapOnlyEntersConfirmState() throws {
        let lines = codeLines(try source("AppUI/Views/ScenarioPickerView.swift"))
        guard let enterLine = firstLine("pendingDeleteScenarioID = scenario.id", in: lines) else {
            return XCTFail("第一下要把情景 id 记进确认态")
        }
        let before = lines.filter { $0.number < enterLine }.suffix(4).map(\.text).joined(separator: "\n")
        XCTAssertTrue(before.contains("else {"),
                      "第一下应落在 else 分支（第 \(enterLine) 行），真删才在 if 分支")
    }

    /// 确认态要看得出来：按钮文案与图标都得变，光靠 disabled 或光换字都不算。
    func testConfirmStateIsVisibleOnTheButton() throws {
        let view = try source("AppUI/Views/ScenarioPickerView.swift")
        XCTAssertTrue(view.contains("Text(confirming ? \"确认删除\" : \"删除\")"),
                      "确认态要换成「确认删除」")
        XCTAssertTrue(view.contains("Image(systemName: confirming ? \"trash.fill\" : \"trash\")"),
                      "确认态图标要跟着变实底")
    }

    // MARK: - ② 确认态必须有退路

    /// 只有「再点一次」而没有取消，确认态一旦进入就只剩硬着头皮点下去
    /// （这条在学习记忆卡上被实测反馈过）。所以确认条里必须就地给「取消」。
    func testConfirmBannerOffersCancel() throws {
        let lines = codeLines(try source("AppUI/Views/ScenarioPickerView.swift"))
        guard let bannerLine = firstLine("private func deleteConfirmBanner(", in: lines) else {
            return XCTFail("找不到删除确认条")
        }
        // 只取确认条这几行：整文件 contains 的话，别处的 `pendingDeleteScenarioID = nil`
        // （比如收起卡片时那一处）会让它假绿。
        let banner = lines.filter { $0.number > bannerLine }.prefix(34).map(\.text).joined(separator: "\n")
        XCTAssertTrue(banner.contains("pendingDeleteScenarioID = nil"),
                      "确认条要有「取消」把确认态清掉")
        XCTAssertTrue(banner.contains("Text(\"取消\")"), "取消按钮要写明是「取消」")
        XCTAssertTrue(banner.contains("exclamationmark.triangle.fill"),
                      "确认条要有警告图标（与学习记忆卡同一口径）")
    }

    /// 收起卡片要把确认态清掉：否则下次展开同一张卡，按钮还停在「确认删除」，
    /// 用户以为自己刚才那下没生效，再点一下就真删了。
    func testConfirmStateClearsWhenCardCollapses() throws {
        let lines = codeLines(try source("AppUI/Views/ScenarioPickerView.swift"))
        guard let changeLine = firstLine(".onChange(of: state.expandedScenarioID)", in: lines) else {
            return XCTFail("展开状态变化时要清掉确认态")
        }
        let after = lines.filter { $0.number > changeLine }.prefix(3).map(\.text).joined(separator: "\n")
        XCTAssertTrue(after.contains("pendingDeleteScenarioID = nil"),
                      "展开态一变就要把确认态归零")
    }

    // MARK: - ③ 既有两步确认不许退化

    /// 学习记忆卡与素材卡的两步确认是这次审查认定的**基准写法**，
    /// 它们一旦被简化成一步，本组哨兵的「一致性」就失去参照物。
    func testExistingTwoStepConfirmationsSurvive() throws {
        let memory = try source("AppUI/Components/LearningMemoryCard.swift")
        XCTAssertTrue(memory.contains("@State private var confirmingClear = false"),
                      "清除学习记忆必须两步确认")
        XCTAssertTrue(memory.contains("Text(confirmingClear ? \"确认清除\" : \"清除记忆\")"),
                      "清除按钮的确认态要换字")
        XCTAssertTrue(memory.contains("Text(\"取消\")"), "清除学习记忆的确认条要有取消")

        let kit = try source("AppUI/Components/MaterialKitCard.swift")
        XCTAssertTrue(kit.contains("@State private var confirmingDelete = false"),
                      "删除素材必须两步确认")
    }
}
