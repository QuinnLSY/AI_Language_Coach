import AIDomain
import AIServices
import Foundation

// MARK: - AppState · AI 自动课程（③）
//
// 排课的**四项依据**全部来自 AppState 已有的真源，这里只做「取真源 → 组装请求」，
// **不重算任何一个**（同 `LearningPlanner` 的纪律）：
//
//   档位     → `placementEstimate.level`（`PlacementEstimator` 派生；样本不足时它自己就是 nil）
//   反复错   → `learningMemory.recurringErrors`（学习记忆里**还没练掉**的那些）
//   顽固音素 → `phonemeWeaknesses`（`PhonemeWeaknessAnalyzer` 派生）
//   自填主题 → `courseTopicDraft`（排课浮层里现写）
//
// 与「改错练习 / 顽固音素专项」的关系：那两样是**单点补漏**（一次练一个错处），
// 这里是把它们**排成一条有序的路线**。所以三处必须读同一份队列 ——
// 各筛一遍的话，计划里说「3 处反复错」，排出来的课却照着另外几处排。

extension AppState {

    /// 主题输入的分隔符：中英文逗号 / 顿号 / 分号 / 换行都算「下一个主题」。
    ///
    /// 按用户自己的习惯敲（「面试, 咖啡店」与「面试、咖啡店」不该有区别）。
    static let courseTopicSeparators = CharacterSet(charactersIn: ",，、;；\n")

    /// 输入框里那行文字拆出来的主题列表。
    var courseTopics: [String] {
        courseTopicDraft
            .components(separatedBy: Self.courseTopicSeparators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 当前学员状态拼成的排课请求（已清洗）。
    ///
    /// ⚠️ 反复错取 `recurringErrors`，**不另外筛一遍**：那一份本身就是「攒够次数、还没练掉」的口径，
    /// 与「改错练习」用的是同一个队列。
    /// ⚠️ 反复错写成「原句 → 改对的样子」：只给一个错处代号，模型不知道该改什么。
    public var courseRequest: CourseRequest {
        CourseRequest(
            level: placementEstimate.level,
            recurringErrors: learningMemory.recurringErrors.map { "\($0.original) → \($0.corrected)" },
            weakPhonemes: phonemeWeaknesses.map(\.display),
            topics: courseTopics
        ).sanitized()
    }

    /// 现在有没有可排课的依据（UI 用它决定「开始排课」是否可点、以及提示哪来的）。
    public var canComposeCourse: Bool { courseRequest.hasSignal }

    // MARK: - 取数与浮层

    /// 取一遍已排的课（开情景面板 / 排课成功 / 删除之后都调它）。
    ///
    /// ⚠️ **没有** `didLoadScenarios` 那种「已加载」守卫：课会随排课与删除实时变，
    /// 加个守卫就会出现「刚排完课，面板里没有」—— 与 `loadScenarios` 那个坑同一个形状
    /// （见 `reloadScenarios()` 的注释）。
    public func loadCourses() async {
        await refreshScenarioCatalog()
    }

    /// 把「自建情景 + AI 课程」并进服务目录，再取一遍面板要用的那两份列表。
    ///
    /// ⚠️ 顺序不能反：先取列表再并目录，首次进页面就既看不到「我的情景」，
    /// AI 排的课那几节更是点不进去（`scenario(id:)` 查不到）。
    /// ⚠️ 两份列表必须**一起**取：它们来自服务层同一次读盘（课与课内情景换在同一个函数里），
    /// 分两次取就会出现「卡片上是课、点进去却不是它的情景」。
    func refreshScenarioCatalog() async {
        await services.reloadCustomScenarios()
        await services.reloadCourses()
        scenarios = await services.availableScenarios()
        courses = await services.availableCourses()
        await syncCourseLevels()
    }

    /// 把课内情景挂成大树上的关卡（③），并把结果落库。
    ///
    /// ⚠️ **必须排在 `services.loadProgress()` 之后**：
    /// `LearnerProgress.applyScenarioBindings` 会把所有关卡的 `scenarioID` 覆盖成绑定表里的值
    /// （表里没有就是 nil），而 `scenario_id` **不在 `levels` 表里** —— 顺序反了，
    /// 课程关卡永远点不进去（`level(boundToScenario:)` 查不到）。
    ///
    /// ⚠️ 合并后要落库：关卡行在 `levels` 表里，不落库星星重启就没了；
    /// 而 `scenarioID` 不在表里，下次读回来由这里重新挂上（幂等）。
    func syncCourseLevels() async {
        let merged = CourseTreeRule.merge(progress: progress, courses: courses)
        guard merged.levels != progress.levels else { return }
        progress = merged
        await services.saveProgress(progress)
    }

    /// 打开「排一条课」浮层：**先把面板开起来再去取数**。
    ///
    /// ⚠️ 顺序与 `openScenarios()` 一致（2026-09-29 用户报障「点击数次才弹框」）：
    /// 先 await 再开面板的话，读盘一慢用户就觉得「点了没反应」，再点几下才碰巧等到它开。
    public func openCourseComposer() async {
        courseResult = nil
        lastGeneratedCourse = nil
        showingCourseComposer = true
        await loadCourses()
    }

    public func closeCourseComposer() {
        showingCourseComposer = false
        courseResult = nil
        lastGeneratedCourse = nil
    }

    public func dismissCourseResult() {
        courseResult = nil
    }

    // MARK: - 排课 / 删除

    /// 排一条课：一次排课 = 一次模型请求（**一次排出整条**，顺序是这条课的价值所在）。
    public func generateCourseFromState() async {
        guard !isGeneratingCourse else { return }
        courseResult = nil
        lastGeneratedCourse = nil
        isGeneratingCourse = true
        defer { isGeneratingCourse = false }
        do {
            let course = try await services.generateCourse(courseRequest)
            lastGeneratedCourse = course
            await loadCourses()
            let first = course.lessons.first?.displayTitle ?? ""
            courseResult = "排好了：「\(course.displayTitle)」（\(course.summary)）"
                + (first.isEmpty ? "" : "，从「\(first)」开始")
                + "。目标词已收进词汇本。"
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            courseResult = reason
        }
    }

    /// 删除一条课（它那几节同时从面板与树上消失；已进词汇本的词不回收 —— 那已经是学员自己的词了）。
    public func deleteCourse(id: String) async {
        await services.deleteCourse(id: id)
        await loadCourses()
    }

    /// 从一个情景反查它属于哪条课（不属于任何课返回 nil）。
    ///
    /// 情景卡片与大树都要用它：课内情景**不提供单节删除**（删一节会让课断成两截，
    /// 进度也接不上），删除入口只挂在整条课上 —— 判定走 `Scenario.origin`（数据），
    /// 不拿分组名比较。
    public func course(containing scenarioID: String) -> CourseBlueprint? {
        courses.first { $0.lessons.contains { $0.id == scenarioID } }
    }
}
