import AIDomain
import Foundation

/// AI 排课的 Prompt 组装（学员状态 → 一条有序的课）。
///
/// ⚠️ 模板 `course_blueprint.txt` 与解析器 `CourseBlueprintRule.parse` 是**一对**：
/// 改任何一方的键名，另一方必须同步改（两边都有测试钉着）。
///
/// 与 `scenarioDraftPrompt` 的分工：那个是「一句描述 → **一个**情景」（用户说练什么就练什么），
/// 这个是「学员状态 → **一条**课」（由老师按他的水平与错处安排顺序）。
/// 两者共用 `scene:` / `sentence:` / `vocabulary:` / `quest:` 四把键 —— **同一套键在两个
/// 地方含义相同**，模型不必学两套语法，解析器也不必写两份。
extension PromptBuilder {

    /// 排课请求体：**一次请求排出整条课**。
    ///
    /// 不拆成「一节课一次请求」：一条课的**顺序**正是它的价值所在
    /// （由易到难、前后呼应），分次生成的话每节都看不见别节，顺序就丢了 ——
    /// 还得让用户等 N 趟，N 次之间更容易互相打架。
    public static func courseBlueprintPrompt(
        request: CourseRequest,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        let cleaned = request.sanitized()
        let template: String
        if let url = AppResourceBundle.url(forResource: "Prompts/course_blueprint", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            You are this language learner's teacher. Arrange an **ordered course** of \
            {min_lessons}-{max_lessons} lessons for him, from easiest to hardest.
            His current state: {state}
            {topics_line}
            {level_line}
            Output key-value lines only:
            course: <course title in {learning_language}> | <title in {native_language}>
            focus: <one line, in {native_language}, saying what this course targets>
            lesson: <lesson title in {learning_language}> | <title in {native_language}>
            scene: <AI role> | <learner role> | <objective in {learning_language}> | \
            <difficulty 1-5> | <opening line in {learning_language}>
            sentence: <a sentence the learner would really say, in {learning_language}>
            vocabulary: <word> | <part of speech> | <meaning in {native_language}> | \
            <example sentence in {learning_language}>
            quest: <one-line goal of this lesson, in {learning_language}>
            Rules: each lesson needs {min_sentences}-{max_sentences} sentence lines and at \
            most {max_words} vocabulary entries; spread his recurring mistakes and mispronounced \
            sounds across all lessons; do not give difficulty 3 for everything; no markdown, \
            no numbering, no blank-line separators.
            """
        }
        return template
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
            .replacingOccurrences(of: "{min_lessons}", with: "\(CourseBlueprintRule.minimumLessons)")
            .replacingOccurrences(of: "{max_lessons}", with: "\(CourseBlueprintRule.maximumLessons)")
            .replacingOccurrences(of: "{min_sentences}", with: "\(CourseBlueprintRule.minimumTargetSentences)")
            .replacingOccurrences(of: "{max_sentences}", with: "\(CourseBlueprintRule.maximumTargetSentences)")
            .replacingOccurrences(of: "{max_words}", with: "\(CourseBlueprintRule.maximumTargetVocabulary)")
            .replacingOccurrences(of: "{state}", with: stateText(cleaned))
            .replacingOccurrences(of: "{topics_line}", with: topicsLine(cleaned))
            .replacingOccurrences(of: "{level_line}", with: levelLine(cleaned.level))
    }

    /// 学员状态原话（`CourseRequest.stateSummary`）。
    ///
    /// ⚠️ **就是卡片上回显的那一句**（`CourseBlueprint.rationale` 留的也是它）：
    /// 学员看到的「照着什么排的」必须等于模型当时拿到的那句话。
    static func stateText(_ request: CourseRequest) -> String {
        request.stateSummary.isEmpty
            ? "还没攒下可参考的记录（先按常规排）。"
            : request.stateSummary
    }

    /// 自填主题那一行。没有主题时整行消失（**不替换成 `-`**：留个空行会让模型以为
    /// 「主题」这个槽位存在却是空的，进而在课里硬凑一个主题）。
    static func topicsLine(_ request: CourseRequest) -> String {
        guard !request.topics.isEmpty else { return "" }
        return "学员自己想练的主题（至少覆盖其中一个）：\(request.topics.joined(separator: "、"))"
    }

    /// 档位 + 难度区间。档位未知时也给一句明确的话 —— 不留下一个空的 `（）`。
    static func levelLine(_ level: CEFRLevel?) -> String {
        guard let level else {
            return "还没定位出他属于哪个档位，难度按他的状态在 1-5 里自己判断。"
        }
        let band = CourseBlueprintRule.difficultyBand(for: level)
        return "他现在的档位是 \(level.code)（\(level.displayName)：\(level.canDo)），"
            + "各节难度请落在 \(band.lowerBound)-\(band.upperBound) 之间。"
    }
}
