import AppCore
import Foundation

/// 本地数据到底存在哪——**文档化**（Phase 29 要求 "Local storage locations documented"）。
///
/// 与其把路径散落在各个模块里、让用户在 Finder 里瞎找，不如集中列一份清单：
/// UI 直接展示它，用户也知道「我的东西在哪、删了会丢什么」。
public struct DataLocation: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    /// 这份数据里有什么（人话，不是文件名）。
    public let detail: String
    /// 绝对路径；不落盘的写占位说明。
    public let path: String
    /// 是否属于个人敏感数据（UI 据此加标识）。
    public let isSensitive: Bool
    /// 「在 Finder 中打开这一项」的目标；nil = 不可打开（如不落盘的日志）。
    ///
    /// 单一路径字符串是不够用的：根目录按钮只能把人带到门口，
    /// 而用户问的是「我发的那张图在哪」「我的音色档案在哪」——
    /// 每一行自己带一个落点，才谈得上「数据位置可自查」。
    public let revealPath: String?

    public init(id: String, title: String, detail: String, path: String, isSensitive: Bool, revealPath: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.path = path
        self.isSensitive = isSensitive
        self.revealPath = revealPath
    }
}

public enum PrivacyDataLocator {

    /// 各类数据的存放位置。
    ///
    /// 路径来源都是各模块自己的默认位置（不在这里重写第二份字面量）。
    ///
    /// - Parameters:
    ///   - attachmentDirectory: 对话附件目录。由**服务层**传进来的原因：附件路径的唯一出口
    ///     是 `AttachmentStore.storageDirectory`，在这里重拼一次就多了一份真相。
    ///   - voiceProfilesFile: 音色档案文件（参考音频 + 授权留痕），同样是用户资产。
    public static func locations(
        attachmentDirectory: URL? = nil,
        voiceProfilesFile: URL? = nil
    ) -> [DataLocation] {
        var result: [DataLocation] = [
            DataLocation(
                id: "learning",
                title: "学习记忆",
                detail: "会话、纠错、词汇本、跟读与发音记录",
                path: LearningDatabase.defaultURL().path,
                isSensitive: true,
                revealPath: LearningDatabase.defaultURL().path
            ),
            DataLocation(
                id: "config",
                title: "应用配置",
                detail: "模型与供应商设置、云端 API Key（仅本机）",
                path: ConfigStore.defaultFileURL().path,
                isSensitive: true,
                revealPath: ConfigStore.defaultFileURL().path
            ),
            DataLocation(
                id: "audit",
                title: "云端调用留痕",
                detail: "仅元数据：能力 / 供应商 / 模型 / 主机 / 时间，不含你的文本",
                path: RemoteCallAudit.logURL().path,
                isSensitive: false,
                revealPath: RemoteCallAudit.logURL().path
            ),
            DataLocation(
                id: "logs",
                title: "运行日志",
                detail: "仅进程内保留，不写入文件；且禁止记录转写文本与 Prompt 正文",
                path: "（不落盘）",
                isSensitive: false
            ),
        ]
        if let attachmentDirectory {
            result.insert(
                DataLocation(
                    id: "attachments",
                    title: "对话附件",
                    detail: "你在对话里发过的图片与文档原文件（随会话保留）",
                    path: attachmentDirectory.path,
                    isSensitive: true,
                    revealPath: attachmentDirectory.path
                ),
                at: 1
            )
        }
        if let voiceProfilesFile {
            result.insert(
                DataLocation(
                    id: "voices",
                    title: "克隆音色档案",
                    detail: "参考音频路径与授权留痕（与配置分开存放，可单独备份）",
                    path: voiceProfilesFile.path,
                    isSensitive: true,
                    revealPath: voiceProfilesFile.path
                ),
                at: result.count - 1
            )
        }
        return result
    }

    /// 数据根目录（UI 展示 + 「在 Finder 中打开」用）。
    public static func dataDirectory() -> String {
        AppPaths.userDataDirectory().path
    }
}
