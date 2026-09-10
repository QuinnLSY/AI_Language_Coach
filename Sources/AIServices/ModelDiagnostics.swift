import AIInterfaces
import Foundation

/// 统一把「模型不可用」翻译成人能看懂的一句话：**哪个模型 + 为什么 + 怎么办**。
///
/// 设计约束：
/// - 纯函数，不依赖任何 Provider / 网络，便于单测与复用（对话区、设置页、启动提示共用）。
/// - 文案只包含用户可见的 Provider 名与模型名，**不含路径、密钥、堆栈**。
/// - 一律以「哪个模型」开头，用户不需要猜是哪个组件出了问题。
public enum ModelDiagnostics {

    /// 一句话描述某个模型：`本地模型 · qwen3:8b`。
    /// model 为空时只留 Provider 名（如 `DeepSeek`），不出现「nil/空」这类字眼。
    public static func label(providerName: String?, model: String?) -> String {
        let name = (providerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (name.isEmpty, trimmedModel.isEmpty) {
        case (false, false): return "\(name) · \(trimmedModel)"
        case (false, true): return name
        case (true, false): return trimmedModel
        case (true, true): return "模型"
        }
    }

    /// 把 ProviderHealth 翻成「哪个模型怎么了」。
    public static func describe(providerName: String?, model: String?, health: ProviderHealth) -> String {
        describe(label: label(providerName: providerName, model: model), health: health)
    }

    /// 把底层错误翻成「哪个模型怎么了」。
    public static func describe(providerName: String?, model: String?, error: Error) -> String {
        describe(label: label(providerName: providerName, model: model), error: error)
    }

    /// 已经拿到完整标签（如 `本地模型 · qwen3:8b`）时的入口。
    public static func describe(label who: String, health: ProviderHealth) -> String {
        switch health {
        case .connected:
            return "\(who) 已就绪"
        case .runtimeUnavailable(let reason):
            return "\(who) 服务未启动或不可达：\(clean(reason))\(hint(for: reason))"
        case .modelUnavailable(let missing):
            return "\(who) 不可用：该模型未在服务中安装\(hint(for: missing))"
        case .configurationInvalid(let reason):
            return "\(who) 配置有误：\(clean(reason))"
        case .requestFailed(let reason):
            return "\(who) 请求失败：\(clean(reason))\(hint(for: reason))"
        }
    }

    /// 已经拿到完整标签时的入口。
    public static func describe(label who: String, error: Error) -> String {
        guard let providerError = error as? AIProviderError else {
            let text = error.localizedDescription
            return "\(who) 调用失败：\(clean(text))\(hint(for: text))"
        }
        switch providerError {
        case .notInitialized:
            return "\(who) 还未就绪（正在启动中），请稍等片刻再发送一次。"
        case .invalidConfiguration(let reason):
            return "\(who) 配置有误：\(clean(reason))"
        case .runtimeUnavailable(let reason):
            return "\(who) 服务未启动或不可达：\(clean(reason))\(hint(for: reason))"
        case .modelUnavailable(let name):
            return "\(who) 不可用：服务里没有模型 \(name)，请在设置中选择已安装的模型。"
        case .connectionFailed(let reason):
            return "\(who) 连接失败：\(clean(reason))\(hint(for: reason))"
        case .timeout(let reason):
            return "\(who) 响应超时：\(clean(reason))。若模型是首次加载，稍后会快一些。"
        case .serverError(let status, let message):
            let detail = message.map { "（\(clean($0))）" } ?? ""
            return "\(who) 服务端错误 \(status)\(detail)"
        case .invalidRequest(let reason):
            return "\(who) 请求无效：\(clean(reason))"
        case .invalidResponse(let reason):
            return "\(who) 响应无法解析：\(clean(reason))"
        case .loadFailed(let reason):
            return "\(who) 加载失败：\(clean(reason))"
        case .cancelled:
            return "\(who) 调用已取消。"
        case .outOfMemory:
            return "\(who) 显存/内存不足，请关闭其它占用 GPU 的程序后重试。"
        case .unsupportedCapability(let reason):
            return "\(who) 不支持该能力：\(clean(reason))"
        case .runtimeCrash(let reason):
            return "\(who) 运行时异常：\(clean(reason))"
        }
    }

    /// 模型可用性提示：模型被用户关闭时，明确告诉他去哪打开。
    public static func stoppedHint(providerName: String?, model: String?) -> String {
        "\(label(providerName: providerName, model: model)) 已关闭，请在「设置 → 模型」里点绿色的「启动」按钮后再对话。"
    }

    // MARK: - 内部

    /// 去掉原因里冗长的英文前后缀，保留可读部分。
    private static func clean(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未知原因" }
        return trimmed
    }

    /// 按关键词给一句可操作的建议（只说该做什么，不猜实现细节）。
    private static func hint(for reason: String) -> String {
        let text = reason.lowercased()
        let serviceWords = ["refused", "could not connect", "connection", "not connected", "network",
                            "host", "unreachable", "ssl", "超时", "timed out", "timeout"]
        if serviceWords.contains(where: { text.contains($0) }) {
            return "。请确认该模型的服务已启动（本地模型可在设置里点「启动」）。"
        }
        if text.contains("404") || text.contains("not found") {
            return "。请检查设置里的模型名是否正确。"
        }
        if text.contains("401") || text.contains("403") || text.contains("api key") || text.contains("unauthorized") {
            return "。请检查 API Key 是否有效。"
        }
        return ""
    }
}
