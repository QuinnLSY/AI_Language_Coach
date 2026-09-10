import AIDomain
import AppCore
import Foundation

/// Prompt 隔离：长 Prompt 只放在 `Resources/Prompts/`，禁止出现在 View / 传输层 / Adapter 里。
public enum PromptBuilder {

    public static func teacherSystemPrompt(
        learningLanguage: String,
        nativeLanguage: String,
        proficiency: String,
        practiceMode: PracticeMode
    ) -> String {
        guard let url = AppResourceBundle.module.url(forResource: "Prompts/teacher_system", withExtension: "txt"),
              let template = try? String(contentsOf: url, encoding: .utf8)
        else {
            return fallbackSystemPrompt(learningLanguage: learningLanguage)
        }
        return template
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
            .replacingOccurrences(of: "{proficiency}", with: proficiency)
            .replacingOccurrences(of: "{practice_mode}", with: practiceMode.displayName)
    }

    /// 练习复盘：把一次练习的流水 + 老师批注交给模型，产出结构化总结（JSON）。
    public static func sessionReviewPrompt(
        learningLanguage: String,
        nativeLanguage: String,
        proficiency: String
    ) -> String {
        guard let url = AppResourceBundle.module.url(forResource: "Prompts/session_review", withExtension: "txt"),
              let template = try? String(contentsOf: url, encoding: .utf8)
        else {
            return """
            Summarise the learner's practice session as one JSON object with keys:
            headline, new_words, strengths, improvements, suggestion. Respond in \(nativeLanguage).
            """
        }
        return template
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
            .replacingOccurrences(of: "{proficiency}", with: proficiency)
    }

    /// 情景对话：把场景结构化配置转成给老师的角色扮演指令。
    ///
    /// 模板走 `Resources/Prompts/scenario.txt`（版本化，Prompt 不写在 Service / UI 里）；
    /// 模板缺失时用等价的英文内联兜底，保证场景仍可玩。
    public static func scenarioBlock(
        scenario: Scenario,
        turnsRemaining: Int,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        let vocabulary = scenario.targetVocabulary.isEmpty ? "(none in particular)" : scenario.targetVocabulary.joined(separator: ", ")
        let grammar = scenario.targetGrammar.isEmpty ? "(none in particular)" : scenario.targetGrammar.joined(separator: ", ")
        // 只剩最后一轮时明确收尾，避免模型无限拖戏。
        let remainingNote = turnsRemaining <= 1
            ? "This is the final turn of the scene."
            : "There are \(turnsRemaining) learner turns left in this scene."
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/scenario", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            Role play scenario
            - Scenario: {scenario_title}
            - You are playing: {ai_role}
            - The learner is playing: {learner_role}
            - Goal of the scene: {objective}
            - Correction style: {correction_mode}
            3. {remaining_note}
            Stay in character and keep replies to 2-3 short sentences.
            """
        }
        return template
            .replacingOccurrences(of: "{scenario_title}", with: scenario.title)
            .replacingOccurrences(of: "{ai_role}", with: scenario.aiRole)
            .replacingOccurrences(of: "{learner_role}", with: scenario.learnerRole)
            .replacingOccurrences(of: "{objective}", with: scenario.objective)
            .replacingOccurrences(of: "{level}", with: scenario.level)
            .replacingOccurrences(of: "{target_vocabulary}", with: vocabulary)
            .replacingOccurrences(of: "{target_grammar}", with: grammar)
            .replacingOccurrences(of: "{correction_mode}", with: scenario.correctionMode.instruction)
            .replacingOccurrences(of: "{remaining_note}", with: remainingNote)
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
    }

    private static func fallbackSystemPrompt(learningLanguage: String) -> String {
        "You are a friendly \(learningLanguage) conversation coach. Keep replies short and encouraging."
    }

    /// 语音输入专用的拼写纠正提示词（**只用于语音，不用于手打**）。
    /// 模板走 `Resources/Prompts/spelling_fix.txt`，缺失时用等价内联兜底。
    public static func spellingFixPrompt(sentence: String) -> String {
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/spelling_fix", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            Fix only the spelling mistakes in the sentence below. Keep every other word, \
            the word order and the punctuation exactly the same. Reply with the corrected \
            sentence only, with no quotes and no explanation.

            Sentence:
            {sentence}
            """
        }
        return template.replacingOccurrences(of: "{sentence}", with: sentence)
    }

    /// 打开应用时老师的开场白（**老师先开口**，避免学员抢在服务就绪前发第一句）。
    /// 模板走 `Resources/Prompts/greeting.txt`，缺失时用等价内联兜底。
    public static func greetingPrompt(learningLanguage: String, nativeLanguage: String) -> String {
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/greeting", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            Open this practice session: greet the learner in {learning_language} in one or two \
            short sentences and invite them to say something. No translations, no notes.
            """
        }
        return template
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
    }

    /// 气泡翻译（点开才调用）。模板走 `Resources/Prompts/translate.txt`，缺失时用等价内联兜底。
    public static func translationPrompt(text: String, targetLanguage: String) -> String {
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/translate", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            Translate the text below into {target_language}. Reply with the translation only.

            Text:
            {text}
            """
        }
        return template
            .replacingOccurrences(of: "{target_language}", with: targetLanguage)
            .replacingOccurrences(of: "{text}", with: text)
    }
}
