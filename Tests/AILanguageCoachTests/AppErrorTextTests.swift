import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 报错文案的两条契约。
///
/// 1. **`.unknown` 的消息就是给用户看的那句话**，不再罩一层「未知错误：」。
///    投进这一档的都是已经被确诊的失败（材料短了 2 个字、模型没答成形、模型没声了），
///    说成「未知错误」= 把可修的问题说成程序崩了；
/// 2. **前五档保留品类前缀** —— 它们的消息通常只是「哪个动作失败了」的片段，
///    前面补「存储错误」/「数据库错误」能告诉用户是哪一层出的问题。
final class AppErrorTextTests: XCTestCase {

    // MARK: - ① `.unknown`：原样透出

    /// 用户真正会看到的两句话（材料出题 / 情景生成），**逐字**比对。
    ///
    /// 逐字（而不是 `contains`）是有意的：加回前缀、多一个空格、把直角引号换成别的，
    /// 都该让这条红。
    func testUnknownMessageIsShownVerbatim() {
        let cases = [
            "材料太短（只有 2 字，至少需要 60 字），撑不起一套练习。",
            "描述太短（3 字，至少 4 字），补一句「你是谁、在哪、要做什么」。",
            "先写一句你想练的场景（比如「在咖啡店点一杯拿铁」）。",
            "本地模型 · qwen3:8b 服务未启动或不可达：connection refused",
        ]
        for message in cases {
            let error = AppError.unknown(message)
            XCTAssertEqual(error.errorDescription, message, "整句话本身就是文案，不该再加工")
            // UI 一路读的是 `localizedDescription`（`LocalizedError` 由它转 `errorDescription`），
            // 所以这条才是「用户真正看到的字符串」。
            XCTAssertEqual(error.localizedDescription, message, "UI 读到的那一份也必须一模一样")
        }
    }

    /// 反方向：前缀的两种残留形态都不许再出现。
    ///
    /// 「未知」是**语义**错（把确诊说成未知），「错误：」是**排版**错（一句话里两个冒号）。
    func testUnknownNoLongerCallsAKnownFaultUnknown() {
        let text = AppError.unknown("材料太短（只有 2 字），撑不起一套练习。").localizedDescription
        XCTAssertFalse(text.contains("未知"), "已经确诊的失败不能说成「未知」：\(text)")
        XCTAssertFalse(text.contains("错误："), "一句话里出现两个冒号是在叠前缀：\(text)")
        XCTAssertTrue(text.hasSuffix("。"), "原句的句号要留着：\(text)")
    }

    // MARK: - ② 其余五档：品类前缀还在

    func testCategorizedErrorsKeepTheirCategory() {
        XCTAssertEqual(
            AppError.configuration("没有可用的 LLM Provider").localizedDescription,
            "配置错误：没有可用的 LLM Provider"
        )
        XCTAssertEqual(AppError.permission("无权访问麦克风").localizedDescription, "权限不足：无权访问麦克风")
        XCTAssertEqual(AppError.storage("保存配置失败：磁盘已满").localizedDescription, "存储错误：保存配置失败：磁盘已满")
        XCTAssertEqual(AppError.audio("没有可用的麦克风输入设备").localizedDescription, "音频错误：没有可用的麦克风输入设备")
        XCTAssertEqual(AppError.database("SQL 执行失败：no such table").localizedDescription, "数据库错误：SQL 执行失败：no such table")
    }
}

// MARK: - ③ 真链路：这句话真的能原样走到用户眼前吗

/// 走**用户真正走的那条路**（`AppState` → `CoachServices`），确认 `.unknown` 那句话
/// 落到提示条上时没有被任何一层再加工。
///
/// 只测纯函数是不够的：`AppState` 那两处 catch 写的是
/// `(error as? LocalizedError)?.errorDescription ?? error.localizedDescription`，
/// 一旦有人把它换成别的拼法（比如自己补一句「生成失败：」），纯函数测试照样全绿。
@MainActor
final class AppErrorNoticeTextTests: XCTestCase {

    /// 太短的描述 → 提示条上就是那一句，且**不带**「未知错误：」。
    func testShortScenarioPromptReachesTheNoticeVerbatim() async throws {
        let (state, directory) = try await makeState()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.scenarioPromptText = "点咖啡"   // 3 字 < 下限 4 字

        await state.generateScenarioFromPrompt()

        let text = try XCTUnwrap(state.scenarioResult, "输入不合格也要说一声，不能静默")
        XCTAssertTrue(text.hasPrefix("描述太短"), "用户该看到的是原因，实际：\(text)")
        XCTAssertFalse(text.contains("未知"), "已经确诊的输入问题不能说成「未知错误」：\(text)")
    }

    /// 空描述走另一支（`.empty`），同样原样透出。
    func testEmptyScenarioPromptReachesTheNoticeVerbatim() async throws {
        let (state, directory) = try await makeState()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.scenarioPromptText = "   "

        await state.generateScenarioFromPrompt()

        let text = try XCTUnwrap(state.scenarioResult)
        XCTAssertEqual(text, "先写一句你想练的场景（比如「在咖啡店点一杯拿铁」）。")
    }

    /// 材料出题（#208）同一条约定：它也是 `.unknown` 的消费者。
    func testShortMaterialReachesTheNoticeVerbatim() async throws {
        let (state, directory) = try await makeState()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.materialDraft = "太短"

        await state.generateMaterialFromDraft()

        let text = try XCTUnwrap(state.materialResult, "材料不合格也要说一声")
        XCTAssertTrue(text.hasPrefix("材料太短"), "实际：\(text)")
        XCTAssertFalse(text.contains("未知"), "实际：\(text)")
    }

    // MARK: - 夹具

    /// 一套「模型根本没开机」的服务：这些用例全部在**校验阶段**就失败，
    /// 不该、也不会走到请求那一层（走了会抛 `AIProviderError.notInitialized`，
    /// 与断言的前缀不符，当场变红）。
    ///
    /// 所有落盘位置都指向临时目录：真实词汇本 / 情景目录一律不许碰。
    private func makeState() async throws -> (state: AppState, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-error-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let services = CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:",
            dictionaryStore: DictionaryBookStore(
                fileURL: directory.appendingPathComponent("dictionaries.json"),
                booksDirectory: directory.appendingPathComponent("books", isDirectory: true)
            ),
            customScenarioStore: CustomScenarioStore(
                directory: directory.appendingPathComponent("scenarios", isDirectory: true)
            )
        )
        let state = AppState(services: services)
        return (state, directory)
    }
}
