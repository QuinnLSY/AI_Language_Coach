import Foundation

// MARK: - AI 排的课随进度续排（③ 的下半截）
//
// ③ 做完了「一次排整条课」，但课是**静止**的：学员闯完了不会往下接，卡住了也不会降档。
// 本文件补的就是这一半 —— 由**闯关进度**决定这条课该不该再排一批、该不该降档。
//
// 三条硬边界：
//
// 1. **只追加，不重排已有节**。一节已存在的课被重排会换 id（`lessonID` 由 课id|序号|标题
//    推出），树上那一格连同学员攒的星一起消失 —— 那是把用户的成果当成可以随手覆盖的数据。
//    所以续排永远是在 `lessons` 后面接，序号接着往下编。
// 2. **降档只影响新排的这一批**。卡住了就往后排得简单一点，已有节的难度不动
//    （动它们等于把已经练过的内容换掉）。
// 3. 纯函数：不碰模型、不碰 IO。要不要排、排什么请求，全由入参决定，可单测。

/// 一条课被练到什么程度了。
public struct CourseProgressState: Sendable, Equatable {

    /// 这条课一共几节。
    public var total: Int
    /// 已经达标（完成、或星星够）的节数。
    public var completed: Int
    /// 练过但**没达标**的节数（卡住）。
    public var stuck: Int
    /// 还没动过的节数。
    public var untouched: Int

    public init(total: Int = 0, completed: Int = 0, stuck: Int = 0, untouched: Int = 0) {
        self.total = total
        self.completed = completed
        self.stuck = stuck
        self.untouched = untouched
    }

    /// 都闯完了（没闯完 / 一节都没有都算 false —— 空课不该催续排）。
    public var isAllDone: Bool { total > 0 && completed == total }
}

/// 续排的决定。
public enum CourseContinuationDecision: Sendable, Equatable {

    /// 别催：还有没练的节（催了就是让人跳着练）。
    case none
    /// 都闯完了 → 接着往下排。
    case advance
    /// 卡住了 → 接着排，但降一档。
    case easier

    /// UI 上那句话（`.none` 为 nil：没话说就不说）。
    public var title: String {
        switch self {
        case .none: ""
        case .advance: "都闯完了，接着排"
        case .easier: "卡住了，降一档接着排"
        }
    }
}

public enum CourseContinuationRule {

    /// 几节卡住就算「卡住了」。
    ///
    /// 定 2 而不是 1：一次没达标可能只是那天状态不好（或只是还没练完），
    /// 两节都拿不下来才是「这条课排难了」的证据。
    public static let stuckThreshold = 2

    // MARK: - 进度

    /// 这条课在树上那几格的真实状态。
    ///
    /// ⚠️ 走 `CourseTreeRule.levels(of:in:)` 这一个取数点：大树、面板、续排判据
    /// 必须看同一份「完成了没有」，各查一遍就会出现「树上显示完成、续排说没完成」。
    public static func progressState(
        of course: CourseBlueprint,
        in progress: LearnerProgress
    ) -> CourseProgressState {
        let levels = CourseTreeRule.levels(of: course, in: progress)
        let total = course.lessons.count
        var completed = 0
        var stuck = 0
        for level in levels {
            // 达标看两件事之一：状态是 `.completed`，或者星星已经够了
            // （`requiredStars` 是课程关卡自己的口径，别在这里另写 3）。
            if level.state == .completed || level.earnedStars >= level.requiredStars {
                completed += 1
            } else if level.state == .inProgress {
                stuck += 1
            }
        }
        return CourseProgressState(
            total: total,
            completed: completed,
            stuck: stuck,
            untouched: max(0, total - completed - stuck)
        )
    }

    /// 该不该接着排。
    ///
    /// 判据顺序：**卡住 > 全闯完 > 其余**。
    /// 卡住优先于「全闯完」是不可能的（全闯完就没有卡住的节），但反过来
    /// 「还有几节没动」必须**压过**「有几节卡住」—— 跳着排新内容只会让课断成两截。
    public static func decision(for state: CourseProgressState) -> CourseContinuationDecision {
        guard state.total > 0 else { return .none }
        if state.stuck >= stuckThreshold { return .easier }
        if state.isAllDone { return .advance }
        return .none
    }

    /// 进度的一句话说明（「6 节里有 2 节卡住了」）。
    ///
    /// 理由一律**带可核对的数字**（同 `AdaptivePath.reasons` 的纪律）：
    /// 「该续排了」是结论，用户要的是「凭什么」。
    public static func summary(for state: CourseProgressState) -> String {
        switch decision(for: state) {
        case .none:
            return "\(state.total) 节里闯完 \(state.completed) 节，还有 \(state.untouched) 节没动"
        case .advance:
            return "\(state.total) 节都闯完了"
        case .easier:
            return "\(state.total) 节里有 \(state.stuck) 节卡住了"
        }
    }

    /// 这条课该不该续排（UI 用它决定按钮出不出现）。
    public static func shouldContinue(
        _ course: CourseBlueprint,
        in progress: LearnerProgress
    ) -> Bool {
        decision(for: progressState(of: course, in: progress)) != .none
    }

    // MARK: - 续排请求

    /// 续排的请求（`.none` 返回 nil —— 不该排就别排）。
    ///
    /// - Parameters:
    ///   - base: 此刻的学员状态（排课四项依据，与第一次排课同源）。
    ///   - course: 要续的那条课。
    ///   - progress: 当前进度（只用来判该不该排、降不降档）。
    ///
    /// ⚠️ 档位取 `base.level ?? course.targetLevel`：续排时学员可能还没重新定位，
    /// 但这条课自己有目标档，拿它兜底 —— 否则「没定位过」的学员永远续不了排。
    /// ⚠️ 两个都不存在时（新学员 + 一条没档位的老课）返回 nil：没有难度依据排出来的
    /// 一节是瞎排（这与首次排课的 `inputIssue` 是同一条纪律）。
    public static func continuationRequest(
        base: CourseRequest,
        course: CourseBlueprint,
        progress: LearnerProgress
    ) -> CourseRequest? {
        let state = progressState(of: course, in: progress)
        let decision = self.decision(for: state)
        guard decision != .none else { return nil }

        let baseLevel = base.level ?? course.targetLevel
        guard baseLevel != nil || base.hasSignal else { return nil }

        let level = decision == .easier
            ? lowered(baseLevel) ?? baseLevel
            : baseLevel

        return CourseRequest(
            level: level,
            recurringErrors: base.recurringErrors,
            weakPhonemes: base.weakPhonemes,
            topics: base.topics,
            // 已经有了的几节原样报给模型 —— 不然它会把「点单」再排一遍，
            // 学员看到的是「续排排出了我已经练过的课」。
            avoidTitles: course.lessons.map(\.displayTitle)
        ).sanitized()
    }

    /// 降一档（A2 → A1）。已经是最低档就**原样返回**（不能再降，也不许返回 nil：
    /// 那样续排会整条消失，用户按了按钮却什么都没发生）。
    public static func lowered(_ level: CEFRLevel?) -> CEFRLevel? {
        guard let level else { return nil }
        let cases = CEFRLevel.allCases
        guard let index = cases.firstIndex(of: level), index > 0 else { return level }
        return cases[index - 1]
    }

    // MARK: - 追加

    /// 把新排的一批节接到这条课后面（**不动已有节**）。
    ///
    /// 三件事必须在这里一次做完，漏一件都会静默出问题：
    /// 1. **按标题去重**：模型看不见「你已经排过什么」，只知道 `avoidTitles` 里那串字；
    ///    它照样可能排出一个同名的节 —— 那对学员就是「续排排出了重复内容」。
    /// 2. **序号接着编**：从 `lessonCount + 1` 起，已有节的序号一个都不动。
    /// 3. **id 重算**：`id` 由「课 id + 序号 + 标题」推出，序号变了 id 就必须重算；
    ///    沿用旧 id 会撞上别的节（`StableFingerprint` 只保证不同输入不同输出）。
    public static func appending(
        _ lessons: [CourseLesson],
        to course: CourseBlueprint
    ) -> CourseBlueprint {
        var seen = Set(course.lessons.map { $0.displayTitle.lowercased() })
        var appended: [CourseLesson] = []
        var order = course.lessonCount

        for lesson in lessons {
            let key = lesson.displayTitle.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            order += 1
            // ⚠️ `CourseLesson.id` 与 `Scenario.id` 都是 `let`（id 由内容推出，不许随手改），
            // 所以这里是**整份重建**而不是就地赋值 —— 序号变了，id 就得跟着重算。
            let lessonID = CourseBlueprintRule.lessonID(
                courseID: course.id, order: order, title: lesson.title
            )
            appended.append(CourseLesson(
                id: lessonID,
                order: order,
                title: lesson.title,
                titleZh: lesson.titleZh,
                goal: lesson.goal,
                // 课内情景就是这一节本身：它的 id 必须换成新的，
                // 否则面板点进去查的是旧 id，大树认不出这一格。
                scenario: lesson.scenario.withID(lessonID),
                words: lesson.words
            ))
        }

        guard !appended.isEmpty else { return course }
        var result = course
        result.lessons.append(contentsOf: appended)
        return result
    }
}

// MARK: - 换 id 的副本

extension Scenario {

    /// 同一份情景、换个 id 的副本（续排重编序号时用）。
    ///
    /// `id` 是 `let`（由内容推出，不许就地改），所以要一份**新**值 ——
    /// 这里把其余字段原样搬过去，一个不落（漏一个就等于把那一节的内容改了）。
    func withID(_ newID: String) -> Scenario {
        Scenario(
            id: newID,
            title: title,
            titleZh: titleZh,
            category: category,
            difficulty: difficulty,
            level: level,
            objective: objective,
            aiRole: aiRole,
            learnerRole: learnerRole,
            opening: opening,
            targetVocabulary: targetVocabulary,
            targetGrammar: targetGrammar,
            targetSentences: targetSentences,
            mainQuest: mainQuest,
            questSteps: questSteps,
            maxTurns: maxTurns,
            correctionMode: correctionMode,
            icon: icon,
            origin: origin
        )
    }
}
