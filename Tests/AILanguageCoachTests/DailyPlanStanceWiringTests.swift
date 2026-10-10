import XCTest

/// 「stance 真的进了安排」的**接线哨兵**。
///
/// `DailyPlanner.plan` 的 `stance:` 是**带默认值**的新参数 —— 这正是最容易出事的一种：
/// 接好了但没人传，编译照样过、测试照样绿，功能却是惰性的（⑤ 刚犯过一次：
/// stance 只有一个读点，因为压根没有地方把它传进安排）。源码才是事实，所以这里钉源码。
final class DailyPlanStanceWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    /// 生产侧每一处 `DailyPlanner.plan(` 都必须显式传 `stance:`。
    ///
    /// 漏传 = 走默认 `.observing` = 自适应永远不改安排，只剩建议卡在动 —— 说了不做。
    func testEveryProductionPlanCallPassesStance() throws {
        let candidates = [
            "Sources/AppUI/AppState.swift",
            "Sources/AppUI/AppState+Blackboard.swift",
        ]
        for path in candidates {
            let text = try source(path)
            let calls = text.split(separator: "DailyPlanner.plan(").dropFirst()
            XCTAssertFalse(calls.isEmpty, "\(path) 里应当有 DailyPlanner.plan 调用（路径变了就改这里）")
            for call in calls {
                // 只看这次调用到收尾括号之间的一段，别被文件里别处的 `stance:` 蒙过去。
                let body = String(call.prefix(400))
                XCTAssertTrue(body.contains("stance:"),
                              "\(path) 的 DailyPlanner.plan 调用没传 stance: —— 自适应不会改安排")
            }
        }
    }

    /// 两处必须传**同一个** stance：高水位是从那份计划里抬出来的，
    /// 一个传一个不传的话，「今天已聊 N 轮」会与卡片上的目标对不上。
    func testBothCallSitesUseTheSameStanceSource() throws {
        for path in ["Sources/AppUI/AppState.swift", "Sources/AppUI/AppState+Blackboard.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("stance: adaptivePath.stance"),
                          "\(path) 必须传 adaptivePath.stance（别另取一个档位）")
        }
    }

    /// 一轮复习的张数也必须跟着 stance 走：每日任务说「多复习」，点进去却还是老张数，
    /// 等于两个地方各说一套。
    func testReviewSessionLimitFollowsStance() throws {
        let path = "Sources/AppUI/AppState+Vocabulary.swift"
        let text = try source(path)
        XCTAssertTrue(text.contains("DailyPlanTuningRule.tuning(for: adaptivePath.stance)"),
                      "\(path) 开一轮复习时必须按 stance 取张数上限")
    }

    /// 微调的理由只许在**任务卡**里出现一次，不许塞回每一项任务的 reason。
    func testTuningNoteIsRenderedOnceByTheCard() throws {
        let card = try source("Sources/AppUI/Components/DailyTasksCard.swift")
        XCTAssertTrue(card.contains("plan.tuningNote"), "任务卡必须把「为什么今天量不一样」显示出来")
        XCTAssertTrue(card.contains("tuningRow"), "理由单独成行，不并进每一项的 reason")

        // 排计划那一侧：只有真的改了量才给理由。
        let planner = try source("Sources/AIDomain/DailyPlan.swift")
        XCTAssertTrue(planner.contains("tuning.isIdentity ? nil : tuning.note"),
                      "没调量就不给理由 —— 恒等微调带一句话只会让人以为计划是随机的")
    }
}
