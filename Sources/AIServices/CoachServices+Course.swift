import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

// MARK: - CoachServices · AI 自动课程（③）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - AI 自动课程（③：由学员状态排出一条有序的课）

/// 已排好的课（按排课时间倒序）。
///
/// 走缓存而不是每次读盘：开情景面板要它、树上挂关卡也要它，而它在同步上下文里被调用
/// （同 `availableScenarios()` 的理由）。刷新的唯一入口是 `reloadCourses()`。
public func availableCourses() -> [CourseBlueprint] { courseCache }

/// 按 id 取一条课（不存在返回 nil）。
public func course(id: String) -> CourseBlueprint? { courseCache.first { $0.id == id } }

/// 重新读盘：已排的课与它们的课内情景**一起**换掉。
///
/// 调用点：开情景面板 / 排课成功 / 删除之后。
/// ⚠️ 两件必须一起刷：只刷课不刷情景，面板里那几节会消失、点进去也找不到；
/// 只刷情景不刷课，卡片上又会少一条课（`availableScenarios()` 与 `availableCourses()`
/// 就是靠这两份缓存对齐的）。
public func reloadCourses() async {
    let courses = await courseStore.all()
    courseCache = courses
    courseScenarioCache = courses.flatMap(\.scenarios)
}

/// 删除一条课（它那几节情景同时从面板与树上消失；已进词汇本的词**不回收** ——
/// 那已经是学员自己的词了）。
public func deleteCourse(id: String) async {
    await courseStore.delete(id: id)
    await reloadCourses()
}

/// 由学员状态排一条课：**一次请求排出整条**。
///
/// 不拆成「一节课一次请求」：一条课的**顺序**（由易到难、前后呼应）正是它的价值，
/// 分次生成时每节都看不见别节，顺序就丢了 —— 还得让用户等 N 趟、N 次之间更容易互相打架。
///
/// 失败一律抛错、**不落盘**：宁可让用户改个主题重排，也不能在树上留一条缺胳膊少腿的课 ——
/// 它会占掉一格，还会以「AI 排的课」的名义长期留在面板里。
public func generateCourse(_ request: CourseRequest) async throws -> CourseBlueprint {
    let course = try await requestBlueprint(request)
    try await courseStore.save(course)
    await reloadCourses()
    await addCourseWords(course)
    return course
}

/// 在这条课**后面接一批新的节**（已有节与它们的进度一个都不动）。
///
/// 与 `generateCourse` 共用同一条请求链路（一次请求排一批，失败零落盘），
/// 差别只有落盘这一步：这里是**追加**（`CourseContinuationRule.appending`），
/// 而不是另存一条新课 —— 另存的话树上会凭空多出一条课，学员还得自己找哪条是续的。
///
/// - Parameters:
///   - courseID: 要续的那条课。
///   - request: 续排请求（由 `CourseContinuationRule.continuationRequest` 产出，
///     里面带着「别再排这几节」与降档后的档位）。
public func continueCourse(_ courseID: String, request: CourseRequest) async throws -> CourseBlueprint {
    // 缓存里没有就回盘再找一次（缓存是「最近一次读盘」的快照，可能还没刷）。
    var existing = course(id: courseID)
    if existing == nil {
        existing = await courseStore.all().first { $0.id == courseID }
    }
    guard let existing else {
        throw AppError.unknown("这条课已经不在了（可能被删了）—— 刷新一下再试。")
    }
    let fresh = try await requestBlueprint(request)
    let merged = CourseContinuationRule.appending(fresh.lessons, to: existing)
    // 排出来的全是已有内容（模型没听进去「别重复」）→ 宁可不落盘：
    // 学员按了「续排」却一条都没多，比报错更难解释。
    guard merged.lessons.count > existing.lessons.count else {
        throw AppError.unknown("排出来的几节和已有内容重复了 —— 换个主题再试一次。")
    }
    try await courseStore.save(merged)
    await reloadCourses()
    // 只有**新排的**那几节的词进词汇本：已有节的词上次就收过了。
    await addCourseWords(merged, from: existing.lessons.count)
    return merged
}

/// 请求模型排一批课（**只请求与解析，不落盘**）。
///
/// 抽出来是为了让「排一整条」与「续排一批」共用同一条链路：
/// 两处各写一份的话，一边改了温度或解析判据，另一边迟早排出口径不一致的课。
private func requestBlueprint(_ request: CourseRequest) async throws -> CourseBlueprint {
    let clean = request.sanitized()
    if let issue = CourseBlueprintRule.inputIssue(for: clean) {
        throw AppError.unknown(issue.message)
    }
    guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
    try await ensureLLMReady()

    let configuration = await config.current
    let provider = await config.current.resolvedProvider(for: .llm)
    let llmRequest = LLMRequest(
        messages: [LLMMessage(role: .system, content: PromptBuilder.courseBlueprintPrompt(
            request: clean,
            learningLanguage: promptLanguage(configuration),
            nativeLanguage: configuration.product.nativeLanguage
        ))],
        model: await currentLLMModel(),
        // 与情景生成同一档（0.6）：排课是创作任务，要一点温度（同一份状态不该排出
        // 逐字一样的课），但不能飘 —— 排出来的每一节都要能直接拿去练。
        temperature: 0.6,
        maxTokens: min(provider?.maxTokens ?? 2048, 2048),
        streaming: false,
        reasoningEffort: LLMRequest.noThinkingEffort
    )
    let response = try await llm.generate(llmRequest)
    guard let course = CourseBlueprintRule.parse(response.text, request: clean) else {
        throw AppError.unknown(
            "没能排出一条完整可练的课（至少 \(CourseBlueprintRule.minimumLessons) 节，每节都要有"
                + "场景、开场白和 \(CourseBlueprintRule.minimumTargetSentences) 句以上目标句）——"
                + "换个主题或再试一次。"
        )
    }
    return course
}

/// 课内每一节的目标词进词汇本（`source: .scenario`）。
///
/// 一节课就是一次情景练习，它的词理应像情景的词一样被每日推荐的**生词档**接住 ——
/// 练过的词第二天再露一面，排课与词汇本才算真正闭上环。
///
/// - Parameter from: 从第几节开始收（续排时跳过已有节 —— 它们的词上次就收过了）。
private func addCourseWords(_ course: CourseBlueprint, from index: Int = 0) async {
    for lesson in course.lessons.dropFirst(max(0, index)) {
        for word in lesson.words {
            _ = await vocabulary.add(word: word.word, meaning: word.meaning, source: .scenario)
        }
    }
}

/// 「关卡 → 情景」绑定表（来自 `Resources/Levels/level_bindings.json`，不落库）。
///
/// 课程阶梯要靠它把关卡挂到 CEFR 档上：关卡自己不知道属于哪一档，
/// 是「它绑的那个情景的 level」决定的。资源缺失时返回空表（不瞎猜）。
public func levelBindings() -> [String: String] {
    LevelBindingCatalog.bundled()
}
}
