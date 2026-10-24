import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

// MARK: - CoachServices · 考试模式（雅思口语 / 面试问答）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 考试模式（雅思口语 / 面试问答）

/// 内置考卷（只读资源文件，进程内读一次即可）。
public func examBlueprints() async -> [ExamBlueprint] {
    if let examCache { return examCache }
    let loaded = ExamCatalog.bundled()
    examCache = loaded
    return loaded
}

/// 考后示范答案：**一次请求**写完所有目标题目。
///
/// 与翻译 / 复盘同一套口径：模型没起来就直接返回空字典（调用方据此说明
/// 「这次没拿到」，而不是把空字符串当成示范答案显示出去）；
/// 返回的内容只认 `[[SAMPLE]]` 标记行，解析规则是纯函数（`ExamSampleAnswerRule.parse`）。
///
/// - Returns: 题号 → 示范答案。空字典 = 没拿到（不可用 / 回空 / 一行都没解析出来）。
public func examSampleAnswers(
    examTitle: String,
    targets: [ExamSampleTarget],
    learningLanguage: String,
    nativeLanguage: String
) async -> [Int: String] {
    guard !targets.isEmpty, isModelRunning(.llm) else { return [:] }
    do { try await ensureLLMReady() } catch { return [:] }
    let configuration = await config.current
    let provider = configuration.resolvedProvider(for: .llm)
    let request = LLMRequest(
        messages: [
            LLMMessage(
                role: .system,
                content: PromptBuilder.examSampleAnswerPrompt(
                    examTitle: examTitle,
                    targets: targets,
                    learningLanguage: learningLanguage,
                    nativeLanguage: nativeLanguage
                )
            ),
            LLMMessage(role: .user, content: "Write the model answers now."),
        ],
        model: configuration.resolvedModel(for: .llm),
        // 示范答案要一点文采，给 0.4：比翻译（0）松，比聊天（默认）紧，
        // 免得同一题两次跑出两套完全不同的句式结构。
        temperature: 0.4,
        maxTokens: provider?.maxTokens,
        streaming: false
    )
    guard let response = try? await llm.generate(request) else { return [:] }
    return ExamSampleAnswerRule.parse(response.text)
}
}
