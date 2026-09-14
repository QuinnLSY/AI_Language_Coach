import Foundation

/// API Key / 凭据文本的**粘贴清洗**（纯函数，脱机可测）。
///
/// 为什么需要它：用户在厂商控制台复制的「Key」常常不是 Key 本身 ——
/// 常见形态是 `"sk-xxx"`（带引号）、`Bearer sk-xxx`（带认证前缀）、
/// 或者从多行文本框里复制时夹了换行与空格。
/// 这些**肉眼几乎看不出来**，但发出去就是 `Authorization: Bearer "sk-xxx"`，
/// 服务端只会回一句「Invalid token」，用户于是反复重建 Key 却怎么也通不过
/// （2026-09-14 反馈：「重新创建了 key 也是无效」）。
///
/// 清洗规则（只做「几乎不可能是 Key 一部分」的删除，绝不改动 Key 本体）：
/// 1. 去掉首尾空白与换行；
/// 2. 去掉成对包裹的引号（`"` `'` `“”` `‘’`）；
/// 3. 去掉开头的 `Bearer` / `bearer:` 之类前缀；
/// 4. 去掉**内部**所有空白与换行（Key 里不可能有空格，有就是复制带进来的）。
///
/// 反例（明确**不做**）：不改大小写、不做 URL 解码、不截断长度 ——
/// 那些都可能把一个合法 Key 改坏，而「改坏 Key」比「让用户重贴一次」严重得多。
public enum CredentialText {

    /// 清洗后的 Key。空输入返回空串。
    public static func normalizedKey(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripWrappingQuotes(text)
        text = stripAuthorizationPrefix(text)
        // 内部空白：粘贴时夹进来的换行 / 空格 / 制表符。Key 本体不含空白字符。
        text = text.components(separatedBy: .whitespacesAndNewlines).joined()
        // 去掉前缀之后可能又露出引号（`Bearer "sk-x"`）或反过来，再各来一轮。
        text = stripAuthorizationPrefix(stripWrappingQuotes(text))
        return text
    }

    /// 是否「看起来做过清洗」——用于在界面上提示用户我们改了什么。
    public static func needsCleaning(_ raw: String) -> Bool {
        let normalized = normalizedKey(raw)
        return !raw.isEmpty && normalized != raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 安全描述（可展示给人看，绝不泄露凭据本体）：`51 位，末尾 ••••2f9a`。
    public static func safeDescription(_ key: String) -> String {
        guard !key.isEmpty else { return "空" }
        guard key.count > 4 else { return "\(key.count) 位（过短，可能是复制不完整）" }
        return "\(key.count) 位，末尾 ••••\(key.suffix(4))"
    }

    // MARK: - 内部

    private static func stripWrappingQuotes(_ text: String) -> String {
        var result = text
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
        var changed = true
        while changed, result.count >= 2 {
            changed = false
            guard let first = result.first, let last = result.last else { break }
            if pairs.contains(where: { $0.0 == first && $0.1 == last }) {
                result = String(result.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return result
    }

    private static func stripAuthorizationPrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in ["bearer:", "bearer ", "bearer"] where lower.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

/// 云端鉴权失败的可读说明（纯函数）。
///
/// 401 只有「密钥不对」一种笼统说法是不够的：服务端其实分得清
/// 「根本没带 Key」（Token not provided）与「带了但 Key 无效」（Invalid token），
/// 这两者的处置完全不同 —— 前者是应用没送出去，后者是 Key 本身的问题。
/// 把服务端原文、请求地址、以及**本次到底送出了什么**一并说出来，
/// 用户（和排查的人）才能一眼定位（2026-09-14 反馈的排查诉求）。
public enum RemoteAuthDiagnostics {

    /// - Parameters:
    ///   - address: 请求地址（host + path，**不含** query，避免泄敏）。
    ///   - keyDescription: `CredentialText.safeDescription` 的结果。
    public static func unauthorized(
        address: String,
        keyDescription: String,
        serverMessage: String?
    ) -> String {
        let server = cleaned(serverMessage)
        if keyDescription == "空" {
            return """
                请求没有携带 API Key，服务端因此拒绝。服务端原文：\(server)。地址 \(address)。\
                请把 Key 填进输入框后再试——输入框为空时应用不会使用任何已保存的旧密钥。
                """
        }
        return """
            服务端拒绝了这个 Key。服务端原文：\(server)。本次送出 \(keyDescription)；地址 \(address)。\
            若刚重建过 Key，请确认粘贴的内容就是 Key 本身（引号、「Bearer 」前缀、换行都会被自动清理）。
            """
    }

    private static func cleaned(_ message: String?) -> String {
        let trimmed = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "（服务端未给出说明）" }
        // 服务端偶发返回整页 HTML；截断以免把报错框撑爆。
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
    }
}
