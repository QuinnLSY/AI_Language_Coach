import AIDomain
import Foundation
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
    /// 连续错得多了（>= `huddleComfortThreshold`）的**簇拥安慰**：几只一起围过来。
    ///
    /// 与 `comfortTick` 二选一，不同时推 —— 判据在翻译表里，发射点只发一次事件。
    public private(set) var huddleComfortTick = 0
    /// 簇拥安慰的门槛：一轮里错到这么多条就不再是「一个人安慰」的事了。
    public static let huddleComfortThreshold = 3
    /// 模块完成脉冲：地面按模块演一段戏（批次四 · A）。
    public private(set) var moduleTick = 0
    /// 最近完成的模块（地面挑戏码用）。
    public private(set) var lastModule: PracticeModule?
    /// 中途退出脉冲：地面「目送你走」（不评判、不庆祝）。
    public private(set) var abandonTick = 0
    /// 最近中途退出的模块（挑送别话用）。
    public private(set) var lastAbandonedModule: PracticeModule?
    /// 学员开口脉冲：最近的一只点点头（「嗯，你在说」）。
    public private(set) var learnerTurnTick = 0
    /// 老师开口脉冲：几只抬起头听（「老师在说话」）。
    public private(set) var teacherTurnTick = 0
    /// 最后一次「学习上发生了点什么」的时刻（地面据此判断「人是不是走开了」）。
    ///
    /// 为什么是时刻而不是布尔：判「久未发言」要的是**时间差**，布尔存不住
    /// 「从什么时候开始安静的」。地面那趟既有心跳拿它跟当下比，零新增定时器。
    public private(set) var lastActivityAt: Date = Date()
    /// 安静多久算「人走开了」（秒）。地面据此让小动物打个盹。
    public static let idleThresholdSeconds: TimeInterval = 240
    /// 最近通关的关卡（供仪式装饰用；nil = 还没通过关）。
    public private(set) var lastCompletedLevelID: String?

    // MARK: 可玩彩蛋（批次六 · E）

    /// 天空被点了一下：树冠飘两片叶子回应（纯玩，不记进度）。
    public private(set) var skyTapTick = 0
    /// 氛围演出隐藏档：连点天空 5 次触发（云、萤火虫收起来，星星不眨眼）。
    /// 会话级 —— 重启恢复默认演出，不必在设置页里再给一个「恢复」入口。
    public private(set) var ambientHidden = false
    /// 连点判定的节拍器（窗口内凑满 5 次算一次「连点」）。
    private var skyPacer = AmbienceTapPacer()

    // MARK: 边界状态（批次八 · H）

    /// 首次进入的欢迎脉冲：全新学员第一次打开应用，林子里欢迎一下。
    /// 判据（全新进度 + 配置没记过欢迎）在 `AppState`，这里只管演。
    public private(set) var welcomeTick = 0
    /// 错误举牌脉冲：老师联系不上时（模型未配置 / 网络失败…），最近的小动物举一块牌子。
    public private(set) var errorSignTick = 0
    /// 牌子上的那句话（`ForestErrorSign.headline(for:)` 的产出）。
    public private(set) var lastErrorHeadline: String?

    /// 首次进入欢迎（只此一次的判定在 AppState；这里每次调用都演）。
    public func welcome() {
        welcomeTick += 1
    }

    /// 老师联系不上：请一只小动物举牌。headline 为空时静默不演（没什么可举的）。
    public func showError(headline: String?) {
        guard let headline, !headline.isEmpty else { return }
        lastErrorHeadline = headline
        errorSignTick += 1
    }

    public init() {}

    /// 事件 → 脉冲的唯一翻译表。
    ///
    /// 每一条进来都算「学习上发生了点什么」，顺手刷新 `lastActivityAt`：
    /// 地面的「久未发言就打盹」判的是**距今多久没动静**，不需要另行埋点。
    public func ingest(_ event: LearningEvent) {
        lastActivityAt = Date()
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
        case .correctionsRecorded(let count):
            // 歪头安慰：纠错不是坏消息——森林用温柔的方式接住它。
            // 错得多了就换成几只一起围过来（同一件事，安慰的分量不同）。
            if count >= Self.huddleComfortThreshold {
                huddleComfortTick += 1
            } else {
                comfortTick += 1
            }
        case .moduleCompleted(let module):
            moduleTick += 1
            lastModule = module
        case .practiceAbandoned(let module):
            abandonTick += 1
            lastAbandonedModule = module
        case .learnerTurn:
            learnerTurnTick += 1
        case .teacherTurn:
            teacherTurnTick += 1
        }
    }

    /// 订阅服务层总线（AppState 持有返回的凭证，订阅随 AppState 生命周期走）。
    @discardableResult
    public func attach(to bus: LearningEventBus) -> LearningEventBus.Subscription {
        bus.subscribe { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }
    }

    /// 天空被点了一下（批次六 · E）：每次都飘叶回应；窗口内凑满 5 次，
    /// 第 5 次额外把氛围演出收起来 / 展开回来（再连点 5 次切换回）。
    public func registerSkyTap(at date: Date = Date()) {
        skyTapTick += 1
        if skyPacer.register(at: date) {
            ambientHidden.toggle()
        }
    }
}
