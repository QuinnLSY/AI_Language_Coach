import AppCore
@testable import AppUI
import XCTest

/// 批次三「氛围收尾」的纯函数与接线哨兵：
/// 学员配饰成长线（攒星换装）、时段问候三档、中间栏连胜飞鸟。
@MainActor
final class AtmosphereWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 源码的**非注释行**（`//` / `///` 开头的整行去掉）。
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            return (index + 1, line)
        }
    }

    /// 取出函数体：从 `needle` 起到下一个函数声明 / 存储属性 / 类型边界为止。
    private func body(of needle: String, in source: String) -> String {
        guard let range = source.range(of: needle) else { return "" }
        let rest = source[range.lowerBound...]
        let tail = rest.dropFirst(needle.count)
        let terminators = ["\n    public func ", "\n    private func ", "\n    func ",
                           "\n    public var ", "\n    private var ", "\n    private struct",
                           "\n    public nonisolated "]
        let ends = terminators.compactMap { tail.range(of: $0)?.lowerBound }
        if let end = ends.min() { return String(rest[..<end]) }
        return String(rest)
    }

    // MARK: - ① 配饰成长线（纯函数）

    /// 档位判据：0–5 红领巾、6–11 背包、12–17 望远镜、18+ 毕业帽；负数钳 0。
    func testAccessoryTiers() {
        XCTAssertEqual(StudentProgression.accessory(totalStars: 0), .student)
        XCTAssertEqual(StudentProgression.accessory(totalStars: 5), .student, "5 星还差一颗，别提前换装")
        XCTAssertEqual(StudentProgression.accessory(totalStars: 6), .studentBackpack)
        XCTAssertEqual(StudentProgression.accessory(totalStars: 11), .studentBackpack)
        XCTAssertEqual(StudentProgression.accessory(totalStars: 12), .studentTelescope)
        XCTAssertEqual(StudentProgression.accessory(totalStars: 17), .studentTelescope)
        XCTAssertEqual(StudentProgression.accessory(totalStars: 18), .studentGraduation)
        XCTAssertEqual(StudentProgression.accessory(totalStars: 999), .studentGraduation, "毕业帽就是顶了，不许有更高档")
        XCTAssertEqual(StudentProgression.accessory(totalStars: -3), .student, "负数钳到 0，照样从红领巾起步")
    }

    /// 「下一档还差几颗星」：最高档返回 nil（没有下一档也是一句可以说的话）。
    func testStarsToNextTier() {
        XCTAssertEqual(StudentProgression.starsToNextTier(totalStars: 0), 6)
        XCTAssertEqual(StudentProgression.starsToNextTier(totalStars: 5), 1, "就差一颗的期待感要说得准")
        XCTAssertEqual(StudentProgression.starsToNextTier(totalStars: 6), 6)
        XCTAssertEqual(StudentProgression.starsToNextTier(totalStars: 12), 6)
        XCTAssertNil(StudentProgression.starsToNextTier(totalStars: 18))
        XCTAssertNil(StudentProgression.starsToNextTier(totalStars: 100))
    }

    // MARK: - ② 时段问候（纯函数）

    /// 三档分界：[5,11) 早、[11,18) 下午、其余（含深夜 0–5）晚。
    func testPeriodGreetingTiers() {
        XCTAssertEqual(PeriodGreeting.line(hour: 5), PeriodGreeting.line(hour: 10), "5–10 同属早晨档")
        XCTAssertNotEqual(PeriodGreeting.line(hour: 10), PeriodGreeting.line(hour: 11), "11 点起换下午档")
        XCTAssertNotEqual(PeriodGreeting.line(hour: 17), PeriodGreeting.line(hour: 18), "18 点起换晚上档")
        XCTAssertEqual(PeriodGreeting.line(hour: 0), PeriodGreeting.line(hour: 3), "深夜归晚上档（还没睡呀的语气）")
        XCTAssertEqual(PeriodGreeting.line(hour: 23), PeriodGreeting.line(hour: 2))
        XCTAssertEqual(PeriodGreeting.line(hour: -1), PeriodGreeting.line(hour: 0), "越界钳回合法小时")
        XCTAssertEqual(PeriodGreeting.line(hour: 24), PeriodGreeting.line(hour: 0))
    }

    // MARK: - ③ 接线哨兵

    /// ⚠️ ChatView 是**手写 init**：新参数必须既进签名、又有显式赋值——
    /// 漏赋值不报错（属性有默认值，静默回落 .student/nil）。
    func testChatViewInitWiresTheNewAtmosphereParameters() throws {
        let chat = try source("AppUI/Views/ChatView.swift")
        let initBody = self.body(of: "public init(chat: ChatService", in: chat)
        XCTAssertFalse(initBody.isEmpty, "找不到 ChatView 手写 init")
        for (needle, why) in [("studentAccessory: AnimalAccessory = .student", "签名缺 studentAccessory"),
                              ("streakBadge: TodayPanel.StreakBadge? = nil", "签名缺 streakBadge"),
                              ("onOpenStreak: (() -> Void)? = nil", "签名缺 onOpenStreak"),
                              ("self.studentAccessory = studentAccessory", "漏赋值（静默回落默认值）"),
                              ("self.streakBadge = streakBadge", "漏赋值（静默回落默认值）"),
                              ("self.onOpenStreak = onOpenStreak", "漏赋值（静默回落默认值）")] {
            XCTAssertTrue(initBody.contains(needle), "ChatView 手写 init：\(why)")
        }
    }

    /// MainView 必须把三件氛围装进 ChatView（限定 ChatView( 调用体，避免别处假绿）。
    func testMainViewWiresAtmosphereIntoChatView() throws {
        let main = try source("AppUI/Views/MainView.swift")
        let call = self.body(of: "ChatView(", in: main)
        XCTAssertFalse(call.isEmpty, "找不到 ChatView 装配")
        XCTAssertTrue(call.contains("studentAccessory: state.studentAccessory"), "学员配饰没走成长线")
        XCTAssertTrue(call.contains("streakBadge: state.streakBadgeForChat"), "连胜飞鸟没接数据")
        XCTAssertTrue(call.contains("onOpenStreak: { state.requestOpenAnnualRecap() }"), "飞鸟没接跳转")
    }

    /// AppState 的配饰档位必须走 `StudentProgression`（判据只此一份），
    /// 连胜数据必须与侧栏同源（`TodayPanel.streakBadge`）。
    func testAppStateIsTheSingleSourceForBothAtmosphereFeeds() throws {
        let appState = try source("AppUI/AppState.swift")
        let accessory = self.body(of: "public var studentAccessory", in: appState)
        XCTAssertTrue(accessory.contains("StudentProgression.accessory(totalStars: progress.totalStars)"),
                      "配饰档位必须从 StudentProgression 算（不许另写第二份判据）")
        let badge = self.body(of: "public var streakBadgeForChat", in: appState)
        XCTAssertTrue(badge.contains("TodayPanel.streakBadge("), "连胜数据必须与侧栏同源")
    }

    /// 树上学员与空态问候也要接上：树上配饰走 StudentProgression，空态走三档问候。
    func testTreeLearnerAndEmptyHintUseTheNewCopy() throws {
        let tree = try source("AppUI/Components/TreeCanvas.swift")
        XCTAssertTrue(tree.contains("StudentProgression.accessory(totalStars: progress.totalStars)"),
                      "树上学员的配饰没走成长线")
        let chat = try source("AppUI/Views/ChatView.swift")
        let hint = self.body(of: "private var emptyHint", in: chat)
        XCTAssertTrue(hint.contains("PeriodGreeting.emptyStateLines(hour:"), "空态问候没走三档文案")
    }

    /// 连胜飞鸟的动效预算（设计拍板：全场最低）：允许**一次性**扑翅，
    /// 但绝不允许出现循环动画（repeatForever / Timer 常驻）。
    func testStreakBirdHasNoLoopingAnimation() throws {
        let bird = codeLines(try source("AppUI/Components/StreakBirdBadge.swift"))
        for line in bird {
            XCTAssertFalse(line.text.contains("repeatForever"), "连胜飞鸟不许有循环动画")
            XCTAssertFalse(line.text.contains("Timer.publish"), "连胜飞鸟不许挂常驻定时器")
        }
        XCTAssertTrue(bird.contains { $0.text.contains("onChange(of: badge.days)") }, "扑翅必须由「连胜 +1」触发")
    }
}
