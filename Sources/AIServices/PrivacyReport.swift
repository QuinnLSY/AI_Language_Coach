import AIDomain
import AIInfrastructure

/// 隐私状况快照（设置页「隐私与安全」卡片的数据源）。
///
/// 之所以单独成一个类型：披露结论与存储位置**由不同层产出**（域层算策略、基础设施层给路径），
/// 在这里合体后 UI 只消费一个值，不必自己拼。
public struct PrivacyReport: Sendable, Equatable {

    /// 当前生效的外发情况（按能力推导，不是按「有没有 Key」猜）。
    public let disclosure: PrivacyPolicy.Disclosure
    /// 本地数据存放位置清单。
    public let locations: [DataLocation]
    /// 数据根目录（供「在 Finder 中打开」）。
    public let dataDirectory: String

    public init(disclosure: PrivacyPolicy.Disclosure, locations: [DataLocation], dataDirectory: String) {
        self.disclosure = disclosure
        self.locations = locations
        self.dataDirectory = dataDirectory
    }

    public static let empty = PrivacyReport(
        disclosure: PrivacyPolicy.Disclosure(flows: []),
        locations: [],
        dataDirectory: ""
    )
}
