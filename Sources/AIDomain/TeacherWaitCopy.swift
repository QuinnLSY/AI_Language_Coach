import Foundation

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
