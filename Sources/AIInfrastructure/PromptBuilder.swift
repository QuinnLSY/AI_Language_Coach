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

    /// 老师人格档位（教学风格）：紧跟人设、排在长期记忆之前。
    ///
    /// ⚠️ **标准档返回空串**，调用方据此不追加任何东西 —— 于是默认配置下这一段 Prompt
    /// 与加档位之前**逐字相同**，不会悄悄改变既有用户的老师行为。
    ///
    /// ⚠️ 模板里那句「Where this style differs from the defaults above, follow this style」
    /// 不是客套：`teacher_system.txt` 明确写着「Be encouraging」「Keep every reply short:
    /// 2 to 4 sentences」，而严格档要讲得更细 —— 不声明优先级，模型会照基础人设走，
    /// 档位就形同虚设。
    public static func teacherPersonaBlock(
        _ persona: TeacherPersona,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        guard persona != .standard else { return "" }
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/teacher_persona", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            The learner has chosen a teaching style: {persona_name}.
            {persona_instruction}
            {language_line}
            Where this style differs from the defaults described above, follow this style instead.
            """
        }
        // 母语兜底：`TeacherPreference.allowsNativeLanguageHints == false`（严格档）
        // 才收紧。**给出替代动作**（简化而不是翻译）——只说「不许讲母语」，
        // 学员卡住时老师就只剩「继续用英语重复一遍」这一条路。
        //
        // ⚠️ 基础人设（`teacher_system.txt`）现在已经是硬规则：所有档位都只用
        // `{learning_language}` 回话（用户口径）。这一行只对严格档**再加一句替代动作**，
        // 供它真的踩到「学员卡住」时按；非严格档不加 —— 加了反而与基础人设重复。
        let languageLine = persona.allowsNativeLanguageHints
            ? ""
            : "Stay in \(learningLanguage) even when the learner is stuck: "
                + "say it more simply instead of switching to \(nativeLanguage)."
        let filled = template
            .replacingOccurrences(of: "{persona_name}", with: persona.promptLabel)
            .replacingOccurrences(of: "{persona_instruction}", with: persona.instruction)
            .replacingOccurrences(of: "{language_line}", with: languageLine)
        // 空占位符会留下一串空行，压掉（同 `responsePlanBlock`）。
        return filled
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
            // ⚠️ 兜底必须与 `learning_memory.txt` 口径一致（尤其「(x2) 以上要主动给机会」
            // 那条）：模板文件万一取不到，老师拿到的指令不能因此少一条，
            // 否则同一份记忆在不同机器上教出两种强度。
            template = """
            Learner memory from earlier sessions — use it lightly, never recite it:
            {memory_items}
            - Mistakes marked (x2) or more: when the conversation naturally allows it, steer toward \
            a question the learner would have to answer using that form, and let them try before \
            you correct. At most once per reply, and never announce it.
            - Reply in {learning_language} only, even if the learner writes in {native_language}.
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
        if !memory.recentTopics.isEmpty {
            lines.append("- Recently practised: \(memory.recentTopics.joined(separator: ", "))")
        }
        if let trend = Self.trendLine(memory.practiceTrend) {
            lines.append(trend)
        }
        return lines
    }

    /// 练习趋势的一句话。样本不足（`.unknown`）返回 nil ——
    /// 老师不该拿到「趋势：未知」这种空话，那只会诱导它去编一个趋势。
    static func trendLine(_ trend: PracticeTrend) -> String? {
        switch trend.direction {
        case .unknown:
            return nil
        case .improving:
            return "- Recent trend: fewer corrections per turn than earlier — keep the current level."
        case .slipping:
            return "- Recent trend: more corrections per turn than earlier — slow down and simplify a little."
        case .steady:
            return "- Recent trend: correction rate is about the same as earlier."
        }
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
            // ⚠️ 这句话说的是「**不要把已知的那个错再讲一遍**」，不是「这轮不用纠错」。
            // 写死成「No correction is needed this turn」时，模型会把**新出现的**错误也放过 ——
            // 于是 `[[FIX]]` 行一个字都不出，错题卡就断了（这条是实测踩出来的）。
            correctionLine = "- No repeat mistake to drill this turn: things you already corrected "
                + "do not need another explanation. Still watch for a NEW mistake from the learner "
                + "(grammar, word choice, spelling, word form) and record it with the [[FIX]] line when there is one."
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

    // MARK: - 主线任务 / 前情提要 / 随口练（需求 3–6）

    /// 主线任务块：告诉老师「这一关要推进哪几步、现在该做什么、重点是什么」。
    ///
    /// 与 `scenarioBlock`（角色扮演的人设与口吻）职责分开：
    /// 那边管「你演谁」，这边管「你要把学员带到哪」——两块都注入，缺一个老师就会跑偏。
    public static func taskBlock(briefing: ScenarioBriefing) -> String {
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/task_briefing", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            Current task — you are leading this, do not drift
            {facts}

            How to lead this task
            1. You are the guide. Name what to do right now, then stay in character.
            2. Push toward the next unfinished step. One step at a time.
            3. Never say the task is finished until every step is done.
            {review_note}
            """
        }
        return template
            .replacingOccurrences(of: "{facts}", with: briefing.factsBlock)
            .replacingOccurrences(of: "{review_note}", with: reviewNote(briefing: briefing))
    }

    /// 要求模型**只输出老师这一句开场白**的提示词（需求 6：老师引导开场）。
    public static func taskOpenerPrompt(briefing: ScenarioBriefing) -> String {
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/task_opener", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            The learner has just arrived to practise. Write ONLY the single message you say right now.
            {facts}
            Cover two things: where you left off, and the one thing to do right now.
            """
        }
        return template
            .replacingOccurrences(of: "{facts}", with: briefing.factsBlock)
    }

    /// 随口练块（需求 4：学生主导，老师少引导、多建议与纠错）。
    public static func freeTalkBlock(review: SessionReview?) -> String {
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/free_talk", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            Free talk practice — the learner leads, you follow
            - No fixed task. Follow their topic.
            - At most one short follow-up question per turn.
            {review_note}
            """
        }
        return template.replacingOccurrences(of: "{review_note}", with: reviewNote(review: review))
    }

    /// 随口练的开场白提示词：老师只是把话头递出去，不替学员定题目。
    public static func freeTalkOpenerPrompt(review: SessionReview?) -> String {
        var lines = [
            "The learner has just started a free-talk practice. Write ONLY the single message you say right now.",
            "- 1 to 2 short sentences.",
            "- Greet them and invite them to pick any topic they like.",
            "- Do not ask a long list of questions, and do not pick a topic for them.",
        ]
        if let headline = review?.headline, !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("- If it fits naturally, you may nod to last time: \(headline)")
        }
        lines.append("Output the message only. No quotes, no labels.")
        return lines.joined(separator: "\n")
    }

    /// 「上次练完留下了什么」的一句提醒；没有历史时返回空串（空标题会诱导模型编内容）。
    private static func reviewNote(briefing: ScenarioBriefing) -> String {
        var rows: [String] = []
        if let headline = briefing.lastReviewHeadline, !headline.isEmpty {
            rows.append("Last time: \(headline)")
        }
        if let first = briefing.lastReviewImprovements.first, !first.isEmpty {
            rows.append("Keep an eye on: \(first)")
        }
        guard !rows.isEmpty else { return "" }
        return "\nWhat you remember from last time\n" + rows.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func reviewNote(review: SessionReview?) -> String {
        guard let review else { return "" }
        var rows: [String] = []
        let headline = review.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !headline.isEmpty { rows.append("Last time: \(headline)") }
        if let first = review.improvements.first, !first.isEmpty { rows.append("Keep an eye on: \(first)") }
        guard !rows.isEmpty else { return "" }
        return "\nWhat you remember from last time\n" + rows.map { "- \($0)" }.joined(separator: "\n")
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

    /// 老师回复跑出母语时的**重说指令**（用户口径：老师必须只能用学习语言回话）。
    ///
    /// 只在真的判出正文里有中文时才发，因此不占常规路径的任何开销。
    /// 措辞要点：① 只重说、不改教学内容；② 连引号里的中文也要去掉；
    /// ③ 只输出重说后的回复本身（否则会把「好的，我重说如下：」也带进正文）。
    ///
    /// ⚠️ **原文必须由提示词自带**，不能只说「把你上一条重说一遍」：
    /// 实测弱模型（agnes-3.0-flash）遇到这种指代，会把**上一条之前**的那句英文照抄回来 ——
    /// 用户看到的就是老师答非所问地复读开场白。调用处（`ChatService`）相应地
    /// **不拼对话历史**，模型就没有可抄错的东西。
    public static func englishOnlyRewritePrompt(learningLanguage: String, text: String) -> String {
        """
        Rewrite the reply below using \(learningLanguage) only. Keep the meaning, the warmth \
        and the length, keep any \(learningLanguage) word it was teaching, and remove every \
        non-\(learningLanguage) character — including words inside quotation marks. \
        Do not answer anyone, do not add anything new, do not mention that you are rewriting. \
        Output the rewritten reply only — keep the [[FIX]] line if there is one.

        Reply to rewrite:
        \(text)
        """
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

    /// 词典查词：一次要回「音标 / 义项 / 固定搭配（含例句）/ 例句 / 构词拆分 / 词源 / 派生词 / 近反义」。
    ///
    /// 比词汇本的释义宽得多，所以换了格式：**可重复的键 + `|` 分隔子字段**
    /// （一个键一个值塞不下 3 条搭配 × 2 个字段，挤在一起反而更容易错位）。
    /// 解析在 `DictionaryDetailRule`，与这里的模板是**一对**，改一处必须改另一处。
    /// 模板走 `Resources/Prompts/dictionary_lookup.txt`，缺失时用等价内联兜底。
    ///
    /// - Parameter baseFormHints: 划到变体时本地推出的原形候选（只当提示，模型可以否掉）。
    ///   ⚠️ 必须给：不给的话模型会**用一句话回答**「这是 subtitle 的复数」，
    ///   而不是给出词条 —— 实测 `subtitles` / `listening` 都栽在这里，页面显示「没查到」。
    public static func dictionaryLookupPrompt(
        word: String,
        learningLanguage: String,
        nativeLanguage: String,
        baseFormHints: [String] = []
    ) -> String {
        let hint: String
        if baseFormHints.isEmpty {
            hint = "The learner picked this word out of a sentence, so it may be an inflected form."
        } else {
            hint = """
            The learner picked this word out of a sentence. It may be an inflected form; \
            its base form is most likely one of: \(baseFormHints.joined(separator: ", ")).
            """
        }
        return vocabularyPrompt(
            resource: "Prompts/dictionary_lookup",
            word: word,
            learningLanguage: learningLanguage,
            nativeLanguage: nativeLanguage,
            fallback: """
            You are a dictionary compiler for a Chinese-speaking learner of {learning_language}.

            Write ONE entry for the headword below. Reply with lines of "key: value" — a key, a colon, \
            then the value. Repeat a key to add another item of that kind. ONLY these keys are allowed:

            word: <the headword, copied exactly as asked>
            phonetic_us: <American IPA, between slashes>
            phonetic_uk: <British IPA, between slashes>
            sense: <part of speech> | <{native_language} senses>
            collocation: <fixed expression> | <{native_language} meaning> | <example sentence> | <{native_language} translation>
            example: <example sentence> | <{native_language} translation>
            morphology: <part> = <its meaning> + <part> = <its meaning> => <combined {native_language} meaning>
            etymology: <one or two {native_language} sentences on where the word comes from>
            derivative: <derived word> | <part of speech> | <{native_language} meaning>
            synonym: <word> | <part of speech> | <{native_language} meaning>
            antonym: <word> | <part of speech> | <{native_language} meaning>
            family_root: <the shared root of the word family> | <its {native_language} meaning>
            family_branch: <a word built on that root> | <part of speech> | <{native_language} meaning> | <how it is built from the root>
            family_member: <the branch word it hangs under> | <a word built on that branch word> | <part of speech> | <{native_language} meaning> | <how it is built>
            form: <the headword as it was asked> = <its base form> | <what this form means here, in {native_language}>

            Rules:
            - "|" separates the fields INSIDE one line; it must NEVER appear inside a field.
            - The key name is only a key. Never write a key name as a value and never leave a value empty.
            - OMIT a key entirely when you have nothing real to say. Never write "-" as a value.
            - phonetic_us / phonetic_uk: write BOTH for a single word (never empty). Omit both for a phrase.
            - sense: one line per part of speech, all common senses joined by "；", 2-4 lines at most.
            - collocation: 2-5 real fixed expressions, each with example and translation.
            - example: 2-3 natural sentences, each with its translation.
            - morphology only when the word is clearly built from parts; etymology only when you know it.
            - derivative 2-4 lines; synonym / antonym 2-4 lines each; every one needs pos AND {native_language} meaning.
            - family_root / family_branch / family_member: the word family tree (words sharing one root),
              written ONLY when the headword really belongs to such a family; omit all three otherwise.
            - INFLECTED FORMS (see the note above the headword). If the headword is a plural, a
              third-person -s form, an -ing form, an -ed form, a comparative/superlative, or an
              irregular form (went / children / better…), you are NOT looking up a word of its own:
              describe its BASE FORM instead, set "word:" to that base form, and add the single
              "form:" line shown above. NEVER reply with a sentence instead of the entry lines.
              Example: asked for "subtitles" → word: subtitle … form: subtitles = subtitle | 复数形式，指影片的字幕
            - Everything is in {native_language} (Chinese) unless the field asks for {learning_language}.
            - No numbering, no bullets, no quotes, no markdown, no commentary.

            \(hint)

            Headword:
            {word}
            """
        )
        .replacingOccurrences(of: "{base_form_hint}", with: hint)
    }

    /// 今日跟读 20 句：按**当天轮到的几个情景**现场生成。
    ///
    /// 为什么要换掉原来那份写死的 `drills.json`：素材每天一样，练到第三天就是在背句子，
    /// 不是在练「第一次听到这句话时能不能跟上」。这里让情景跟着日期轮转，
    /// 句子按情景现编（更长、带从句），同一天内由缓存保证稳定。
    ///
    /// 解析在 `ShadowingDailyRule.parse`，与模板是**一对**，改一处必须改另一处。
    /// 模板走 `Resources/Prompts/shadowing_daily.txt`，缺失时用等价内联兜底。
    public static func shadowingDailyPrompt(
        learningLanguage: String,
        nativeLanguage: String,
        scenarioList: [(name: String, objective: String, level: String, difficulty: Int)],
        perScenario: Int,
        total: Int
    ) -> String {
        let rendered = scenarioList.enumerated().map { index, item -> String in
            let objective = item.objective.isEmpty ? "" : "（目标：\(item.objective)）"
            return "\(index + 1). \(item.name)\(objective) | \(item.level) | \(item.difficulty)"
        }.joined(separator: "\n")

        let template = loadTemplate(resource: "Prompts/shadowing_daily", fallback: Self.shadowingDailyFallback)
        return template
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
            .replacingOccurrences(of: "{scenario_list}", with: rendered)
            .replacingOccurrences(of: "{per_scenario}", with: "\(perScenario)")
            .replacingOccurrences(of: "{total}", with: "\(total)")
    }

    /// 内置兜底模板（与资源文件一字不差）。
    static let shadowingDailyFallback = """
    You write today's shadowing practice for a Chinese-speaking learner of {learning_language}.

    Below is a numbered list of scenarios, one per line, formatted as:
    <number>. <scenario name> (optional: its objective) | <CEFR level> | <1-5 difficulty>

    Write {per_scenario} sentences for EACH scenario above — {total} sentences in total, in the
    SAME ORDER as the scenarios are listed. Every sentence must be spoken {learning_language}
    that a real person would actually say in that situation.

    Reply with lines of "key: value". ONLY these two keys are allowed:

    topic: <the scenario name, copied exactly as listed> | <1-5 difficulty, copied from the list>
    sentence: <the sentence> | <its {native_language} translation> | <what to watch out for when saying it>

    Rules for each line:
    - "|" separates the fields INSIDE one line. It must NEVER appear inside a field.
    - The key name is only a key. Never write a key name as a value, and never leave a field empty.
    - Write the "topic" line once, then its {per_scenario} "sentence" lines, then the next topic.
    - A sentence must be a COMPLETE, natural utterance of 12 to 24 words — long enough to have
      real rhythm. Use a subordinate clause, a common collocation, or a discourse marker in most
      of them. Short one-clause sentences ("I'd like a coffee, please.") are NOT acceptable.
    - Vary the sentence types: statements, polite requests, questions, a hesitation or a caveat.
      Do not start more than two sentences in the whole reply with the same word.
    - The sentences must be self-contained: someone shadowing one sentence must be able to say
      it without seeing the others.
    - The third field of a "sentence" line is spoken-style advice in {native_language}: linking,
      weak forms, stress, or a sound to be careful with. Name at least one real word from the
      sentence. Never write vague advice like "pay attention to intonation" alone.
    - Everything except the {learning_language} sentences themselves is written in
      {native_language} (Chinese).
    - No numbering, no bullets, no quotes, no markdown, no commentary, no headings.

    Worked example of a CORRECT reply (scenario list had just one scenario, with 2 sentences):

    topic: 机场值机 | 3
    sentence: I'd like to check in for the flight to Vancouver, but I'm not sure which counter handles international departures. | 我想办理飞往温哥华航班的值机，但不确定哪个柜台办理国际航班。 | check in 连读成 check-in，international 重音在第三个音节 -ter-。
    sentence: Do you think I could still make the connection if the first flight is delayed by an hour? | 你觉得如果第一班飞机延误一小时，我还能赶上转机吗？ | could 弱读，connection 的 -tion 读 /ʃn/。

    The scenario list for today:

    {scenario_list}

    Now write all {total} sentences, following every rule above:
    """

    /// 读 `Resources/Prompts/<name>.txt`；缺失时用兜底模板。
    static func loadTemplate(resource: String, fallback: String) -> String {
        if let url = AppResourceBundle.module.url(forResource: resource, withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8),
           !loaded.isEmpty {
            return loaded
        }
        return fallback
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

    /// 写作批改（#230）：一次请求拿回「分数 + 重点建议 + 逐条批改 + 整段改写 + 生词」。
    /// 解析在 `WritingReviewRule`（AIDomain），与模板是**一对**，改一处必须改另一处。
    /// 模板走 `Resources/Prompts/writing_review.txt`，缺失时用等价内联兜底。
    public static func writingReviewPrompt(
        topic: String,
        essay: String,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        let template = loadTemplate(resource: "Prompts/writing_review", fallback: Self.writingReviewFallback)
        return template
            .replacingOccurrences(of: "{topic}", with: topic)
            .replacingOccurrences(of: "{essay}", with: essay)
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
    }

    /// 写作批改的兜底模板（与资源文件一字不差）。
    static let writingReviewFallback = """
    You are the learner's writing coach for {learning_language}. The learner wrote a short essay (80-120 words) for today's writing task. Grade it and correct it.

    The writing task:
    {topic}

    The learner's essay:
    {essay}

    Reply with lines of "key: value". ONLY these keys are allowed:

    score: <0-100, one integer>
    advice: <ONE key piece of advice in {native_language}, one or two sentences.>
    fix: <the wrong fragment, copied EXACTLY from the essay> || <the corrected fragment> || <why, one short {native_language} sentence>
    rewrite: <the whole essay rewritten naturally, keeping the learner's own ideas>
    word: <a word or phrase worth remembering> || <part of speech> || <{native_language} meaning>

    Rules:
    - "||" separates the fields INSIDE one line. It must NEVER appear inside a field.
    - fix: 3 to 6 lines, most important errors first. Copy the wrong fragment word-for-word.
    - rewrite: keep the learner's meaning and voice; it may span several lines, ending before the first "word:" line.
    - word: 2 to 5 lines.
    - Everything except the {learning_language} fragments and sentences is written in {native_language} (Chinese).
    - No numbering, no bullets, no quotes, no markdown, no commentary.
    """

    // MARK: - 阅读理解出题（#231）

    /// 出一篇短文 + 3-5 道四选一（一次阅读 = 一次模型请求；判分在本地零请求）。
    public static func readingGenerationPrompt(
        theme: String,
        level: String,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        let template = loadTemplate(resource: "Prompts/reading_generation", fallback: Self.readingGenerationFallback)
        return template
            .replacingOccurrences(of: "{theme}", with: theme)
            .replacingOccurrences(of: "{level}", with: level)
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
    }

    /// 阅读出题的兜底模板（与资源文件一字不差）。
    static let readingGenerationFallback = """
    You are the learner's reading coach for {learning_language}. Write today's short reading passage with comprehension questions.

    Today's theme: {theme}
    The learner's estimated level: {level}

    Reply with lines of "key: value". ONLY these keys are allowed:

    title: <a short English title for the passage>
    passage: <the passage, 150-220 words; may span several lines, ends before the first "q:" line>
    q: <one comprehension question in English>
    opt: <option 1> || <option 2> || <option 3> || <option 4>
    answer: <index of the correct option, 0-3>
    quote: <the sentence from the passage that supports the answer, copied word-for-word>
    explain: <in {native_language}, why that option is correct and the relevant English knowledge point>
    trap: <in {native_language}, why the wrong options are tempting and how to avoid this trap>

    Rules:
    - 3 to 5 questions, exactly 4 options each, exactly ONE correct and plausible wrong options.
    - "||" separates the fields INSIDE one line. It must NEVER appear inside a field.
    - quote must be copied word-for-word from the passage so it can be highlighted.
    - Every answer must be findable in the passage, never outside knowledge.
    - Everything except English fragments and sentences is written in {native_language} (Chinese).
    - No numbering, no bullets, no quotes, no markdown, no commentary.
    """

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
