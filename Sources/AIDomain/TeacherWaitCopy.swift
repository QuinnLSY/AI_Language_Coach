import Foundation

/// 老师等待的**真实阶段**（2026-09-27 第三批 #359；2026-10-14 加「总结上次」、去掉「装配」）。
///
/// 为什么不是按秒数分档：按时间编「第三步：润色语言」是**编造进度**，
/// 违反 `TeacherWaitCopy` 第 1 条铁律（没有进度可报就不编百分比）。
/// 这里只有两个**真实存在**的阶段 —— 总结阶段在复盘上一段练习（一次真实模型调用），
/// 生成阶段在等模型吐字，`ChatView` 手里正好有这两个信号（`isPreparingOpening` /
/// `chat.isGreeting`），分界线不是猜的。
///
/// ⚠️ 原来的 `.booting`（启动装配）档已删（2026-10-14 报障）：开屏不再自动开场，
/// 装配那几秒老师**根本没被叫来**，挂一张「老师正在准备…」等于无中生有一条老师发言 ——
/// 那张卡与老师的消息气泡同形（圆头像 + 名字 + 三个跳动的点），用户看到的就是
/// 「一打开老师先发起对话、过一会儿又被引导卡顶掉」。装配期现在直接显示引导卡
/// （话题卡、「继续上次对话」都在，有得可点），比一张假的等待卡诚实得多。
public enum TeacherWaitStage: Int, Sendable, CaseIterable, Comparable {

    /// 总结上次的练习：复盘上一段（点「继续上次对话」之后的第一段真实工作），
    /// 再决定是接着聊、换一段还是继续情景任务。
    case reviewing
    /// 生成开场白：总结完了，模型正在写第一句话。
    case greeting

    public static func < (lhs: TeacherWaitStage, rhs: TeacherWaitStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 阶段条上的短标签。用进行时的「正在…」而不是完成时的名词：
    /// 这一行的高亮就是「现在卡在哪一步」，名字本身要能独立读成一句话。
    public var displayName: String {
        switch self {
        case .reviewing: "正在总结上次的练习"
        case .greeting: "正在写开场白"
        }
    }
}

/// 老师开场等待态的文案（纯函数）。
///
/// 存在理由：开场白是一次**真实模型调用**，冷启动实测 30–60s，而这段时间界面上
/// 只有三个跳动的点 —— 用户分不清「在等模型」还是「已经卡死」。
///
/// 两条硬规则：
/// 1. **只说在等什么，不说还剩多少**：没有进度可报就不编百分比，
///    能报的只有「已经等了多久」这个事实。
/// 2. **等久了才解释原因**：刚等两秒就说「第一次会慢」，像在给卡顿找借口；
///    真等到八秒，这句解释才是用户此刻最需要的信息。
public enum TeacherWaitCopy {

    /// 从第几秒开始报秒数（一上来就蹦数字会像倒计时出错）。
    public static let showSecondsFrom = 3
    /// 从第几秒开始解释「为什么慢」。
    public static let explainFrom = 8

    /// 主标题。
    public static func title(seconds: Int) -> String {
        guard seconds >= showSecondsFrom else { return "老师正在准备…" }
        return "老师正在准备…（已等待 \(seconds) 秒）"
    }

    /// 副标题：只在真的等久了才出现。`nil` = 这一行不显示。
    public static func detail(seconds: Int) -> String? {
        guard seconds >= explainFrom else { return nil }
        return "第一次打开要把模型加载进内存，会慢一些；之后就快了。"
    }
}
