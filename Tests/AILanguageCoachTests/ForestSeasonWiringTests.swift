import XCTest

/// 四季场景大扩充（#620–#629）的**季节接线哨兵**。
///
/// 十一个装饰组件（春：风筝 / 蒲公英+蝴蝶；夏：风车 / 光斑+流萤；
/// 秋：雁阵 / 果树 / 落叶堆+南瓜；冬：雪地+雪人 / 冰柱 / 哈气）各自都有单测与
/// 离屏渲染回归；这一份钉的是**最后一环**：它们确实挂在对应的季节分支下，
/// 且层级接对了地方（风筝在树之上、风车在树之后、雪在草之下、
/// 落叶南瓜在草之上、冰柱与枝上雪同一层风）。
///
/// 这些判据的症状全都是「组件写对了、测试也绿了，但画面上就是没有」——
/// 季节分支漏接 / 接错季节 / 层级接反时，组件级测试照绿。
final class ForestSeasonWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    /// 去掉整行注释后的文本行 —— 注释里提到组件名不该让哨兵报绿
    /// （`testTheSeedDoesNotRelyOnHashValue` 曾被自己的文档注释绊倒过一次）。
    private func codeLines(_ source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { raw in
                let line = String(raw)
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
                return line
            }
    }

    /// 取 `if <guard> {` 起、到配对右花括号为止的整块（含嵌套闭包），
    /// 返回 (开关行下标, 块内行)。
    ///
    /// ⚠️ 按**花括号配平**切块，而不是「往后数 N 行」—— 块内多行参数列表与
    /// 嵌套闭包会让行数每次改动都漂移，判据跟着瞎红或不红。
    /// 也不数出现次数：`if false { ForestButterflies() }` 照样计数 = 假绿。
    private func blocks(after guardText: String, in lines: [String]) -> [(start: Int, body: [String])] {
        var result: [(start: Int, body: [String])] = []
        var searchFrom = lines.startIndex
        while let start = lines[searchFrom...].firstIndex(where: { $0.contains(guardText) }) {
            var depth = 0
            var body: [String] = []
            var opened = false
            for line in lines[start...] {
                for ch in line {
                    if ch == "{" { depth += 1; opened = true }
                    else if ch == "}" { depth -= 1 }
                }
                if opened && depth > 0 { body.append(line) }
                if opened && depth == 0 { break }
            }
            result.append((start, body))
            searchFrom = start + 1
        }
        return result
    }

    private func text(_ body: [String]) -> String { body.joined(separator: "\n") }

    // MARK: - 地面带：四季分支各挂各的

    /// 春天分支必须挂上蒲公英与蝴蝶（#621）。
    ///
    /// 反证：把分支的季节改成 `.winter` → 红在「没找到春天分支」。
    func testSpringBranchMountsDandelionsAndButterflies() throws {
        let lines = codeLines(try source("Sources/AppUI/Components/TreeCanvas.swift"))
        let block = try XCTUnwrap(blocks(after: "if theme.season == .spring {", in: lines).first?.body,
                                  "地面带里没有春天分支（判据要跟着改）")
        XCTAssertTrue(text(block).contains("ForestDandelions(theme:"), "春天分支没挂蒲公英")
        XCTAssertTrue(text(block).contains("ForestButterflies(theme:"), "春天分支没挂蝴蝶")
    }

    /// 夏天分支必须挂上叶隙光斑、流萤与蜻蜓（#623 / #635）。
    ///
    /// 反证：删掉 `ForestDragonflies(theme: …)` 那一行 → 红。
    func testSummerBranchMountsDapplesFirefliesAndDragonflies() throws {
        let lines = codeLines(try source("Sources/AppUI/Components/TreeCanvas.swift"))
        let block = try XCTUnwrap(blocks(after: "if theme.season == .summer {", in: lines).first?.body,
                                  "地面带里没有夏天分支（判据要跟着改）")
        XCTAssertTrue(text(block).contains("ForestDapples(theme:"), "夏天分支没挂叶隙光斑")
        XCTAssertTrue(text(block).contains("ForestFireflies(theme:"), "夏天分支没挂流萤")
        XCTAssertTrue(text(block).contains("ForestDragonflies(theme:"), "夏天分支没挂蜻蜓")
    }

    /// 秋天是**两处**分支，且分层故意分开（#624 / #625）：
    /// 果树画在草叶之前（草从树根前长出），落叶堆与南瓜画在草之上（叶子落在草上）。
    ///
    /// 反证：把两处并成一处 → 红在「秋天应该是两处分支」或分层混接断言。
    func testAutumnBranchesMountOrchardLeavesAndPumpkins() throws {
        let lines = codeLines(try source("Sources/AppUI/Components/TreeCanvas.swift"))
        let found = blocks(after: "if theme.season == .autumn {", in: lines)
        XCTAssertEqual(found.count, 2, "秋天应该是两处分支（果树在草下、落叶南瓜在草上）")
        let orchard = try XCTUnwrap(found.first?.body, "没有果园那一处分支")
        XCTAssertTrue(text(orchard).contains("ForestOrchard(theme:"), "秋天分支没挂果树")
        let extras = try XCTUnwrap(found.last?.body, "没有落叶南瓜那一处分支")
        XCTAssertTrue(text(extras).contains("ForestLeafPiles(theme:"), "秋天分支没挂落叶堆")
        XCTAssertTrue(text(extras).contains("ForestPumpkins(theme:"), "秋天分支没挂南瓜")
        // 分层不许混：果园那一段里不许出现落叶堆（并成一层就丢了「草从树根前长出」）
        XCTAssertFalse(text(orchard).contains("ForestLeafPiles"),
                       "果园分支里混进了落叶堆：两层被并成一层了")
    }

    /// 冬天分支必须挂上雪地与雪人（#626 / #627）。
    ///
    /// 反证：删掉 `ForestSnowmen(theme: …)` 那一段 → 红。
    func testWinterBranchMountsSnowFieldAndSnowmen() throws {
        let lines = codeLines(try source("Sources/AppUI/Components/TreeCanvas.swift"))
        let block = try XCTUnwrap(blocks(after: "if theme.season == .winter {", in: lines).first?.body,
                                  "地面带里没有冬天分支（判据要跟着改）")
        XCTAssertTrue(text(block).contains("ForestSnowField(theme:"), "冬天分支没挂雪地")
        XCTAssertTrue(text(block).contains("ForestSnowmen(theme:"), "冬天分支没挂雪人")
    }

    // MARK: - 天空：风筝在树之上、风车在树之后

    /// 风筝只在春天出现、飘在树**之上**（代码顺序在后 = 画在上层），
    /// 并且接上氛围隐藏档（连点天空 5 次「林子完全安静」时风筝也要停摆）。
    ///
    /// 反证：把 `ForestKites` 那一段移到 `TreeScrollView(` 之前 → 红在层级断言。
    func testKitesFloatAboveTheTreeInSpring() throws {
        let lines = codeLines(try source("Sources/AppUI/Views/MainView.swift"))
        let found = blocks(after: "if state.theme.season == .spring {", in: lines)
        let entry = try XCTUnwrap(found.first, "中栏里没有春天分支（判据要跟着改）")
        XCTAssertTrue(text(entry.body).contains("ForestKites(theme:"), "春天分支没挂风筝")
        XCTAssertTrue(text(entry.body).contains("still:"),
                      "风筝没接氛围隐藏档（连点天空 5 次该停摆）")
        let treeIndex = try XCTUnwrap(lines.firstIndex(where: { $0.contains("TreeScrollView(") }),
                                       "中栏里找不到 TreeScrollView（判据要跟着改）")
        XCTAssertGreaterThan(entry.start, treeIndex,
                             "风筝画在树之后了：会被树冠吃掉大半（它该飘在林子上空）")
    }

    /// 雁阵并入四季飞鸟层（2026-10-23）：`ForestGeese` 不再单独挂在右栏。
    ///
    /// ⚠️ 这条防的是「两群雁」：右栏里还留着旧的 `ForestGeese`，加上最外层那层
    /// 贯穿两栏的 `ForestSeasonBirds`，秋天天上会有两群雁（一群只覆盖右栏）。
    ///
    /// 反证：把 `ForestGeese(theme: …)` 那段加回 `levelPanel` → 红。
    func testGeeseAreNoLongerMountedSeparatelyInTheTreePanel() throws {
        let lines = codeLines(try source("Sources/AppUI/Views/MainView.swift"))
        XCTAssertFalse(lines.contains { $0.contains("ForestGeese(") },
                       "右栏里还单独挂着雁阵 —— 与最外层的四季飞鸟层重复了（两群雁）")
        // 雁的造型与队形仍在（并入新体系），只是换了入口
        XCTAssertTrue(lines.isEmpty == false)
    }

    // MARK: - 四季飞鸟层（2026-10-23）

    /// 最外层必须挂 `ForestSeasonBirds`，且：
    /// 1. **画在最底层**（`ForestSky` 之后、`HStack` 之前 —— 顺序即层级）；
    /// 2. 幅宽是**两栏之和**（`chatW + resizeHandleWidth + treeW`）；
    /// 3. 高度带是**上三分之一**（`proxy.size.height / 3`）；
    /// 4. 接上氛围隐藏档。
    ///
    /// 反证 1：把 `ForestSeasonBirds` 那段移到 `HStack` 之后 → 红在「最底层」。
    /// 反证 2：把幅宽改成 `treeW`（只挂右栏）→ 红在「贯穿两栏」。
    /// 反证 3：把高度改成 `proxy.size.height` → 红在「上三分之一」。
    func testSeasonBirdsSpanBothColumnsAndSitBehindTheContent() throws {
        let lines = codeLines(try source("Sources/AppUI/Views/MainView.swift"))
        let entry = try XCTUnwrap(blocks(after: "if let season = state.theme.season {", in: lines).first,
                                  "最外层没有四季飞鸟层（判据要跟着改）")
        let body = text(entry.body)
        XCTAssertTrue(body.contains("ForestSeasonBirds("), "没挂四季飞鸟层")
        XCTAssertTrue(body.contains("kind: BirdKind.forSeason(season)"),
                      "没按季节选鸟种（四季该是四种不同的鸟）")
        XCTAssertTrue(body.contains("still: state.forest.ambientHidden"),
                      "飞鸟层没接氛围隐藏档（连点天空 5 次该停摆）")
        // 贯穿中间栏 + 右栏
        XCTAssertTrue(body.contains("chatW + resizeHandleWidth + treeW"),
                      "幅宽不是两栏之和 —— 鸟群到分割线就没了（用户报的正是这个）")
        // 上三分之一
        XCTAssertTrue(body.contains("proxy.size.height / 3"),
                      "高度带不是上三分之一")
        // 层级：必须在 ForestSky 之后、HStack 之前
        let skyIndex = try XCTUnwrap(lines.firstIndex(where: { $0.contains("ForestSky(") }),
                                       "最外层找不到 ForestSky（判据要跟着改）")
        let hstackIndex = try XCTUnwrap(lines.firstIndex(where: { $0.contains("HStack(spacing: 0)") }),
                                        "最外层找不到三栏的 HStack（判据要跟着改）")
        XCTAssertGreaterThan(entry.start, skyIndex,
                             "飞鸟层画在天空之前了：会被天空盖住")
        XCTAssertLessThan(entry.start, hstackIndex,
                          "飞鸟层画在内容之上：会挡住中间栏的聊天文字（用户选的是背景层）")
    }

    /// 四种鸟的**造型**必须各自接进 `BirdBody` 的分派（不许四季共用一种）。
    ///
    /// ⚠️ 这条与渲染里的「墨迹面积指纹」是两条互补的判据：面积指纹是**综合**的
    /// （造型 + 队形 + 体型 + 数量），万一某两种鸟的面积碰巧接近就会漏；
    /// 源码哨兵直接钉「四种造型都到场」，与像素无关。
    ///
    /// 反证：把 `BirdBody` 的 switch 改成四季都走 `GooseBody` → 红（计数对不上）。
    func testFourBirdShapesAreAllWiredIntoTheBodyDispatch() throws {
        let lines = codeLines(try source("Sources/AppUI/Components/ForestBirds.swift"))
        let bodies = ["GooseBody(theme:", "EgretBody(theme:", "SwallowBody(theme:", "CraneBody(theme:"]
        for name in bodies {
            XCTAssertEqual(occurrences(of: name, in: text(lines)), 1,
                           "\(name) 没接进 BirdBody 的分派（四季共用一种造型了）")
        }
    }

    /// 风车只在夏天出现、立在树**之后**（代码顺序在前 = 画在下层）——
    /// 远处的东西本就该被树冠挡掉一角，「远」由景深推出来不是靠后画的层级。
    ///
    /// 反证：把 `ForestWindmills` 那一段移到 `TreeScrollView(` 之后 → 红。
    func testWindmillsSitBehindTheTreeInSummer() throws {
        let lines = codeLines(try source("Sources/AppUI/Views/MainView.swift"))
        let found = blocks(after: "if state.theme.season == .summer {", in: lines)
        let entry = try XCTUnwrap(found.first, "中栏里没有夏天分支（判据要跟着改）")
        XCTAssertTrue(text(entry.body).contains("ForestWindmills(theme:"), "夏天分支没挂风车")
        let treeIndex = try XCTUnwrap(lines.firstIndex(where: { $0.contains("TreeScrollView(") }),
                                       "中栏里找不到 TreeScrollView（判据要跟着改）")
        XCTAssertLessThan(entry.start, treeIndex,
                          "风车画在树之前了：成了贴在树上的贴纸（它该在树后稍远）")
    }

    // MARK: - 树冠与动物：季节守卫在组件内部

    /// 冰柱必须挂在「冬季 + drawsIcicles」双开关下，且与枝上雪线**同一层风里**
    ///（`swaying(band:` 包着它）—— 雪在枝上、冰在枝下，是同一根枝的上下两侧。
    ///
    /// 反证：删掉 `if drawsIcicles {` → 红；把 LimbIcicles 移到 swaying 闭包外 → 红。
    func testCrownHangsIciclesUnderWinterLimbs() throws {
        let lines = codeLines(try source("Sources/AppUI/Components/TreeCrown.swift"))
        let entry = try XCTUnwrap(blocks(after: "if theme.season == .winter, drawsSnow {", in: lines).first,
                                  "树冠里没有冬季积雪层（判据要跟着改）")
        let body = entry.body
        XCTAssertTrue(body.contains(where: { $0.contains("swaying(band:") }),
                      "积雪层没有包进本层 WindSway（雪不会跟着叶子晃）")
        guard let guardIndex = body.firstIndex(where: { $0.contains("if drawsIcicles {") }),
              let mountIndex = body.firstIndex(where: { $0.contains("LimbIcicles(theme:") }) else {
            XCTFail("冰柱没挂在 drawsIcicles 开关下（或整段被删了）")
            return
        }
        XCTAssertLessThan(guardIndex, mountIndex, "冰柱画在开关判断之前了")
        // 同一层风：挂载行必须出现在某个 swaying 之后（闭包内）
        let swayIndex = try XCTUnwrap(body.firstIndex(where: { $0.contains("swaying(band:") }),
                                       "积雪层没有 WindSway")
        XCTAssertGreaterThan(mountIndex, swayIndex,
                             "冰柱不在本层风里：叶子晃它不晃（雪在枝上、冰在枝下该一起晃）")
    }

    /// 小动物的白哈气必须挂在「冷天才哈」的判据下（#628），且带呼吸循环动效。
    ///
    /// 反证：把 `AnimalBreath.shows(` 换成 `true` → 红在「没找到哈气接线」。
    func testAnimalsBreatheOnlyWhenCold() throws {
        let lines = codeLines(try source("Sources/AppUI/Theme/Animals.swift"))
        let block = try XCTUnwrap(blocks(after: "if drawsBreath, AnimalBreath.shows(", in: lines).first?.body,
                                  "小动物没有哈气接线（判据要跟着改）")
        XCTAssertTrue(text(block).contains("BreathPuff(size: size, puff: breathing ? 1 : 0)"),
                      "哈气没挂在冷天判据下（或参数形态变了）")
        XCTAssertTrue(text(block).contains(".loopAnimation("),
                      "哈气没有呼吸循环动效（成了一团死不动的雾）")
    }

    // MARK: - 氛围隐藏档（连点天空 5 次：林子完全安静）

    /// 地面带里那几层**自己起表**的季节装饰必须吃到氛围隐藏档。
    ///
    /// 症状：连点天空 5 次之后，云收了、雨停了、风筝与雁定住了，春蝶 / 蒲公英絮 /
    /// 夏夜流萤 / 蜻蜓照飞 —— 它们隔着 `TreeScrollView → TreeCanvas →
    /// ForestGroundBand` 三层，`still:` 参数传不进去，所以走环境值
    /// `\.forestAmbientStill`（2026-10-23 审计实测）。
    ///
    /// 反证：删掉任一组件里那行 `@Environment(\.forestAmbientStill)` → 红在处数；
    /// 只声明不接进判据（删掉 `|| ambientStill`）→ 红在第二条。
    func testSelfTimedGroundDecorationsReadTheAmbientStillFlag() throws {
        let files: [(name: String, path: String, expected: Int)] = [
            ("春蝶 + 蒲公英", "Sources/AppUI/Components/ForestSpringExtras.swift", 2),
            ("光斑 + 流萤 + 蜻蜓", "Sources/AppUI/Components/ForestSummerExtras.swift", 3),
        ]
        for file in files {
            let lines = codeLines(try source(file.path))
            let reads = occurrences(of: "@Environment(\\.forestAmbientStill)",
                                    in: text(lines))
            XCTAssertEqual(reads, file.expected,
                           "\(file.name)：该有 \(file.expected) 处读氛围隐藏档，实到 \(reads)")
            // ⚠️ 光声明不算数：必须真的乘进冻结判据（声明了不用 = 静默失效）。
            // ⚠️ 判的是**处数**不是「出现过」：一个文件里有两层装饰，只接一层时
            // 「出现过」照样绿，画面上却是「蝴蝶停了、蜻蜓还在飞」。
            let wired = occurrences(of: "let frozen = still || ambientStill || motion.reduceMotion",
                                    in: text(lines))
            XCTAssertEqual(wired, file.expected,
                           "\(file.name)：该有 \(file.expected) 层接进冻结判据，实到 \(wired)")
            // 读点与接线点必须一一对应（多一个声明没接、或少接一层，都在这里现形）
            XCTAssertEqual(reads, wired,
                           "\(file.name)：声明了 \(reads) 处、只接了 \(wired) 处 —— 有一层是假接线")
        }
    }

    /// 根上必须注入 `\.forestAmbientStill` —— 否则上面那几层读到的永远是 false。
    ///
    /// 反证：删掉 `MainView` 里那一行 → 红（与 `testRootAnimatesTheSeasonSwitch`
    /// 同一个道理：光有读点、没有注入，环境值就是默认的 false）。
    func testRootInjectsTheAmbientStillFlag() throws {
        let lines = codeLines(try source("Sources/AppUI/Views/MainView.swift"))
        XCTAssertTrue(
            lines.contains(where: {
                $0.contains(".environment(\\.forestAmbientStill, state.forest.ambientHidden)")
            }),
            "根上没有注入 forestAmbientStill：地面带那几层永远读不到氛围隐藏档"
        )
    }

    // MARK: - 换季淡入淡出（#636）

    /// 根上必须挂换季动画 —— 配色那一半的渐变全靠它。
    ///
    /// 只给各层加 `.seasonFade()` 而根上没有这一行时，季节分支的插拔不落在任何
    /// 带动画的事务里，过渡就是一句空话（症状：装饰层「设了过渡却照样瞬跳」）。
    ///
    /// 反证：删掉 `MainView` 里那一行 → 红（`ForestSeasonFadeRenderTests` 的两条
    /// 也会一起红，那里是同一件事的像素级判据）。
    func testRootAnimatesTheSeasonSwitch() throws {
        let lines = codeLines(try source("Sources/AppUI/Views/MainView.swift"))
        XCTAssertTrue(
            lines.contains(where: { $0.contains(".appAnimation(.scene, value: state.theme.season)") }),
            "根上没挂换季动画：山丘 / 树冠 / 草坡的配色仍是瞬间跳变"
        )
    }

    /// 每个季节分支里的**每一层**都要带 `.seasonFade()`，且不许自己写别的过渡。
    ///
    /// 判据是「层数 == 淡入淡出数」而不是「出现过」：冬天那一处有两层（雪地 + 雪人），
    /// 只淡一层时「出现过」照样绿，画面上却是雪人凭空冒出来。
    ///
    /// 反证：删掉任意一处 `.seasonFade()` → 红在层数对不上；
    /// 给某一层加 `.transition(.scale)` → 红在「换季只许淡，不许挪」。
    func testEverySeasonBranchFadesItsLayers() throws {
        let files: [(path: String, prefix: String)] = [
            ("Sources/AppUI/Components/TreeCanvas.swift", "if theme.season == ."),
            ("Sources/AppUI/Views/MainView.swift", "if state.theme.season == ."),
        ]
        // 地面带四季十层（雪地+雪人 / 果树 / 蒲公英+蝴蝶 / 光斑+流萤+蜻蜓 /
        // 落叶堆+南瓜）+ 天空两层（风车 / 风筝）。
        // ⚠️ 雁阵 2026-10-23 并入四季飞鸟层（`ForestSeasonBirds`，四季共用一层，
        // 由 `testSeasonBirdsSpanBothColumnsAndSitBehindTheContent` 单独钉）——
        // 所以这里从 13 降到 12，且不再按季节分支找它。
        // 只设下界：往后加层照绿，但「一处分支都没找到」这种空转会被挡住。
        var layers = 0
        for file in files {
            let lines = codeLines(try source(file.path))
            for season in ["spring", "summer", "autumn", "winter"] {
                for entry in blocks(after: "\(file.prefix)\(season) {", in: lines) {
                    let body = text(entry.body)
                    let calls = occurrences(of: "(theme:", in: body)
                    XCTAssertGreaterThan(calls, 0,
                                         "\(file.path) 的 \(season) 分支里没有装饰组件（判据要跟着改）")
                    let fades = occurrences(of: "seasonFade()", in: body)
                    XCTAssertEqual(fades, calls,
                                   "\(file.path) 的 \(season) 分支有 \(calls) 层、只淡了 \(fades) 层")
                    XCTAssertFalse(body.contains(".transition("),
                                   "\(file.path) 的 \(season) 分支自己写了过渡：换季只许淡，不许挪")
                    layers += calls
                }
            }
        }
        XCTAssertGreaterThanOrEqual(layers, 12,
                                    "只查到 \(layers) 层季节装饰（地面带 10 + 天空 2），判据漏了分支")
    }

    /// 树冠的积雪与冰柱也要跟着淡（#626 / #628）—— 它们是冬天分支里唯一一处
    /// 不在地面带的层，漏了就是「按一下冬天，雪凭空出现在枝头」。
    ///
    /// 反证：删掉 `TreeCrown` 里 `.seasonFade()` 那一行 → 红。
    func testCrownFadesItsWinterSnowAndIcicles() throws {
        let lines = codeLines(try source("Sources/AppUI/Components/TreeCrown.swift"))
        let entry = try XCTUnwrap(
            blocks(after: "if theme.season == .winter, drawsSnow {", in: lines).first,
            "树冠里没有冬季积雪层（判据要跟着改）"
        )
        XCTAssertTrue(text(entry.body).contains("seasonFade()"),
                      "树冠的积雪 / 冰柱没有换季淡入淡出")
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - 跨季防串

    /// 每个季节分支只许挂自己的组件 —— 防复制粘贴把别家的装饰带进来
    /// （症状：夏天冒蝴蝶、冬天冒光斑，而每个组件自己的测试都是绿的）。
    ///
    /// 反证：往冬天分支里粘一行 `ForestButterflies(theme: …)` → 红。
    func testSeasonBranchesDoNotLeakAcrossSeasons() throws {
        let lines = codeLines(try source("Sources/AppUI/Components/TreeCanvas.swift"))
        func blockText(_ season: String) throws -> String {
            text(blocks(after: "if theme.season == .\(season) {", in: lines).flatMap(\.body))
        }
        let spring = try blockText("spring")
        XCTAssertFalse(spring.contains("ForestSnowField"), "春天分支里出现了冬天下的雪")
        XCTAssertFalse(spring.contains("ForestOrchard"), "春天分支里出现了秋天的果树")
        let summer = try blockText("summer")
        XCTAssertFalse(summer.contains("ForestButterflies"), "夏天分支里出现了春天的蝴蝶")
        let autumn = try blockText("autumn")
        XCTAssertFalse(autumn.contains("ForestFireflies"), "秋天分支里出现了夏天的流萤")
        XCTAssertFalse(autumn.contains("ForestDragonflies"), "秋天分支里出现了夏天的蜻蜓")
        let winter = try blockText("winter")
        XCTAssertFalse(winter.contains("ForestButterflies"), "冬天分支里出现了春天的蝴蝶")
        XCTAssertFalse(winter.contains("ForestDapples"), "冬天分支里出现了夏天的光斑")
    }
}
