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

    /// 跨会话学习记忆（第 15 步）：把 `LearningMemory` 折成给老师的一小段背景。
    ///
    /// **没有内容时返回空串** —— 调用方据此不追加任何东西，新学员看到的就是干净的老师人设。
    /// 模板走 `Resources/Prompts/learning_memory.txt`，缺失时用等价内联兜底。
    public static func learningMemoryBlock(
        _ memory: LearningMemory,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        guard !memory.isEmpty else { return "" }
        let items = memoryItems(memory)
        guard !items.isEmpty else { return "" }
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/learning_memory", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            Learner memory from earlier sessions — use it lightly, never recite it:
            {memory_items}
            - Stay in {learning_language}; use {native_language} only when the learner is stuck.
            """
        }
        return template
            .replacingOccurrences(of: "{memory_items}", with: items.joined(separator: "\n"))
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
    }

    /// 记忆条目的人类可读行：**只渲染有内容的段落**（空段落连标题都不出现，
    /// 否则老师会读到「Recurring mistakes:」这种空标题而去编内容）。
    static func memoryItems(_ memory: LearningMemory) -> [String] {
        var lines: [String] = []
        if !memory.recurringErrors.isEmpty {
            let text = memory.recurringErrors.prefix(5).map { error -> String in
                let times = error.count > 1 ? " (x\(error.count))" : ""
                let note = error.explanation.isEmpty ? "" : " — \(error.explanation)"
                return "\"\(error.original)\" -> \"\(error.corrected)\"\(times)\(note)"
            }.joined(separator: "; ")
            lines.append("- Recurring mistakes: \(text)")
        }
        if !memory.focusWords.isEmpty {
            lines.append("- Words worth reusing: \(memory.focusWords.joined(separator: ", "))")
        }
        if !memory.weakDimensions.isEmpty {
            let text = memory.weakDimensions
                .map { "\($0.displayName) (\(Int($0.averageScore.rounded()))/100)" }
                .joined(separator: ", ")
            lines.append("- Pronunciation to work on: \(text)")
        }
        return lines
    }

    /// 本轮教学计划（Agent 层，第 7–10 步的**渲染目标**）。
    ///
    /// 这里正是计划 Phase 10 想要的那条边界：教学逻辑住在 `TeacherAgent` /
    /// `GrammarAgent` / `ConversationAgent` / `ResponsePlanner`（纯函数、可断言），
    /// 本函数只负责把结论措辞成一段静默指令 —— prompt 不再是业务逻辑的唯一所在地。
    ///
    /// **没有可讲的东西时返回空串**（`ResponsePlan.isWorthInstructing`）：
    /// 每轮都塞一段空指令既白占上下文，也可能让模型误以为「必须找出个错」才算完成任务。
    public static func responsePlanBlock(
        _ plan: ResponsePlan,
        decision: TeacherDecision,
        direction: ConversationDirection,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        guard plan.isWorthInstructing || !decision.learningFocus.isEmpty else { return "" }
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/response_plan", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            Teaching plan for this turn. Follow it quietly — never mention that a plan exists.
            - Response mode: {response_mode}
            - Correction intensity: {correction_level}
            {correction_line}
            {question_line}
            """
        }

        let correctionLine: String
        if plan.correction.show, let focus = plan.focusError {
            let style = plan.correction.style == .brief ? "brief" : "detailed"
            correctionLine = "- Correction (\(style), at most \(plan.correction.maxItems)): "
                + "\"\(focus.original)\" -> \"\(focus.corrected)\" (\(focus.category.rawValue))"
        } else {
            correctionLine = "- No correction is needed this turn."
        }
        let explanationLine = plan.explanation.show
            ? "- Explanation: \(plan.explanation.length == .full ? "say why, in one or two sentences" : "add one very short note on why")"
            : ""
        let focusLine = decision.learningFocus.isEmpty
            ? ""
            : "- Learning focus: " + decision.learningFocus.joined(separator: ", ")
        let vocabularyLine = plan.targetVocabulary.isEmpty
            ? ""
            : "- Try to naturally reuse: " + plan.targetVocabulary.joined(separator: ", ")
        let questionLine = plan.nextQuestion
            ? "- End with a question that invites the learner to say a little more."
            : "- Do not ask a new question; let the turn land."
        let engagementLine = direction.engagementCue.map { "- \($0)" } ?? ""

        let filled = template
            .replacingOccurrences(of: "{response_mode}", with: decision.responseMode.instruction)
            .replacingOccurrences(of: "{intent}", with: plan.intent.rawValue)
            .replacingOccurrences(of: "{correction_level}", with: decision.correctionLevel.instruction)
            .replacingOccurrences(of: "{direction_line}", with: "- Conversation move: " + direction.move.instruction)
            .replacingOccurrences(of: "{correction_line}", with: correctionLine)
            .replacingOccurrences(of: "{explanation_line}", with: explanationLine)
            .replacingOccurrences(of: "{focus_line}", with: focusLine)
            .replacingOccurrences(of: "{vocabulary_line}", with: vocabularyLine)
            .replacingOccurrences(of: "{question_line}", with: questionLine)
            .replacingOccurrences(of: "{engagement_line}", with: engagementLine)
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)

        // 空占位符会留下一串空行，压掉（模板本身没有需要保留的空行）。
        return filled
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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

    /// 词条补全：模型把「重点单词 / 近义词 / 反义词」写成光秃秃的英文（实测
    /// `precipitation, rainfall, drizzle, drought`），定向补一次词性 + 中文。
    /// 模板走 `Resources/Prompts/vocabulary_terms.txt`，缺失时用等价内联兜底。
    public static func vocabularyTermsPrompt(
        words: [String],
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        vocabularyPrompt(
            resource: "Prompts/vocabulary_terms",
            word: words.joined(separator: ", "),
            learningLanguage: learningLanguage,
            nativeLanguage: nativeLanguage,
            fallback: """
            You complete vocabulary notes for a Chinese-speaking learner of {learning_language}.

            Below is a list of {learning_language} words that a language model wrote down without \
            their part of speech or their {native_language} translation. Fill in those two missing pieces.

            Reply with ONE line per word, in EXACTLY this format, and nothing else:

            word||pos||{native_language} translation

            - "||" is the ONLY separator: exactly two "||" per line, and NEVER inside a field.
            - pos: abbreviated part of speech, e.g. n. / v. / adj. / adv. / phr.
            - The third field MUST be {native_language} (Chinese), senses separated by "；".
            - Keep the SAME spelling and order as the input words.
            - Never leave a field empty and never repeat the field names as content.
            - No numbering, no bullets, no quotes, no commentary.

            Words:
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

    // MARK: - 附件说明（第 3 项需求：聊天支持图片 / 视频 / 文件）

    /// 告诉模型「学员还附了这些文件，但你看不到内容」。
    ///
    /// 为什么必须补这一句，而不是让附件静默消失：
    /// 界面上明明白白躺着一个附件，模型却完全不知道它存在，这不是「降级」，是**信息错位**——
    /// 学员问「这张图里的句子对不对」，老师的回答会变成凭空发挥。
    /// 说清楚「我看不到」，老师才会诚实追问，而不是编。
    ///
    /// 空数组返回空串（调用方据此不加任何东西）。
    public static func attachmentNoteBlock(fileNames: [String]) -> String {
        let names = fileNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return "" }
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/attachment_note", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            The learner also attached file(s) that this model cannot read directly: {file_names}. \
            Do not claim to have seen their contents.
            """
        }
        return template
            .replacingOccurrences(of: "{file_names}", with: names.joined(separator: ", "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
