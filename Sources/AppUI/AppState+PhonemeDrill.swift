import AIDomain
import AIServices
import Foundation

// MARK: - AppState · 顽固音素专项（进阶 ③）
//
// 每次跟读的逐音素得分都落了库，但一直只是「这一次念得怎么样」。
// 这里把它们**跨次聚合成「我哪个音老发错」**，并据此开一轮最小对立对跟读 ——
// 把数据反哺回练习，而不是只让人看一个分数。
extension AppState {

    /// 聚合时回看多少条跟读记录。
    ///
    /// 只统计**带发音报告**的那些（`pronunciation != nil`），所以这个上限
    /// 是「最多翻多少条」，不是「用多少条」—— 纯文本预览那类记录会自动跳过。
    private static let phonemeSampleLimit = 100

    /// 重新算一遍顽固音素。
    ///
    /// 与跟读汇总一起在进页面时跑（`loadShadowing`）：这一轮练完会改变结论，
    /// 下次进来就该看到新的名单。
    public func refreshPhonemeWeaknesses() async {
        let attempts = await services.shadowing.recentAttempts(limit: Self.phonemeSampleLimit)
        phonemeWeaknesses = PhonemeWeaknessAnalyzer.weaknesses(
            from: attempts.compactMap(\.pronunciation)
        )
    }

    /// 针对一个顽固音素开一轮最小对立对跟读。
    ///
    /// 直接顶掉当前这批素材：**专项练的时候不该混着今日句子练** ——
    /// 混着练的话，注意力被两句不相干的素材分走，这一轮就白来了。
    public func startPhonemeDrill(for weakness: PhonemeWeakness) {
        let drills = MinimalPairDrill.drills(for: weakness)
        // 没有词对的音素不硬凑（凑出来的就不是最小对立对了），静默不动即可：
        // UI 那一侧只在能出练习时才把按钮亮出来。
        guard !drills.isEmpty else { return }
        shadowingDrills = drills
        shadowingIsDailyGenerated = false
        isPhonemeDrill = true
        phonemeDrillFocus = weakness.phoneme
        resetShadowingProgress()
        applySection(.shadowing)
    }

    /// 退出专项，恢复今日 / 内置素材。
    ///
    /// ⚠️ 必须清掉 `shadowingDrills` 再重载：`loadShadowing` 见素材非空就不加载了，
    /// 不清的话专项那几句会一直留在页面上，看着像「今天的句子只有这四句」。
    public func exitPhonemeDrill() async {
        guard isPhonemeDrill else { return }
        isPhonemeDrill = false
        phonemeDrillFocus = nil
        shadowingDrills = []
        await loadShadowing()
    }

    /// 当前专项在练的音（IPA，展示用）；不在专项里时 nil。
    public var phonemeDrillFocusDisplay: String? {
        phonemeDrillFocus.map { PhonemeDisplay.ipa(for: $0) }
    }
}
