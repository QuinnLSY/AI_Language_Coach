import Foundation

/// 考试模式：考官式流程（雅思口语 Part 1/2/3、面试问答序列）。
///
/// **这一套与「课程 / 闯关」体系完全分开**，有意为之：
/// - 课程用星星记**参与度**、用判定卡记**内容覆盖**，那是「陪你练」的反馈；
/// - 考试用**维度分（band）**，那是「按考官口径给你打个分」的反馈。
/// 两套评价混在一起，学员就分不清「我没过关」和「我这次分数不高」是同一件事还是两件事。
/// 因此本文件**不引用 `Quest` / `Curriculum` / `ScenarioRewardRule` 的任何类型**，
/// 也不产出星星或判定卡。
///
/// ⚠️ 维度分参考雅思口语的四项标准（流利与连贯 / 词汇 / 语法 / 发音），
/// 但**不是官方评分**，也不可能替代考官。分数一律标注为「参考分」，
/// 且每一项都必须带上算出它的原始指标（`ExamScore.evidence`）——
/// 只给一个数字不给依据，就成了「把推断说成实测」。
///
/// 流程与题目**不放代码里**：题目在 `Resources/Exams/*.json`（同场景素材的约定）。

// MARK: - 考试形式

public enum ExamFormat: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    /// 雅思口语：Part 1 简介问答 / Part 2 个人陈述 / Part 3 深入讨论。
    case ieltsSpeaking
    /// 面试问答序列。
    case jobInterview

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ieltsSpeaking: "雅思口语"
        case .jobInterview: "面试问答"
        }
    }

    public var icon: String {
        switch self {
        case .ieltsSpeaking: "globe.europe.africa.fill"
        case .jobInterview: "person.badge.clock.fill"
        }
    }
}

// MARK: - 题目

/// 一个环节（雅思的一个 Part，或面试里的一组同类问题）。
public struct ExamStage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// 给学员看的作答要求（一句话说清「这一环节怎么答」）。
    public var instructions: String
    /// 考官问句。一句 = 一问，答完自动进下一问。
    public var prompts: [String]
    /// 单问限时（秒）。到点由 UI 收尾，不阻塞在题上。
    public var timeLimitSeconds: Int
    /// 期望作答词数下限：低于它算「没答够」，是任务完成度的依据之一。
    public var minimumWords: Int

    public init(
        id: String,
        title: String,
        instructions: String,
        prompts: [String],
        timeLimitSeconds: Int,
        minimumWords: Int
    ) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.prompts = prompts
        // 限时至少 10 秒、期望词数至少 5 —— 素材写错不该让考试变成无法完成的题。
        self.timeLimitSeconds = max(timeLimitSeconds, 10)
        self.minimumWords = max(minimumWords, 5)
    }
}

/// 一套考卷（形式 + 环节序列）。
public struct ExamBlueprint: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var format: ExamFormat
    public var title: String
    public var summary: String
    public var stages: [ExamStage]

    public init(
        id: String,
        format: ExamFormat,
        title: String,
        summary: String,
        stages: [ExamStage]
    ) {
        self.id = id
        self.format = format
        self.title = title
        self.summary = summary
        self.stages = stages
    }

    /// 全场共几问。
    public var questionCount: Int { stages.reduce(0) { $0 + $1.prompts.count } }

    /// 全场限时上限（各环节之和）——UI 的「整场还剩多久」用它，不另存一份。
    public var totalTimeLimitSeconds: Int { stages.reduce(0) { $0 + $1.timeLimitSeconds } }
}

// MARK: - 作答

/// 学员对某一问的作答。
public struct ExamAnswer: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// **全局第几问**（从 1 起），在作答当时记下来。
    ///
    /// ⚠️ 不能事后用 `answers` 的下标推：中间跳过一题之后，下标就与题号错位了，
    /// 而报告里写着「第 3 题只说了 8 词」——错位的题号会指着一道答得很好的题。
    public var questionNumber: Int
    public var stageID: String
    public var prompt: String
    public var text: String
    /// 实际说了多久（秒）。**由调用方测量后传入**，域层不猜时间。
    public var seconds: Int
    /// 这一问里老师标出的错误条数。
    ///
    /// `nil` = **没有这一路数据**（比如学员用键盘作答、或该轮没有纠错行）。
    /// ⚠️ 绝不把 nil 当 0：那是「没有数据」与「零错误」的区别，
    /// 混用会让语法分凭空变高（见 `ExamScoring`）。
    public var errorCount: Int?

    public init(
        id: String = UUID().uuidString,
        questionNumber: Int,
        stageID: String,
        prompt: String,
        text: String,
        seconds: Int,
        errorCount: Int? = nil
    ) {
        self.id = id
        self.questionNumber = max(questionNumber, 1)
        self.stageID = stageID
        self.prompt = prompt
        self.text = text
        self.seconds = max(seconds, 0)
        self.errorCount = errorCount
    }

    /// 词数（按空白切分，见 `ExamScoring.wordCount`）。
    public var wordCount: Int { ExamScoring.wordCount(of: text) }
}

// MARK: - 会话状态机

/// 一次考试的过程。纯值类型：所有转移都能在无 UI、无模型的单测里断言。
public struct ExamSession: Sendable, Equatable {
    public let blueprint: ExamBlueprint
    public private(set) var answers: [ExamAnswer]
    /// 当前环节下标。等于 `stages.count` 表示已考完。
    public private(set) var stageIndex: Int
    /// 当前环节内的第几问。
    public private(set) var promptIndex: Int

    public init(blueprint: ExamBlueprint) {
        self.blueprint = blueprint
        self.answers = []
        self.stageIndex = 0
        self.promptIndex = 0
    }

    public var currentStage: ExamStage? {
        blueprint.stages.indices.contains(stageIndex) ? blueprint.stages[stageIndex] : nil
    }

    public var currentPrompt: String? {
        guard let stage = currentStage, stage.prompts.indices.contains(promptIndex) else { return nil }
        return stage.prompts[promptIndex]
    }

    /// 当前是第几问（全局，从 1 起）。已考完时返回总问数。
    public var questionNumber: Int {
        let before = blueprint.stages.prefix(stageIndex).reduce(0) { $0 + $1.prompts.count }
        return min(before + promptIndex + 1, blueprint.questionCount)
    }

    public var totalQuestions: Int { blueprint.questionCount }

    public var isFinished: Bool { stageIndex >= blueprint.stages.count }

    /// 当前这一问的限时（秒）。已考完为 0。
    public var currentTimeLimitSeconds: Int { currentStage?.timeLimitSeconds ?? 0 }

    /// 记一次作答，并自动推进到下一问（本环节问完则进下一环节）。
    ///
    /// 空白作答**不记录**，但仍推进 —— 学员跳过一题不该把整场卡住，
    /// 而「跳过」这件事会体现在 `answeredCount < questionCount` 上，不会被抹掉。
    @discardableResult
    public mutating func recordAnswer(
        text: String,
        seconds: Int,
        errorCount: Int? = nil
    ) -> ExamAnswer? {
        guard let stage = currentStage, let prompt = currentPrompt else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var recorded: ExamAnswer?
        if !trimmed.isEmpty {
            // 题号必须在推进之前取 —— `advance()` 之后就变成下一题了。
            let answer = ExamAnswer(
                questionNumber: questionNumber,
                stageID: stage.id,
                prompt: prompt,
                text: trimmed,
                seconds: seconds,
                errorCount: errorCount
            )
            answers.append(answer)
            recorded = answer
        }
        advance()
        return recorded
    }

    /// 跳过当前这一问（超时未答 / 学员主动跳过）。
    public mutating func skipCurrentPrompt() {
        guard !isFinished else { return }
        advance()
    }

    private mutating func advance() {
        guard let stage = currentStage else { return }
        promptIndex += 1
        if promptIndex >= stage.prompts.count {
            stageIndex += 1
            promptIndex = 0
        }
    }

    /// 提前收场：把剩余题目全部跳过（学员点「结束」）。
    public mutating func finishEarly() {
        stageIndex = blueprint.stages.count
        promptIndex = 0
    }

    // MARK: - 按题号取数（题号是唯一键，绝不用下标推）

    /// 第 `number` 问的题面（从 1 起）。找不到返回 nil。
    public func prompt(forQuestion number: Int) -> String? {
        var remaining = number
        for stage in blueprint.stages {
            if remaining <= stage.prompts.count { return stage.prompts[remaining - 1] }
            remaining -= stage.prompts.count
        }
        return nil
    }

    /// 第 `number` 问的作答记录（没答过 / 被跳过返回 nil）。
    public func answer(forQuestion number: Int) -> ExamAnswer? {
        answers.first { $0.questionNumber == number }
    }

    /// 事后补记某一问的纠错条数。
    ///
    /// 纠错来自老师那一轮回复（一次真实的模型往返），而作答在发送的同一刻就落进了考卷，
    /// 两者之间隔着一次生成 —— 所以只能事后补。**只在还没有数据时写入**（`nil`）；
    /// 反复覆盖会让「没测到」与「测到零错误」再次混为一谈，那正是本文件防的那件事。
    ///
    /// - Returns: 真的写进去了才返回 true。
    @discardableResult
    public mutating func attachErrorCount(_ count: Int, toQuestion number: Int) -> Bool {
        guard let index = answers.firstIndex(where: { $0.questionNumber == number }) else { return false }
        guard answers[index].errorCount == nil else { return false }
        answers[index].errorCount = max(count, 0)
        return true
    }
}
