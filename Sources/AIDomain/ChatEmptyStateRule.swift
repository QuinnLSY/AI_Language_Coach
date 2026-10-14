import Foundation

/// 对话区「空态 / 进行中」判据（纯函数）。
///
/// 单独拎出来的理由：这条判据**漏一个条件，界面就开始说谎**。
/// 判据原来写成一句布尔表达式埋在视图里，日后新增状态没人会记得回头补；
/// 做成函数才能把每个条件一条条钉住。
///
/// ⚠️ 2026-10-14 把参数从 `isBooting` 换成 `isTeacherPreparing`（报障：开屏先冒出一条
/// 「老师发言」再被引导卡顶掉）。装配那几秒属于「本地服务在拉起来」，开屏**不再自动开场**，
/// 老师并没有被叫来 —— 那时该显示的是引导卡（话题卡、继续上次对话都在，有得可点），
/// 而不是一张写着「老师正在准备…」的等待卡（它与老师的消息气泡同形）。
/// 等待卡只在**真的有人要说话**时出现：点「继续上次对话」后的复盘，或正在写开场白。
public enum ChatEmptyStateRule {

    /// 该不该显示「和老师打个招呼」那张引导卡。
    ///
    /// 只有「真的什么都没有、而且也没有任何东西在路上」时才显示。
    public static func showsInvitation(
        messageCount: Int,
        hasStreamingText: Bool,
        hasStreamingReasoning: Bool,
        isGenerating: Bool,
        isTeacherPreparing: Bool
    ) -> Bool {
        guard messageCount == 0, !hasStreamingText, !hasStreamingReasoning else { return false }
        return !isGenerating && !isTeacherPreparing
    }

    /// 该不该在消息列表后面挂一张「进行中」的卡（等待卡或流式卡）。
    ///
    /// ⚠️ 必须认 `isTeacherPreparing`：点「继续上次对话」之后的第一段是**复盘上一段**
    /// （一次真实模型调用，不走 `chat` 的生成通道，`isGenerating` 是 false）——
    /// 不认它的话，引导卡会在点击后原封不动留在屏幕上，用户以为那一下没点上。
    /// 开场白同理：`chat.isGreeting` 期间 `streamingText` 还是空的。
    public static func showsPendingCard(
        isGenerating: Bool,
        isTeacherPreparing: Bool
    ) -> Bool {
        isGenerating || isTeacherPreparing
    }
}
