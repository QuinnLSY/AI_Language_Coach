import AIDomain
import AIInfrastructure
import AIInterfaces
import Foundation

/// 写作批改（#230）。
///
/// 铁律：**一次写作 = 一次模型请求**。题目来自内置题库（`WritingTopicPicker`，
/// 零请求），批改这一发请求拿回全部分数 / 批改 / 改写 / 生词。
/// 三闸门与计费（`beginBillableCall`）都在 LLM 适配器内部，本服务不重复设卡。
public actor WritingService {

    private let llm: LLMManager

    public init(llm: LLMManager) {
        self.llm = llm
    }

    /// 批改一篇作文。任何失败返回 nil（UI 给可操作的提示，不抛错打扰写作心流）。
    public func review(
        topic: WritingTopic,
        essay: String,
        learningLanguage: String,
        nativeLanguage: String,
        model: String? = nil
    ) async -> WritingReview? {
        let trimmed = essay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return nil }
        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: PromptBuilder.writingReviewPrompt(
                        topic: topic.title,
                        essay: trimmed,
                        learningLanguage: learningLanguage,
                        nativeLanguage: nativeLanguage
                    )
                )
            ],
            model: model,
            temperature: 0.2,
            maxTokens: 1600,
            streaming: false,
            // 批改是结构化短任务：关思考（与释义 / 翻译同理由）。
            reasoningEffort: LLMRequest.noThinkingEffort
        )
        guard let response = try? await llm.generate(request) else { return nil }
        let review = WritingReviewRule.parse(response.text, original: trimmed)
        // 输出跑飞（一个字段都没解析出来）按失败处理，不给用户一张空卡。
        return review.isEmpty ? nil : review
    }
}
