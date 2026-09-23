import AIDomain
import Foundation

/// 一句话生成情景的 Prompt 组装（一句话 → 一个可练的情景 + 自带题目）。
///
/// ⚠️ 模板 `scenario_draft.txt` 与解析器 `ScenarioDraftRule.parse` 是**一对**：
/// 改任何一方的键名 / 字段顺序，另一方必须同步改（两边都有测试钉着）。
///
/// 与 `material_kit.txt` 的分工：那个是「把一篇文章拆成三样东西」（有原文可依），
/// 这个是「从零生成一个情景」（无原文，靠模型按描述创作）——
/// 所以后者要求模型自己判难度、自己写目标句，且**必须自带题目**（否则练完没法核对）。
extension PromptBuilder {

    /// 情景生成请求体：一次请求产出一个情景（开场白 / 目标句 / 目标词 / 主线任务）。
    ///
    /// 「一次操作 = 一个模型请求」在这里的落点：生成是一个整体动作 ——
    /// 开场白与目标句必须彼此贴合，拆成两次请求只会让用户等两趟、还更容易前后不一致。
    public static func scenarioDraftPrompt(
        prompt: String,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/scenario_draft", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            A language learner wants to practise one specific situation. \
            Turn the description into a role-play scenario.
            Output key-value lines only:
            title: <title in {learning_language}> | <title in {native_language}>
            scene: <AI role> | <learner role> | <objective> | <difficulty 1-5> | <opening line>
            sentence: <a sentence the learner would really say>
            vocabulary: <word> | <part of speech> | <meaning> | <example sentence>
            quest: <one-line goal of the session>
            Rules: at least {min_sentences} and at most {max_sentences} sentence lines; \
            vocabulary at most {max_words} entries; no markdown, no numbering.
            The situation:
            {prompt}
            """
        }
        return template
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
            .replacingOccurrences(of: "{min_sentences}", with: "\(ScenarioDraftRule.minimumTargetSentences)")
            .replacingOccurrences(of: "{max_sentences}", with: "\(ScenarioDraftRule.maximumTargetSentences)")
            .replacingOccurrences(of: "{max_words}", with: "\(ScenarioDraftRule.maximumTargetVocabulary)")
            .replacingOccurrences(of: "{prompt}", with: prompt)
    }
}
