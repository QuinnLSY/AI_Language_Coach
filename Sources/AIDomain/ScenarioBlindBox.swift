import Foundation

// MARK: - 盲盒情景（随机开局）
//
// 为什么要有这一层：情景面板是一张几十条的清单，而清单对「不知道练什么」的人毫无帮助 ——
// 他上下翻一遍，最后还是关掉面板去随口练。清单解决的是「我知道要什么」，
// 盲盒解决的是「我不知道，你随便给我一个」。
//
// 四条规矩：
//
// 1. **抽不到刚抽过的那个**。连点「换一个」必须每次都换 —— 抽回同一个，
//    学员只会以为按钮坏了（「我点了，它没动」），而实际上它只是随机回了原地。
// 2. **可复现**：同样的（池、上一次的 id、第几次抽）一定抽出同一个。
//    这条不是为用户，是为测试：不能复现的随机只能靠「跑一百次看看」来验，
//    那种测试永远是绿的，也永远什么都没验。
// 3. **刻意不按天恒定**（不走 `DailySeed` 那套）：盲盒的乐趣就在「每次都不一样」，
//    按天恒定它就成了每日推荐，开屏看一眼再关掉。
// 4. **没练过的排前面**：盲盒的意义是带你去没去过的地方；全练过了才回到整池重抽。
//
// 纯函数、零 IO、不 import UI。

/// 盲盒池里的一条（**只有界面要展示的那几个字段**，别把整个 `Scenario` 搬进来）。
///
/// 之所以不直接抽 `Scenario`：抽签只关心「叫什么、哪一档、练没练过」，
/// 传整个素材进来，将来任何一个字段变动都会把这一层拖着改一遍。
public struct BlindBoxEntry: Sendable, Equatable, Identifiable {

    public var id: String
    /// 母语标题（卡片主标题；素材没写时由调用方退成学习语言标题）。
    public var title: String
    /// 学习语言标题。
    public var subtitle: String
    /// 分组（如「旅行」）。
    public var category: String
    /// 已经过关（排到后面抽）。
    public var isCompleted: Bool

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        category: String = "",
        isCompleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.isCompleted = isCompleted
    }
}

public enum ScenarioBlindBox {

    /// 种子用途（与别的「确定性随机」各走各的序列，互不牵连）。
    ///
    /// ⚠️ 与 `DailySeed.seed` 同款理由，绝不能用 `Hasher`：它每进程换种子，
    /// 同一份输入跨启动会抽出不同的情景。
    private static let purpose = "scenario-blindbox"

    // MARK: - 入池

    /// 哪些情景进盲盒池。
    ///
    /// - 课内情景（`.course`）**不进**：它们在课卡里逐节列着，抽到也滚不过去
    ///   （面板上那张卡根本不在散装分组里）。
    /// - 正在练的那个**不进**：它已经在练了，抽到它等于原地不动，
    ///   学员看到的是「我抽了一下，回到了我正在做的事」。
    public static func entries(
        from scenarios: [Scenario],
        completedIDs: Set<String> = [],
        activeID: String? = nil
    ) -> [BlindBoxEntry] {
        var seen: Set<String> = []
        var pool: [BlindBoxEntry] = []
        for scenario in scenarios {
            // id 为空的素材没法滚、也没法开练，进了池就是点了没反应。
            guard !scenario.id.isEmpty else { continue }
            guard scenario.origin != .course else { continue }
            if let activeID, !activeID.isEmpty, scenario.id == activeID { continue }
            guard seen.insert(scenario.id).inserted else { continue }
            pool.append(BlindBoxEntry(
                id: scenario.id,
                // ⚠️ `titleZh` 空了（用户自建素材常这样）就退成英文标题，
                // 别让卡上开出一个空名字 —— 那比不抽还让人怀疑。
                title: scenario.titleZh.isEmpty ? scenario.title : scenario.titleZh,
                subtitle: scenario.title,
                category: scenario.category,
                isCompleted: completedIDs.contains(scenario.id)
            ))
        }
        return pool
    }

    // MARK: - 抽

    /// 抽一个。
    ///
    /// - Parameters:
    ///   - pool: 候选池（`entries(from:)` 的产出）。
    ///   - avoiding: 上一次抽到的 id —— **绝不**再抽它。
    ///   - roll: 第几次抽（每次抽都 +1；换一个全靠它换序列）。
    /// - Returns: 抽中的那条；池为空时 nil（调用方据此不画按钮）。
    public static func pick(
        from pool: [BlindBoxEntry],
        avoiding: String?,
        roll: Int
    ) -> BlindBoxEntry? {
        let pool = deduplicated(pool)
        guard !pool.isEmpty else { return nil }

        // 没练过的排前面；全练过了才回到整池（那时候「随机」就是随机重练一关）。
        let fresh = pool.filter { !$0.isCompleted }
        let tier = fresh.isEmpty ? pool : fresh

        let rotated = tier.filter { $0.id != avoiding }
        guard !rotated.isEmpty else {
            // 这一档里只剩刚抽过的那个：退回整池再排一次。
            // 整池也只剩它一个（或全是它）→ 认了，总比返回 nil 让按钮变成死的强。
            return pool.filter { $0.id != avoiding }.first ?? tier.first
        }

        var rng = SeededRandomGenerator(seed: DailySeed.seed(
            for: "roll=\(roll)\u{1}avoid=\(avoiding ?? "-")",
            purpose: purpose
        ))
        let index = Int(rng.next() % UInt64(rotated.count))
        return rotated[index]
    }

    /// 面板上这一行此刻该显示哪一条（**只有抽中的那张卡还展开着才算**）。
    ///
    /// 用户自己把它收起、或展开到别张卡上，这一行就该回到「从 N 个里挑」——
    /// 否则会出现「上面写着开出《X》，下面 X 那张卡是收起的」，两处对不上。
    /// 这条判据放在领域层而不是视图里：它是规则，且只有这样才测得到。
    public static func revealedEntry(
        in pool: [BlindBoxEntry],
        lastID: String?,
        expandedID: String?
    ) -> BlindBoxEntry? {
        guard let lastID, lastID == expandedID else { return nil }
        return pool.first { $0.id == lastID }
    }

    // MARK: - 文案（一律插真值，不许写死）

    /// 按钮名：第一下是「随机来一个」，抽过之后是「换一个」。
    public static func buttonTitle(hasRevealed: Bool) -> String {
        hasRevealed ? "换一个" : "随机来一个"
    }

    /// 副标：池子多大就写多大（写死「十几个」这种话，素材一加就变成骗人）。
    public static func subtitle(poolCount: Int) -> String {
        guard poolCount > 0 else { return "" }
        return "从 \(poolCount) 个情景里随手挑一个，没练过的优先"
    }

    /// 开出了什么：名字 + 学习语言名 + 分组，缺哪段省哪段（不补占位符）。
    public static func revealText(_ entry: BlindBoxEntry) -> String {
        var parts: [String] = ["《\(entry.title)》"]
        // 自建素材常常只有中文名，那时再挂一遍同样的字就是废话。
        if !entry.subtitle.isEmpty, entry.subtitle != entry.title { parts.append(entry.subtitle) }
        if !entry.category.isEmpty { parts.append(entry.category) }
        return "开出" + parts.joined(separator: " · ")
    }

    // MARK: - 内部

    /// 顺手去重：`pick` 也可能被直接喂一份手工构造的池（测试、将来的别处）。
    ///
    /// ⚠️ 保**第一次**出现的那条：同一 id 前后的 `isCompleted` 可能不一样，
    /// 留后面那条等于让调用方的排序静默失效。
    private static func deduplicated(_ pool: [BlindBoxEntry]) -> [BlindBoxEntry] {
        var seen: Set<String> = []
        var out: [BlindBoxEntry] = []
        for entry in pool where seen.insert(entry.id).inserted {
            out.append(entry)
        }
        return out
    }
}
