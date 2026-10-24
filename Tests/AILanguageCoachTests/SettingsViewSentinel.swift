import Foundation

/// `SettingsView` 一族源码的**全家桶读取**（#662）。
///
/// #662 起 `SettingsView.swift`（3227 行、单结构体 22 个 MARK 段）按主题拆成：
/// - `SettingsView.swift`：主结构体（属性 / body / card 容器 / PartnerRole）
/// - `SettingsView+Appearance.swift`：页头 / 帮助中心 / 显示 / 主题 / 动效 / 声音
/// - `SettingsView+Partner.swift`：伙伴角色 / 森林同伴
/// - `SettingsView+Models.swift`：模型服务商 / 模型运行按钮 / 教师语音选项
/// - `SettingsView+VoiceCenter.swift`：语音模型管理中心 / 远程调用审计
/// - `SettingsView+VoiceCloning.swift`：声音克隆 / 教师语音控制
/// - `SettingsView+Learning.swift`：学习语言 / 练习提醒 / 词汇 / 情景
/// - `SettingsView+Privacy.swift`：隐私与数据 / Finder 揭示按钮
/// - `SettingsView+Runtime.swift`：运行环境 / 每日目标 / 语速
/// - `SettingsView+Cache.swift`：缓存与日志
/// - `SettingsView+Advanced.swift`：快捷中心 / 高级 / 导入导出
///
/// 源码哨兵钉的是**这组设置页**而不是某一个文件 —— 全家桶读取，日后按域再拆也
/// 不再打破哨兵。按文件名排序拼接（顺序确定）→ 计数与行号类判据保持稳定。
///
/// ⚠️ 拼接顺序：`SettingsView+*.swift` 的 `+`（ASCII 43）排在 `SettingsView.swift` 的
/// `.`（ASCII 46）之前 → **定义**会排在**调用点**之前。凡按「首次匹配」做顺序断言的
/// needle，必须收窄到调用点形态（同 #661 的 `grassBlade(x: inset +` 教训）。
enum SettingsViewSentinel {

    /// 目录（相对仓库根；测试进程的 CWD 就是仓库根）。
    static let directory = "Sources/AppUI/Views"

    /// 全家桶前缀：主体 + 全部主题扩展。
    static let prefixes = ["SettingsView"]

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

    /// 全家桶拼接并**剥掉整行注释**（原 `Self.code` / `codeLines(of:)` 的语义）：
    /// 注释里为了说明反例写的旧写法不该把负面断言自己骗过去。
    /// 仅用于原本走这些 helper 的判据；无负面断言的 `contains` 判据用 `joined()` 即可。
    static func joinedCode() throws -> String {
        try joined().split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 剥注释后的行数组（原 `codeLines(of:)` 的返回形态）。
    static func joinedCodeLines() throws -> [String] {
        try joinedCode().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
