import XCTest

/// #595「学习记忆单条可控」的**接线哨兵**。
///
/// 这件功能的失效方式很安静：卡片两个回调有**默认空实现**，页面忘了传就成了
/// 「按钮都在、点了什么都没发生」—— 渲染差分看不出来，源码才是事实。
/// 所以这里钉的都是**调用形态整串**，不是出现次数。
final class LearningMemoryControlWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    /// 截出某个方法的全体（到下一个 `public func` 或文件尾为止）。
    private func body(of method: String, in text: String) -> String {
        guard let start = text.range(of: method) else { return "" }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "public func ") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    /// 页面必须把两个动作传给记忆卡（默认空实现 = 按钮点了没反应）。
    func testRecordsViewPassesRowActionsToTheCard() throws {
        let text = try source("Sources/AppUI/Views/RecordsView.swift")
        XCTAssertTrue(
            text.contains("onForget: { error in"),
            "RecordsView 必须把「忘记这一处」接进记忆卡 —— 回调有默认空实现，忘了传就是静默失效"
        )
        XCTAssertTrue(
            text.contains("state.editRecurringError(error, corrected: corrected, explanation: explanation)"),
            "RecordsView 必须把「修改这一处」接进记忆卡"
        )
    }

    /// 卡片必须真的把回调接到行内按钮上（不是挂了参数不用）。
    func testCardForwardsActionsFromTheRow() throws {
        let text = try source("Sources/AppUI/Components/LearningMemoryCard.swift")
        XCTAssertTrue(
            text.contains("Task { await onForget(error) }"),
            "行内删除键必须调 onForget（整串钉住：Task + await + 实参）"
        )
        XCTAssertTrue(
            text.contains("Task { await onEdit(error, draftCorrected, draftExplanation) }"),
            "编辑态的保存必须调 onEdit（整串钉住：两份草稿都要传出去）"
        )
    }

    /// AppState 两个动作必须委派给服务层，且成功后重算记录页 ——
    /// 「删掉的东西在任何一页还看得见」是本功能最可见的败笔，
    /// 而 `loadRecords()` 内部会一并刷新记忆卡与错题本（同源）。
    func testAppStateDelegatesAndRefreshes() throws {
        let text = try source("Sources/AppUI/AppState+ExamMode.swift")

        let forget = body(of: "public func forgetRecurringError", in: text)
        XCTAssertTrue(
            forget.contains("try await services.forgetRecurringError(error)"),
            "忘记必须走服务层（guard 学习库在那层，UI 不碰数据库）"
        )
        XCTAssertTrue(
            forget.contains("await loadRecords()"),
            "忘记成功后必须重算记录页：记忆卡与错题本都要跟着变"
        )

        let edit = body(of: "public func editRecurringError", in: text)
        XCTAssertTrue(
            edit.contains("try await services.editRecurringError(error, corrected: corrected, explanation: explanation)"),
            "修改必须走服务层，且三个参数原样透传"
        )
        XCTAssertTrue(
            edit.contains("await loadRecords()"),
            "修改成功后必须重算记录页"
        )
    }

    /// 服务层这两个写路径**不许 `try?`**：绕开错误上抛就等于
    /// 「失败了也当成功」，提示条永远不亮（用户成果类写入的铁律）。
    func testServiceWritePathsNeverSwallowErrors() throws {
        let text = try source("Sources/AIServices/CoachServices.swift")

        let forget = body(of: "public func forgetRecurringError", in: text)
        XCTAssertTrue(forget.contains("guard let learning else { throw AppError.database(\"学习库尚未就绪\") }"),
                      "忘记前必须守卫学习库，库没就绪要抛错而不是静默返回 0")
        XCTAssertFalse(forget.contains("try?"), "忘记路径不许 try? 吞错")

        let edit = body(of: "public func editRecurringError", in: text)
        XCTAssertFalse(edit.contains("try?"), "修改路径不许 try? 吞错")
    }
}
