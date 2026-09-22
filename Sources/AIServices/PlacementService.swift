import AIDomain
import AIInfrastructure
import Foundation

/// 入学定级的编排服务（进阶 ⑤）。
///
/// 这一层薄得几乎只剩一件事：**把题库读进来、缓存住，按种子递给域层出卷**。
/// 出卷 / 判分 / 定级的规则全在 `AIDomain.EntrancePlacementRule`（纯函数）——
/// 摸底这件事必须能脱机跑完，作答与判分都不许发起模型请求。
///
/// ⚠️ 题库读不到时**返回空**、并留一句说明，绝不内置几道兜底题：
/// 假题目会给出一个真结果（「你是 B1」），那比明确说「题库没读到」糟糕得多。
public actor PlacementService {

    /// 题库在进程内只读一次（资源文件，永不变化）。
    private var bankCache: [PlacementQuestion]?
    /// 上一次加载失败的原因（nil = 正常）。
    private var lastLoadError: String?

    public init() {}

    /// 题库（按档位升序、同档按 id 稳定排序）。
    public func questions() -> [PlacementQuestion] {
        if let bankCache { return bankCache }
        let loaded = PlacementCatalog.bundled()
        bankCache = loaded
        if loaded.isEmpty {
            lastLoadError = "没有读到定级题库（Resources/Placement/*.json），请检查安装包资源是否完整。"
        } else if loaded.count < CEFRLevel.allCases.count {
            // 一档都没有可用的题 → 出卷会跳过这一档，结果只能覆盖到有题的档。
            // 这不是错，但要让用户知道结果的范围。
            lastLoadError = "题库不完整：只读到 \(loaded.count) 道题，定级结果只覆盖有题的那些档位。"
        }
        return loaded
    }

    /// 出一份卷子（种子决定每档抽哪几道；重测换种子即换一批题）。
    public func paper(seed: UInt64) -> PlacementPaper {
        EntrancePlacementRule.paper(from: questions(), seed: seed)
    }

    /// 上一句说明（题库缺失 / 不完整）。
    public func loadNote() -> String? { lastLoadError }
}
