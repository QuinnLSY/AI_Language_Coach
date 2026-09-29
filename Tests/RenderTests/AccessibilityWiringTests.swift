import XCTest

/// 批次七 · G（无障碍与 reduceMotion 全覆盖）的**接线哨兵**。
///
/// 为什么用源码扫描：读屏标注与 reduceMotion 守卫都是「离屏拼不出来、AX 也测不了」
/// 的接线事实（MEMORY 铁律：合成点击 / 离屏 AX 都不可测）——能钉住的只有源码本身。
final class AccessibilityWiringTests: XCTestCase {

    /// 仓库根：Tests/RenderTests/本文件.swift → 上溯三级。
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - reduceMotion 守卫

    /// 裸 `.animation(` 里挂 `repeatForever` 全 AppUI 禁绝（批次七修的就是这一处：
    /// 萤火虫裸挂着 repeatForever，「减弱动态效果」开着它照样飘）。
    ///
    /// ⚠️ 必须**跨行窗口**检测（2026-09-29 反证抓出来的假绿）：`.animation(` 与
    /// `repeatForever` 经常分行写，按行匹配抓不到 —— 对每个 `.animation(` 向后看
    /// 160 字符的窗口。`.loopAnimation(` / `.appAnimation(` 不含 `.animation(` 子串，
    /// 不会误伤；`withAnimation` + reduceMotion 守卫（Animals.swift 的老写法）也不在此列。
    ///
    /// 反证：把 ForestSky.swift 萤火虫那段改回裸 `.animation(.easeInOut(...).repeatForever...)` → 红。
    func testNoBareRepeatForeverAnimationModifier() throws {
        let directory = repoRoot.appendingPathComponent("Sources/AppUI")
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            var cursor = text.startIndex
            while let range = text.range(of: ".animation(", range: cursor..<text.endIndex) {
                // 起点所在**完整行**是注释 → 跳过（教学注释里的「裸 .animation(.repeatForever)」
                // 字样会当起点、把窗口里**合法的** .loopAnimation(...).repeatForever(...) 拖下水）。
                // ⚠️ 必须从匹配点**向前**找行首：匹配点在行中间时，从它截到行尾看不到 // 前缀
                // （2026-09-29 全量测试第三次抓出来的假绿 —— 截半行等于没滤）。
                let lineStart = text[..<range.lowerBound].lastIndex(of: "\n")
                    ?? text.startIndex
                let lineEnd = text[range.lowerBound...].firstIndex(of: "\n") ?? text.endIndex
                if text[text.index(after: lineStart)..<lineEnd]
                    .trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    cursor = range.upperBound
                    continue
                }
                let windowEnd = text.index(
                    range.lowerBound, offsetBy: 160, limitedBy: text.endIndex
                ) ?? text.endIndex
                // 窗口内先滤掉注释行再查 —— 源码注释里写「裸 .animation(.repeatForever)」
                // 是教学文字，不是违规代码（2026-09-29 全量测试抓出来的误伤）。
                let windowLines = text[range.lowerBound..<windowEnd]
                    .components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                if windowLines.joined().contains("repeatForever") {
                    let lineNumber = text[..<range.lowerBound]
                        .components(separatedBy: .newlines).count
                    offenders.append("\(url.lastPathComponent):\(lineNumber)")
                }
                cursor = range.upperBound
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "这些地方还在裸挂 repeatForever（reduceMotion 管不到它，请改走 .loopAnimation）：\(offenders.joined(separator: ", "))"
        )
    }

    // MARK: - 装饰层读屏收敛

    /// 天空层必须整体对读屏隐藏（70 颗无名星星会淹没真正的控件）。
    ///
    /// 反证：删掉 ForestSky.swift 根上的 `.accessibilityHidden(true)` → 红。
    func testForestSkyIsHiddenFromVoiceOver() throws {
        let sky = try source("Sources/AppUI/Components/ForestSky.swift")
        XCTAssertTrue(
            sky.contains(".accessibilityHidden(true)"),
            "ForestSky 是纯氛围装饰，必须对 VoiceOver 整体隐藏（日夜切换走 CelestialToggle，不受影响）"
        )
    }

    /// 树的三段装饰（树干 / 树冠 / 藤蔓）与落叶层、花草带都必须读屏不可见；
    /// 关卡节点必须带 isButton 语义 —— VoiceOver 用户要能进练习。
    ///
    /// 反证：删掉 LevelNode 的 `.accessibilityAddTraits(` → 红。
    func testTreeCanvasHidesDecorationAndExposesLevelsAsButtons() throws {
        let tree = try source("Sources/AppUI/Components/TreeCanvas.swift")

        // 装饰收敛：树体 Group、落叶层、地面花草带，至少三处 hidden。
        let hiddenCount = tree.components(separatedBy: ".accessibilityHidden(true)").count - 1
        XCTAssertGreaterThanOrEqual(
            hiddenCount, 3,
            "TreeCanvas 里对读屏隐藏的装饰层不足 3 处（树体 / 落叶 / 花草带），现 \(hiddenCount) 处"
        )

        // 关卡可达：读屏文案 + 按钮语义 + 提示，三件套缺一不可。
        // （isButton 是条件式的：locked 关卡点了不响应，不给按钮语义 —— 说「尚未解锁」更诚实。）
        XCTAssertTrue(
            tree.contains(".accessibilityAddTraits("),
            "LevelNode 是 onTapGesture，VoiceOver 树里默认不存在 —— 必须补 isButton 语义"
        )
        XCTAssertTrue(
            tree.contains(".accessibilityElement(children: .ignore)"),
            "LevelNode 必须收敛成一个读屏元素（否则 58pt 圆 + 星数 + 标题被念成三段碎片）"
        )
        XCTAssertTrue(
            tree.contains(".accessibilityLabel(Self.voiceOverLine("),
            "LevelNode 必须挂 voiceOverLine（文案唯一出处 AccessibilityLines.levelLine，可单测）"
        )
    }

    /// 连胜徽章必须挂有语义的读屏文案（光念「7 天」谁也听不懂）。
    ///
    /// 反证：删掉 StreakBirdBadge 的 `.accessibilityLabel(...)` → 红。
    func testStreakBadgeExposesALabelNotJustANumber() throws {
        let badge = try source("Sources/AppUI/Components/StreakBirdBadge.swift")
        XCTAssertTrue(
            badge.contains(".accessibilityLabel(Self.voiceOverLine("),
            "连胜徽章的读屏要是一句有语义的话（AccessibilityLines.streakLine），不是孤零零的天数"
        )
    }
}
