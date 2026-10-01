import AIDomain
import Foundation

/// 考试模式的 Prompt 组装（雅思口语 / 面试问答）。
///
/// 与 `PromptBuilder` 主文件分开：那边是「老师怎么教」，这边是「考官怎么考」——
/// 两套口径的价值取向相反（一个要陪着你练，一个要按流程考你），
/// 混在一个文件里改一处很容易顺手改坏另一处。
///
/// ⚠️ 模板一律来自 `Resources/Prompts/`，本文件只做**取值与拼装**；
/// 缺模板时有等价内联兜底，保证考试仍能进行（与 `PromptBuilder` 同一条约定）。
extension PromptBuilder {

    // MARK: - 考官轮次

    /// 注入系统提示词的考官块：把老师从「陪练」换成「考官」。
    public static func examExaminerBlock(
        _ context: ExamTurnContext,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        let template: String
        if let url = AppResourceBundle.url(forResource: "Prompts/exam_examiner", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            Exam mode — you are the examiner, not a tutor
            - Exam: {exam_title} ({exam_format})
            - Current section: {stage_title}

            {turn_note}

            Rules for this exam turn
            1. One examiner line at most, then the question. No lectures.
            2. Never answer the question yourself.
            3. Mark at most one clear mistake on its own line as: [[FIX]] said => better => short reason
            """
        }
        return template
            .replacingOccurrences(of: "{exam_title}", with: context.examTitle)
            .replacingOccurrences(of: "{exam_format}", with: context.format.displayName)
            .replacingOccurrences(of: "{stage_title}", with: context.stageTitle)
            .replacingOccurrences(of: "{stage_instructions}", with: context.stageInstructions)
            .replacingOccurrences(of: "{turn_note}", with: turnNote(context))
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
    }

    /// 要求模型**只输出开场那一条**（考卷第一问由考官自己念出来）。
    public static func examOpenerPrompt(
        _ context: ExamTurnContext,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        let template: String
        if let url = AppResourceBundle.url(forResource: "Prompts/exam_opener", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            You are the examiner. Write ONLY the single message you say right now.
            - Exam: {exam_title}
            - Question {question_number} of {total_questions}: {prompt}
            - Expect at least {minimum_words} words within {time_limit_seconds} seconds.
            """
        }
        return template
            .replacingOccurrences(of: "{exam_title}", with: context.examTitle)
            .replacingOccurrences(of: "{stage_title}", with: context.stageTitle)
            .replacingOccurrences(of: "{stage_instructions}", with: context.stageInstructions)
            .replacingOccurrences(of: "{question_number}", with: "\(context.questionNumber)")
            .replacingOccurrences(of: "{total_questions}", with: "\(context.totalQuestions)")
            .replacingOccurrences(of: "{prompt}", with: context.prompt)
            .replacingOccurrences(of: "{minimum_words}", with: "\(context.minimumWords)")
            .replacingOccurrences(of: "{time_limit_seconds}", with: "\(context.timeLimitSeconds)")
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
    }

    /// 三种轮次（开场 / 答完一问 / 收场）各自该做什么 —— **只在代码里判**，
    /// 不让模板自己做条件分支：一个模板要同时说三件事，最后一句都说不清。
    static func turnNote(_ context: ExamTurnContext) -> String {
        if context.isClosing {
            return """
            The exam has ended, the candidate's last answer has been recorded.
            - Say one short closing line as the examiner and thank the candidate.
            - Do not ask anything else, do not evaluate them, do not give any score.
            """
        }
        if context.answeredQuestionNumber > 0 {
            return """
            The candidate has just answered question {answered} of {total}.
            - Open with half a sentence of acknowledgement ("Thank you." / "All right, thank you.") and move on.
            - Then ask question {number} of {total} exactly as given: {prompt}
            - Expected length: at least {minimum} words, within {limit} seconds.
            - Say nothing this turn about how good or bad their answer was.
            """
            .replacingOccurrences(of: "{answered}", with: "\(context.answeredQuestionNumber)")
            .replacingOccurrences(of: "{total}", with: "\(context.totalQuestions)")
            .replacingOccurrences(of: "{number}", with: "\(context.questionNumber)")
            .replacingOccurrences(of: "{prompt}", with: context.prompt)
            .replacingOccurrences(of: "{minimum}", with: "\(context.minimumWords)")
            .replacingOccurrences(of: "{limit}", with: "\(context.timeLimitSeconds)")
        }
        return """
        The exam has just started. Nobody has answered yet.
        - Ask question {number} of {total} exactly as given: {prompt}
        - Expected length: at least {minimum} words, within {limit} seconds.
        """
        .replacingOccurrences(of: "{number}", with: "\(context.questionNumber)")
        .replacingOccurrences(of: "{total}", with: "\(context.totalQuestions)")
        .replacingOccurrences(of: "{prompt}", with: context.prompt)
        .replacingOccurrences(of: "{minimum}", with: "\(context.minimumWords)")
        .replacingOccurrences(of: "{limit}", with: "\(context.timeLimitSeconds)")
    }

    // MARK: - 示范答案（考后一次请求）

    /// 示范答案请求体：给定几问 + 学员原答，要一份可对照的回答。
    public static func examSampleAnswerPrompt(
        examTitle: String,
        targets: [ExamSampleTarget],
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        let template: String
        if let url = AppResourceBundle.url(forResource: "Prompts/exam_sample_answers", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            Write one model answer per question.
            Output exactly: [[SAMPLE]] <number> || <answer>
            Questions
            {questions}
            """
        }
        return template
            .replacingOccurrences(of: "{exam_title}", with: examTitle)
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
            // 每条示范答案的目标长度：取「答得最短的那一问」作下限、60 词作上限 ——
            // 一个固定数字会让不擅长开口的人望而生畏，也会让 Part 2 显得太短。
            .replacingOccurrences(of: "{target_words}", with: "\(targetWordCount(targets))")
            .replacingOccurrences(of: "{questions}", with: questionList(targets))
    }

    /// 示范答案该写多少词：以学员自己答得最短的一问为下限，60 词封顶。
    static func targetWordCount(_ targets: [ExamSampleTarget]) -> Int {
        let shortest = targets.map { ExamScoring.wordCount(of: $0.answer) }.min() ?? 0
        return min(max(shortest, 30), 60)
    }

    static func questionList(_ targets: [ExamSampleTarget]) -> String {
        targets.map { target in
            var lines = ["\(target.questionNumber). \(target.prompt)"]
            let spoken = ExamScoring.wordCount(of: target.answer)
            if spoken == 0 {
                lines.append("   (the candidate said nothing here)")
            } else {
                lines.append("   (what the candidate said, \(spoken) words: \(target.answer))")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
