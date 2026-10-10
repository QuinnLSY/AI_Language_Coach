import AIDomain
import AppCore
import Foundation

/// 本机服务启停命令的**用户授权**（#S2-6）。
///
/// ## 为什么需要
///
/// `ProviderConfig.serviceStartCommand / serviceStopCommand` 是**配置里的一串 shell 命令**，
/// 应用会拿它去 `/bin/sh -lc` 执行。配置文件是纯文本、且**能被备份包覆盖**——
/// 于是「导入一份别人给的备份 → 重启 → 开屏自动拉起」就是一条完整的
/// **任意命令执行**链，而用户全程没有看过一眼那串命令。
///
/// 这不是理论：S2-1 已经把「浮层可同屏叠放」这种前提错误修过一次，
/// 同一个审查里也确认了开屏确实会自动执行这条命令。
///
/// ## 口径：**提示 + 用户确认**（用户 2026-10-10 拍板，保守方案）
///
/// 不做「剥离命令」或「白名单」——本机服务的启动脚本千变万化，白名单会把它挡死；
/// 也不静默放行。做法是：
/// 1. 任何一条命令**第一次**都要用户看见原文并确认；
/// 2. 确认按**命令内容的指纹**记住（`StableFingerprint`）：命令一改，授权立刻失效，
///    重新确认 —— 所以「先让用户看 innocuous 命令、事后换掉内容」这条攻击链也断掉了；
/// 3. 授权只落在 `UserDefaults`（几十字节，不建表），设置页可一键撤销全部。
public enum ShellCommandApproval {

    private static let defaultsKey = "alc.shellCommandApprovals"

    /// 命令内容的稳定指纹（跨启动一致，**不是** `hashValue`）。
    public static func fingerprint(of command: String) -> String {
        StableFingerprint.hex(prefix: "cmd", of: normalize(command))
    }

    /// 这条命令是否已被用户确认过。
    public static func isApproved(_ command: String) -> Bool {
        let key = fingerprint(of: command)
        return approvedKeys().contains(key)
    }

    /// 记下「用户确认过这条命令」。
    public static func approve(_ command: String) {
        var keys = approvedKeys()
        keys.insert(fingerprint(of: command))
        save(keys)
        AppLog.info("已记录本机服务命令的授权（\(fingerprint(of: command))）", category: "service")
    }

    /// 撤销全部授权（设置页「不再自动执行这些命令」）。
    public static func revokeAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    public static func approvedCount() -> Int { approvedKeys().count }

    /// 命令的规范化：去首尾空白。**只去空白、不做别的加工** ——
    /// 指纹必须与 shell 实际拿到的那串一字不差地对应，否则改一个空格就能绕过授权。
    static func normalize(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func approvedKeys() -> Set<String> {
        let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return Set(stored)
    }

    private static func save(_ keys: Set<String>) {
        UserDefaults.standard.set(Array(keys).sorted(), forKey: defaultsKey)
    }
}