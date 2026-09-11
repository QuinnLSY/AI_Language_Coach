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

    /// 词汇本按需释义（第 24 步）：给生词配「音标 / 词性 / 中文义项 / 解释 / 例句及翻译 / 近反义 / 重点单词」。
    /// 模板走 `Resources/Prompts/vocabulary_define.txt`，缺失时用等价内联兜底。
    public static func vocabularyDefinePrompt(word: String, learningLanguage: String, nativeLanguage: String) -> String {
        vocabularyPrompt(
            resource: "Prompts/vocabulary_define",
            word: word,
            learningLanguage: learningLanguage,
            nativeLanguage: nativeLanguage,
            fallback: vocabularyPromptFallback(
                role: "You are building a vocabulary notebook for a Chinese-speaking learner of {learning_language}.",
                entryLabel: "Word or expression:",
                exampleStyle: "ONE natural sentence"
            )
        )
    }

    /// 每日推荐释义：与词汇本**同一套字段**（音标 / 词性 / 中文义项 / 解释 / 例句及翻译 / 近反义 / 重点单词），
    /// 只有例句偏雅思书面风格。
    /// 模板走 `Resources/Prompts/vocabulary_daily.txt`，缺失时用等价内联兜底。
    public static func vocabularyDailyPrompt(word: String, learningLanguage: String, nativeLanguage: String) -> String {
        vocabularyPrompt(
            resource: "Prompts/vocabulary_daily",
            word: word,
            learningLanguage: learningLanguage,
            nativeLanguage: nativeLanguage,
            fallback: vocabularyPromptFallback(
                role: "You are a vocabulary coach for a Chinese-speaking learner of {learning_language} (IELTS level).",
                entryLabel: "Word or phrase:",
                exampleStyle: "ONE natural IELTS-style sentence"
            )
        )
    }

    /// 音标兜底：模型偶尔漏音标、或只回一个「/」（实测出现过）。
    /// 这时定向补一次极短的请求，只问 IPA；模板走 `Resources/Prompts/vocabulary_phonetic.txt`。
    public static func vocabularyPhoneticPrompt(word: String, learningLanguage: String) -> String {
        vocabularyPrompt(
            resource: "Prompts/vocabulary_phonetic",
            word: word,
            learningLanguage: learningLanguage,
            nativeLanguage: "Chinese",
            fallback: """
            You give the IPA transcription of a single {learning_language} word.

            Reply with ONLY the transcription between slashes — nothing else, no key name, no explanation.

            - Use British or American IPA with stress marks, e.g. /səbˈstænʃl/.
            - Never write a bare "/" and never leave it empty: if unsure, still give your best transcription.

            Word:
            {word}
            """
        )
    }

    /// 词汇释义提示词的公共装配（两个入口只差角色描述与例句风格）。
    private static func vocabularyPrompt(
        resource: String,
        word: String,
        learningLanguage: String,
        nativeLanguage: String,
        fallback: String
    ) -> String {
        let template: String
        if let url = AppResourceBundle.module.url(forResource: resource, withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = fallback
        }
        return template
            .replacingOccurrences(of: "{word}", with: word)
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
    }

    /// 资源文件缺失时的等价兜底模板（字段与资源模板一字不差）。
    private static func vocabularyPromptFallback(role: String, entryLabel: String, exampleStyle: String) -> String {
        """
        \(role)

        For the entry below, reply with EXACTLY these nine lines and nothing else:

        phonetic: <IPA>
        pos: <part of speech>
        meaning: <Chinese senses>
        explanation: <Chinese explanation>
        example: <one sentence>
        translation: <Chinese translation of the example>
        synonyms: <synonyms>
        antonyms: <antonyms>
        keywords: <key words, or ->

        Rules for each line:
        - The words phonetic / pos / meaning / explanation / example / translation / synonyms / antonyms / keywords are only KEYS. Put the key and a colon at the start of its line, then the real content. NEVER write a bare key name as content.
        - phonetic: the IPA between slashes, e.g. /səbˈstænʃl/. Write this ONLY when the entry is a SINGLE word; if the entry is a phrase, write -. For a single word the IPA is REQUIRED: give the full transcription, never leave it empty and never write a bare "/".
        - pos: abbreviated part of speech (n. / v. / adj. / adv. / phr.). Join several with "/", e.g. n./v.
        - meaning: the {native_language} (Chinese) translation(s). List EVERY common sense, separated by "；".
        - explanation: 1-2 {native_language} sentences about usage or collocations. It goes on ITS OWN line; never paste it into the meaning line.
        - example: \(exampleStyle) in {learning_language} that clearly uses the entry.
        - translation: the {native_language} translation of that example sentence.
        - synonyms / antonyms: 1-2 {learning_language} words each, separated by "、"; write - when there is none.
        - keywords: for a multi-word entry, 2-4 key words as "word (part-of-speech) Chinese translation", separated by "；"; for a single word write -.
        - No numbering, no quotes, no extra lines, no commentary.

        Here is a worked example of a CORRECT reply (for the word "substantial"):

        phonetic: /səbˈstænʃl/
        pos: adj.
        meaning: 大量的；实质性的；重要的
        explanation: 强调数量或程度超出一般，多用于正式书面语境，如 substantial progress / a substantial amount。
        example: The government made substantial changes to the education policy.
        translation: 政府对教育政策做出了重大调整。
        synonyms: considerable、significant
        antonyms: slight、minor
        keywords: -

        \(entryLabel)
        {word}
        """
    }
}
