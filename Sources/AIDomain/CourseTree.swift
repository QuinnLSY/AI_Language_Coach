import Foundation

// MARK: - AI 课程在大树上的位置（③）
//
// 用户口径（2026-10-10）：AI 排的课**挂到大树上**，但要与正文（内置情景）关卡
// **一眼看得出不同**；星星与正文**同权**计入总星数与爬树进度。
//
// 三条硬约束（都是踩过才知道的）：
//
// 1. **高度 > 1 就表示「正文之上」**：内置 8 关占 0.06…0.92，课程那几节从 1.08 起排，
//    几何上不可能与它们重叠；画布高度跟着 `canvasTopFraction` 一起长。
//    ⚠️ 用**高度**当来源标识、而不是 id 前缀 —— 前缀是约定，改一次就静默失效，
//    而它决定的是「这一格删不删得掉」。
// 2. **关卡行要落库**（`levels` 表），否则星星重启就没了；但 `scenarioID` **不在表里**，
//    `loadProgress()` 读回来是 nil，所以每次都要由 `merge` 重新挂回去。
//    ⚠️ 而 `LearnerProgress.applyScenarioBindings` 会把**所有**关卡的 `scenarioID`
//    覆盖成绑定表里的值（表里没有就是 nil）—— 顺序必须「先绑定、再 merge」，
//    反过来课程关卡永远点不进去。
// 3. **高度按所有课一起编号**：多条课各自从 1.08 起会叠在同一高度上；
//    先拍平成一棵序列再发高度，两条课自然一前一后（旧课在下、新课紧贴树冠）。

/// 纯函数：把已排的课并进大树关卡表。
public enum CourseTreeRule {

    /// 正文最高那一关（0.92）之上，课程第一格的高度 —— 中间留一格呼吸位。
    public static let firstCourseHeight = 1.08
    /// 相邻两格的高度差（与内置关卡的 0.12 步长同量级，视觉密度一致）。
    public static let heightStep = 0.12
    /// 每一节要几颗星（与内置关卡同口径：说满轮次 3 星）。
    public static let requiredStars = 3

    /// 一节课在树上的关卡 id。
    ///
    /// 由**节 id** 推出（不是由「第几条课、第几节」推出）：重排后同一节课还是同一格，
    /// 已经攒的星、已完成的状态全部接得上。
    public static func levelID(for lessonID: String) -> String {
        StableFingerprint.hex(prefix: "course-level", of: lessonID)
    }

    /// 第 `index` 格（0 起）的高度。
    public static func height(index: Int) -> Double {
        firstCourseHeight + heightStep * Double(max(index, 0))
    }

    /// 左右交错（与内置一致，节点不会全挤在一侧）。
    public static func branch(index: Int) -> TreeLevel.BranchSide {
        index % 2 == 0 ? .left : .right
    }

    /// 画布要画到多高（正文那一段是 1.0）。
    ///
    /// ⚠️ **没有课程关卡时必须返回 1.0**：树的滚动锚点与开屏定位都读它，
    /// 差一点点学员就会被定位到半空（那组算式有测试钉着）。
    public static func canvasTopFraction(_ progress: LearnerProgress) -> Double {
        let top = progress.levels.map(\.heightFraction).max() ?? 1
        return max(1, top + 0.08)
    }

    /// 把所有已排的课并进关卡表（纯函数）。
    ///
    /// - Parameters:
    ///   - progress: 刚读完的进度（**必须已经跑过 `applyScenarioBindings`**）。
    ///   - courses: 已排的课（按排课时间倒序或正序都行，这里自己按时间排）。
    /// - Returns: 并进课程关卡、并重算过总星数与爬树百分比的进度。
    ///
    /// 幂等：同一份输入跑两次得到同一份输出（每次都从传入的 `progress` 重算，
    /// 不在上一份结果上叠加）—— 启动、生成之后、删课之后都要调它，三处口径必须一致。
    public static func merge(
        progress: LearnerProgress,
        courses: [CourseBlueprint]
    ) -> LearnerProgress {
        var result = progress

        // 拍平：旧课在下、新课紧贴树冠（用户刚排的那条一眼就在最高处）。
        let slots = courses
            .sorted { $0.createdAt < $1.createdAt }
            .flatMap { course in course.lessons.sorted { $0.order < $1.order }.map { (course, $0) } }
        let wanted = Set(slots.map { levelID(for: $0.1.id) })

        // 课被删掉 / 重排后少了一节 → 那一格从树上撤掉。
        // 判据是高度（`isAboveCurriculum`），不是 id 前缀。
        result.levels.removeAll { $0.isAboveCurriculum && !wanted.contains($0.id) }

        var indexByID = Dictionary(uniqueKeysWithValues: result.levels.indices.map { (result.levels[$0].id, $0) })
        for (index, slot) in slots.enumerated() {
            let (course, lesson) = slot
            let id = levelID(for: lesson.id)
            let height = height(index: index)
            let side = branch(index: index)
            if let at = indexByID[id] {
                // 已在树上（重排 / 重启读回来的）：**只换位置与文案，星星与状态留着**。
                result.levels[at].title = lesson.displayTitle
                result.levels[at].subtitle = course.displayTitle
                result.levels[at].heightFraction = height
                result.levels[at].branch = side
                result.levels[at].scenarioID = lesson.id
            } else {
                result.levels.append(TreeLevel(
                    id: id,
                    title: lesson.displayTitle,
                    subtitle: course.displayTitle,
                    heightFraction: height,
                    branch: side,
                    // ⚠️ 初始态是 `.unlocked` 而不是 `.inProgress`：
                    // `LearnerProgress.currentLevelID` 取的是「第一个 `.inProgress`」，
                    // 课程关卡插在末尾本来无害，可一旦它自称「正在学」，
                    // 树上高亮与开屏定位就会从正文那一格跳到树冠之上。
                    state: .unlocked,
                    requiredStars: requiredStars,
                    earnedStars: 0,
                    scenarioID: lesson.id
                ))
                indexByID[id] = result.levels.count - 1
            }
        }

        // 星星与正文同权：课程那几节也进总星数与爬树百分比（用户口径）。
        result.recalculateSummary()
        return result
    }

    /// 这一条课在树上的几格（面板与树都要用同一个取数点）。
    public static func levels(of course: CourseBlueprint, in progress: LearnerProgress) -> [TreeLevel] {
        course.lessons.compactMap { lesson in
            progress.levels.first { $0.id == levelID(for: lesson.id) }
        }
    }
}
