import XCTest

/// 第一批（动效 token / 统一按压反馈）的**接线哨兵**。
///
/// 为什么用源码扫描：
/// - 「按压有没有反馈」在离屏里拼不出来 —— 合成 `NSEvent` 绝不能喂给 AppKit 的
///   事件处理方法（会把整个测试进程 abort 掉，MEMORY 里的老教训）。能钉住的只有接线事实。
/// - 2026-09-25 之前全项目 **205 处** `.buttonStyle(.plain)`：`.plain` 的本意是去掉
///   macOS 默认按钮外框，代价是**连按压反馈一起没了** —— 这就是「点了没反应」的系统性根因。
///   这条必须钉死，否则往后随便加一个 `.plain` 就把反馈静默退回去了。
final class MotionTokenWiringTests: XCTestCase {

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

    private var appUIDirectory: URL {
        repoRoot.appendingPathComponent("Sources/AppUI")
    }

    // MARK: - 按压反馈

    /// 全项目不许再有裸露的 `.buttonStyle(.plain)`（注释里提到的样例不算）。
    ///
    /// 反证：把任意一处 `.appPressable` 改回 `.plain` → 红。
    func testNoButtonFallsBackToTheFeedbackFreePlainStyle() throws {
        let enumerator = FileManager.default.enumerator(
            at: appUIDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (offset, line) in lines.enumerated() {
                guard line.contains(".buttonStyle(.plain)") else { continue }
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                offenders.append("\(url.lastPathComponent):\(offset + 1)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "这些按钮还在用无反馈的 .plain（会静默退回「点了没反应」）：\(offenders.joined(separator: ", "))"
        )
    }

    /// 根上必须注入动效档位与按压层 —— 这是全树继承的唯一入口。
    ///
    /// 反证：删掉 MainView 里的 `.appMotionRoot(override:)` 或 `.buttonStyle(.appPressable)` → 红。
    func testMotionRootIsInjectedAtTheAppRoot() throws {
        let main = try source("Sources/AppUI/Views/MainView.swift")

        XCTAssertTrue(
            main.contains(".appMotionRoot(override:"),
            "MainView 根必须注入 .appMotionRoot(override:) —— 否则整棵树都不跟随动效档位"
        )
        XCTAssertTrue(
            main.contains(".buttonStyle(.appPressable)"),
            "MainView 根必须注入 .buttonStyle(.appPressable) —— 165 处 Button 靠这一行拿到按压反馈"
        )
    }

    /// 按压层只许做**不改变布局**的反馈。
    ///
    /// 本项目里「整张卡片就是按钮」的地方不止一处（词书封面、纠错卡、年历…），
    /// 一旦往按压层里加 `scaleEffect` / `offset` / `frame`，按下时卡片边缘会抖一下 ——
    /// 在 macOS 上那不是反馈，是穿帮。
    ///
    /// 反证：往 `AppButtonStyle.makeBody` 里加一行 `.scaleEffect(0.96)` → 红。
    ///
    /// ⚠️ 只扫**代码**：本文件自己的注释里就写着为什么不用 `scaleEffect`，
    /// 连注释一起扫会把自己判成违规（2026-09-25 实现时就踩到过）。
    func testPressFeedbackNeverChangesGeometry() throws {
        let style = try source("Sources/AppUI/Components/AppButtonStyle.swift")
        let code = style
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(
            code.contains(".opacity("),
            "按压反馈应当作用在不透明度上（不改几何）"
        )
        for forbidden in ["scaleEffect", "offset(", ".frame("] {
            XCTAssertFalse(
                code.contains(forbidden),
                "按压层不许出现 \(forbidden) —— 它会让「整张卡就是按钮」的地方在按下时抖动"
            )
        }
    }

    // MARK: - 参数收敛

    /// 尚未 token 化的内联动画参数不得超过当前登记的数量。
    ///
    /// 当前 17 处**有意保留**的业务节奏 —— 它们不是「交互反馈」，改快了就不是那个东西：
    /// TreeCanvas 树 ×5（生长 / 花开 / 上干的呼吸感）、LivelyAnimal ×3（跳 / 摇的性格幅度）、
    /// Animals ×3（Zzz 漂浮已带 reduceMotion 守卫、敲黑板 0.11/0.13s）、
    /// DictionarySampleWordsRow ×2（翻卡 `flipDuration`）、TeacherCorner ×1（带 `delay` 的收展）、
    /// MainView ×1（主题切换的慢crossfade）、ChatView ×1（三点已带 reduceMotion 守卫）、
    /// VocabularyView ×1（条件时长：慢翻页 1.8s）。
    ///
    /// 这个天花板的意思是：**每加一处都要想清楚它该不该进 token**，而不是任其增长。
    ///
    /// 反证：在任何普通 View 里内联一条 `.easeOut(duration: 0.3)` → 数量超上限 → 红。
    func testInlineAnimationParametersStayUnderTheRegisteredCeiling() throws {
        let ceiling = 17
        let offenders = try inlineAnimationOffenders()
        XCTAssertLessThanOrEqual(
            offenders.count, ceiling,
            "内联动画参数涨到 \(offenders.count) 处（上限 \(ceiling)）：\(offenders.joined(separator: " | "))\n"
                + "新增的应当走 AppMotion token；确属业务节奏的，先提高 ceiling 并写明理由"
        )
    }

    /// 扫出还在内联 besides token 的动画参数（`withAnimation(.ease*` / `.animation(.spring*` 等）。
    private func inlineAnimationOffenders() throws -> [String] {
        let pattern = try NSRegularExpression(
            pattern: #"(withAnimation|\.animation)\(\.(easeIn|easeOut|easeInOut|linear|spring)"#
        )
        let enumerator = FileManager.default.enumerator(
            at: appUIDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            if url.lastPathComponent == "AppMotion.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let lineNumber = text[..<swiftRange.lowerBound]
                    .components(separatedBy: .newlines).count
                offenders.append("\(url.lastPathComponent):\(lineNumber)")
            }
        }
        return offenders
    }
}
