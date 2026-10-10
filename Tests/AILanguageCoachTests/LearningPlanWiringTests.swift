import XCTest

/// 学习计划的**接线哨兵**：钉住两件「改代码时最容易悄悄丢掉」的事。
///
/// 都是**源码级**断言 —— 这两类的缺陷（复用了别的真源 / 视图树多出一根线）
/// 在渲染差分里看不出来，源码才是事实。
final class LearningPlanWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    /// 去掉整行注释后的 (行号, 文本) —— 注释里提到旧写法不该让哨兵报红。
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, raw in
                let line = String(raw)
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
                return (index + 1, line)
            }
    }

    /// 计划的「还没练掉的错」必须**复用** `ErrorDrillSession.queue` ——
    /// 记忆卡、改错练习、学习计划三处必须报同一个数。
    /// 一旦有人在这里自己写一遍过滤，三处就会各说各的（这正是本轮要避免的双真源）。
    func testPendingErrorsReuseTheDrillQueue() throws {
        let path = "Sources/AppUI/AppState+LearningPlan.swift"
        let text = try source(path)

        XCTAssertTrue(
            text.contains("ErrorDrillSession.queue("),
            "\(path) 必须复用 ErrorDrillSession.queue 来算待练错题"
        )

        for line in codeLines(text) where line.text.contains("conqueredErrorIDs.contains") {
            XCTFail("\(path):\(line.number) 自己写了一遍「排除已攻克」—— 应改为复用 ErrorDrillSession.queue")
        }
    }

    /// 计划卡的**内容只该有一份**：页面挂组件，不许把内容再复制回页面。
    /// 第二份配方一定会与第一份漂移（这正是把内容提取成 `LearningPlanCard` 的原因）。
    func testPlanCardContentLivesOnlyInTheComponent() throws {
        let pagePath = "Sources/AppUI/Views/LearningProgressView.swift"
        let page = try source(pagePath)

        XCTAssertTrue(
            page.contains("LearningPlanCard("),
            "\(pagePath) 应当挂载 LearningPlanCard"
        )

        for line in codeLines(page) where line.text.contains("plan.stage.focus") {
            XCTFail("\(pagePath):\(line.number) 又把计划内容内联回页面了 —— 内容只该住在 LearningPlanCard 里")
        }

        // 组件本身必须存在且含有重点行（防止「挂了个空壳」）。
        let component = try source("Sources/AppUI/Components/LearningPlanCard.swift")
        XCTAssertTrue(component.contains("ForEach(plan.stage.focus)"), "组件才是画重点行的地方")
    }
}
