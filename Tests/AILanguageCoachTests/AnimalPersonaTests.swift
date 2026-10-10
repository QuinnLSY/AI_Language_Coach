import AppCore
@testable import AppUI
import XCTest

/// 批次五 · D「物种个性 + 伙伴关系」的测试。
///
/// - **纯函数**：性格表、招牌动作、按活跃度挑人、伙伴配对与「先跑过去等着」；
/// - **接线哨兵**：性格参数化最容易做漏的一步是「写好了没人用」——
///   编排里还在 `randomElement()`，编译器一声不响，只是动物又变回一模一样。
///
/// ⚠️ 反证必须**真删真改**：源码哨兵扫的是原始文本，注释掉的行照样被扫到。
@MainActor
final class AnimalPersonaTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            return (index + 1, line)
        }
    }

    /// 取出某个函数体：从 `needle` 起到下一个函数声明为止。
    private func funcBody(of needle: String, in source: String) -> String {
        guard let range = source.range(of: needle) else { return "" }
        let rest = source[range.lowerBound...]
        let tail = rest.dropFirst(needle.count)
        let ends = ["\n    private func ", "\n    public func ", "\n    func "]
            .compactMap { tail.range(of: $0)?.lowerBound }
        if let end = ends.min() { return String(rest[..<end]) }
        return String(rest)
    }

    // MARK: - ① 性格表本身

    /// 每个物种都有性格，且参数落在合理区间（别让某只动物「永不出现」或「独占舞台」）。
    func testEverySpeciesHasASanePersona() {
        for kind in AnimalKind.allCases {
            let persona = AnimalPersonaBook.persona(for: kind)
            XCTAssertFalse(persona.soloActions.isEmpty, "\(kind.displayName) 没有独角戏")
            XCTAssertFalse(persona.trait.isEmpty, "\(kind.displayName) 没有性格说明")
            XCTAssertTrue((0.5...1.5).contains(persona.energy),
                          "\(kind.displayName) 的活跃度 \(persona.energy) 越界（0.5–1.5）")
        }
    }

    /// `wiggle` 是**双人舞专用**：独角戏池里不许出现它（一只动物自己摇摆看着像抽搐）。
    ///
    /// 反证：往任意物种的 `soloActions` 里塞 `.wiggle` → 红。
    func testWiggleStaysReservedForPairDances() {
        for kind in AnimalKind.allCases {
            let persona = AnimalPersonaBook.persona(for: kind)
            XCTAssertFalse(persona.soloActions.contains(.wiggle),
                           "\(kind.displayName) 的独角戏里不该有 wiggle（那是双人舞）")
            XCTAssertNotEqual(persona.signature, .wiggle,
                              "\(kind.displayName) 的招牌动作不该是 wiggle")
        }
    }

    /// 只有猫头鹰爱往枝桠上飞 —— 这条判据写错的表现是「松鼠也往树上飞」。
    func testOnlyTheOwlFavorsPerch() {
        let perchLovers = AnimalKind.allCases.filter { AnimalPersonaBook.persona(for: $0).favorsPerch }
        XCTAssertEqual(perchLovers, [.owl], "爱飞上枝桠的应当只有猫头鹰：\(perchLovers)")
    }

    /// 招牌动作按概率顶掉随机档：同一档里，兔子更爱蹦、考拉更爱打盹。
    func testSignatureOverridesTheRandomSlot() {
        // 命中招牌（roll 落在前 30%）
        XCTAssertEqual(AnimalPersonaBook.action(for: .rabbit, roll: 0.1, fallback: .shake), .hop)
        XCTAssertEqual(AnimalPersonaBook.action(for: .panda, roll: 0.1, fallback: .hop), .nod)
        // 没命中就照旧演随机档
        XCTAssertEqual(AnimalPersonaBook.action(for: .rabbit, roll: 0.9, fallback: .shake), .shake)
        XCTAssertEqual(AnimalPersonaBook.action(for: .panda, roll: 0.9, fallback: .hop), .hop)
    }

    /// 独角戏从本物种的偏好池里抽：抽到的**一定**在池子里，且覆盖得到池子里的每一项。
    func testSoloActionComesFromItsOwnPool() {
        for kind in AnimalKind.allCases {
            let pool = AnimalPersonaBook.persona(for: kind).soloActions
            var seen: Set<Int> = []
            for step in 0..<200 {
                let roll = Double(step) / 200
                let action = AnimalPersonaBook.soloAction(for: kind, roll: roll)
                XCTAssertTrue(pool.contains(action), "\(kind.displayName) 演了不在偏好池里的动作")
                seen.insert(action.rawValue)
            }
            XCTAssertEqual(seen.count, Set(pool.map(\.rawValue)).count,
                           "\(kind.displayName) 的偏好池里有的动作一直没被抽到（抽签写歪了）")
        }
    }

    // MARK: - ② 按活跃度挑人

    /// 精力旺的更常被点到（兔子 vs 小熊：同一组随机种子下兔子明显多）。
    ///
    /// 反证：`pick` 改成 `present.randomElement()`（不看活跃度）→ 次数拉平 → 红。
    func testEnergeticSpeciesGetPickedMoreOften() {
        let kinds: [AnimalKind] = [.bear, .rabbit]
        var bearCount = 0
        var rabbitCount = 0
        for step in 0..<400 {
            let roll = Double(step) / 400
            guard let picked = AnimalPersonaBook.pick(kinds: kinds, present: [0, 1], roll: roll) else { continue }
            if picked == 0 { bearCount += 1 } else { rabbitCount += 1 }
        }
        XCTAssertGreaterThan(rabbitCount, bearCount,
                             "兔子（活跃 1.35）该比小熊（0.75）更常被点到：\(rabbitCount) vs \(bearCount)")
        XCTAssertGreaterThan(bearCount, 0, "再懒也得有出场机会（性格是「偏」不是「只」）")
    }

    /// 空场与越界：没人就不演，roll 越界也不崩。
    func testPickHandlesEmptyAndOutOfRange() {
        XCTAssertNil(AnimalPersonaBook.pick(kinds: [.fox], present: [], roll: 0.5))
        XCTAssertEqual(AnimalPersonaBook.pick(kinds: [.fox, .bear], present: [0, 1], roll: -1), 0)
        XCTAssertEqual(AnimalPersonaBook.pick(kinds: [.fox, .bear], present: [0, 1], roll: 99), 1)
        // kinds 比在场槽位短（状态还没初始化）时也不崩
        XCTAssertNotNil(AnimalPersonaBook.pick(kinds: [], present: [3], roll: 0.2))
    }

    // MARK: - ③ 伙伴

    /// 伙伴是**固定**的一只，且不是学员自己（自己陪自己不算伙伴）。
    func testCompanionIsAFixedDifferentSpecies() {
        for kind in AnimalKind.allCases {
            let companion = ForestCompanion.partner(for: kind)
            XCTAssertNotEqual(companion, kind, "\(kind.displayName) 的伙伴不该是自己")
        }
    }

    /// 「先跑过去等着」：下一关在左枝就往左，在右枝就往右，全通关了就原地陪着庆祝。
    func testCompanionDashesTowardTheNextLevel() {
        XCTAssertLessThan(ForestCompanion.dashX(nextBranchIsLeft: true), 0)
        XCTAssertGreaterThan(ForestCompanion.dashX(nextBranchIsLeft: false), 0)
        XCTAssertEqual(ForestCompanion.dashX(nextBranchIsLeft: nil), 0, "没有下一关就原地庆祝")
    }

    /// 伙伴个头要比学员小一号（一眼分得出谁是谁）。
    func testCompanionIsSmallerThanTheLearner() {
        XCTAssertLessThan(ForestCompanion.size, 64, "学员是 64，伙伴得明显小一号")
        XCTAssertGreaterThan(ForestCompanion.besideLearner.width, 40, "别压在学员身上")
    }

    // MARK: - ④ 接线哨兵

    /// 编排真的用了性格：谁上场按活跃度加权、独角戏从偏好池抽、
    /// 跳/摇两档也会让招牌动作插队。
    ///
    /// 反证：把 `AnimalPersonaBook.pick` 换回 `present.randomElement()` → 红。
    func testOrchestrationActuallyUsesThePersonas() throws {
        let file = try source("AppUI/Components/TreeCanvas.swift")
        // ⚠️ 只扫编排这一段：别的地方（安慰时随机派一只）用 randomElement 是应该的。
        let body = funcBody(of: "private func orchestrateLife(", in: file)
        XCTAssertFalse(body.isEmpty, "要能取到编排函数体")
        XCTAssertTrue(body.contains("AnimalPersonaBook.pick(kinds: kinds, present: present,"),
                      "挑谁上场必须按活跃度加权")
        XCTAssertTrue(body.contains("AnimalPersonaBook.soloAction(for: kind, roll: signatureRoll)"),
                      "独角戏必须从物种偏好池里抽")
        XCTAssertTrue(body.contains("AnimalPersonaBook.action(for: kind, roll: signatureRoll,"),
                      "跳 / 摇两档也要让招牌动作插队")
        XCTAssertFalse(body.contains("present.randomElement()"),
                       "编排里不该再有「不看性格」的随机挑人")
    }

    /// 「爱不爱飞上枝桠」看的是**当前**物种（轮换会换人），不是开屏那一份 `order`。
    ///
    /// 反证：改回 `order[index % order.count] == .owl` → 红。
    func testPerchJudgementFollowsTheCurrentSpecies() throws {
        let tree = codeLines(try source("AppUI/Components/TreeCanvas.swift"))
        let flat = tree.map(\.text).joined(separator: "\n")
        XCTAssertTrue(flat.contains("let kind = kindAt(index: index, fallback: order[index % order.count])"),
                      "性格要按当前槽位的物种算")
        XCTAssertTrue(flat.contains("if persona.favorsPerch && !perched[index]"),
                      "飞枝判定必须走性格里的 favorsPerch")
        XCTAssertFalse(flat.contains("order[index % order.count] == .owl"),
                       "不许再拿初始 order 判「是不是鸟」——轮换换过人就串味了")
    }

    /// 主界面把小伙伴传给树、设置里能自己选（三个角色共用一个展示区）。
    ///
    /// 反证：删掉 MainView 的 `companionAnimal:` 装配 → 红。
    func testCompanionIsWiredFromSettingsToTheTree() throws {
        let main = try source("AppUI/Views/MainView.swift")
        XCTAssertTrue(main.contains("companionAnimal: state.companionAnimalKind"),
                      "主界面要把小伙伴传给成长之树")

        let scroll = try source("AppUI/Components/TreeScrollView.swift")
        XCTAssertTrue(scroll.contains("companionAnimal: companionAnimal"),
                      "TreeScrollView 要把小伙伴透传给 TreeCanvas")

        let settings = try source("AppUI/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("case .companion: await state.setCompanionAnimal(kind)"),
                      "设置里要能自己选小伙伴")
    }

    /// 伙伴陪着学员爬：它站在 `learnerY + 偏移`，**不许**改动 `learnerY` 与滚动锚点算式
    /// （那是 `TreeScrollViewTests` 钉死的）。
    ///
    /// 反证：把 `.position(y: learnerY + ...)` 改成自己算一条 y → 红。
    func testCompanionRidesTheLearnerAnchorWithoutTouchingIt() throws {
        let tree = codeLines(try source("AppUI/Components/TreeCanvas.swift"))
        let flat = tree.map(\.text).joined(separator: "\n")
        XCTAssertTrue(flat.contains("y: learnerY + ForestCompanion.besideLearner.height"),
                      "伙伴必须挂在学员的 y 上（陪着爬，不是各爬各的）")
        XCTAssertTrue(flat.contains("public nonisolated static func learnerY(for"),
                      "learnerY 的算式要原样留着")
        // ⚠️ marker 只钉到**参数表开头**，不钉整串形参：③ 给它加了 progress（树高随课程变）。
        // 钉死形参 = 加一个参数就报「不在文件里」，而这条守的是「算式不许被改写」，
        // 真正要钉的是它仍然走同一套 y(for:…) 而不是自己算一条。
        XCTAssertTrue(flat.contains("baseY: height - groundHeight,"),
                      "learnerY 仍要落在「画布底 − 地面带」这条树干基线上")
    }

    /// 通关时伙伴先跑过去等着（`dashCompanionAhead` 挂在既有的 ceremonyTick 上）。
    func testCompanionDashesOnLevelCompletion() throws {
        let file = try source("AppUI/Components/TreeCanvas.swift")
        let flat = codeLines(file).map(\.text).joined(separator: "\n")
        // ⚠️ 钉的是**调用**（挂在 ceremonyTick 上的那一段），函数自己躺在那儿不算数。
        // ⚠️ 逐行拼而不是用多行字面量：后者会按闭合引号缩进整段左移，看着对其实对不上。
        let hook = ".onChange(of: ceremonyTick) { _, tick in\n"
            + "            guard tick > 0 else { return }\n"
            + "            dashCompanionAhead()"
        XCTAssertTrue(file.contains(hook),
                      "通关时伙伴要有反应（dashCompanionAhead 得挂在 ceremonyTick 上）")
        XCTAssertTrue(flat.contains("ForestCompanion.dashX(nextBranchIsLeft: next.map { $0.branch == .left })"),
                      "往哪个方向跑要看下一关在哪一侧")
    }
}
