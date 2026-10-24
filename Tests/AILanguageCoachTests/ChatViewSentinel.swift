import Foundation

/// `ChatView` 一族源码的**全家桶读取**（#663）。
///
/// #663 起 `ChatView.swift`（2896 行：单结构体 + 5 个尾部类型）按主题拆成：
/// - `ChatView.swift`：主结构体（属性 / body / 杂项 helper）
/// - `ChatView+Header.swift`：头部（模型名 / 上下文环 / 状态行）
/// - `ChatView+Briefing.swift`：前情提要条 / 情景目标条 / 练习提醒
/// - `ChatView+Messages.swift`：消息区滚动骨架（滚动跟随 / 跳底 / 淡入遮罩 / 特卡）
/// - `ChatView+Bubbles.swift`：消息行（时间戳 / 空态 / 继续上次 / 错误条 / 气泡 / 编辑）
/// - `ChatView+Translation.swift`：译文卡片与纠错卡（含 TranslateButton / SpeakButton / 语速菜单）
/// - `ChatView+Banners.swift`：输入区上方各类提示条（停服 / 语音错 / 译文错 / 素材错）
/// - `ChatView+Composer.swift`：输入区布局（工具栏 / 发送 / 素材托盘 / 素材选取）
/// - `ChatView+InputField.swift`：输入框本体 / 发送条件 / 取消语音 / 麦克风
/// - `ChatView+ComposerInfo.swift`：上下文占用说明 / 考试占位文案 / `send()`
/// - `ChatView+Panels.swift`：尾部 5 个类型（ThinkingPanel / ContextGauge / TypingDots /
///   StarterQuestionRotator / RollingStarterQuestionView）
///
/// 源码哨兵钉的是**这组对话页**而不是某一个文件 —— 全家桶读取，日后按域再拆也
/// 不再打破哨兵。按文件名排序拼接（顺序确定）→ 计数与行号类判据保持稳定。
///
/// ⚠️ 拼接顺序：`ChatView+*.swift` 的 `+`（ASCII 43）排在 `ChatView.swift` 的
/// `.`（ASCII 46）之前 → **定义**会排在**调用点**之前。凡按「首次匹配」做顺序断言的
/// needle，必须收窄到调用点形态（同 #661 的 `grassBlade(x: inset +` 教训）。
enum ChatViewSentinel {

    /// 目录（相对仓库根；测试进程的 CWD 就是仓库根）。
    static let directory = "Sources/AppUI/Views"

    /// 全家桶前缀：主体 + 全部主题扩展。
    static let prefixes = ["ChatView"]

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
