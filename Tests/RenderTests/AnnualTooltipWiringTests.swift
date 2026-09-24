import XCTest

/// 浮卡**结构性哨兵**：防「接线重复」与「反证残留」两类不上像素的缺陷。
///
/// 背景（#5 三轮实机报障）：把「浮卡从热图层提升到整卡层」落地时，
/// 热图层那份老实现没删干净，`tooltipOverlay` 被挂了两处 ——
/// 实机 hover 出**两个浮卡**：一个在最上层，另一个被 footer/footnote 盖住。
///
/// 为什么必须用源码扫描而不是渲染回归：
/// - 两份浮卡的落点由**各自的钳制容器**决定。测试钩子 `previewFocus`
///   直接注入整卡坐标时，两处算出的 origin 会重合，图上只看得见一份（假绿）；
///   而真实 hover 走「热图坐标 + 卡片已知偏移」的路径，两份才会错开。
///   离屏环境下 preference 传播时序不可控，搭不出稳定的 hover 路径。
/// - 这类缺陷的本质是**视图树上多接了一根线**，源码即事实，扫描最准。
final class AnnualTooltipWiringTests: XCTestCase {

    /// 仓库根：Tests/RenderTests/本文件.swift → 上溯三级。
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 浮卡的挂载点应**恰有一处**（整卡层）。
    ///
    /// ⚠️ 必须剔除函数**定义行**（`func tooltipOverlay(containerSize: …)` 也含扫描串）——
    /// 否则恒为「定义 1 + 调用 N」，永远数不准（首版就栽在这）。
    ///
    /// 反证：把热图层那份 overlay 加回去 → `mounts == 2` → 红。
    func testTooltipIsMountedExactlyOnce() throws {
        let code = try source("Sources/AppUI/Components/AnnualRecapCard.swift")
        let mounts = code
            .components(separatedBy: .newlines)
            .filter { !$0.contains("func tooltipOverlay") }
            .reduce(0) { $0 + ($1.components(separatedBy: "tooltipOverlay(containerSize:").count - 1) }
        XCTAssertEqual(
            mounts, 1,
            """
            浮卡挂载点应恰有 1 处（body 的整卡层），实测 \(mounts) 处。
            多出来的那份会被 footer/footnote 画在头上 —— 实机表现为两个浮卡。
            若函数已改名，请同步更新本哨兵的扫描串。
            """
        )
    }

    /// Sources 里不许留「反证：」临时改动标记。
    ///
    /// 约定：所有**合法**提到反证的注释一律写成「反证实测」「反证态」等（不带冒号），
    /// `// 反证：` 这个前缀专属于「临时改坏的实现」，反证跑完必须还原。
    /// 上一轮就是漏还原了这样一处，才让两个浮卡一起上了实机。
    ///
    /// 反证：在任意 Sources 文件里加一行 `// 反证：xxx` → 红。
    func testNoCounterfactualLeftoversInSources() throws {
        let sources = repoRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: .newlines).enumerated()
            where line.contains("// 反证：") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Sources 里残留了反证用的临时改动：\(offenders.joined(separator: ", ")) —— 反证跑完必须完整还原"
        )
    }
}
