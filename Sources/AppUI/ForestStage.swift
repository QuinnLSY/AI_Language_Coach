import AIDomain
import Observation

/// 森林舞台：把学习事件翻译成「森林各处该动一下」的脉冲。
///
/// 为什么是脉冲（递增计数）而不是事件对象：树 / 地面 / 天空各订阅者只关心
/// 「又发生了一件什么事，演一遍」，不需要事件的历史与载荷——载荷（哪一关、
/// 什么词）在数据层本来就有（进度、词汇本是单一真相）。
///
/// 各订阅者**独立可关**：脉冲只是信号，演不演由各视图按自己的开关决定
/// （地面 obey `activityAllowed` / 夜晚安静；树的仪式跟着 reduceMotion 走）。
@MainActor
@Observable
public final class ForestStage {

    /// 收词脉冲：树上飘一片叶子；地面的小剧场（跑出去叼回来）也接这里。
    public private(set) var wordTick = 0
    /// 最近收进的生词（捡词叙事的台词内容；nil = 本会话还没收过词）。
    ///
    /// 批次二起地面剧场需要知道「叼回来的是什么」——这是脉冲之外唯一
    /// 需要载荷的地方，从事件里顺手记下，调用方不用再查词汇本。
    public private(set) var lastCollectedWord: String?
    /// 练习完成脉冲：树冠飘几片叶子（小回应）。
    public private(set) var practiceTick = 0
    /// 攒星脉冲：枝头新果实弹入一颗（果实数量本身从进度算，这里只管「动一下」）。
    public private(set) var fruitPulseTick = 0
    /// 通关脉冲：全套仪式（树冠抖三抖 + 落叶缤纷 + 烟花）。
    public private(set) var ceremonyTick = 0
    /// 纠错脉冲：地面派一只小动物「歪头安慰」（批次二接通）。
    public private(set) var comfortTick = 0
    /// 最近通关的关卡（供仪式装饰用；nil = 还没通过关）。
    public private(set) var lastCompletedLevelID: String?

    public init() {}

    /// 事件 → 脉冲的唯一翻译表。
    public func ingest(_ event: LearningEvent) {
        switch event {
        case .wordCollected(let word):
            wordTick += 1
            lastCollectedWord = word
        case .practiceCompleted:
            practiceTick += 1
        case .starsEarned:
            fruitPulseTick += 1
        case .levelCompleted(let levelID):
            ceremonyTick += 1
            lastCompletedLevelID = levelID
        case .correctionsRecorded:
            // 歪头安慰：纠错不是坏消息——森林用温柔的方式接住它。
            comfortTick += 1
        }
    }

    /// 订阅服务层总线（AppState 持有返回的凭证，订阅随 AppState 生命周期走）。
    @discardableResult
    public func attach(to bus: LearningEventBus) -> LearningEventBus.Subscription {
        bus.subscribe { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }
    }
}
