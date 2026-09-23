import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 报错文案的三条契约。
///
/// 1. **`AppError` 六档一律原样透出消息，谁也不加品类前缀。**
///    曾经是「前五档加、`.unknown` 不加」，于是同一句话能长到三个冒号：
///    `保存音色失败：存储错误：保存音色档案失败：文件 “x” 无法写入。`
///    ——UI 的 catch 补一句动作名，前缀再补一句品类，而动作名抛出点早写过了；
/// 2. **动作名由「知道自己在干什么」的那一层写，且只写一次。** 抛出点最清楚，
///    所以 UI 的 catch 默认只做透出；底层是系统框架 / Provider 抛的（消息里没有动作、
///    甚至是英文），才由那一层的调用者补**唯一一层**动词。
/// 3. **`AppError` 的分类没有丢** —— 它留在这几个 `case` 上，日志、诊断、测试照样能分辨。
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

    // MARK: - ② 六档一视同仁：不加品类前缀

    /// **逐档**比对「消息 → 文案」是恒等变换。
    ///
    /// 用逐档（而不是一句 `contains`）是因为这里要钉的是**全部六档行为一致**这个事实：
    /// 谁给某一档单独加回「配置错误：」，对应那一行立刻变红，而且红在他自己那一档上。
    func testNoTierPrependsACategoryLabel() {
        let cases: [(AppError, String)] = [
            (.configuration("还没有可用的语言模型，先在设置里启用一个。"), "还没有可用的语言模型，先在设置里启用一个。"),
            (.permission("无权访问麦克风"), "无权访问麦克风"),
            (.storage("保存音色档案失败：磁盘已满"), "保存音色档案失败：磁盘已满"),
            (.audio("没有可用的麦克风输入设备"), "没有可用的麦克风输入设备"),
            (.database("SQL 执行失败：no such table"), "SQL 执行失败：no such table"),
            (.unknown("模型没有给出可解析的词条，可以再点一次试试"), "模型没有给出可解析的词条，可以再点一次试试"),
        ]
        for (error, message) in cases {
            XCTAssertEqual(error.localizedDescription, message, "\(error) 这一档被加工过")
        }
    }

    /// 病根那条：**消息自己已经交代了动作**时，不许再被罩一层。
    ///
    /// 这是「存储 / 保存」说两遍的原始现场。断言里特意带上「成功时不会出现的前缀词」——
    /// 单看字符串相等也能测出问题，但把「存储错误」三个字点名写出来，
    /// 失败信息本身就能告诉后来者：加回来的是这一层。
    func testAMessageThatAlreadyNamesItsActionIsNotAnnotated() {
        let text = AppError.storage("保存音色档案失败：文件 “x” 无法写入。").localizedDescription
        XCTAssertEqual(text, "保存音色档案失败：文件 “x” 无法写入。")
        XCTAssertFalse(text.contains("存储错误"), "「存储」与「保存」是同一件事说两遍：\(text)")
        XCTAssertEqual(text.filter { $0 == "：" }.count, 1, "一句话只该有一个冒号：\(text)")
    }
}

// MARK: - ③ 真链路：这句话真的能原样走到用户眼前吗

/// 走**用户真正走的那条路**（`AppState` → `CoachServices`），确认底层那句话
/// 落到提示条上时没有被任何一层再加工。
///
/// 只测纯函数是不够的：`AppState` 的各个 `catch` 一旦有人改成自己拼一句前缀，
/// 纯函数测试照样全绿 —— 下面这几条分别盯着四条不同的链路。
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

    /// 导入一本读不出词条的词典：提示条上是**存储层那句话本身**。
    ///
    /// 修之前是「导入失败：存储错误：这个文件里没有读到任何词条。…」——
    /// 用户点的是「导入」，看到的是「存储」，中间还夹一层品类。
    func testDictionaryImportFailureIsNotWrappedAgain() async throws {
        let (state, directory) = try await makeState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-dictionary.json")
        try Data("这不是 JSON 数组".utf8).write(to: file)

        await state.importDictionary(from: file)

        let notice = try XCTUnwrap(state.dictionaryNotice, "导入失败必须说一声")
        XCTAssertEqual(
            notice.text,
            "这个文件里没有读到任何词条。词典是 JSON 数组，每条至少要有 word 字段。",
            "底层那句话就是文案，不该再加工"
        )
        XCTAssertFalse(notice.text.contains("导入失败"), "重复说一遍「导入」：\(notice.text)")
    }

    /// 参考音频读不进来：「没能把这个音频文件读进来（x.wav）：…」——
    /// **动作只在 service 层写一次**。
    ///
    /// 这条盯的是那个反例：`importVoiceReference` 原来抛系统原文（英文、不说在干什么），
    /// 于是 UI 只能补一句「保存音色失败：」；而走 `saveVoiceProfile` 那一路时
    /// 底层又写着「保存音色档案失败：」——两条路并成一句就是三个冒号。
    /// 现在动作下沉到 service，UI 一律透出，**两条路各自只有一层**。
    func testVoiceReferenceFailureNamesTheActionOnce() async throws {
        let (state, directory) = try await makeState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("no-such-voice.wav")

        let profile = await state.createClonedVoice(
            name: "我的声音",
            referenceURL: missing,
            consentStatement: "本人声音"
        )

        XCTAssertNil(profile, "音频都没读进来，不该留下档案")
        let text = try XCTUnwrap(state.voiceProfileNotice, "失败必须说一声")
        XCTAssertTrue(text.hasPrefix("没能把这个音频文件读进来（no-such-voice.wav）"), "实际：\(text)")
        XCTAssertFalse(text.contains("保存音色失败"), "动作名在两层各写一遍：\(text)")
        XCTAssertFalse(text.contains("存储错误"), "品类前缀也回来了：\(text)")
    }

    // MARK: - 夹具

    /// 一套「模型根本没开机」的服务：这些用例全部在**校验阶段**就失败，
    /// 不该、也不会走到请求那一层（走了会抛 `AIProviderError.notInitialized`，
    /// 与断言的前缀不符，当场变红）。
    ///
    /// 所有落盘位置都指向临时目录：真实词汇本 / 情景目录 / 音色目录一律不许碰。
    /// 音色那一条尤其要盯住 —— `VoiceProfileStore.referenceAudioDirectory` 是从
    /// 注入的 `fileURL` 派生的，正是为了让这里注入的临时路径**连音频目录一起隔离**。
    private func makeState() async throws -> (state: AppState, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-error-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let services = CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:",
            voiceProfileStore: VoiceProfileStore(
                fileURL: directory.appendingPathComponent("voice-profiles.json")
            ),
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
