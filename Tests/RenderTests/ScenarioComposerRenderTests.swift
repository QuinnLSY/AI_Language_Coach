import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 一句话生成情景的**界面与接线**（⑦）：描述浮层、自建情景卡片、删除入口、无模型时的失败回执。
///
/// 与 `MaterialRenderTests` 同款做法：离屏渲染出图 + 真 `AppState` 走接线；
/// 断言只钉「用户真能看见 / 真能点」，PNG 落 `.workbuddy/verify/` 供人眼复核。
///
/// ⚠️ 「删除按钮画没画出来」这类**控件存在性**断言离屏测不了（SwiftUI 的 `Button` 在
/// 离屏树上不是 `NSButton`，也没有可读的 AX 标签）—— 判据 `origin` 由
/// `ScenarioDraftTests.testBundledScenariosAreBuiltInAndDraftsAreCustom` 钉死，
/// 画面本身就出 PNG 复核。
@MainActor
final class ScenarioComposerRenderTests: XCTestCase {

    private var window: NSWindow?

    // MARK: - 夹具

    private let sampleOutput = """
    title: Ordering an oat milk latte | 咖啡店换燕麦奶
    scene: barista | customer | order a latte and ask to swap the milk | 2 | Hi! What can I get for you today?
    sentence: Could I get a latte with oat milk instead?
    sentence: Does it cost extra to swap the milk?
    vocabulary: oat milk | n. | 燕麦奶 | Could I have oat milk instead?
    vocabulary: swap | v. | 换掉 | Can I swap the milk?
    quest: Order your drink and change one thing about it
    """

    private let prompt = "在咖啡店点一杯 latte，想换成 oat milk"

    private func makeDraft() throws -> ScenarioDraft {
        try XCTUnwrap(ScenarioDraftRule.parse(sampleOutput, prompt: prompt))
    }

    /// 一套「模型必定秒失败」的 AppState；`customScenarioStore` 指向临时目录（绝不碰真实数据）。
    ///
    /// ⚠️ 必须把 llm 指到 stub 死端口并 activate：默认配置里的 `ollama.llm` 在本机
    /// Ollama 真在跑时是**可用**的，会让「模型不可用」类断言变成环境彩票。
    private func makeState(seed: ScenarioDraft? = nil) async throws -> (state: AppState, drafts: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenario-probe-\(UUID().uuidString)", isDirectory: true)
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
        let drafts = directory.appendingPathComponent("scenarios", isDirectory: true)
        let scenarioStore = CustomScenarioStore(directory: drafts)
        if let seed { try await scenarioStore.save(seed) }
        let services = CoachServices(
            config: store,
            databasePath: ":memory:",
            customScenarioStore: scenarioStore
        )
        return (AppState(services: services), drafts)
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    private func render(_ view: AnyView, day: Bool, width: CGFloat, height: CGFloat = 200) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            view
                .fixedSize(horizontal: false, vertical: true)
                .forestTheme(theme)
                .frame(width: width)
                .background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

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
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 描述浮层：空草稿给指引、填了内容不塌、失败真有回执

    func testComposerSheetRendersInBothThemesAndDumpsPNG() async throws {
        let (state, _) = try await makeState()
        let day = try render(AnyView(ScenarioComposerSheet(state: state, onClose: {})), day: true, width: 560)
        let night = try render(AnyView(ScenarioComposerSheet(state: state, onClose: {})), day: false, width: 560)
        // 编辑器 104 + 三个示例 chip + 按钮行 + 内边距：空态也该有像样的高度。
        XCTAssertGreaterThan(day.size.height, 240, "描述浮层空态就有编辑器与示例，不能是条窄缝")
        XCTAssertEqual(day.size.height, night.size.height, accuracy: 1, "日夜两版版式必须一致")
        try dump(day.rep, name: "round54-scenario-composer-day.png")
        try dump(night.rep, name: "round54-scenario-composer-night.png")
    }

    func testComposerSheetShowsInputHintAndResultBanner() async throws {
        let (state, _) = try await makeState()
        let empty = try render(AnyView(ScenarioComposerSheet(state: state, onClose: {})), day: true, width: 560)

        // 太短：动作行左侧出现「再写具体一点（3/4 字）」。
        state.scenarioPromptText = "练口语"
        let short = try render(AnyView(ScenarioComposerSheet(state: state, onClose: {})), day: true, width: 560)
        XCTAssertEqual(short.size.height, empty.size.height, accuracy: 1, "提示只占动作行，不该把浮层撑高")

        state.scenarioPromptText = prompt
        let filled = try render(AnyView(ScenarioComposerSheet(state: state, onClose: {})), day: true, width: 560)
        XCTAssertEqual(
            filled.size.height, empty.size.height, accuracy: 1,
            "编辑器是定高的：填了内容只换文字，浮层版式不许跟着跳"
        )

        // 失败回执（模型不可用）必须真的占出一行横幅，而不是默默什么都不发生。
        state.scenarioResult = "没能生成一个完整的情景（缺标题 / 场景 / 开场白，或目标句不够两句）——换个说法再试一次。"
        let failed = try render(AnyView(ScenarioComposerSheet(state: state, onClose: {})), day: true, width: 560)
        XCTAssertGreaterThan(failed.size.height, filled.size.height + 20, "失败回执要有实打实的一行")
        try dump(failed.rep, name: "round54-scenario-composer-failure.png")
    }

    // MARK: - ② 自建情景进面板：分组、卡片、删除入口

    func testPickerShowsSelfBuiltScenariosInsideThePanel() async throws {
        let draft = try makeDraft()
        let (state, _) = try await makeState(seed: draft)
        await state.reloadScenarios()

        let custom = try XCTUnwrap(state.scenarios.first { $0.id == draft.id })
        XCTAssertEqual(custom.origin, .custom)
        let builtIn = try XCTUnwrap(state.scenarios.first { $0.origin == .builtIn })

        state.expandedScenarioID = custom.id
        let customOnly = try render(AnyView(ScenarioPickerView(state: state, onClose: {})), day: true, width: 640)
        state.scenarios = [custom]
        let oneCard = try render(AnyView(ScenarioPickerView(state: state, onClose: {})), day: true, width: 640)
        XCTAssertGreaterThan(
            customOnly.size.height, oneCard.size.height,
            "自建情景与内置情景必须同时出现在面板里（各成一组卡片）"
        )
        try dump(customOnly.rep, name: "round54-scenario-picker-custom-expanded.png")

        state.scenarios = [builtIn]
        state.expandedScenarioID = builtIn.id
        let builtInOnly = try render(AnyView(ScenarioPickerView(state: state, onClose: {})), day: true, width: 640)
        try dump(builtInOnly.rep, name: "round54-scenario-picker-builtin-expanded.png")
    }

    // MARK: - ③ 接线：删除真删、生成失败如实报错且不落盘

    func testDeletingASelfBuiltScenarioRemovesItFromPanelAndDisk() async throws {
        let draft = try makeDraft()
        let (state, drafts) = try await makeState(seed: draft)
        await state.reloadScenarios()
        await state.loadCustomScenarios()
        XCTAssertEqual(state.customScenarioDrafts.map(\.id), [draft.id])
        XCTAssertTrue(state.scenarios.contains { $0.id == draft.id })

        await state.deleteCustomScenario(id: draft.id)

        XCTAssertTrue(state.customScenarioDrafts.isEmpty, "草稿列表立即空掉")
        XCTAssertFalse(state.scenarios.contains { $0.id == draft.id }, "面板里的卡片立即消失")
        let files = try FileManager.default.contentsOfDirectory(atPath: drafts.path)
        XCTAssertTrue(files.isEmpty, "盘上也不该留着：\(files)")
    }

    func testGenerateWithoutModelReportsHonestlyAndWritesNothing() async throws {
        let (state, drafts) = try await makeState()
        // 太短：连模型都不该碰。
        state.scenarioPromptText = "练口语"
        await state.generateScenarioFromPrompt()
        XCTAssertNotNil(state.scenarioResult, "必须有回执")
        XCTAssertNil(state.lastGeneratedScenarioDraft)

        // 够长但没有可用的模型：同样只报错、不落盘。
        state.scenarioPromptText = prompt
        await state.generateScenarioFromPrompt()
        XCTAssertNotNil(state.scenarioResult, "生成失败要有可读说明")
        XCTAssertNil(state.lastGeneratedScenarioDraft)
        XCTAssertTrue(state.customScenarioDrafts.isEmpty)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: drafts.path)) ?? []
        XCTAssertTrue(files.isEmpty, "模型不可用时**不落盘**：宁可重试也不能存半成品")
    }
}
