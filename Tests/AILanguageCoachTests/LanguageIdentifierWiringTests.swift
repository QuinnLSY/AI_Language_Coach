import AIDomain
import AIInfrastructure
import AppCore
import XCTest

/// 「学习语言」的标识接线哨兵（接缝 A）。
///
/// 报障形态：模型收到 `practise en-US`、语音服务收到 `en-US` 而不是 `English`、
/// 或者换语言后某一处忘了跟着改 —— 它们**都不报错、不崩溃**，只是措辞变生硬、
/// 识别悄悄变差，所以只能扫源码盯住「这几处到底用哪一个值」。
///
/// 两条线索：
/// 1. **提示词**要的是语言名（`English`），不是配置里的 BCP-47（`en-US`）；
/// 2. **语言名只许住在语言表里**（`LanguageOptions`），业务代码一律从 `LearningLanguage` 派生。
///
/// ⚠️ 被扫的字符串不能出现在源码注释里（注释里的同款字符串会让哨兵假绿）；
/// 反证必须**真删**，注释掉同样会被扫到 —— 因此扫描一律跳过注释行。
final class LanguageIdentifierWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 源码的**非注释行**（整行 `//` / `///` 去掉），行号保留（第 1 行 = index 0）。
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
            return (index + 1, line)
        }
    }

    private func assertAbsent(_ needle: String, in path: String, reason: String) throws {
        for line in codeLines(try source(path)) where line.text.contains(needle) {
            XCTFail("\(path):\(line.number) \(reason)")
        }
    }

    // MARK: - 喂进提示词的值必须是语言名，不是配置标识

    /// `CoachServices` 里所有喂提示词的调用点都必须走 `promptLanguage(...)`：
    /// 不能再把 `configuration.product.learningLanguage`（= `en-US`）直接灌进去。
    func testCoachServicesNeverFeedsRawConfigurationTagToPrompts() throws {
        try assertAbsent(
            "learningLanguage: configuration.product.learningLanguage",
            in: "AIServices/CoachServices.swift",
            reason: "配置里的 BCP-47 被直接灌进了提示词（应走 promptLanguage(configuration)）"
        )
        let coach = try source("AIServices/CoachServices.swift")
        XCTAssertTrue(coach.contains("learningLanguage: promptLanguage(configuration)"),
                      "CoachServices 应当用 promptLanguage(configuration) 喂提示词")
    }

    /// `ChatService` 同理：学员档案里的 `learningLanguage` 是 BCP-47，不能直接进提示词。
    func testChatServiceNeverFeedsRawProfileTagToPrompts() throws {
        try assertAbsent(
            "learningLanguage: profile.learningLanguage",
            in: "AIServices/ChatService.swift",
            reason: "档案里的 BCP-47 被直接灌进了提示词（应用 profile.language.serviceName）"
        )
        let chat = try source("AIServices/ChatService.swift")
        XCTAssertTrue(chat.contains("learningLanguage: profile.language.serviceName"),
                      "ChatService 应当用 profile.language.serviceName 喂提示词")
    }

    /// 考试示范答案那一处也是提示词：`AppState+ExamMode` 必须先把配置标签换算成语言名。
    func testExamModeDerivesServiceNameBeforePrompt() throws {
        let examMode = try source("AppUI/AppState+ExamMode.swift")
        XCTAssertTrue(examMode.contains("LearningLanguage(bcp47: product.learningLanguage).serviceName"),
                      "考试示范答案的语言参数应当是语言名，而不是 en-US")
    }

    // MARK: - 拼写纠正模板里的语言假设

    /// `spelling_fix.txt` 曾经把「听错的 English 单词」写死 —— 那是模板里唯一的语言假设。
    /// 模板不是 Swift 代码，编译器看不见，漏改不会报错，只能靠这里盯住。
    func testSpellingFixTemplateIsLanguageParameterised() throws {
        let template = try source("AIInfrastructure/Resources/Prompts/spelling_fix.txt")
        XCTAssertTrue(template.contains("{learning_language}"),
                      "拼写纠正模板必须用 {learning_language} 占位，而不是写死 English")
        XCTAssertFalse(template.contains("English"),
                       "拼写纠正模板里不该再出现写死的 English")
    }

    /// 占位符真的会被替换掉（不是留在提示词里当字面量给模型看）。
    func testSpellingFixPromptSubstitutesBothPlaceholders() {
        let prompt = PromptBuilder.spellingFixPrompt(sentence: "I have a apple", learningLanguage: "English")
        XCTAssertTrue(prompt.contains("English"), "语言占位符没被替换")
        XCTAssertTrue(prompt.contains("I have a apple"), "句子占位符没被替换")
        XCTAssertFalse(prompt.contains("{learning_language}"), "语言占位符残留在提示词里")
        XCTAssertFalse(prompt.contains("{sentence}"), "句子占位符残留在提示词里")
    }

    // MARK: - 语言名只许住在语言表里

    /// `"English"` 只允许出现在 `LanguageOptions`（它是语言清单的**显示名**）。
    /// 业务代码里写死语言名，加语言时漏改的那一处不会报错，只会静默用错语言。
    func testEnglishLiteralOnlyLivesInTheLanguageTable() throws {
        let allowed: Set<String> = ["AIDomain/LanguageOptions.swift"]
        var scanned = 0
        let enumerator = FileManager.default.enumerator(atPath: "Sources")
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            scanned += 1
            let text = try String(contentsOfFile: "Sources/\(relative)", encoding: .utf8)
            for line in codeLines(text) where line.text.contains("\"English\"") {
                XCTAssertTrue(allowed.contains(relative),
                              "Sources/\(relative):\(line.number) 出现了写死的 \"English\"：应从 LearningLanguage 派生")
            }
        }
        // 扫到 0 个文件说明路径写错了 —— 那这个哨兵就是假绿，比不写还危险。
        XCTAssertGreaterThan(scanned, 50, "没扫到源文件（当前 \(scanned) 个）：扫描路径不对，哨兵形同虚设")
    }
}
