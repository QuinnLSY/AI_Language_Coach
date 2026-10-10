import XCTest

/// 自适应学习路径的**接线哨兵**：钉住三件「改代码时最容易悄悄丢掉」的事。
///
/// 都是**源码级**断言 —— 这三类缺陷（另算一遍数量、另查一次库、内容内联回页面）
/// 在渲染差分里看不出来，源码才是事实。
final class AdaptivePathWiringTests: XCTestCase {

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

    /// 数量必须**复用**计划那一侧已算好的口径，不许在这里再算一遍。
    ///
    /// 再多一处过滤，就会出现「计划卡说 3 处、建议卡说 2 处」——
    /// 用户看不出哪个对，只会觉得这个应用在瞎猜。
    func testCountsReuseThePlanSideSources() throws {
        let path = "Sources/AppUI/AppState+AdaptivePath.swift"
        let text = try source(path)

        XCTAssertTrue(text.contains("pendingErrorCount"), "\(path) 必须复用 pendingErrorCount")
        XCTAssertTrue(text.contains("dueVocabularyRemaining"), "\(path) 必须复用 dueVocabularyRemaining")

        for line in codeLines(text) where line.text.contains("conqueredErrorIDs") {
            XCTFail("\(path):\(line.number) 自己写了一遍「排除已攻克」—— 应改为复用 pendingErrorCount")
        }
    }

    /// 发音走势只许来自 `ProgressSnapshot`，不许自己查一次库。
    ///
    /// `shadowingAttempts(since:limit:)` 也在手边，但它要窗口与聚合口径，
    /// 在这里重算一遍等于给同一个「发音走势」开第二个真源。
    func testPronunciationTrendComesFromTheSnapshot() throws {
        let path = "Sources/AppUI/AppState+AdaptivePath.swift"
        let text = try source(path)

        XCTAssertTrue(
            text.contains("progressSnapshot.pronunciationTrend"),
            "\(path) 的发音序列必须来自 progressSnapshot.pronunciationTrend"
        )

        for line in codeLines(text) where line.text.contains("shadowingAttempts(") {
            XCTFail("\(path):\(line.number) 自己查了一次跟读记录 —— 应改为读 progressSnapshot")
        }
    }

    /// 动作映射只许复用计划那一侧已有的入口，不许开第二套。
    func testActionsReuseTheExistingEntry() throws {
        let path = "Sources/AppUI/AppState+AdaptivePath.swift"
        let text = try source(path)
        XCTAssertTrue(
            text.contains("performLearningPlanFocus"),
            "\(path) 必须复用 performLearningPlanFocus，别为同一件事开第二个动作入口"
        )
    }

    /// 建议卡的**内容只该有一份**：页面挂组件，不许把内容再复制回页面；
    /// 判定也不许搬进视图（挪进视图就再也测不到了）。
    func testCardContentLivesOnlyInTheComponent() throws {
        let pagePath = "Sources/AppUI/Views/LearningProgressView.swift"
        let page = try source(pagePath)

        XCTAssertTrue(page.contains("AdaptivePathCard("), "\(pagePath) 应当挂载 AdaptivePathCard")

        for line in codeLines(page) where line.text.contains("path.reasons") {
            XCTFail("\(pagePath):\(line.number) 又把建议内容内联回页面了 —— 内容只该住在 AdaptivePathCard 里")
        }
        for line in codeLines(page) where line.text.contains("AdaptivePathRule.evaluate") {
            XCTFail("\(pagePath):\(line.number) 判定搬进视图了 —— 只该住在 AdaptivePathRule / AppState 里")
        }

        // 组件本身必须真的画理由与下一步（防止「挂了个空壳」）。
        let component = try source("Sources/AppUI/Components/AdaptivePathCard.swift")
        XCTAssertTrue(component.contains("path.reasons"), "组件才是画依据的地方")
        XCTAssertTrue(component.contains("path.nextActions"), "组件才是画下一步的地方")
    }
}
