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

    public init(id: String, title: String, detail: String, path: String, isSensitive: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.path = path
        self.isSensitive = isSensitive
    }
}

public enum PrivacyDataLocator {

    /// 各类数据的存放位置。
    ///
    /// 路径来源都是各模块自己的默认位置（不在这里重写第二份字面量）。
    public static func locations() -> [DataLocation] {
        [
            DataLocation(
                id: "learning",
                title: "学习记忆",
                detail: "会话、纠错、词汇本、跟读与发音记录",
                path: LearningDatabase.defaultURL().path,
                isSensitive: true
            ),
            DataLocation(
                id: "config",
                title: "应用配置",
                detail: "模型与供应商设置、云端 API Key（仅本机）",
                path: ConfigStore.defaultFileURL().path,
                isSensitive: true
            ),
            DataLocation(
                id: "audit",
                title: "云端调用留痕",
                detail: "仅元数据：能力 / 供应商 / 模型 / 主机 / 时间，不含你的文本",
                path: RemoteCallAudit.logURL().path,
                isSensitive: false
            ),
            DataLocation(
                id: "logs",
                title: "运行日志",
                detail: "仅进程内保留，不写入文件；且禁止记录转写文本与 Prompt 正文",
                path: "（不落盘）",
                isSensitive: false
            ),
        ]
    }

    /// 数据根目录（UI 展示 + 「在 Finder 中打开」用）。
    public static func dataDirectory() -> String {
        AppPaths.userDataDirectory().path
    }
}
