import AIDomain
import XCTest

/// ⑦-B③ 盲盒情景的**领域层**：入池判据 + 抽签规则 + 文案。
///
/// 钉的是三条会静默失效的规则：
/// - 连点「换一个」**绝不能**抽回刚抽过的那个（抽回去，用户只会以为按钮坏了）；
/// - 同样的入参**必须**抽出同一个（不能复现的随机，测试只能靠「跑一百次」来验，那种测试永远绿）；
/// - 「没练过的优先」是**优先**不是**排除** —— 全练过了得回到整池，否则按钮就死了。
final class ScenarioBlindBoxTests: XCTestCase {

    // MARK: - 入池

    func testEmptyScenariosLeaveAnEmptyPool() {
        XCTAssertTrue(ScenarioBlindBox.entries(from: []).isEmpty)
    }

    /// 课内情景不进池：它们在课卡里逐节列着，面板上没有对应的散装卡片，抽到也滚不过去。
    func testCourseScenariosStayOutOfThePool() {
        let pool = ScenarioBlindBox.entries(from: [
            Self.scenario(id: "a"),
            Self.scenario(id: "b", origin: .course)
        ])
        XCTAssertEqual(pool.map(\.id), ["a"])
    }

    /// 正在练的那个不进池：它已经在练了，抽到它等于原地不动。
    func testActiveScenarioStaysOutOfThePool() {
        let pool = ScenarioBlindBox.entries(from: [
            Self.scenario(id: "a"), Self.scenario(id: "b")
        ], activeID: "a")
        XCTAssertEqual(pool.map(\.id), ["b"])
    }

    func testEmptyIDNeverEntersThePool() {
        let pool = ScenarioBlindBox.entries(from: [Self.scenario(id: "")])
        XCTAssertTrue(pool.isEmpty, "id 为空的素材没法滚、也没法开练")
    }

    func testDuplicateIDsKeepTheFirst() {
        let pool = ScenarioBlindBox.entries(from: [
            Self.scenario(id: "a", titleZh: "第一个"),
            Self.scenario(id: "a", titleZh: "第二个")
        ])
        XCTAssertEqual(pool.count, 1)
        XCTAssertEqual(pool.first?.title, "第一个", "留后面那条等于让调用方的排序静默失效")
    }

    /// 没写母语标题（用户自建素材常这样）→ 退成学习语言标题，别开出个空名字。
    func testTitleFallsBackToTheLearningTitle() {
        let pool = ScenarioBlindBox.entries(from: [
            Self.scenario(id: "a", title: "Airport Check-in", titleZh: "")
        ])
        XCTAssertEqual(pool.first?.title, "Airport Check-in")
    }

    // MARK: - 抽：连点必换

    /// 连点 30 次，每一次都不得是上一次那个。
    ///
    /// 这条是盲盒的命：抽回同一个，用户看到的是「我点了，它没动」。
    func testNeverPicksTheOneJustSeen() {
        let pool = Self.pool(ids: ["a", "b", "c", "d"])
        var last: String?
        for roll in 0..<30 {
            guard let picked = ScenarioBlindBox.pick(from: pool, avoiding: last, roll: roll) else {
                return XCTFail("第 \(roll) 次抽不出来")
            }
            XCTAssertNotEqual(picked.id, last, "第 \(roll) 次抽回了刚抽过的那个")
            last = picked.id
        }
    }

    /// 池里只有一条：认了，就是它（返回 nil 会让按钮变成死的，那更糟）。
    func testOnlyOneCandidateAlwaysReturnsIt() {
        let pool = Self.pool(ids: ["only"])
        XCTAssertEqual(ScenarioBlindBox.pick(from: pool, avoiding: nil, roll: 0)?.id, "only")
        XCTAssertEqual(ScenarioBlindBox.pick(from: pool, avoiding: "only", roll: 7)?.id, "only")
    }

    func testEmptyPoolPicksNothing() {
        XCTAssertNil(ScenarioBlindBox.pick(from: [], avoiding: nil, roll: 0))
    }

    // MARK: - 抽：可复现

    /// 同样的入参必须抽出同一个 —— 随机不可复现，测试就只能靠「跑一百次看看」。
    func testSameInputsPickTheSameOne() {
        let pool = Self.pool(ids: ["a", "b", "c", "d", "e"])
        let first = ScenarioBlindBox.pick(from: pool, avoiding: "a", roll: 3)
        let second = ScenarioBlindBox.pick(from: pool, avoiding: "a", roll: 3)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertNotNil(first)
    }

    /// roll 递增要真的换序列：20 次里至少开出 3 个不同的（否则「换一个」名不副实）。
    func testRollChangesThePick() {
        let pool = Self.pool(ids: ["a", "b", "c", "d", "e", "f"])
        var seen: Set<String> = []
        for roll in 0..<20 {
            guard let picked = ScenarioBlindBox.pick(from: pool, avoiding: nil, roll: roll) else { continue }
            seen.insert(picked.id)
        }
        XCTAssertGreaterThan(seen.count, 2, "20 次只开出 \(seen.count) 个：换一个没在换")
    }

    // MARK: - 抽：没练过的优先

    /// 第一下（还没抽过）一定是没练过的那个。
    func testUnfinishedComesFirst() {
        let pool = Self.pool(ids: ["a", "b", "c"], completed: ["a", "b"])
        XCTAssertEqual(ScenarioBlindBox.pick(from: pool, avoiding: nil, roll: 0)?.id, "c")
        XCTAssertEqual(ScenarioBlindBox.pick(from: pool, avoiding: nil, roll: 5)?.id, "c")
    }

    /// 全练过了 → 回到整池：那时候「随机」就是随机重练一关，按钮不能变成死的。
    func testAllCompletedFallsBackToTheWholePool() {
        let pool = Self.pool(ids: ["a", "b", "c"], completed: ["a", "b", "c"])
        var seen: Set<String> = []
        for roll in 0..<20 {
            guard let picked = ScenarioBlindBox.pick(from: pool, avoiding: nil, roll: roll) else { continue }
            seen.insert(picked.id)
        }
        XCTAssertGreaterThan(seen.count, 1, "全练过了就没人可抽 = 「换一个」成死的")
    }

    /// 「不抽回刚那个」优先于「没练过的优先」：只剩一个没练过、且刚抽过它时，
    /// 宁可给一个练过的，也不能原地不动。
    func testAvoidingWinsOverFreshFirst() {
        let pool = Self.pool(ids: ["a", "b"], completed: ["b"])
        let picked = ScenarioBlindBox.pick(from: pool, avoiding: "a", roll: 0)
        XCTAssertEqual(picked?.id, "b", "没练过的那个刚抽过，这一下必须换（哪怕换到练过的）")
    }

    // MARK: - 这一行显示哪一条

    func testRevealedOnlyCountsWhileTheCardIsStillExpanded() {
        let pool = Self.pool(ids: ["a", "b"])
        XCTAssertNil(ScenarioBlindBox.revealedEntry(in: pool, lastID: "a", expandedID: nil))
        XCTAssertNil(ScenarioBlindBox.revealedEntry(in: pool, lastID: "a", expandedID: "b"),
                     "展开到别张卡上，这一行就该回到「从 N 个里挑」")
        XCTAssertEqual(ScenarioBlindBox.revealedEntry(in: pool, lastID: "a", expandedID: "a")?.id, "a")
        XCTAssertNil(ScenarioBlindBox.revealedEntry(in: pool, lastID: nil, expandedID: "a"))
    }

    // MARK: - 文案

    func testSubtitleInterpolatesThePoolSize() {
        XCTAssertEqual(ScenarioBlindBox.subtitle(poolCount: 12), "从 12 个情景里随手挑一个，没练过的优先")
        XCTAssertEqual(ScenarioBlindBox.subtitle(poolCount: 0), "", "没有可抽的就不该留一句空话")
    }

    func testButtonTitleSwitchesAfterTheFirstReveal() {
        XCTAssertEqual(ScenarioBlindBox.buttonTitle(hasRevealed: false), "随机来一个")
        XCTAssertEqual(ScenarioBlindBox.buttonTitle(hasRevealed: true), "换一个")
    }

    func testRevealTextJoinsOnlyWhatItHas() {
        let full = BlindBoxEntry(id: "a", title: "机场值机", subtitle: "Airport Check-in", category: "旅行")
        XCTAssertEqual(ScenarioBlindBox.revealText(full), "开出《机场值机》 · Airport Check-in · 旅行")

        let noCategory = BlindBoxEntry(id: "b", title: "面试问答", subtitle: "Job Interview", category: "")
        XCTAssertEqual(ScenarioBlindBox.revealText(noCategory), "开出《面试问答》 · Job Interview")

        // 只有一个名字时再挂一遍同样的字是废话。
        let chineseOnly = BlindBoxEntry(id: "c", title: "点咖啡", subtitle: "点咖啡", category: "日常")
        XCTAssertEqual(ScenarioBlindBox.revealText(chineseOnly), "开出《点咖啡》 · 日常")
    }

    // MARK: - 工装

    private static func scenario(
        id: String,
        title: String = "Scenario",
        titleZh: String = "情景",
        category: String = "日常",
        origin: Scenario.Origin = .builtIn
    ) -> Scenario {
        Scenario(
            id: id,
            title: title,
            titleZh: titleZh,
            category: category,
            difficulty: 2,
            level: "A2-B1",
            objective: "",
            aiRole: "",
            learnerRole: "",
            opening: "",
            origin: origin
        )
    }

    private static func pool(ids: [String], completed: Set<String> = []) -> [BlindBoxEntry] {
        var out: [BlindBoxEntry] = []
        for id in ids {
            out.append(BlindBoxEntry(
                id: id,
                title: "情景\(id)",
                subtitle: "Scenario \(id)",
                category: "日常",
                isCompleted: completed.contains(id)
            ))
        }
        return out
    }
}
