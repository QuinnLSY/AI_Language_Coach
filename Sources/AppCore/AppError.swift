import Foundation

/// 通用应用层错误。Provider 相关错误见 `AIInterfaces.AIProviderError`。
///
/// **六档一律原样透出消息，谁也不加品类前缀。** 上一版是「前五档加前缀、`.unknown` 不加」，
/// 结果是同一句话里出现两个冒号，甚至三个：
///
/// ```
/// 保存音色失败：存储错误：保存音色档案失败：文件 “x” 无法写入。   ← 修之前
/// 保存音色档案失败：文件 “x” 无法写入。                          ← 现在
/// ```
///
/// 三层各有各的错，但病根只有一个：**前缀让消息看起来像「片段」**——于是 `catch`
/// 处觉得自己该补动作名，而动作名抛出点早就写过了。去掉前缀之后消息就是一句完整的话，
/// `catch` 自然只做透出（口径见 `MEMORY.md` 的「用户可见文案」）。
///
/// 顺带一提「存储错误」「数据库错误」这类前缀本身也没多大用：用户既不能据此决定做什么，
/// 也无法判断严重性——他需要的是「什么动作失败了 + 为什么 + 能不能重试」。而**分类并没有丢**：
/// 它留在这几个 `case` 上，日志、诊断、测试照样能分辨是配置还是存储出的问题。
///
/// 所以往任何一档里丢东西时，请**直接写给人看的那句话**（动作 + 原因），不要写内部术语，
/// 也不要指望前缀替你补上下文。
public enum AppError: Error, Sendable, LocalizedError, Equatable {
    case configuration(String)
    case permission(String)
    case storage(String)
    case audio(String)
    case database(String)
    case unknown(String)

    /// 六档共用一支：消息即文案。
    ///
    /// 写成合并的 `case` 分支是有意的——它让「六档行为完全一致」成为一眼可见的事实，
    /// 将来谁想给某一档单独加前缀，就必须先把这个分支拆开，拆的时候会读到上面那段理由。
    public var errorDescription: String? {
        switch self {
        case .configuration(let m), .permission(let m), .storage(let m),
             .audio(let m), .database(let m), .unknown(let m):
            m
        }
    }
}
