import XCTest
@testable import AppUI

/// S2-1 浮层 Esc 栈顶仲裁的回归测试。
///
/// 背景：我上一批（`4343980`）在 `View+EscapeToClose.swift` 里写下的前提是
/// 「浮层条件渲染 → 同屏最多一个 ESC 挂载点」。**前提是错的**：上传材料 / 描述场景
/// 两个浮层的唯一入口就在情景面板头部，打开它们不关 `showingScenarios`，所以同屏
/// 必有两个挂载点；设置页还有第 5 个（原生 `keyboardShortcut(.escape)`）。
/// 后果是「一次 Esc 关掉底下那层、顶层还挂着」。
///
/// 这批测试分两类：**行为**用 `EscDismissLayer.topmost`（纯函数，32 种组合全覆盖，
/// 不必渲染）；**接线**用源码哨兵钉住「每个挂载点都必须传 isActive」。
final class EscStackTests: XCTestCase {

    // MARK: - 工具

    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private nonisolated static func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    // MARK: - 行为：栈顶判定

    /// 回归本体：情景面板 + 上传材料（每次点「上传材料」必现的共存）必须由材料层响应 Esc。
    func testMaterialUploadOutranksScenarios() {
        let top = EscDismissLayer.topmost(
            settings: false, scenarios: true, materialUpload: true, scenarioComposer: false, globalSearch: false
        )
        XCTAssertEqual(top, .materialUpload, "材料浮层压在情景面板之上，Esc 该关它而不是底下那层")
    }

    /// 描述场景浮层同理（它也是从情景面板头部竖起来的）。
    func testScenarioComposerOutranksScenarios() {
        let top = EscDismissLayer.topmost(
            settings: false, scenarios: true, materialUpload: false, scenarioComposer: true, globalSearch: false
        )
        XCTAssertEqual(top, .scenarioComposer)
    }

    /// 三层同屏（菜单栏「设置…」可在情景+材料开着时弹出来）——原先最坏情况是
    /// 一次 Esc 关掉设置页，底下两层都还挂着。
    func testThreeStackedOverlaysPickExactlyTheTopOne() {
        let top = EscDismissLayer.topmost(
            settings: true, scenarios: true, materialUpload: true, scenarioComposer: false, globalSearch: false
        )
        XCTAssertEqual(top, .materialUpload)
    }

    /// 全局搜索挂在根 ZStack 闭合后的 `.overlay` 里，永远最上层。
    func testGlobalSearchIsAlwaysTheTopLayer() {
        let top = EscDismissLayer.topmost(
            settings: true, scenarios: true, materialUpload: true, scenarioComposer: true, globalSearch: true
        )
        XCTAssertEqual(top, .globalSearch)
    }

    /// 设置页与材料层同为 zIndex 20，但声明更早 → 在下面。
    func testSettingsSitsBelowMaterialUpload() {
        let top = EscDismissLayer.topmost(
            settings: true, scenarios: true, materialUpload: true, scenarioComposer: false, globalSearch: false
        )
        XCTAssertNotEqual(top, .settings)
        let onlySettings = EscDismissLayer.topmost(
            settings: true, scenarios: true, materialUpload: false, scenarioComposer: false, globalSearch: false
        )
        XCTAssertEqual(onlySettings, .settings, "只有设置页与情景面板时，Esc 该关设置页")
    }

    /// 32 种组合全覆盖：返回的那一层必须**确实开着**，且所有比它更上层的都关着。
    /// （只钉住几个例子的话，把中间某两层的顺序换掉照样绿。）
    func testTopmostIsConsistentForEveryCombination() {
        let order: [EscDismissLayer] = [.globalSearch, .scenarioComposer, .materialUpload, .settings, .scenarios]
        for mask in 0..<32 {
            var on: [EscDismissLayer: Bool] = [:]
            for (index, layer) in order.enumerated() { on[layer] = (mask >> index) & 1 == 1 }
            let top = EscDismissLayer.topmost(
                settings: on[.settings]!,
                scenarios: on[.scenarios]!,
                materialUpload: on[.materialUpload]!,
                scenarioComposer: on[.scenarioComposer]!,
                globalSearch: on[.globalSearch]!
            )
            let open = order.filter { on[$0]! }
            if let top {
                XCTAssertTrue(on[top]!, "组合 \(mask)：返回的 \(top) 必须自己开着")
                let higher = order.prefix { $0 != top }.filter { on[$0]! }
                XCTAssertTrue(higher.isEmpty, "组合 \(mask)：\(top) 上面还有开着却没抢到 Esc 的 \(higher)")
            } else {
                XCTAssertTrue(open.isEmpty, "组合 \(mask)：一个都没开却返回了 \(String(describing: top))")
            }
        }
    }

    // MARK: - 接线：每个挂载点都必须参与仲裁

    /// MainView 四个浮层逐一传 `isActive`；漏一处那个浮层就又变成平等键等价项。
    func testEveryOverlayPassesItsActiveFlag() throws {
        let raw = try Self.code("Sources/AppUI/Views/MainView.swift")
        XCTAssertEqual(Self.occurrences(of: ".escCloses(", in: raw), 4, "四个浮层各挂一处")
        for layer in ["globalSearch", "scenarios", "scenarioComposer", "materialUpload"] {
            XCTAssertTrue(
                raw.contains("isActive: state.escDismissLayer == .\(layer)"),
                "\(layer) 浮层必须传 isActive"
            )
        }
        XCTAssertEqual(Self.occurrences(of: "escDismissLayer", in: raw), 4,
                       "escCloses 与 isActive 一一对应，不许有多余或缺失的挂载点")
    }

    /// 设置页那个挂载点是原生 `keyboardShortcut(.escape)`，同样要参与仲裁；
    /// 若改回无条件挂载，它就永远可关 = 变成第 5 个平等键等价项。
    func testSettingsCloseButtonGoesThroughTheSameArbitration() throws {
        let raw = try Self.code("Sources/AppUI/Views/SettingsView.swift")
        XCTAssertTrue(raw.contains("escShortcut(isActive: state.escDismissLayer == .settings)"),
                      "设置页的 Esc 必须走栈顶仲裁")
        XCTAssertEqual(Self.occurrences(of: "keyboardShortcut(.escape", in: raw), 0,
                       "设置页不许再有裸的 keyboardShortcut(.escape)")
    }

    /// 修饰器本体：非栈顶时**一个键等价项都不注册**（挂一个空 Button 仍会抢 Esc）。
    func testInactiveOverlaysRegisterNoShortcut() throws {
        let raw = try Self.code("Sources/AppUI/Components/View+EscapeToClose.swift")
        XCTAssertTrue(raw.contains("func escCloses(_ action: @escaping () -> Void, isActive: Bool = true)"),
                      "escCloses 必须带 isActive")
        let body = try XCTUnwrap(Self.code("Sources/AppUI/Components/View+EscapeToClose.swift")
            .components(separatedBy: "func escCloses")[1]
            .components(separatedBy: "func escShortcut")[0])
        XCTAssertTrue(body.contains("if isActive"), "非栈顶时不渲染按钮")
        let shortcutIndex = try XCTUnwrap(body.range(of: "keyboardShortcut(.escape"))
        let guardIndex = try XCTUnwrap(body.range(of: "if isActive"))
        XCTAssertLessThan(guardIndex.lowerBound, shortcutIndex.lowerBound,
                          "keyboardShortcut 必须在 isActive 守卫之内")
        // ⚠️ 排除断言：光有上面那条不够——把 isActive 改成恒真也能过，
        // 那是「所有层都抢 Esc」的老毛病。
        XCTAssertFalse(body.contains("if true"), "不许把仲裁短路成恒真")
    }

    /// 描述场景浮层是满屏遮罩，漏进快捷键拦截 = 按 ⌘3 会把底下那页切走。
    func testScenarioComposerAlsoBlocksPageShortcuts() throws {
        let raw = try Self.code("Sources/AppUI/AppState+Shortcuts.swift")
        let body = try XCTUnwrap(raw.components(separatedBy: "isShortcutBlockingOverlayPresented: Bool {")[1]
            .components(separatedBy: "\n    }")[0])
        XCTAssertTrue(body.contains("showingScenarioComposer"), "描述场景浮层必须进快捷键拦截")
    }
}