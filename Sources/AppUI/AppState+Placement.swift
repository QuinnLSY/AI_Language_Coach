import AIDomain
import AIServices
import Foundation

// MARK: - 入学定级（placement test，进阶 ⑤）
//
// 这一层管三件事：出卷、收答案、把结果存下来。
// 出卷与判分的规则在 `AIDomain.EntrancePlacementRule`（纯函数），所以
// **从出卷到出结果全程零模型请求** —— 摸底是用户打开应用做的第一件事，
// 那时候模型可能还没起、网络可能还是别人的 Wi-Fi。

extension AppState {

    /// 定级结果的持久化键（UserDefaults：一个几十字节的结构体，不值得建表）。
    static let placementResultStorageKey = "placement.result"

    static func loadPlacementResult() -> PlacementResult? {
        guard let data = UserDefaults.standard.data(forKey: placementResultStorageKey) else { return nil }
        return try? JSONDecoder().decode(PlacementResult.self, from: data)
    }

    private func savePlacementResult() {
        guard let placementResult,
              let data = try? JSONEncoder().encode(placementResult)
        else { return }
        UserDefaults.standard.set(data, forKey: Self.placementResultStorageKey)
    }

    // MARK: 对外读数

    /// 定下来的起点档位（没做过摸底 = nil）。
    public var placementLevel: CEFRLevel? { placementResult?.level }

    /// 当前这道题（没出卷 / 已经答完为 nil）。
    ///
    /// ⚠️ **答完必须变 nil**。结算时下标停在最后一题上（`finishPlacement` 不推进下标），
    /// 如果这里照样返回那道题，就会出现「卷子已经判完了，还有一道当前题」这种自相矛盾的状态 ——
    /// 界面上被 `placementOutcome` 分支挡住了看不出来，但任何「还有当前题就继续」的循环
    /// 都会转不出来。交卷即无题，这条口径只在这里有一份。
    public var currentPlacementQuestion: PlacementQuestion? {
        guard placementOutcome == nil else { return nil }
        return placementPaper.question(at: placementIndex)
    }

    /// 卷子答到第几题（从 1 数；答完则等于总题数）。
    public var placementProgressText: String {
        let total = placementPaper.questionCount
        guard total > 0 else { return "" }
        return "第 \(min(placementIndex + 1, total)) / \(total) 题"
    }

    /// 用**真实练习数据**估出来的档位（#229 的能力定位）。
    ///
    /// 与摸底是两把不同的尺子，所以这里不合并、也不覆盖：
    /// - 摸底：第 0 天就能给结果，量的是「认得出多少、语法准不准」；
    /// - 那条：要 25 轮对话 + 3 天 + 20 个词才肯开口，量的是「实际用出来什么水平」。
    ///
    /// ⚠️ 两者不一致（自测 B2、实际 A2）本身就是最有用的信息 ——
    /// 所以卡片会把两行一起展示，而不是挑一个显示。
    /// 实现见 `AppState+Progress.placementEstimate`（此处不重复一份）。

    /// **出题该用哪一档**（`B1`；空串 = 还没法定，让 Prompt 侧按「观察中」处理）。
    ///
    /// 优先级：**有把握的实测估计 > 摸底自测 > 空**。
    ///
    /// ⚠️ 为什么不是「摸底优先」：摸底只有十来道选择题，是第 0 天的权宜之计；
    /// 一旦攒够了真实输出（25 轮对话 + 3 天 + 20 个词），那个数比自测可靠得多。
    /// 反过来，样本不够时那条估计是 nil，这时候摸底的档位就是唯一能用的信息 ——
    /// 对第一次打开应用的用户来说，它正是从「没有」到「有一个」的那一步。
    public var effectivePlacementLevelText: String {
        if placementEstimate.isConfident, let level = placementEstimate.level {
            return level.rawValue.uppercased()
        }
        if let level = placementLevel { return level.rawValue.uppercased() }
        return ""
    }

    // MARK: 流程

    /// 打开摸底浮层。题库缺失就在这里说清楚（进去之后再发现没题更糟）。
    public func openPlacement() async {
        await loadPlacementBank()
        isPlacementShowing = true
    }

    public func closePlacement() {
        // ⚠️ 只关浮层，**不清进度**：摸底做到第 7 题去接了个电话，回来接着做。
        isPlacementShowing = false
    }

    /// 题库只在第一次进来时读一次（服务里已经缓存）。
    private func loadPlacementBank() async {
        isPlacementLoading = true
        // 读一次、拿回两样东西：题库（这里只用它判空）与「题库不完整」的说明。
        _ = await services.placement.questions()
        placementNotice = await services.placement.loadNote()
        isPlacementLoading = false
    }

    /// 开始（或重测）一轮摸底。
    ///
    /// 种子每次 +1：同一档的题库会逐次轮换，不会连着两次看到同一张卷子。
    public func startPlacement() async {
        isPlacementLoading = true
        let paper = await services.placement.paper(
            seed: EntrancePlacementRule.nextSeed(after: placementResult?.seed)
        )
        isPlacementLoading = false
        guard !paper.isEmpty else {
            placementNotice = await services.placement.loadNote()
                ?? "没有出成卷子（题库是空的）。"
            return
        }
        placementPaper = paper
        placementAnswers = [:]
        placementIndex = 0
        placementOutcome = nil
        placementNotice = nil
    }

    /// 选一个选项 → 立刻进入下一题（不在中途给对错：这是摸底，不是练习）。
    ///
    /// 中途给反馈会让人「根据提示改答案」，量出来的就不是当前水平了。
    /// 也**不允许回退**：能退回去改，同样会让结果偏高。
    ///
    /// ⚠️ 本方法**靠 `currentPlacementQuestion` 在交卷后返回 nil 来防重入**：
    /// 少了那道闸，答完之后误点一下选项会覆盖 `placementAnswers`、把下标已到末尾
    /// 的分支再走一次 → `finishPlacement()` 重算 → **成绩当场被改掉**
    ///（撤掉守卫实测：correct 1 变 2）。所以那道闸不是「语义好看」，是承重的。
    public func choosePlacementOption(_ optionIndex: Int) {
        guard let question = currentPlacementQuestion else { return }
        guard question.options.indices.contains(optionIndex) else { return }
        placementAnswers[question.id] = optionIndex
        if placementIndex + 1 < placementPaper.questionCount {
            placementIndex += 1
        } else {
            finishPlacement()
        }
    }

    /// 判分 + 落盘。
    private func finishPlacement() {
        let result = EntrancePlacementRule.result(paper: placementPaper, answers: placementAnswers)
        placementOutcome = result
        placementResult = result
        savePlacementResult()
    }

    /// 收工：关掉浮层并把这一轮的卷面清掉（结果已经落在 `placementResult` 里）。
    public func dismissPlacementOutcome() {
        placementOutcome = nil
        placementPaper = .empty
        placementAnswers = [:]
        placementIndex = 0
        isPlacementShowing = false
    }

    public func dismissPlacementNotice() { placementNotice = nil }
}
