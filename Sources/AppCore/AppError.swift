import Foundation

/// 通用应用层错误。Provider 相关错误见 `AIInterfaces.AIProviderError`。
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
        case .unknown(let m): "未知错误：\(m)"
        }
    }
}
