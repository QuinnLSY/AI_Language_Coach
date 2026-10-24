import Foundation

/// `TreeCanvas` 一族源码的**全家桶读取**（#661）。
///
/// #661 起 `TreeCanvas.swift`（2812 行、21 个类型混居）按主题拆成：
/// - `TreeCanvas.swift`：主画布（`TreeCanvas` / `TreeLevelNote` / `TreeViewport`）
/// - `TreeCanvas+AnnualRings.swift`：年轮徽记（摘要 / 判据 / 绘制）
/// - `TreeBody.swift`：树干 / 树冠 / 果实 / 树枝 / 藤蔓叶
/// - `TreeCanvas+Events.swift`：事件落叶层 / 通关烟花层
/// - `TreeCanvas+LevelNode.swift`：课程云带 / 关卡节点
/// - `ForestGroundBand.swift`：林间地面带主体（状态 / body / 活动开关）
/// - `ForestGroundBand+Lifecycle/Skit/Scenery/Residents.swift`：按主题的扩展
///
/// 源码哨兵钉的是**这组画面**而不是某一个文件 —— 全家桶读取，日后按域再拆也
/// 不再打破哨兵。按文件名排序拼接（顺序确定）→ 计数与行号类判据保持稳定。
enum TreeCanvasSentinel {

    /// 目录（相对仓库根；测试进程的 CWD 就是仓库根）。
    static let directory = "Sources/AppUI/Components"

    /// 全家桶前缀：主体 / 年轮 / 树体 / 事件 / 关卡节点 / 地面带全家。
    static let prefixes = ["ForestGroundBand", "TreeBody", "TreeCanvas"]

    /// 全家桶文件名（排序后）。一个都没有 = 目录不对或文件被删，直接抛。
    static func fileNames() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { name in
                name.hasSuffix(".swift") && prefixes.contains(where: { name.hasPrefix($0) })
            }
            .sorted()
        guard !names.isEmpty else {
            throw NSError(domain: "sentinel", code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                            "\(directory) 下没有 \(prefixes.joined(separator: " / "))*.swift"])
        }
        return names
    }

    /// 逐文件读取（**行号保真**：失败信息里的 `file:line` 是真实位置）。
    static func perFile() throws -> [(file: String, text: String)] {
        try fileNames().map { ($0, try String(contentsOfFile: "\(directory)/\($0)", encoding: .utf8)) }
    }

    /// 全家桶拼接（`contains` / 计数 / `body(of:)` 提取用这个）。
    static func joined() throws -> String {
        try perFile().map(\.text).joined(separator: "\n")
    }
}
