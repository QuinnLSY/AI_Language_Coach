import Foundation

/// 模型「启动 / 关闭」按钮的状态判定（纯函数，便于单测）。
///
/// 语义是「这个模型**现在真的能用**吗」，而不是「用户有没有点过关闭」：
///
/// - 只看「用户意图」，会出现死角——本地服务没启动时，卡片写着「服务未启动或不可达」，
///   按钮却只有一个红色的「关闭」，用户无处可点；
/// - 只看「健康检查」，用户主动关掉的模型又会变回「启动」，与用户意图打架。
///
/// 所以只有**两者同时成立**才算「运行中」（按钮显示红色「关闭」），
/// 其余一律显示绿色「启动」——本地点它真的会拉起后台服务，云端点它重新校验连接。
public enum ModelRunControl {

    /// 是否处于「运行中」（按钮显示「关闭」）。
    public static func isActive(running: Bool, healthOK: Bool) -> Bool {
        running && healthOK
    }

    /// 点一下按钮后应当切到的状态（运行中 → 关闭；其余 → 启动）。
    public static func nextRunningState(running: Bool, healthOK: Bool) -> Bool {
        !isActive(running: running, healthOK: healthOK)
    }

    /// 按钮文案。
    public static func title(running: Bool, healthOK: Bool) -> String {
        isActive(running: running, healthOK: healthOK) ? "关闭" : "启动"
    }

    /// 按钮图标。
    public static func systemImage(running: Bool, healthOK: Bool) -> String {
        isActive(running: running, healthOK: healthOK) ? "stop.circle.fill" : "play.circle.fill"
    }
}
