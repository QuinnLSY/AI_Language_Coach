import Foundation

/// 通用应用层错误。Provider 相关错误见 `AIInterfaces.AIProviderError`。
///
/// **前五档会给消息加一个品类前缀，`.unknown` 不加** —— 两者的消息来源不同：
///
/// - 前五档的消息通常是「哪个动作失败了」的片段（`保存配置失败：…`），前面补一个
///   「存储错误」/「数据库错误」能告诉用户**这是哪一层**出的问题；
/// - `.unknown` 是收容所，投进来的**本身就是完整的一句话**，而且大多来自
///   `ModelDiagnostics.describe` 这类会自己交代「谁、怎么坏的」的地方
///   （`本地模型 · qwen3:8b 服务未启动或不可达：…`）。再罩一层「未知错误：」
///   既没多给信息，还把**已经确诊**的失败说成了「未知」——用户看到「未知错误」
///   只会以为是程序崩了，而不是「材料短了 3 个字」。
///
/// 所以往 `.unknown` 里丢东西时，请**直接写给人看的那句话**，不要写内部术语。
public enum AppError: Error, Sendable, LocalizedError, Equatable {
    case configuration(String)
    case permission(String)
    case storage(String)
    case audio(String)
    case database(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .configuration(let m): "配置错误：\(m)"
        case .permission(let m): "权限不足：\(m)"
        case .storage(let m): "存储错误：\(m)"
        case .audio(let m): "音频错误：\(m)"
        case .database(let m): "数据库错误：\(m)"
        case .unknown(let m): m
        }
    }
}
