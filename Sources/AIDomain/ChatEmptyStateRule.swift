import Foundation

/// 对话区「空态 / 进行中」判据（纯函数）。
///
/// 单独拎出来的理由：这条判据**漏一个条件，界面就开始说谎**。
/// 启动装配那几秒 `isGenerating` 还是 false、消息也是空的，于是「和老师打个招呼，
/// 开始今天的攀爬吧」照常出现 —— 而那一刻打招呼根本没有东西接得住
/// （冷启动实测 30–60s 才轮到老师说第一句）。
///
/// 判据原来写成一句布尔表达式埋在视图里，日后新增状态没人会记得回头补；
/// 做成函数才能把每个条件一条条钉住。
public enum ChatEmptyStateRule {

    /// 该不该显示「和老师打个招呼」那张引导卡。
    ///
    /// 只有「真的什么都没有、而且也没有任何东西在路上」时才显示。
    public static func showsInvitation(
        messageCount: Int,
        hasStreamingText: Bool,
        hasStreamingReasoning: Bool,
        isGenerating: Bool,
        isBooting: Bool
    ) -> Bool {
        guard messageCount == 0, !hasStreamingText, !hasStreamingReasoning else { return false }
        return !isGenerating && !isBooting
    }

    /// 该不该在消息列表后面挂一张「进行中」的卡（等待卡或流式卡）。
    ///
    /// ⚠️ 必须认 `isBooting`：启动装配那段 `isGenerating` 还是 false，
    /// 只认它的话这几秒对话区是一片空白（消息同样是空的）。
    public static func showsPendingCard(isGenerating: Bool, isBooting: Bool) -> Bool {
        isGenerating || isBooting
    }
}
