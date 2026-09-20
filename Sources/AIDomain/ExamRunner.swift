import Foundation

/// 一场考试**进行中**的推进与计时。
///
/// 为什么要单独一层，而不是把时间塞进 `ExamSession`：
/// - `ExamSession` 管的是**题目流程**（答一问进一问、跳过不卡住、题号不错位），
///   它的每一次转移都与时钟无关 —— 单测里可以瞬间考完一场；
/// - `ExamRunner` 才认识 `Date`，负责「这一问什么时候起表、学员答了多久、该不该推进」。
///
/// 两者分开，评分与流程的测试不必伪造时间，计时的口径也只有一个地方在算。
///
/// ⚠️ **计时起点是题目真正出现在学员面前的那一刻**（`arm(now:)`），
/// 不是「上一问答完」的那一刻。后者包含了老师生成下一问的耗时
/// （本机冷加载实测 30–60 秒），把它算进作答时间，倒计时一开场就被吃掉大半，
/// 语速（词/分）也会被系统性地算低 —— 那是「把等待说成学员说得慢」。
///
/// ⚠️ `turns`（已答 / 未答）**一律以题号为键**，绝不用 `answers` 的下标推：
/// 中间跳过一题之后，下标就与题号错位了（`ExamAnswer.questionNumber` 的注释里记着这个坑）。
public struct ExamRunner: Sendable, Equatable {

    public private(set) var session: ExamSession
    /// 本场开始时刻（界面上的「整场用时」用它）。
    public let startedAt: Date
    /// 切到当前这一问的时刻 —— 不管考官有没有把它说出来。
    private var advancedAt: Date
    /// 当前这一问**真正展示出来**的时刻。nil = 考官还在生成，此刻不计时。
    private var armedAt: Date?

    public init(blueprint: ExamBlueprint, startedAt: Date = Date()) {
        self.session = ExamSession(blueprint: blueprint)
        self.startedAt = startedAt
        self.advancedAt = startedAt
        self.armedAt = nil
    }

    // MARK: - 取数（全部转发自考卷流程）

    public var blueprint: ExamBlueprint { session.blueprint }
    public var answers: [ExamAnswer] { session.answers }
    public var currentStage: ExamStage? { session.currentStage }
    public var currentPrompt: String? { session.currentPrompt }
    public var questionNumber: Int { session.questionNumber }
    public var totalQuestions: Int { session.totalQuestions }
    public var isFinished: Bool { session.isFinished }
    public var questionLimitSeconds: Int { session.currentTimeLimitSeconds }

    /// 当前这一问**是不是已经在计时**。没起表时倒计时显示「等待考官提问…」。
    public var isArmed: Bool { armedAt != nil && !isFinished }

    /// 当前这一问的截止时刻（没起表 / 已考完为 nil）。
    public var questionDeadline: Date? {
        guard let armedAt, !isFinished else { return nil }
        return armedAt.addingTimeInterval(TimeInterval(session.currentTimeLimitSeconds))
    }

    /// 倒计时剩余秒数（没起表 / 已考完为 nil）。
    public func remainingSeconds(now: Date) -> Int? {
        guard let deadline = questionDeadline else { return nil }
        return max(Int(deadline.timeIntervalSince(now).rounded(.up)), 0)
    }

    /// 当前这一问是否已经超时。
    public func isTimedOut(now: Date) -> Bool {
        guard isArmed else { return false }
        return (remainingSeconds(now: now) ?? 0) <= 0
    }

    /// 这一问实际说了多久：从**起表**算起；考官一直没开口（没起表）时退化为
    /// 「从切到这一问算起」—— 退化的口径会包含生成耗时，但总好过把时长记成 0
    /// （0 秒会被评分当成「没有这一路数据」）。
    public func measuredSeconds(now: Date) -> Int {
        max(Int(now.timeIntervalSince(armedAt ?? advancedAt).rounded()), 0)
    }

    /// 刚答完的那一问的题号（还没答过为 nil）。
    public var lastAnsweredQuestionNumber: Int? { session.answers.last?.questionNumber }

    // MARK: - 计时

    /// 起表：题目已经出现在学员面前，从现在开始算作答时间。
    ///
    /// 重复调用（比如老师分两条消息说完同一问）只认**第一次** —— 后到的
    /// 「起表」会把已经走过的秒数抹掉，等于凭空给学员加时间。
    public mutating func arm(now: Date = Date()) {
        guard !isFinished, armedAt == nil else { return }
        armedAt = now
    }

    // MARK: - 推进

    /// 记一次作答并推进到下一问。空白文本不记录（但仍推进，见 `ExamSession.recordAnswer`）。
    ///
    /// - Returns: 记下来的那一条（空白 / 已考完时为 nil）。
    @discardableResult
    public mutating func submit(
        text: String,
        now: Date = Date(),
        errorCount: Int? = nil
    ) -> ExamAnswer? {
        guard !isFinished else { return nil }
        let recorded = session.recordAnswer(
            text: text,
            seconds: measuredSeconds(now: now),
            errorCount: errorCount
        )
        markAdvanced(now: now)
        return recorded
    }

    /// 跳过当前这一问（超时未答 / 学员主动跳过）。**不记录作答** ——
    /// 「跳过」这件事靠 `answers.count < totalQuestions` 体现，不能被抹掉。
    public mutating func skip(now: Date = Date()) {
        guard !isFinished else { return }
        session.skipCurrentPrompt()
        markAdvanced(now: now)
    }

    /// 提前收场（学员点「结束考试」）：剩余题目全部跳过。
    public mutating func finishEarly(now: Date = Date()) {
        guard !isFinished else { return }
        session.finishEarly()
        armedAt = nil
        advancedAt = now
    }

    /// 老师标出的错误条数**事后**补记到某一问上。
    ///
    /// 为什么是事后：纠错来自老师那一轮回复（一次真实的模型往返），
    /// 而作答在发送的同一刻就落进了考卷 —— 两者之间隔着一次生成。
    /// 只在**还没有数据**时写入（`nil`），绝不覆盖。
    ///
    /// - Returns: 真的写进去了才返回 true（找不到题号、已有数据都是 false）。
    @discardableResult
    public mutating func attachErrorCount(_ count: Int, toQuestion number: Int) -> Bool {
        session.attachErrorCount(count, toQuestion: number)
    }

    private mutating func markAdvanced(now: Date) {
        advancedAt = now
        armedAt = nil
    }

    // MARK: - 出题 / 结算

    public func report(pronunciation: ExamBand? = nil) -> ExamReport {
        ExamScoring.report(for: session, pronunciation: pronunciation)
    }

    /// 老师这一轮该按什么口径说话。
    ///
    /// ⚠️ 它同时是「当前问到哪一题」的**唯一取数点**：老师的问题、
    /// 界面上的题号、起表的时机都从这里推，三处不可能各说各的。
    public var turnContext: ExamTurnContext? {
        guard !isFinished,
              let stage = session.currentStage,
              let prompt = session.currentPrompt
        else { return nil }
        return ExamTurnContext(
            format: session.blueprint.format,
            examTitle: session.blueprint.title,
            stageTitle: stage.title,
            stageInstructions: stage.instructions,
            questionNumber: session.questionNumber,
            totalQuestions: session.totalQuestions,
            prompt: prompt,
            minimumWords: stage.minimumWords,
            timeLimitSeconds: stage.timeLimitSeconds,
            answeredQuestionNumber: lastAnsweredQuestionNumber ?? 0,
            isClosing: false
        )
    }

    /// 收尾口径：题答完了（或学员提前结束），老师只该说一句考官式的告别，
    /// 不再提问、不再评价。**把它交给老师而不是本地硬写**，是为了让考官
    /// 说的话前后是一个人在说。
    public var closingContext: ExamTurnContext? {
        guard isFinished else { return nil }
        let lastStage = session.blueprint.stages.last
        return ExamTurnContext(
            format: session.blueprint.format,
            examTitle: session.blueprint.title,
            stageTitle: lastStage?.title ?? session.blueprint.title,
            stageInstructions: lastStage?.instructions ?? "",
            questionNumber: session.totalQuestions,
            totalQuestions: session.totalQuestions,
            prompt: session.answers.last?.prompt ?? session.blueprint.title,
            minimumWords: lastStage?.minimumWords ?? 0,
            timeLimitSeconds: lastStage?.timeLimitSeconds ?? 0,
            answeredQuestionNumber: lastAnsweredQuestionNumber ?? 0,
            isClosing: true
        )
    }
}

// MARK: - 考官口径（注入 Prompt 的取值集合）

/// 老师这一轮必须知道的事：考什么、问到哪、期望答多长。
///
/// 刻意**不带**学员的作答内容与分数：分数由 `ExamScoring` 的纯函数算，
/// 不经过模型；把分数塞给模型，它就会在考场上把分数说出来。
public struct ExamTurnContext: Sendable, Equatable {
    public let format: ExamFormat
    public let examTitle: String
    public let stageTitle: String
    public let stageInstructions: String
    public let questionNumber: Int
    public let totalQuestions: Int
    public let prompt: String
    public let minimumWords: Int
    public let timeLimitSeconds: Int
    /// 学员刚答完的是第几问（0 = 还没答过，说明这是开场）。
    public let answeredQuestionNumber: Int
    /// 是否已经收场（题答完了 / 学员提前结束）。
    public let isClosing: Bool

    public init(
        format: ExamFormat,
        examTitle: String,
        stageTitle: String,
        stageInstructions: String,
        questionNumber: Int,
        totalQuestions: Int,
        prompt: String,
        minimumWords: Int,
        timeLimitSeconds: Int,
        answeredQuestionNumber: Int,
        isClosing: Bool
    ) {
        self.format = format
        self.examTitle = examTitle
        self.stageTitle = stageTitle
        self.stageInstructions = stageInstructions
        self.questionNumber = questionNumber
        self.totalQuestions = totalQuestions
        self.prompt = prompt
        self.minimumWords = minimumWords
        self.timeLimitSeconds = timeLimitSeconds
        self.answeredQuestionNumber = answeredQuestionNumber
        self.isClosing = isClosing
    }
}
