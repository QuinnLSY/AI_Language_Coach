import Foundation

/// 跨进程稳定的指纹（FNV-1a，取低 32 位拼成 8 位十六进制）。
///
/// ⚠️ **绝不能用 `Hasher` / `hashValue`**：它们每个进程一个随机种子，同一个输入
/// 在不同启动下得到不同的值 —— 拿它生成落盘 id，「同一份材料 / 同一个情景」
/// 重启后就会变成两份，去重、覆盖更新全部失效。
///
/// 落盘单元的 id（材料 `material-*`、自定义情景 `custom-scenario-*` …）一律走这里。
public enum StableFingerprint {

    /// 生成 `<prefix>-<8位hex>`。
    ///
    /// - Parameter text: 参与指纹的原文（调用方自己决定取多少字、要不要拼分隔符）。
    public static func hex(prefix: String, of text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // ⚠️ 把 prefix 拼在 format 串**外面**：它若含 `%` 会被当成格式符（用户输入不可控）。
        return prefix + String(format: "-%08x", UInt32(truncatingIfNeeded: hash))
    }
}
