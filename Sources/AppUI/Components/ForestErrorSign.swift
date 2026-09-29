import SwiftUI

/// 错误举牌（批次八 · H 边界状态）：老师联系不上时，林子里的小动物举一块牌子。
///
/// 详情仍然走聊天区的错误横幅（那里有完整可读的错误与建议，口径见 `AppError`
/// 六档纪律）；牌子上只写一句**短的、拟人的**概括 —— 让「出事了」从余光就看得见，
/// 而不是只有聊天区一行字。两处互不掺和：这里是林间小剧场的台词，不是错误文案本体。
public enum ForestErrorSign {

    /// 从 ChatService 的错误消息里挑一句举牌文案（纯函数，单测逐类钉住）。
    ///
    /// 消息来自 `ModelDiagnostics`（中英文混排），关键词**大小写都收**：
    /// 先 `lowercased()` 再比对，英文关键词一律小写形态。
    public static func headline(for message: String) -> String {
        let lowered = message.lowercased()
        // ⚠️ 只认「API key」这一个搭配，不认裸 `key`：后者会把 KeyError /
        // "key not found" / "keyword" 这类与鉴权无关的消息也翻成「钥匙不对」——
        // 举错牌子比不举更糟（用户会去查一个根本没问题的密钥）。
        if lowered.contains("密钥") || lowered.contains("鉴权") || lowered.contains("401")
            || lowered.contains("unauthorized") || lowered.contains("api key")
            || lowered.contains("apikey") || lowered.contains("api_key") {
            return "钥匙好像不对…"
        }
        if lowered.contains("未配置") || lowered.contains("没有可用") || lowered.contains("未启用")
            || lowered.contains("not configured") {
            return "老师还没来…"
        }
        if lowered.contains("未运行") || lowered.contains("未启动") || lowered.contains("stopped")
            || lowered.contains("不在运行") {
            return "老师在打盹…"
        }
        if lowered.contains("网络") || lowered.contains("超时") || lowered.contains("timeout")
            || lowered.contains("timed out") || lowered.contains("连接") || lowered.contains("connection")
            || lowered.contains("network") {
            return "风太大，话传不过来…"
        }
        return "先歇一歇，等会儿再试"
    }
}

/// 举牌视图：牌面写一句话，下面一根小杆插在草地上、举在小动物头顶。
struct ForestSignBoard: View {
    let theme: ForestTheme
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(theme.accent.opacity(0.45), lineWidth: 1)
                        )
                        .shadow(color: theme.shadow, radius: 3, x: 0, y: 2)
                )
            // 牌子的杆
            Capsule()
                .fill(theme.trunkShade)
                .frame(width: 3, height: 22)
        }
        // 读屏：牌子是对错误的装饰性转述，完整错误在聊天区横幅里，这里不重复念。
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
