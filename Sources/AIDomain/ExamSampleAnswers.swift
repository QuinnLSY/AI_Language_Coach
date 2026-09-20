import Foundation

/// 考后「示范答案」：挑几问，请老师写一份可以对照的回答。
///
/// 三件事都是纯函数，因此「挑哪几问」「模型回的一团字里哪几行算答案」都能被单测钉住，
/// 不必等一次真实模型往返才知道对不对。
public enum ExamSampleAnswerRule {

    /// 模型输出里每一行的标记。与纠错的 `[[FIX]]` 同一套思路：
    /// 让模型在一段自然文本里标出结构化片段，代码只认标记，不猜语义。
    public static let marker = "[[SAMPLE]]"

    /// 一次最多给几问出示范答案。
    ///
    /// ⚠️ 上限不是性能考虑，是**钱与注意力**：一场雅思口语 7–8 问，
    /// 每题都写一份示范答案，学员一条也不会看，但每一次都是真实的模型输出。
    public static let maxTargets = 3

    /// 该给哪几问配示范答案。
    ///
    /// 优先级：
    /// 1. **跳过的题**（完全没答 —— 最该知道自己本来可以说什么）；
    /// 2. **答得太短的题**（`ExamMetrics.undersizedQuestions`，低于环节期望词数）。
    ///
    /// 全都答够时返回空 —— 那就**不发请求**，也不硬凑一份示范答案出来。
    public static func targets(session: ExamSession, report: ExamReport) -> [Int] {
        var picked: [Int] = []
        let answered = Set(session.answers.map(\.questionNumber))
        for number in 1...max(session.totalQuestions, 1) where !answered.contains(number) {
            picked.append(number)
        }
        for number in report.metrics.undersizedQuestions where !picked.contains(number) {
            picked.append(number)
        }
        // 截断按优先级，展示顺序按题号 —— 优先级决定「先给谁」，
        // 题号决定「在报告里从上往下读」。
        return picked.prefix(maxTargets).sorted()
    }

    /// 打包成提示词要用的素材（题号 + 题面 + 学员原答）。
    public static func items(for targets: [Int], in session: ExamSession) -> [ExamSampleTarget] {
        targets.compactMap { number in
            guard let prompt = session.prompt(forQuestion: number) else { return nil }
            return ExamSampleTarget(
                questionNumber: number,
                prompt: prompt,
                answer: session.answer(forQuestion: number)?.text ?? ""
            )
        }
    }

    /// 解析模型输出：只认 `[[SAMPLE]] 3 || 正文` 这种行。
    ///
    /// 认不出来的行**直接丢掉**：模型偶尔会加一句「希望有帮助」，
    /// 把那种话当成示范答案显示给学员，比少一条更糟。
    /// 同一个题号出现多次时**只认第一条**（后来的多半是重复或补充说明）。
    public static func parse(_ text: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(marker) else { continue }
            let body = trimmed.dropFirst(marker.count)
            let parts = body.components(separatedBy: "||")
            guard parts.count >= 2 else { continue }
            let numberText = parts[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ".:：、")
            ))
            guard let number = Int(numberText), number >= 1 else { continue }
            let answer = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty, result[number] == nil else { continue }
            result[number] = answer
        }
        return result
    }
}

/// 一条待写的示范答案：题号 + 题面 + 学员原答（原答用于让示范答案真正「高一个档次」，
/// 而不是泛泛而谈）。
public struct ExamSampleTarget: Sendable, Equatable {
    public let questionNumber: Int
    public let prompt: String
    public let answer: String

    public init(questionNumber: Int, prompt: String, answer: String) {
        self.questionNumber = questionNumber
        self.prompt = prompt
        self.answer = answer
    }
}
