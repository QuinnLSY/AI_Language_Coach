import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 课程阶梯卡 / 覆盖度判定卡（P1-2）的**离屏渲染**回归。
///
/// 与 `PhonemeBreakdownRenderTests`、`DailyTasksCardRenderTests` 同款理由：
/// 本次验证环境熄屏，一律走离屏出图；断言只钉「用户真能看见」这件事。
///
/// ⚠️ 同样**不做墨迹包围盒**断言：两张卡都自带全宽底色，包围盒恒等于卡宽。
/// 改用「高度」+「特定颜色像素数」（阈值自校准，理由见 `greenInk`）。
@MainActor
final class CurriculumRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 520

    // MARK: - 造数据

    private func scenario(_ id: String, level: String, zh: String) -> Scenario {
        Scenario(
            id: id, title: id, titleZh: zh, category: "测试", difficulty: 3, level: level,
            objective: "o", aiRole: "ai", learnerRole: "learner", opening: "hi",
            targetVocabulary: [], targetGrammar: [],
            targetSentences: ["In my opinion, this is the point."], maxTurns: 12
        )
    }

    /// 一档阶梯：情景若干 + 大树关卡若干。
    private func stage(
        _ level: CEFRLevel,
        scenarioCount: Int,
        required: Int,
        earned: Int,
        state: LevelState
    ) -> CurriculumStage {
        let scenarios = (0..<scenarioCount).map {
            scenario("\(level.rawValue)_\($0)", level: level.code, zh: "情景\($0 + 1)")
        }
        let levelNode = TreeLevel(
            id: "lv_\(level.rawValue)", title: "关卡\(level.code)", subtitle: "",
            heightFraction: 0.5, branch: .left, state: state,
            requiredStars: required, earnedStars: earned, scenarioID: scenarios.first?.id
        )
        return CurriculumStage(level: level, scenarios: scenarios, levels: [levelNode])
    }

    private func ladder(done: Bool) -> [CurriculumStage] {
        [
            stage(.a1, scenarioCount: 2, required: 6, earned: done ? 6 : 0, state: done ? .completed : .locked),
            stage(.a2, scenarioCount: 4, required: 8, earned: done ? 8 : 0, state: done ? .completed : .locked),
            stage(.b1, scenarioCount: 4, required: 7, earned: done ? 7 : 0, state: done ? .completed : .locked),
            stage(.b2, scenarioCount: 3, required: 6, earned: done ? 6 : 0, state: done ? .completed : .locked),
        ]
    }

    private func assessment(_ verdict: CurriculumVerdict) -> CurriculumAssessment {
        switch verdict {
        case .passed:
            let coverage = CurriculumCoverage(
                turnsUsed: 12, maxTurns: 14,
                matchedSentences: ["a", "b", "c"], missingSentences: [],
                matchedWords: ["w1", "w2", "w3", "w4", "w5", "w6"], missingWords: []
            )
            return CurriculumAssessment(
                level: .b1, coverage: coverage, verdict: .passed,
                reasons: [
                    "轮次 12/14，达到了这一档要求的 10 轮",
                    "目标句说到 3 句（要求 3 句）",
                    "目标词用到 6 个（要求 5 个）",
                ]
            )
        case .close:
            let coverage = CurriculumCoverage(
                turnsUsed: 12, maxTurns: 14,
                matchedSentences: ["a", "b"], missingSentences: ["The main reason is that it saves time."],
                matchedWords: ["w1", "w2", "w3", "w4", "w5"], missingWords: ["however"]
            )
            return CurriculumAssessment(
                level: .b1, coverage: coverage, verdict: .close,
                reasons: [
                    "轮次 12/14，达到了这一档要求的 10 轮",
                    "目标句只说到 2 句，还差 1 句",
                    "目标词用到 5 个（要求 5 个）",
                    "还没说到的句子：「The main reason is that it saves time.」",
                ],
                nextSentence: "The main reason is that it saves time."
            )
        case .notYet:
            let coverage = CurriculumCoverage(
                turnsUsed: 3, maxTurns: 14,
                matchedSentences: [], missingSentences: ["one two three", "four five six", "seven eight nine"],
                matchedWords: ["w1"], missingWords: ["w2", "w3", "w4", "w5", "w6"]
            )
            return CurriculumAssessment(
                level: .b1, coverage: coverage, verdict: .notYet,
                reasons: [
                    "轮次 3/14，这一档要求说满 10 轮",
                    "目标句只说到 0 句，还差 3 句",
                    "目标词只用到 1 个，还差 5 个",
                    "还没说到的句子：「one two three」",
                ],
                nextSentence: "one two three"
            )
        }
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    private func render(_ view: AnyView, day: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: cardWidth).background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，避免把内容裁掉。
        let size = CGSize(width: cardWidth, height: max(80, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    /// 全图最大的「绿 − 红」差值。
    private func maxGreenDelta(_ rep: NSBitmapImageRep) -> Double {
        var best = -1.0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                best = max(best, color.greenComponent - color.redComponent)
            }
        }
        return best
    }

    /// 比 `baseline` 更绿的像素数。
    ///
    /// ⚠️ **不写死绝对色值**：离屏渲染会过一次色彩空间换算，sRGB 落到位图上
    /// 饱和度要掉约四分之一（见 `DailyTasksCardRenderTests` 的实测记录）；
    /// 更麻烦的是**主题自己的中性色就是偏绿的**（日间 `hover` 是 `0xEAF3E8`），
    /// 所以「锁着的那一版」本身就有约 0.055 的 `g − r`。基准只能从同批渲染里量。
    private func greenInk(_ rep: NSBitmapImageRep, above baseline: Double) -> Int {
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent, g = color.greenComponent
                if g - r > baseline, g > 0.45 { count += 1 }
            }
        }
        return count
    }

    /// 与左上角底色不同的像素数（「确实画了东西」）。
    private func inkCount(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 0, y: 0) else { return 0 }
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if delta > 0.15 { count += 1 }
            }
        }
        return count
    }

    /// 两张同尺寸位图里颜色明显不同的像素数（「日夜两版真的不一样」的判据）。
    ///
    /// 比 `luma(0,0)` 可靠：不带底色的面板（情景选择面板）角落像素两版都是透明，
    /// 角落取值永远相等，断言就永远失败 —— 那不是「主题没生效」，是探针选错了位置。
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 0 }
        var count = 0
        for x in stride(from: 0, to: a.pixelsWide, by: 2) {
            for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(ca.redComponent - cb.redComponent)
                    + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                if delta > 0.15 { count += 1 }
            }
        }
        return count
    }

    /// 全图最大的「红 − 蓝」差值（琥珀 / 暖色的指纹）。
    private func maxAmberDelta(_ rep: NSBitmapImageRep) -> Double {        var best = -1.0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                best = max(best, min(color.redComponent, color.greenComponent) - color.blueComponent)
            }
        }
        return best
    }

    private func luma(_ rep: NSBitmapImageRep) throws -> CGFloat {
        let color = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
        return color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 几档就画几块

    func testMoreTiersMakeTheCardTaller() throws {
        let one = try render(
            AnyView(CurriculumLadderCard(stages: [ladder(done: false)[0]])), day: true
        )
        let four = try render(AnyView(CurriculumLadderCard(stages: ladder(done: false))), day: true)
        XCTAssertGreaterThan(
            four.size.height, one.size.height + 180,
            "四档比一档至少多出三块（每块 ≈ 80pt：档名 + can-do + 进度条 + 情景行）"
        )
    }

    // MARK: - ② 练完的那一档必须有绿（不是靠文字说「已练完」）

    func testCompletedTierDrawsGreenInk() throws {
        let locked = try render(AnyView(CurriculumLadderCard(stages: ladder(done: false))), day: true)
        let done = try render(AnyView(CurriculumLadderCard(stages: ladder(done: true))), day: true)

        let baseline = maxGreenDelta(locked.rep)
        let peak = maxGreenDelta(done.rep)
        XCTAssertGreaterThan(peak, baseline + 0.04, "练完的档位必须比全是锁的版本明显更绿（实测 \(peak) vs \(baseline)）")
        XCTAssertGreaterThan(
            greenInk(done.rep, above: baseline + 0.02), 300,
            "四档全练完要有成片绿色（四枚封印 + 四条进度条），实测 \(greenInk(done.rep, above: baseline + 0.02)) 像素"
        )
        XCTAssertLessThan(
            greenInk(locked.rep, above: baseline + 0.02), 200,
            "全是锁的版本不该有成片绿（基准自带的那点绿要排除掉），实测 \(greenInk(locked.rep, above: baseline + 0.02)) 像素"
        )
    }

    // MARK: - ③ 判定卡：差几句就得写几句

    func testVerdictCardGrowsWithTheMissingSentenceLine() throws {
        let passed = try render(
            AnyView(CurriculumVerdictCard(assessment: assessment(.passed), scenarioTitle: "观点表达")),
            day: true
        )
        let close = try render(
            AnyView(CurriculumVerdictCard(assessment: assessment(.close), scenarioTitle: "观点表达")),
            day: true
        )
        XCTAssertGreaterThan(
            close.size.height, passed.size.height + 12,
            "「还没说到的句子」那一行必须真的占高度，否则学员看不到该补哪句"
        )
    }

    /// 「就差一点」用琥珀、「过关」用绿 —— 两种结果必须一眼分得出来。
    func testVerdictCardColorTellsPassFromClose() throws {
        let passed = try render(
            AnyView(CurriculumVerdictCard(assessment: assessment(.passed), scenarioTitle: "观点表达")),
            day: true
        )
        let close = try render(
            AnyView(CurriculumVerdictCard(assessment: assessment(.close), scenarioTitle: "观点表达")),
            day: true
        )
        let passedGreen = maxGreenDelta(passed.rep)
        let closeGreen = maxGreenDelta(close.rep)
        let closeAmber = maxAmberDelta(close.rep)

        XCTAssertGreaterThan(passedGreen, 0.15, "过关版必须有绿色（实测 \(passedGreen)）")
        XCTAssertLessThan(closeGreen, passedGreen - 0.1, "「就差一点」不该画成绿的（实测 \(closeGreen)）")
        XCTAssertGreaterThan(closeAmber, 0.25, "「就差一点」应是琥珀色（实测 \(closeAmber)）")
    }

    // MARK: - ④ 日夜两版都要能看（并落盘供人眼复核）

    func testBothCardsRenderInBothThemesAndDumpPNG() throws {
        let day = try render(AnyView(CurriculumLadderCard(stages: ladder(done: true))), day: true)
        let night = try render(AnyView(CurriculumLadderCard(stages: ladder(done: true))), day: false)
        // 这里只钉「两版都真的画了东西、且底色确实不同」——
        // 「练完有绿」由 `testCompletedTierDrawsGreenInk` 用相对基准判，
        // 不在这一条里再写绝对值（色彩管理一变就会假失败）。
        XCTAssertGreaterThan(try luma(day.rep), try luma(night.rep), "两版底色必须真的不同")
        XCTAssertGreaterThan(inkCount(day.rep), 3000, "日间版必须真画出内容")
        XCTAssertGreaterThan(inkCount(night.rep), 3000, "夜间版必须真画出内容")
        XCTAssertEqual(day.size.height, night.size.height, accuracy: 2, "同一份内容，两版高度应一致")
        try dump(day.rep, name: "round33-curriculum-ladder-day.png")
        try dump(night.rep, name: "round33-curriculum-ladder-night.png")

        let verdictDay = try render(
            AnyView(CurriculumVerdictCard(assessment: assessment(.close), scenarioTitle: "观点表达")),
            day: true
        )
        let verdictNight = try render(
            AnyView(CurriculumVerdictCard(assessment: assessment(.close), scenarioTitle: "观点表达")),
            day: false
        )
        XCTAssertGreaterThan(try luma(verdictDay.rep), try luma(verdictNight.rep))
        XCTAssertGreaterThan(inkCount(verdictDay.rep), 1500, "判定卡日间版必须真画出内容")
        XCTAssertGreaterThan(inkCount(verdictNight.rep), 1500, "判定卡夜间版必须真画出内容")
        try dump(verdictDay.rep, name: "round33-curriculum-verdict-day.png")
        try dump(verdictNight.rep, name: "round33-curriculum-verdict-night.png")
    }

    // MARK: - ⑤ 端到端：真实素材真的排成了四档，进度页真的画出来了

    /// 走真实链路（`AppState(services:)` → `openProgress()` → `state.curriculumStages`）。
    /// 组件好看不代表接线通了 —— 这条才是接线。
    func testProgressPageShowsCurriculumLadderEndToEnd() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("curriculum-probe-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        await state.loadScenarios()
        await state.openProgress()

        let stages = state.curriculumStages
        XCTAssertEqual(stages.map(\.level), [.a1, .a2, .b1, .b2], "随包素材要能排出完整的四档阶梯")
        for stage in stages {
            XCTAssertFalse(stage.scenarios.isEmpty, "\(stage.level.code) 档没有情景")
        }
        // 高等级那两档必须挂到大树上，否则练完无处记星。
        for code in [CEFRLevel.b1, .b2] {
            XCTAssertFalse(
                stages.first { $0.level == code }?.levels.isEmpty ?? true,
                "\(code.code) 档必须挂到成长树的关卡上"
            )
        }
        // 需求 1：闯关进度**从零开始**，所以整体进度必须是 0，
        // 而不是「种子里已经过了几关」。这条断言就是「清零」的守卫。
        XCTAssertEqual(state.curriculumProgress, 0, "清零后整体进度从 0 起算")
        XCTAssertEqual(state.progress.levels.filter { $0.state == .completed }.count, 0, "没有已通关的关卡")

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            LearningProgressView(state: state).forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 1900)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        XCTAssertGreaterThan(host.fittingSize.height, 400, "整页应能布局")
        try dump(rep, name: "round33-progress-page-with-curriculum.png")
    }

    /// 判定卡的输入取自**真实说话记录**：说了目标句就该过关，没说就不过。
    /// 这条钉的是「判定用的是学员真说过的话」，不是构造出来的数据。
    func testVerdictFollowsRealLearnerWords() {
        let scenario = BundledScenarioFixture.opinionExpression()
        let good = CurriculumScorer.assess(
            scenario: scenario,
            utterances: [
                "In my opinion, working from home is better.",
                "I prefer to study in the morning.",
                "The main reason is that it saves time.",
                "However, I agree there are some problems.",
                "1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
            ]
        )
        XCTAssertEqual(good.verdict, .passed, "把目标句都说了就该过关：\(good.reasons)")

        let silent = CurriculumScorer.assess(scenario: scenario, utterances: ["ok", "yes"])
        XCTAssertEqual(silent.verdict, .notYet, "只说 ok / yes 不能过关：\(silent.reasons)")
    }

    /// 情景选择面板：**练之前就能看见主线任务与教学重点**（需求 3）。
    ///
    /// 与旧版的区别：卡片默认是**收起**的（点一下才展开），所以不能再用
    /// 「列表总高必须体现目标句」来判 —— 改成「展开前后高度差」，
    /// 那一段高度差正是主线任务 + 教学重点 + 大树联动那一块。
    func testScenarioPickerExpandsToShowQuestAndFocusEndToEnd() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("picker-probe-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        await state.loadScenarios()

        XCTAssertFalse(state.scenarios.isEmpty, "随包情景应能加载")
        // 需求 3：**每一关都要有主线任务**。随包素材必须都写了，否则会退回自动推导 ——
        // 推导出来的步骤名是目标句原文，读起来不像「任务」。
        for scenario in state.scenarios {
            let plan = scenario.questPlan
            XCTAssertGreaterThan(plan.total, 0, "「\(scenario.id)」没有主线任务")
            XCTAssertGreaterThan(plan.anchoredSteps.count, 0, "「\(scenario.id)」的主线任务没有可判定的锚点")
            XCTAssertFalse(plan.title.isEmpty, "「\(scenario.id)」的主线任务没有标题")
        }
        XCTAssertTrue(
            state.scenarios.allSatisfy { !$0.targetSentences.isEmpty },
            "每个随包情景都要有目标句，否则「教学重点」判不了"
        )

        // 收回合态。
        state.expandedScenarioID = nil
        let collapsed = try renderPicker(state, name: nil)

        // 展开第一张卡。
        let target = try XCTUnwrap(state.scenarios.first?.id)
        state.expandedScenarioID = target
        let expanded = try renderPicker(state, name: "round34-scenario-picker-expanded.png")

        XCTAssertGreaterThan(
            expanded.size.height - collapsed.size.height, 60,
            "展开后要多出「主线任务 + 教学重点 + 大树联动」这一块（实测差 \(expanded.size.height - collapsed.size.height)）"
        )
        XCTAssertGreaterThan(inkCount(expanded.rep), inkCount(collapsed.rep), "展开区确实画了东西")
    }

    /// 需求 3 的**视觉留档**：展开态卡片日夜两版都能看清，且「完成情况」真的跟着进度走。
    ///
    /// 这条同时是一条真断言（不只是出图）：主线进度必须**从库里读**出来 ——
    /// 若卡片上的「主线 x/y」是自己编的，`saveQuestProgress` 之后数字就不会变。
    func testScenarioPickerExpandedDumpBothThemesAndProgress() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("picker-dump-\(UUID().uuidString).json")
        )
        let services = CoachServices(config: store, databasePath: ":memory:")
        let state = AppState(services: services)
        await state.loadScenarios()

        let target = try XCTUnwrap(state.scenarios.first, "随包情景应能加载")
        let plan = target.questPlan
        let firstStep = try XCTUnwrap(plan.steps.first, "第一关必须有主线任务步骤")
        state.expandedScenarioID = target.id

        let zeroDay = try renderPicker(state, day: true, name: "round43-scenario-expanded-day.png")
        let zeroNight = try renderPicker(state, day: false, name: "round43-scenario-expanded-night.png")
        // ⚠️ 这里**不能**用 `luma(0,0)` 判日夜：情景面板没有铺满底色，
        // 角落像素在两版里都是透明（读出来都是 0）。改成量「两张图真的不一样」。
        XCTAssertGreaterThan(inkCount(zeroDay.rep), 3000, "日间版必须真画出内容")
        XCTAssertGreaterThan(inkCount(zeroNight.rep), 3000, "夜间版必须真画出内容")
        XCTAssertGreaterThan(
            differingPixels(zeroDay.rep, zeroNight.rep), 3000,
            "日夜两版必须真的渲染成不同颜色，否则「夜间版」是没生效的"
        )

        // 推进一步并落库：卡片的「完成情况 / 当前节点」必须跟着变。
        await services.saveQuestProgress(
            ScenarioQuestRecord(scenarioID: target.id, doneStepIDs: [firstStep.id])
        )
        await state.refreshQuestRecords()
        let progressed = state.questProgress(for: target)
        XCTAssertEqual(progressed.doneCount, 1, "进度没从库里读出来 → 卡片上的「主线 x/y」就是假的")
        XCTAssertEqual(
            progressed.currentStep?.id, plan.steps.dropFirst().first?.id,
            "第一步完成后，当前节点必须前移到下一步（否则老师催的还是已经做过的事）"
        )
        _ = try renderPicker(state, day: true, name: "round43-scenario-progressed-day.png")
    }
    /// 离屏渲染情景选择面板并返回自然高度（同时留档 PNG）。
    ///
    /// ⚠️ 必须自己铺 `theme.panel`：面板本身**不带底色**（真实应用里由
    /// `MainView.scenariosOverlay` 的圆角底托着）。不铺的话夜间版会被合成到浅色上，
    /// 出来一张「浅底 + 浅字」的图 —— 看着像配色坏了，其实只是少了那层底。
    private func renderPicker(_ state: AppState, day: Bool = true, name: String?) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let host = NSHostingView(rootView: AnyView(
            ScenarioPickerView(state: state, onClose: {})
                .forestTheme(theme)
                .background(theme.panel)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 2400)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let height = max(ceil(host.fittingSize.height), 200)
        let size = CGSize(width: 720, height: height)
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let name { try dump(rep, name: name) }
        return Render(rep: rep, size: size)
    }
}

/// 取随包发布的「观点表达」场景（判定链路的真实输入）。
private enum BundledScenarioFixture {
    static func opinionExpression() -> Scenario {
        let scenario = ScenarioCatalog.bundled().first { $0.id == "opinion_expression" }
        return scenario ?? Scenario(
            id: "opinion_expression", title: "Sharing Opinions", titleZh: "观点表达",
            category: "思维", difficulty: 4, level: "B1", objective: "", aiRole: "ai",
            learnerRole: "learner", opening: "", targetVocabulary: [], targetGrammar: [],
            targetSentences: []
        )
    }
}
