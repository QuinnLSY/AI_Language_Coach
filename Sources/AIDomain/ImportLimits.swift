import Foundation

/// 本地文件导入的体积门槛。
///
/// ⚠️ 与 `AttachmentPolicy`（聊天附件 20 MB）**刻意分开**，不做成一个通用上限：
/// 那一条约束的是「会被内联进请求体」的附件，这里两条约束的是另外两种后果 ——
/// 材料正文会被**整份读进内存**（`String(contentsOfFile:)`），
/// 音色参考音频会被**整份写进数据目录**（学习库与配置和它同处一室）。
/// 三种后果不同，合并成一个数字的那天就是其中一条开始失守的那天。
public enum ImportLimitPolicy {

    /// 材料正文（txt / md）上限 2 MB。
    ///
    /// 2 MB 纯文本约百万字符，远超任何「拿来做练习」的材料体量。
    public static let maxMaterialBytes = 2 * 1024 * 1024

    /// 音色参考音频上限 50 MB。
    ///
    /// 克隆样本通常只有几秒到几十秒，50 MB 已是极宽松；**不给上限**时，
    /// 一个 4 GB 的文件能把数据目录连同学习库、配置一起写挂。
    public static let maxVoiceReferenceBytes = 50 * 1024 * 1024

    /// 读文件体积；读不到返回 `nil`。
    ///
    /// 刻意不兜成 0：读不到体积（文件不存在 / 无权限）时，应当让后面真正的读取动作
    /// 用它自己的错误消息报出来，而不是在这里编一句「空文件」把真实原因盖掉。
    public static func byteCount(ofFileAt url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// 材料正文超限的原因（nil = 放行）。
    public static func materialRejectionReason(fileName: String, byteCount: Int) -> String? {
        rejection(fileName: fileName, byteCount: byteCount,
                  limit: maxMaterialBytes, noun: "文本材料")
    }

    /// 音色参考音频超限的原因（nil = 放行）。
    public static func voiceReferenceRejectionReason(fileName: String, byteCount: Int) -> String? {
        rejection(fileName: fileName, byteCount: byteCount,
                  limit: maxVoiceReferenceBytes, noun: "参考音频")
    }

    private static func rejection(
        fileName: String,
        byteCount: Int,
        limit: Int,
        noun: String
    ) -> String? {
        guard byteCount > 0 else { return "「\(fileName)」是个空文件，没有可用的内容。" }
        guard byteCount > limit else { return nil }
        return "「\(fileName)」有 \(megabytes(byteCount)) MB，超过\(noun) \(limit / 1024 / 1024) MB 的上限。"
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1024 / 1024)
    }
}
