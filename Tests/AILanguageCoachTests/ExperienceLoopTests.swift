import XCTest

/// ④ 体验闭环批次的源码哨兵（错题再练 / 浮层 ESC / VAD 去假 / 读屏标签）。
///
/// 这四件事的共同点是「语义在 UI 连线里，单测够不着」——合成按键喂不进 AppKit、
/// VoiceOver 读不出标签，所以判据钉在源码上。纪律与铁律一致：
/// 判据**限定声明体**（brace 计数），不裸 `contains` 全文件（同名语句会救活假绿）。
final class ExperienceLoopTests: XCTestCase {

    // MARK: - 工具

    /// 读源码并剥掉纯注释行（注释里的历史文案不能救活判据）。
    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 提取某个声明（`func` / `var`）的**声明体**（brace 计数）。
    /// 与 `functionBody` 的区别：接受任意前缀，能框计算属性与子视图 struct。
    private nonisolated static func declBody(matching marker: String, in source: String) throws -> String {
        guard let signature = source.range(of: marker) else {
            throw NSError(domain: "sentinel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到声明 \(marker)"])
        }
        guard let open = source.range(of: "{", range: signature.upperBound..<source.endIndex) else {
            throw NSError(domain: "sentinel", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 \(marker) 的声明体开头"])
        }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[open.lowerBound..<index])
                }
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "sentinel", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "\(marker) 的声明体没有闭合"])
    }

    private nonisolated static func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    // MARK: - 浮层统一 ESC

    /// ESC 修饰器必须挂在零尺寸、无障碍隐藏的按钮上（不然读屏会多出一颗「关闭」）。
    func testEscapeCloseModifierHidesItsButton() throws {
        let raw = try Self.code("Sources/AppUI/Components/View+EscapeToClose.swift")
        XCTAssertTrue(raw.contains("keyboardShortcut(.escape, modifiers: [])"),
                      "ESC 必须走 keyboardShortcut（与设置页同一机制）")
        XCTAssertTrue(raw.contains(".accessibilityHidden(true)"),
                      "透明关闭按钮不能进无障碍树")
        XCTAssertTrue(raw.contains("frame(width: 0, height: 0)"),
                      "关闭按钮必须零尺寸（不参与布局）")
    }

    /// 五个浮层挂 ESC；入学定级**刻意不挂**（答题中途误按太亏，与「点遮罩不关」同哲学）。
    func testOverlaysCloseOnEscapeButPlacementDeliberatelyDoesNot() throws {
        let raw = try Self.code("Sources/AppUI/Views/MainView.swift")
        // ③ 加了「排一条课」浮层（从情景面板头部竖起来，同那两层一组）。
        // 数量是**钉**不是描述：多一处 = 挂到了不该挂的浮层，少一处 = 那个浮层永远关不掉。
        XCTAssertEqual(Self.occurrences(of: ".escCloses", in: raw), 5,
                       "escCloses 恰好挂 5 处（全局搜索 / 情景 / 描述场景 / 排课 / 上传材料）；多了就是挂到了不该挂的浮层")
        // 入学定级的声明体里不能出现 escCloses —— 误按 ESC 会打断答题。
        let placement = try Self.declBody(matching: "private var placementOverlay: some View", in: raw)
        XCTAssertFalse(placement.contains(".escCloses"),
                       "入学定级刻意不响应 ESC（出口只有 × 与结果页按钮）")
    }

    // MARK: - 错题卡「再练一次」+ 展开

    /// 「再练一次」放回输入框的是**原句**（练的是把这句重说对，不是照抄改后句）。
    func testPracticeAgainPutsTheOriginalBackIntoTheComposer() throws {
        let raw = try Self.code("Sources/AppUI/Views/ChatView.swift")
        let wiring = try Self.declBody(matching: "private func correctionCard(_ correction: GrammarCorrection)", in: raw)
        XCTAssertTrue(wiring.contains("input = correction.original"),
                      "再练一次必须把原句放回输入框（correctionCard 连线体里钉死）")
        XCTAssertTrue(raw.contains("再练一次"), "错题卡上要有「再练一次」按钮")
    }

    /// 解析说明默认收两行、可展开（长解释全铺开会淹掉对话）。
    func testExplanationCollapsesByDefaultAndCanExpand() throws {
        let raw = try Self.code("Sources/AppUI/Views/ChatView.swift")
        let explanation = try Self.declBody(matching: "private var explanation: some View", in: raw)
        XCTAssertTrue(explanation.contains("isExplanationExpanded ? nil : 2"),
                      "解析说明默认 lineLimit(2)")
        XCTAssertTrue(explanation.contains("isExplanationExpanded.toggle()"),
                      "展开开关必须真的切换状态")
    }

    // MARK: - VAD 卡片去假

    /// 模型管理中心不再列出说话检测（没有 runtime，列出来是假卡片）。
    func testVadCardIsRemovedFromModelCenter() throws {
        let raw = try Self.code("Sources/AppUI/Views/SettingsView.swift")
        XCTAssertTrue(raw.contains("[.asr, .tts, .embedding, .pronunciation]"),
                      "能力清单四项：ASR / TTS / 记忆索引 / 发音评测")
        XCTAssertEqual(Self.occurrences(of: ".tts, .vad", in: raw), 0,
                       "vad 不得再出现在能力清单里")
        XCTAssertFalse(raw.contains("内置模拟"), "设置页不再出现「内置模拟」假状态文案")
    }

    /// 数据面不再粉饰：ModelRegistry 的兜底文案必须诚实。
    func testModelRegistryDoesNotFakeSimulationStatus() throws {
        let raw = try Self.code("Sources/AppUI/AppState+ModelRegistry.swift")
        XCTAssertEqual(Self.occurrences(of: "\"内置模拟\"", in: raw), 0,
                       "健康状态不得再报「内置模拟」——没有那种东西（来源描述里的 mock runtime 说明不受限）")
        XCTAssertTrue(raw.contains("本地规则推断"),
                      "发音评测没接云端时的真实状态是本地规则推断")
    }

    // MARK: - 读屏标签

    /// icon-only 按钮必须有 accessibilityLabel（.help 是鼠标悬浮提示，读屏不拿它当名字）。
    func testIconOnlyButtonsCarryAccessibilityLabels() throws {
        let search = try Self.code("Sources/AppUI/Components/GlobalSearchPanel.swift")
        XCTAssertTrue(search.contains("accessibilityLabel(\"关闭搜索\")"),
                      "全局搜索的 × 要有读屏标签")

        let chat = try Self.code("Sources/AppUI/Views/ChatView.swift")
        let translate = try Self.declBody(matching: "private struct TranslateButton: View", in: chat)
        XCTAssertTrue(translate.contains(".accessibilityLabel("),
                      "翻译按钮（icon-only）要有读屏标签")

        let settings = try Self.code("Sources/AppUI/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("accessibilityLabel(\"关闭设置\")"))
        XCTAssertTrue(settings.contains("accessibilityLabel(\"重新检测本地模型\")"))
        XCTAssertTrue(settings.contains("accessibilityLabel(\"重新检测语音服务\")"))
        XCTAssertTrue(settings.contains("accessibilityLabel(\"删除备份："))
        XCTAssertTrue(settings.contains("accessibilityLabel(\"在 Finder 中打开备份目录\")"))
    }
}
