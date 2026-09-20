import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 考试模式的**界面与接线**（#206）：考场条、结算卡、以及「开始考试 → 作答 → 结算」整条链路。
///
/// 与 `DailyTasksCardRenderTests` 同款理由：当前验证环境熄屏，走离屏渲染出图；
/// 断言只钉「用户真能看见」这件事 —— 环节说明真占一行、每个维度真占一行、
/// 示范答案真的比没有的时候高一截。顺带把 PNG 落到 `.workbuddy/verify/` 供人眼复核。
@MainActor
final class ExamRenderTests: XCTestCase {

    private var window: NSWindow?

    // MARK: - 夹具

    /// 一道题、一个环节的最小考卷（渲染用，不去读真实资源 —— 真实资源由
    /// `ExamModeTests.testBundledBlueprintsLoad` 与下面的端到端用例各自盯住）。
    private func blueprint(
        prompts: [String] = ["What do you like most about the area you live in?"],
        seconds: Int = 40,
        minimumWords: Int = 25,
        instructions: String = "三个日常问题，每个答 2–3 句（25 词以上），别只回一个词。"
    ) -> ExamBlueprint {
        ExamBlueprint(
            id: "test.exam", format: .ieltsSpeaking, title: "雅思口语模拟", summary: "按 Part 1/2/3 走一遍",
            stages: [
                ExamStage(
                    id: "part1", title: "Part 1 · 简介问答", instructions: instructions,
                    prompts: prompts, timeLimitSeconds: seconds, minimumWords: minimumWords
                )
            ]
        )
    }

    private func bar(_ blueprint: ExamBlueprint, armed: Bool, now: Date = Date()) -> ExamBarModel {
        var runner = ExamRunner(blueprint: blueprint, startedAt: now)
        if armed { runner.arm(now: now) }
        return ExamBarModel(
            title: runner.blueprint.title,
            stageTitle: runner.currentStage?.title ?? "",
            instructions: runner.currentStage?.instructions ?? "",
            questionNumber: runner.questionNumber,
            totalQuestions: runner.totalQuestions,
            minimumWords: runner.currentStage?.minimumWords ?? 0,
            limitSeconds: runner.questionLimitSeconds,
            deadline: runner.questionDeadline,
            questionKey: "\(runner.questionNumber)-\(runner.questionDeadline?.timeIntervalSince1970 ?? 0)"
        )
    }

    /// 一份「答过几问」的真实报告（走 `ExamScoring` 纯函数，不编报告）。
    private func report(
        answerCount: Int,
        pronunciation: Bool = false
    ) -> ExamReport {
        let prompts = ["Q1", "Q2", "Q3", "Q4"]
        var runner = ExamRunner(blueprint: blueprint(prompts: prompts), startedAt: Date())
        for index in 0..<answerCount {
            runner.arm(now: Date())
            let text = index == 0
                ? "I live in a small apartment near the river because it is quiet at night."
                : "It is fine."
            runner.submit(text: text, now: Date())
        }
        return runner.report(pronunciation: pronunciation ? ExamBand(6.5) : nil)
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    private func render(_ view: AnyView, day: Bool, width: CGFloat) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        // `fixedSize(vertical:)` 是这里的关键：被测卡片里有 `ScrollView`，
        // 不给它一个「按内容算高度」的约束，出图永远只有一屏（高度差分全是假的）。
        let host = NSHostingView(rootView: AnyView(
            view
                .fixedSize(horizontal: false, vertical: true)
                .forestTheme(theme)
                .frame(width: width)
                .background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问自然高度，再按自然高度出图，避免把内容裁掉。
        // ⚠️ 下限要**足够小**：考场条本身只有四十来点高，卡在 60 会把
        // 「有没有那一行说明」的差别整个抹平（实测踩过）。
        let size = CGSize(width: width, height: max(24, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
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

    // MARK: - ① 考场条：环节说明真占一行

    func testExamBarShowsSectionInstructions() throws {
        let long = "给你一张题卡，连续说 1–2 分钟（80 词以上），中间不要停：先说要讲什么，"
            + "再说怎么学到的，最后说它为什么对你有用，尽量用 because / although 展开。"
        let oneLine = try render(
            AnyView(ExamSessionBar(model: bar(blueprint(instructions: "每个问题答 2–3 句。"), armed: true))),
            day: true, width: 700
        )
        let none = try render(
            AnyView(ExamSessionBar(model: bar(blueprint(instructions: ""), armed: true))),
            day: true, width: 700
        )
        let wrapped = try render(
            AnyView(ExamSessionBar(model: bar(blueprint(instructions: long), armed: true))),
            day: true, width: 700
        )
        XCTAssertGreaterThan(
            oneLine.size.height, none.size.height,
            "环节的作答要求必须是独立一行（学员要知道这一环节怎么答）"
        )
        XCTAssertGreaterThan(
            wrapped.size.height, oneLine.size.height + 10,
            "要求长的时候要换行占更多高度，不能截断成一行"
        )
    }

    // MARK: - ② 未起表与已起表是两副样子

    func testExamBarDistinguishesArmedFromWaiting() throws {
        let waiting = try render(
            AnyView(ExamSessionBar(model: bar(blueprint(), armed: false))), day: true, width: 700
        )
        let running = try render(
            AnyView(ExamSessionBar(model: bar(blueprint(), armed: true))), day: true, width: 700
        )
        // 两者文字不同（「等待考官提问…」vs`0:40`），至少说明倒计时不是同一份状态画出来的。
        XCTAssertNotEqual(
            inkCount(waiting.rep), inkCount(running.rep),
            "等待态与计时态的墨迹量不该完全一致"
        )
        XCTAssertEqual(ExamSessionBar.clock(45), "0:45")
        XCTAssertEqual(ExamSessionBar.clock(80), "1:20")
        XCTAssertEqual(ExamSessionBar.clock(0), "0:00")
    }

    // MARK: - ③ 日夜两版都能看（并落盘供人眼复核）

    func testExamBarRendersInBothThemesAndDumpsPNG() throws {
        let model = bar(blueprint(), armed: true)
        let day = try render(AnyView(ExamSessionBar(model: model)), day: true, width: 700)
        let night = try render(AnyView(ExamSessionBar(model: model)), day: false, width: 700)
        XCTAssertGreaterThan(day.size.height, 30)
        try dump(day.rep, name: "round42-exam-bar-day.png")
        try dump(night.rep, name: "round42-exam-bar-night.png")
    }

    // MARK: - ④ 结算卡：维度多一个就多一行

    func testReportCardGrowsWithEachDimension() throws {
        let four = try render(
            AnyView(ExamReportCard(
                report: report(answerCount: 3),
                sampleAnswers: [:], sampleTargets: [], sampleNotice: nil, isGeneratingSamples: false
            )),
            day: true, width: 560
        )
        let five = try render(
            AnyView(ExamReportCard(
                report: report(answerCount: 3, pronunciation: true),
                sampleAnswers: [:], sampleTargets: [], sampleNotice: nil, isGeneratingSamples: false
            )),
            day: true, width: 560
        )
        XCTAssertGreaterThan(
            five.size.height, four.size.height + 30,
            "多一个评分维度（发音）就该多出一整块，不能只是数字变化"
        )
    }

    /// 示范答案是真的多一块内容（不是只把标题换了）。
    func testReportCardShowsSampleAnswers() throws {
        let noSamples = try render(
            AnyView(ExamReportCard(
                report: report(answerCount: 2),
                sampleAnswers: [:], sampleTargets: [], sampleNotice: nil, isGeneratingSamples: false
            )),
            day: true, width: 560
        )
        let targets = [
            ExamSampleTarget(questionNumber: 3, prompt: "Q3", answer: "It is fine."),
            ExamSampleTarget(questionNumber: 4, prompt: "Q4", answer: ""),
        ]
        let withSamples = try render(
            AnyView(ExamReportCard(
                report: report(answerCount: 2),
                sampleAnswers: [
                    3: "Although the town is small, there is a river walk where neighbours meet every evening.",
                    4: "I would say that the biggest change has been how people learn new skills online.",
                ],
                sampleTargets: targets, sampleNotice: nil, isGeneratingSamples: false
            )),
            day: true, width: 560
        )
        XCTAssertGreaterThan(
            withSamples.size.height, noSamples.size.height + 100,
            "两条示范答案（题面 + 正文）必须真的占出高度来"
        )
    }

    /// 没拿到示范答案时只能如实说没拿到，并且给「重试」。
    func testReportCardShowsNoticeWhenSamplesFailed() throws {
        let failed = try render(
            AnyView(ExamReportCard(
                report: report(answerCount: 1),
                sampleAnswers: [:],
                sampleTargets: [ExamSampleTarget(questionNumber: 2, prompt: "Q2", answer: "")],
                sampleNotice: "示范答案这次没拿到（模型没起来，或返回里没有可用的答案行）。",
                isGeneratingSamples: false
            )),
            day: true, width: 560
        )
        try dump(failed.rep, name: "round42-exam-report-samples-missing.png")
        XCTAssertGreaterThan(failed.size.height, 200)
    }

    func testReportCardRendersInBothThemesAndDumpsPNG() throws {
        let report = report(answerCount: 3, pronunciation: true)
        let card = ExamReportCard(
            report: report,
            sampleAnswers: [2: "Although it looks like a small change, learning to cook properly saved me a lot of money."],
            sampleTargets: [ExamSampleTarget(questionNumber: 2, prompt: "Q2", answer: "It is fine.")],
            sampleNotice: nil, isGeneratingSamples: false
        )
        let day = try render(AnyView(card), day: true, width: 560)
        let night = try render(AnyView(card), day: false, width: 560)
        try dump(day.rep, name: "round42-exam-report-day.png")
        try dump(night.rep, name: "round42-exam-report-night.png")

        func luma(_ rep: NSBitmapImageRep) throws -> CGFloat {
            let color = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
            return color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
        }
        XCTAssertGreaterThan(try luma(day.rep), try luma(night.rep), "两版底色必须真的不同")
    }

    // MARK: - ⑤ 端到端接线（开始考试 → 作答 → 结算）

    /// 一支「模型必定秒失败」的 AppState。
    ///
    /// ⚠️ 不能直接用默认配置：`llm` 会被解析到**本机真在跑的 Ollama** 上，
    /// 一次真实推理几十秒。注册一支端点必然连不上的 provider 并激活它，
    /// 请求立刻失败 —— 而本用例要钉的正是**模型不可用时考试也不能卡住**。
    private func makeDeadLLMState() async throws -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exam-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.updateProvider(
            ProviderConfig(
                id: "stub.llm", kind: .llm, enabled: true, runtime: .remoteAPI,
                endpoint: "http://127.0.0.1:9/v1", apiKey: "sk-dead",
                model: "stub-model", candidateModels: ["stub-model"]
            )
        )
        try await store.mutateProduct { product in
            product.activateProvider("stub.llm", for: .llm)
            product.selectModel("stub-model", for: .llm)
        }
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    /// 等一个条件成立（异步链路没有现成的信号，只能轮询到上限）。
    private func waitUntil(
        timeout: TimeInterval = 8,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testExamRunsEndToEndWithoutAModel() async throws {
        let state = try await makeDeadLLMState()
        await state.loadExamBlueprints()
        XCTAssertFalse(state.examBlueprints.isEmpty, "随包考卷必须读得到")
        let blueprint = try XCTUnwrap(state.examBlueprints.first { $0.questionCount > 1 })
        let firstPrompt = try XCTUnwrap(blueprint.stages.first?.prompts.first)

        await state.startExam(blueprint)
        XCTAssertTrue(state.isExamActive, "开始考试后状态必须真的进去了")

        // 模型不可用 → 开场白走本地兜底，**而且兜底内容就是第一问**。
        await waitUntil { !state.chat.messages.isEmpty && !state.chat.isGenerating }
        let opener = try XCTUnwrap(state.chat.messages.last)
        XCTAssertEqual(opener.role, .assistant)
        XCTAssertTrue(
            opener.content.contains(firstPrompt),
            "考官没接上时也必须把题念出来，否则整场卡在第一问：\(opener.content)"
        )

        // 考场条：题号/限时/期望词数都来自考卷，倒计时在题目出现后才起表。
        let bar = try XCTUnwrap(state.examBarModel)
        XCTAssertEqual(bar.totalQuestions, blueprint.questionCount)
        XCTAssertEqual(bar.questionNumber, 1)
        XCTAssertNotNil(bar.deadline, "题目已经念出来了，倒计时就该起表")
        XCTAssertEqual(bar.limitSeconds, blueprint.stages.first?.timeLimitSeconds)

        // 作答 → 记进考卷、推进到下一问。
        let answer = "I live in a small apartment near the river because it is quiet at night, "
            + "although the rent has gone up a lot this year."
        XCTAssertTrue(state.sendChat(answer), "考试模式下发送必须被接受")
        XCTAssertEqual(state.examRunner?.answers.count, 1)
        XCTAssertEqual(state.examRunner?.answers.first?.text, answer)
        XCTAssertEqual(
            state.examRunner?.questionNumber, 2,
            "答完一问自动进下一问（这正是「答完自动进下一题」的落点）"
        )
        XCTAssertEqual(bar.questionNumber, 1, "旧快照不该被改写")

        // 渲染一次「考试进行中」的对话区：真实 AppState + 真实考场条，
        // 等考场条为下一问重新起表之后出图（否则画的是「等待考官提问」那一态）。
        await waitUntil { state.examBarModel?.deadline != nil }
        let live = try render(AnyView(ChatView(
            chat: state.chat,
            modelName: "stub-model",
            health: state.health,
            teacherKind: .panda,
            studentKind: .bear,
            exam: state.examBarModel,
            onSend: { text in state.sendChat(text) }
        )), day: true, width: 720)
        try dump(live.rep, name: "round42-chat-with-exam-bar.png")
        XCTAssertGreaterThan(live.size.height, 200, "对话区应能把考场条一起画出来")
        XCTAssertEqual(state.examBarModel?.questionNumber, 2, "考场条跟着走到第 2 问")

        // 超时路径：没到点（且已经起表）时一次都不该跳。
        await state.examQuestionTimedOut()
        XCTAssertEqual(state.examRunner?.questionNumber, 2)

        // 提前交卷 → 报告一定出得来（分数是纯函数算的，不依赖模型）。
        await state.finishExam()
        let report = try XCTUnwrap(state.examReport, "结算卡必须有报告")
        XCTAssertEqual(report.metrics.answeredCount, 1)
        XCTAssertEqual(report.metrics.questionCount, blueprint.questionCount)
        XCTAssertFalse(report.scores.isEmpty, "答过一问就该有维度分")
        XCTAssertFalse(report.isComplete, "提前交卷不该被说成全场考完")
        XCTAssertNil(state.examBarModel, "考完之后考场条必须收起来（否则像还没结束）")
        XCTAssertNil(
            report.metrics.errorsPerAnswer,
            "没有走过老师那一轮就不该有纠错数据（宁可封顶，也不能编一个零错误）"
        )

        // 关掉报告 → 考试状态清干净，可以回到普通练习。
        state.dismissExamReport()
        XCTAssertFalse(state.isExamActive)
        XCTAssertNil(state.examReport)
    }

    /// 纯文案：考场态输入框只说要求，不给可以照念的句子。
    func testExamComposerHint() {
        let model = bar(blueprint(), armed: true)
        let hint = ChatView.examComposerHint(model)
        XCTAssertTrue(hint.contains("第 1/1 问"))
        XCTAssertTrue(hint.contains("至少 25 词"))
        XCTAssertTrue(hint.contains("答完自动进下一题"))
        XCTAssertFalse(hint.contains("?"), "考场输入框里不该出现一句可以照念的问题")
    }

    // MARK: - 工具

    /// 全图「有色墨迹」像素数（底色之外的内容）。用于区分两版文案真的不一样。
    private func inkCount(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let luma = color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
                if luma < 0.55 { count += 1 }
            }
        }
        return count
    }
}
