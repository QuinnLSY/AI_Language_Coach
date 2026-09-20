import AIDomain
import AIInfrastructure
import AIInterfaces
import Foundation

/// 每日短文阅读（#231）。
///
/// 铁律：**一次阅读 = 一次模型请求**。文章主题走内置主题库（`ReadingThemeLibrary`
/// 按 `dayKey` 轮换，零请求）；文章 + 题目 + 答案 + 溯源句 + 解析 + 错因，
/// 一发请求全部拿回。判分是**本地纯函数**（`ReadingGrader`）—— 四选一的答案
/// 生成时已随文下发，没有「批改请求」这一环。
/// 三闸门与计费（`beginBillableCall`）都在 LLM 适配器内部，本服务不重复设卡。
public actor ReadingService {

    private let llm: LLMManager

    public init(llm: LLMManager) {
        self.llm = llm
    }

    /// 出一篇短文与配套题目。任何失败返回 nil（UI 给可操作的提示）。
    ///
    /// - Parameter level: CEFR 档位名（如 "B1"）；空串时模板里兜底写 A2-B1。
    public func generate(
        theme: String,
        level: String,
        learningLanguage: String,
        nativeLanguage: String,
        model: String? = nil
    ) async -> ReadingPassage? {
        let dayKey = WritingTopicPicker.dayKey(for: Date())
        let levelText = level.isEmpty ? "A2-B1 (intermediate learner)" : level
        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: PromptBuilder.readingGenerationPrompt(
                        theme: theme,
                        level: levelText,
                        learningLanguage: learningLanguage,
                        nativeLanguage: nativeLanguage
                    )
                )
            ],
            model: model,
            temperature: 0.7,
            maxTokens: 2400,
            streaming: false,
            // 出题是结构化短任务：关思考（与批改 / 释义同理由）。
            reasoningEffort: LLMRequest.noThinkingEffort
        )
        guard let response = try? await llm.generate(request) else { return nil }
        let passage = ReadingReviewRule.parse(response.text, dayKey: dayKey)
        // 输出跑飞（没文章或一道凑齐的题都没有）按失败处理，不给用户一张空卡。
        return passage.isEmpty ? nil : passage
    }
}
