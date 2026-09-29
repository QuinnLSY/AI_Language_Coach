import AIDomain
@testable import AppUI
import XCTest

/// A–H 八个批次的实现审查回归（2026-09-30）。
///
/// 审查对象是「编译不报错、跑起来也不崩、但**承诺没兑现**」的那类实现缺陷 ——
/// 它们不在类型系统里，只能靠判据钉住：
///
/// - **静态档失效**：氛围演出收起后星星照眨 / 太阳光环照转（`still` 只在 onAppear 读一次）；
/// - **并发写同一位移**：两条编排循环同时拽一只动物（`hopTo` 没有批次对账）；
/// - **越界与误判**：烟花锚点空表越界、举牌关键词过宽。
///
/// ⚠️ 反证必须**真删**：源码哨兵扫的是原始文本，注释掉的代码行照样被扫到。
/// 反证标记统一 `// 反证：`，还原后 `grep -rn "反证：" Sources/` 必须为空。
@MainActor
final class ForestSafetyAuditTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 源码的**非注释行**（`//` / `///` 开头的整行去掉），行号保留。
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            return (index + 1, line)
        }
    }

    /// 取出函数体：从 `needle` 起到下一个函数声明 / 类型边界为止。
    private func body(of needle: String, in source: String) -> String {
        guard let range = source.range(of: needle) else { return "" }
        let rest = source[range.lowerBound...]
        let tail = rest.dropFirst(needle.count)
        let terminators = ["\n    public func ", "\n    private func ", "\n    func ",
                           "\n    public nonisolated ", "\n    private struct", "\n    public var "]
        let ends = terminators.compactMap { tail.range(of: $0)?.lowerBound }
        if let end = ends.min() { return String(rest[..<end]) }
        return String(rest)
    }

    // MARK: - ① 静态档（ambientStill）必须当场生效

    /// 静态档下氛围表演一律停 —— 判据只有一处（纯函数）。
    ///
    /// 反证：把 `animates` 改成 `return armed` → 红。
    func testAmbientStillStopsEveryPerformance() {
        XCTAssertTrue(AmbientMotion.animates(armed: true, still: false), "演出档照常动")
        XCTAssertFalse(AmbientMotion.animates(armed: true, still: true),
                       "静态档必须停 —— 连点天空 5 次收起演出后还在动就是没兑现")
    }

    /// 太阳光环 / 星星的循环动画要由 `animates` 驱动，且**不许**退回到
    /// `onAppear { if !still }` 那种只在出现时读一次的写法。
    ///
    /// 2026-09-30 审查发现：切静态档时视图不会重新 appear，`still` 变了动画值不变，
    /// 于是「林子进入完全安静的静态」是句空话（云与萤火虫因为是整层移除才没暴露）。
    ///
    /// 反证：① 把 `value: AmbientMotion.animates(...)` 改回 `value: spin` / `value: twinkle` → 红；
    /// ② 把 `onAppear` 改回 `if !still { ... }` → 红。
    func testStillIsWiredIntoTheAnimationValueNotOnlyIntoOnAppear() throws {
        let sky = try source("AppUI/Components/ForestSky.swift")

        for (typeName, stateName) in [("private struct SunView: View", "spin"),
                                      ("private struct StarsField: View", "twinkle")] {
            let block = self.body(of: typeName, in: sky)
            XCTAssertFalse(block.isEmpty, "找不到 \(typeName)")
            let lines = codeLines(block)
            XCTAssertTrue(
                lines.contains { $0.text.contains("value: AmbientMotion.animates(armed: \(stateName)") },
                "\(typeName) 的循环动画必须由 `AmbientMotion.animates` 驱动（静态档要当场停）"
            )
            XCTAssertFalse(
                lines.contains { $0.text.contains("if !still") },
                "\(typeName) 不许再把 still 只判在 onAppear 里（切档不会重新 appear，拦不住）"
            )
        }
    }

    // MARK: - ② 地面编排：同一位移不许被两处同时写

    /// `hopTo` 每步都要对批次号：游走 / 离场 / 归位 / 捡词撞车时**后来者胜出**。
    ///
    /// 活动编排与轮换编排是两条并发的 `while` 循环，盯上同一只时两个 `hopTo`
    /// 会交替写同一个 `offsets[index]` —— 动物被两边同时拽，画面上是原地抽搐。
    ///
    /// 反证：删掉 `hopTo` 里那句 `hopTokens[index] == token` 的守卫 → 红。
    func testHopToAbortsWhenANewerMoveTakesOver() throws {
        let canvas = try source("AppUI/Components/TreeCanvas.swift")
        let hop = self.body(of: "private func hopTo(", in: canvas)
        XCTAssertFalse(hop.isEmpty, "找不到 hopTo")

        let lines = codeLines(hop)
        XCTAssertTrue(lines.contains { $0.text.contains("hopTokens[index] = token") },
                      "每次发起移动都要领一个新批次号")
        XCTAssertTrue(lines.contains { $0.text.contains("hopTokens[index] == token") },
                      "循环里必须逐步对账：期间有新意图就退出，不许继续写 offsets")
    }

    /// 全体回家要先把在飞的移动作废：否则离场 / 游走那趟 `hopTo` 会在归位之后
    /// 继续写 `offsets`，刚站好的队伍又被拽走一只（入夜那一刻最容易看见）。
    ///
    /// 反证：删掉 `sendEveryoneHome()` 里的 `invalidateHops()` → 红。
    func testSendEveryoneHomeInvalidatesInFlightHops() throws {
        let canvas = try source("AppUI/Components/TreeCanvas.swift")
        let home = self.body(of: "private func sendEveryoneHome()", in: canvas)
        XCTAssertFalse(home.isEmpty, "找不到 sendEveryoneHome")
        XCTAssertTrue(codeLines(home).contains { $0.text.contains("invalidateHops()") },
                      "回家之前必须作废所有在飞的移动批次")
    }

    /// 轮换循环**退出时**（被取消也算）要把还挂着「暂离」的居民接回场上。
    ///
    /// 2026-09-30 审查发现：`away = true` 只由归期循环复位，而那个循环只从
    /// **在场**的槽位里挑人。拖分割线改宽度档位会让 `.task(id:)` 重启、循环被取消，
    /// 走向「回家路上」的那几只就此再没人接 —— 草坡上永久少几只，越拖越少。
    ///
    /// 反证：删掉 `orchestrateRotation` 的 `defer { bringStraysHome() }` → 红。
    func testRotationBringStraysHomeWhenTheLoopEnds() throws {
        let canvas = try source("AppUI/Components/TreeCanvas.swift")
        let rotation = self.body(of: "private func orchestrateRotation(", in: canvas)
        XCTAssertFalse(rotation.isEmpty, "找不到 orchestrateRotation")
        XCTAssertTrue(codeLines(rotation).contains { $0.text.contains("defer { bringStraysHome() }") },
                      "轮换循环退出（含被取消）时必须把暂离的居民接回场上")

        // 捡词那趟也一样：`away` 置真之后若被打断，同样得接回来。
        let fetch = self.body(of: "private func fetchWord(", in: canvas)
        XCTAssertFalse(fetch.isEmpty, "找不到 fetchWord")
        XCTAssertTrue(codeLines(fetch).contains { $0.text.contains("bringStraysHome()") },
                      "捡词被打断时也不许把这位留在画外")
    }

    /// 心跳的间隔**每轮重算**：写在循环外就成了一个固定节拍器，
    /// 八只动物踩着同一个鼓点动（注释里的「随机抖动」也只剩开跑前那一次）。
    ///
    /// 反证：把 `let interval` 挪回 `while` 之前 → 红。
    func testLifeHeartbeatRecomputesItsIntervalEveryRound() throws {
        let canvas = try source("AppUI/Components/TreeCanvas.swift")
        let life = self.body(of: "private func orchestrateLife(", in: canvas)
        XCTAssertFalse(life.isEmpty, "找不到 orchestrateLife")

        guard let loopStart = life.range(of: "while !Task.isCancelled {")?.lowerBound,
              let interval = life.range(of: "let interval")?.lowerBound else {
            return XCTFail("orchestrateLife 里找不到心跳循环或间隔算式")
        }
        XCTAssertGreaterThan(interval, loopStart, "间隔必须每轮重算（写在循环外就是固定节拍器）")
        XCTAssertTrue(life.contains("min(max(activityFrequency, 0), 1)"),
                      "频率要钳回 0…1：越界值会把间隔算成负数（sleep 负数 = 忙循环）")
    }

    // MARK: - ③ 越界与误判

    /// 烟花的簇起点：锚点表为空不许越界（`anchors` 是 `public var`，外部给空表
    /// 会把整棵树带崩），簇数多于锚点时挤在最后一簇（既有行为）。
    ///
    /// 反证：把 `anchor(forBurst:anchors:)` 改回裸 `anchors[min(...)]` → 空表那条红。
    func testFireworksAnchorSurvivesAnEmptyAnchorTable() {
        let empty = CelebrationFireworks.anchor(forBurst: 0, anchors: [])
        XCTAssertEqual(empty.x, 0.5, accuracy: 1e-9, "空锚点表要退回画面中上部，不许越界")
        XCTAssertEqual(empty.y, 0.3, accuracy: 1e-9)

        let table = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.4)]
        XCTAssertEqual(CelebrationFireworks.anchor(forBurst: 1, anchors: table).x, 0.9, accuracy: 1e-9)
        XCTAssertEqual(CelebrationFireworks.anchor(forBurst: 7, anchors: table).x, 0.9, accuracy: 1e-9,
                       "簇数多于锚点时挤在最后一簇（既有行为不许改）")
    }

    /// 举牌文案：**只认「API key」这一搭配**，不认裸 `key`。
    ///
    /// 2026-09-30 审查发现：`lowered.contains("key")` 会把 KeyError /
    /// "key not found" 这类与鉴权无关的消息也翻成「钥匙不对」——
    /// 举错牌子比不举更糟（用户会去查一个根本没问题的密钥）。
    ///
    /// 反证：把关键词改回裸 `contains("key")` → 第一条红。
    func testErrorSignDoesNotBlameTheKeyForUnrelatedMessages() {
        XCTAssertEqual(ForestErrorSign.headline(for: "Invalid API KEY provided"), "钥匙好像不对…",
                       "真·鉴权失败仍然归到钥匙（大小写都收）")
        XCTAssertNotEqual(ForestErrorSign.headline(for: "KeyError: 'choices' in response"), "钥匙好像不对…",
                          "与鉴权无关的 key 不该让用户去查密钥")
        XCTAssertNotEqual(ForestErrorSign.headline(for: "keyword extraction failed"), "钥匙好像不对…")
    }
}
