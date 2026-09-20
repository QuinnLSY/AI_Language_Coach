import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 上传材料自动出题的**界面与接线**（#208）：材料卡、上传浮层、无模型时的生成链路。
///
/// 与 `ExamRenderTests` 同款做法：离屏渲染出图 + 真 `AppState` 走接线；
/// 断言只钉「用户真能看见 / 真能点」这件事，PNG 落 `.workbuddy/verify/` 供人眼复核。
@MainActor
final class MaterialRenderTests: XCTestCase {

    private var window: NSWindow?

    // MARK: - 夹具

    private let sampleOutput = """
    title: Onboarding at a small startup | 小公司入职第一天
    scenario: HR manager | new employee | introduce yourself and ask about the team | 3 | Welcome! Tell me a bit about yourself.
    vocabulary: onboarding | n. | 入职引导 | The onboarding takes two days.
    vocabulary: colleague | n. | 同事 | My colleagues are very friendly.
    sentence: I joined the team last Monday. | 我上周一入职。 | joined 连读
    sentence: Could you tell me where my desk is? | 你能告诉我我的工位在哪吗？ | Could you 弱读
    """

    private let sampleMaterial = """
    Dear new hires, welcome to the company. Your onboarding takes two days. On the first day you will meet your
    colleagues and learn about the team. Please ask questions whenever something is unclear. Your desk is on the
    second floor next to the meeting room, and everyone is happy to show you around.
    """

    private func makeKit() throws -> MaterialKit {
        try XCTUnwrap(MaterialKitRule.parse(sampleOutput, text: sampleMaterial))
    }

    /// 一支「模型必定秒失败」的 AppState（与 `ExamRenderTests.makeDeadLLMState` 同构）。
    ///
    /// ⚠️ 必须把 llm 指到 stub 死端口并 activate：默认配置里的 `ollama.llm` 在本机
    /// Ollama 真在跑时是**可用**的，会让「模型不可用」类断言变成环境彩票。
    private func makeDeadLLMState() async throws -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("material-probe-\(UUID().uuidString)", isDirectory: true)
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
        let services = CoachServices(
            config: store,
            databasePath: ":memory:",
            materialStore: MaterialStore(directory: directory.appendingPathComponent("materials", isDirectory: true))
        )
        return AppState(services: services)
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    private func render(_ view: AnyView, day: Bool, width: CGFloat) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
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

    // MARK: - ① 材料卡：日夜两版 + 内容真的占高度

    func testMaterialCardRendersInBothThemesAndDumpsPNG() async throws {
        let kit = try makeKit()
        let day = try render(AnyView(cardProxy(kit, state: try await makeDeadLLMState())), day: true, width: 660)
        let night = try render(AnyView(cardProxy(kit, state: try await makeDeadLLMState())), day: false, width: 660)
        XCTAssertGreaterThan(day.size.height, 90, "材料卡要有像样的高度（图标 + 标题 + chips + 按钮）")
        try dump(day.rep, name: "round43-material-card-day.png")
        try dump(night.rep, name: "round43-material-card-night.png")
    }

    /// `MaterialKitCard` 是 internal（组件不认识面板），测试同模块内直接构造。
    private func cardProxy(_ kit: MaterialKit, state: AppState) -> some View {
        MaterialKitCard(kit: kit, state: state)
    }

    // MARK: - ② 上传浮层：空草稿给指引、有结果给回执

    func testUploadSheetShowsDraftHintAndResultBanner() async throws {
        let state = try await makeDeadLLMState()
        let empty = try render(AnyView(MaterialUploadSheet(state: state, onClose: {})), day: true, width: 560)

        state.materialDraft = sampleMaterial
        let filled = try render(AnyView(MaterialUploadSheet(state: state, onClose: {})), day: true, width: 560)
        XCTAssertGreaterThan(filled.size.height, empty.size.height - 10, "填了正文后编辑器高度不该塌")

        // 生成失败也要有回执（模型不可用），而不是默默什么都不发生。
        state.materialDraft = sampleMaterial
        state.materialResult = "没能从材料里拆出完整的练习（缺标题 / 情景 / 跟读句），请重试一次。"
        let failed = try render(AnyView(MaterialUploadSheet(state: state, onClose: {})), day: true, width: 560)
        XCTAssertGreaterThan(failed.size.height, filled.size.height + 20, "失败回执必须真的占出一行横幅")
        try dump(failed.rep, name: "round43-material-sheet-failure.png")
    }

    // MARK: - ③ 接线：导入文件 → 草稿；模型不可用 → 如实报错且不落盘

    func testImportFileFillsDraftAndGenerationFailsHonestlyWithoutModel() async throws {
        let state = try await makeDeadLLMState()

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("material-\(UUID().uuidString).txt")
        try sampleMaterial.write(to: file, atomically: true, encoding: .utf8)
        state.importMaterialFile(at: file.path)
        XCTAssertTrue(state.materialDraft.contains("Dear new hires"), "导入的正文要进草稿")

        await state.generateMaterialFromDraft()
        XCTAssertNotNil(state.materialResult, "生成必须有回执（成功或失败）")
        XCTAssertTrue(state.materialKits.isEmpty, "模型不可用时**不落盘**：宁可重试也不能存半成品")
        state.importMaterialFile(at: file.path + ".nonexistent")
        XCTAssertNotNil(state.materialResult, "读不到的文件要如实说，不许静默")
    }
}
