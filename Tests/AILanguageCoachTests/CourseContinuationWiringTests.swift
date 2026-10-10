import XCTest

/// 续排的**接线哨兵**。
///
/// 续排最容易做歪的两处，渲染差分都看不出来，只能钉源码：
/// 一是把「追加」写成「另存一条新课」（树上凭空多一条课），
/// 二是 AppState 自己拼一份请求（漏掉「别再排这几节」→ 模型把练过的课再排一遍）。
final class CourseContinuationWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    /// 服务层必须是**追加**、不是另存：`save` 的得是合并后的那条课。
    func testServiceAppendsInsteadOfSavingANewCourse() throws {
        let text = try source("Sources/AIServices/CoachServices.swift")
        XCTAssertTrue(text.contains("CourseContinuationRule.appending"),
                      "续排必须走 appending（追加），另存一条新课会让树上凭空多一条")
        XCTAssertTrue(text.contains("try await courseStore.save(merged)"),
                      "落盘的必须是合并后的那条课，不是刚排出来的一批")
    }

    /// 排新课与续排共用同一条请求链路：各写一份的话，一边改了解析判据另一边迟早不一致。
    func testBothPathsShareOneRequestPipeline() throws {
        let text = try source("Sources/AIServices/CoachServices.swift")
        XCTAssertTrue(text.contains("try await requestBlueprint(request)"),
                      "两处都得走 requestBlueprint")
        // 只有一处 save 在 generateCourse 里（排新课），续排那处是自己那份 merged。
        XCTAssertLessThanOrEqual(
            text.components(separatedBy: "courseStore.save(").count - 1, 2,
            "落盘点又多了：续排与排新课应当各只落一次"
        )
    }

    /// 只有**新排的**那几节的词进词汇本：已有节的词上次就收过了。
    func testOnlyNewWordsGoToTheVocabularyBook() throws {
        let text = try source("Sources/AIServices/CoachServices.swift")
        XCTAssertTrue(text.contains("addCourseWords(merged, from: existing.lessons.count)"),
                      "续排只收新节的词，重复收会把词汇本灌水")
        XCTAssertTrue(text.contains("addCourseWords(course)"), "排新课则整条收")
    }

    /// AppState 的请求必须由规则产出（里面带着「别再排这几节」与降档后的档位）。
    func testAppStateAsksTheRuleForTheRequest() throws {
        let text = try source("Sources/AppUI/AppState+Course.swift")
        XCTAssertTrue(text.contains("CourseContinuationRule.continuationRequest("),
                      "不许在这里自己拼一份请求 —— 会漏掉 avoidTitles")
        XCTAssertTrue(text.contains("CourseContinuationRule.shouldContinue"),
                      "该不该续排只有一个判据来源")
    }

    /// 续排入口挂在排课浮层上，且只在「真的该续」时出现。
    func testContinuationEntryLivesOnTheComposer() throws {
        let text = try source("Sources/AppUI/Views/CourseComposerSheet.swift")
        XCTAssertTrue(text.contains("state.coursesAwaitingContinuation"),
                      "入口必须读 AppState 派生好的那份，不在视图里再筛一遍")
        XCTAssertTrue(text.contains("state.continueCourse(id: course.id)"), "按钮得真的接上动作")
    }
}
