import SwiftUI
import AIDomain

// #661 自 TreeCanvas.swift 拆出（2026-10-24）：原文件 2812 行、21 个类型混居，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
// MARK: - 林间地面带（固定吸附在成长之树面板底部，不随树滚动，居民始终可见可点）

struct ForestGroundBand: View {
    let theme: ForestTheme
    /// 小动物气泡总开关（设置可关）。
    var bubblesAllowed: Bool = true
    /// 实际生效的活动开关（配置 && 白天）。夜晚自动安静。
    var activityAllowed: Bool = true
    /// 活动频率（0...1）：值越大动作间隔越短。
    var activityFrequency: Double = 0.5
    /// 右下角表情按钮回调（与设置里的开关联动）。
    var onActivityToggle: (() -> Void)? = nil
    /// 外部庆祝信号（今日任务全部完成）：每次 +1，全体小动物跳一次并冒一句庆祝话。
    var celebrationTick: Int = 0
    /// 收词脉冲（`state.forest.wordTick`）：一只小动物跑出画面叼一张单词卡回来。
    var wordTick: Int = 0
    /// 最近收进的生词（捡词叙事的台词；nil = 不演，只留树上的叶子回应）。
    var wordPayload: String? = nil
    /// 纠错脉冲（`state.forest.comfortTick`）：派一只小动物歪头安慰。
    var comfortTick: Int = 0
    /// 连续错得多时的**簇拥安慰**（`huddleComfortTick`）：几只一起围过来。
    var huddleComfortTick: Int = 0
    /// 模块完成脉冲：按模块演一段戏（批次四 · A 分模块回应）。
    var moduleTick: Int = 0
    /// 最近完成的模块。
    var lastModule: PracticeModule? = nil
    /// 中途退出脉冲：目送你走（不评判、不庆祝）。
    var abandonTick: Int = 0
    /// 最近中途退出的模块。
    var lastAbandonedModule: PracticeModule? = nil
    /// 学员开口脉冲：最近的一只点点头。
    var learnerTurnTick: Int = 0
    /// 老师开口脉冲：几只抬起头听。
    var teacherTurnTick: Int = 0
    /// 最后一次「学习上发生了点什么」的时刻：据此判断人是不是走开了
    /// （安静太久 → 有谁打个盹）。判时间差，不判布尔。
    var lastActivityAt: Date = Date()
    /// 验证钩子：启动时先冒一句「它们在睡觉」（仅在 `--sleep-bubble` 下由主界面传入）。
    var previewSleepBubble: Bool = false
    /// 点了一只小动物（批次六 · F 轻音效：一声叫；气泡照旧由本视图冒）。
    /// ⚠️ 带着**被点那只**的当前物种出山（轮换会换物种，叫声要跟着换 —— 2026-09-29）。
    var onResidentTap: ((AnimalKind) -> Void)? = nil
    /// 首次进入欢迎脉冲（批次八 · H）：居民依次跳一圈 + 一句欢迎词。
    var welcomeTick: Int = 0
    /// 错误举牌脉冲（批次八 · H）：老师联系不上时，最近的小动物举一块牌子。
    var errorSignTick: Int = 0
    /// 牌子上的那句话（与 tick 分开传：同一句话再举一次也要靠 tick 触发）。
    var errorHeadline: String? = nil
    /// 学员在当前会话开口的次数（`ChatService.learnerTurnCount`）：
    /// 大树下草坪上「对话种下的植物」长几株（2026-09-29 从中间栏搬进林子）。
    var conversationRounds: Int = 0
    /// 连续剧情（#418-C）：出幕脉冲 + 这一幕是哪一幕。判定与记账在 `ForestStage`
    /// （它有事件历史），这里只管挑角演 —— 判定在舞台、演在草坪，两边各管各的。
    var storyActTick: Int = 0
    var lastStoryAct: ForestStoryArc.Act? = nil
    /// 学员在树上的攀爬位置（0…1，`LearnerProgress.climbFraction`）。
    ///
    /// **C：动物与学习过程联动**的落点。学习事件面已经很宽（收词 / 纠错 /
    /// 模块完成 / 通关 / 簇拥安慰 / 举牌 / 剧情……），唯独「进度条自己往前走了」
    /// 没有任何回应 —— 而那恰恰就是「学习过程」本身。这里只做一件事：
    /// 涨了就派最近的一只小跳一下、喊一句，**不庆祝、不放烟花**。
    var climbFraction: Double = 0

    /// 已解锁的伙伴数（⑦-C③，`ForestUnlock.companions`）：面板摆得下几只由宽度定，
    /// 林子里**现有几位**由它定，取小者（见 `ForestGroundPlan.plan(width:unlocked:)`）。
    var unlockedCompanions: Int = ForestUnlock.maxCompanions

    /// 连续剧情的主角（#418-C）：一旦绑定，这一轮学习里的各幕都由它领衔
    /// （在场才认；暂离了就换角重绑）。会话级 @State，重启自然换人。
    @State var storyLead: Int? = nil

    /// 画面上**真的画出来**的居民数（由 `ForestGroundPlan` 按面板宽排，随宽度变）。
    ///
    /// 为什么要有它（2026-10-01 修）：槽位总数恒为 8，但窄面板下只排 3~5 只
    /// （`index >= count` 的槽位画成 `opacity(0)`，气泡层也有 `i < count` 守卫）。
    /// 挑角原先在 8 个槽位里随机，六成概率挑到画外的角色 —— 那一幕就演给空气看：
    /// 动作看不见、气泡也不出，用户只看到「攒够星却什么都没发生」。
    @State private var residentCount: Int = 0

    /// 此刻在场（没暂离）且**看得见**的居民槽位 —— 挑角只能在这一段里挑。
    var presentResidents: [Int] {
        (0..<residentCount).filter { !away[$0] }
    }

    /// 离场告别语（轮换时随机抽一条）。
    static let leavePhrases = [
        "我先回家吃点心啦～",
        "妈妈叫我回家吃饭！",
        "林子那边好像有好玩的，我去瞧瞧～",
        "拜拜，明天再来找你们玩！",
        "咦，那边的蘑菇好像发芽了，我去看看！",
    ]
    /// 进场打招呼语（轮换时随机抽一条）。
    static let greetPhrases = [
        "嗨～我来了！",
        "你们好呀，我是新搬来的邻居！",
        "嘿！一起玩吗？",
        "刚才在路上捡到一个新单词，分你们一半！",
        "大家好，这里的草真香呀～",
    ]

    /// 夜晚点击右下角表情按钮时冒出的话（**小动物们都睡了**，随机抽一条，连点随机切换）。
    ///
    /// `nonisolated`：这是一张纯文案表，不含任何隔离状态；写成隔离的会让
    /// 单测（非隔离上下文）读它时撞上「主 actor 属性不能从非隔离上下文引用」。
    nonisolated static let sleepPhrases = [
        "嘘——小动物们都睡着啦，别打扰它们哦～",
        "夜深了，它们正做着甜甜的梦呢，明早再来吧！",
        "呼……呼……睡得好香，轻一点声音哦。",
        "月亮值班啦，小动物们都钻进窝里睡觉了。",
        "它们说：明早第一缕阳光时再见！晚安～",
    ]

    /// 双人小对话（一问一答）：一条脚本由两只相邻的小动物交替说完。
    /// 每条 2 句起步，句子里带点学习气但不教训人。
    nonisolated static let dialogueScripts: [[String]] = [
        ["你说，rainbow 为什么有七种颜色？", "因为每种颜色都是一个单词呀！"],
        ["今天你练口语了吗？", "练啦！舌头都绕两圈了～"],
        ["我们比赛背单词吧！", "好呀，输的请吃松果！"],
        ["那朵云像不像 sheep？", "像！b-a-a～"],
        ["你听过回声说英语吗？", "听过！它还会复读呢。"],
        ["今天的句子好长呀。", "没关系，拆成小段就短啦！"],
    ]

    /// 纠错后的安慰话（歪头 + 一句温柔的话——错误被温柔接住）。
    nonisolated static let comfortPhrases = [
        "没关系，错着错着就会啦！",
        "我也常念错呀，再来一遍就好～",
        "错误是单词的小脚印，说明你在往前走！",
        "抱抱你，这次我们慢慢读。",
    ]

    /// 学员又往上爬了一层时的招呼（C：动物与学习过程联动）。
    ///
    /// ⚠️ 语气纪律：**不庆祝**（里程碑有 `ceremonyTick` / `celebrationTick` 两档，
    /// 那两档会跳会放烟花），这里只表示「我看见你往上爬了」——一句话，一个小跳。
    nonisolated static let ascentPhrases = [
        "又上一层啦！",
        "我看见你往上爬了～",
        "这一格也站稳了，继续！",
        "越爬越高，我抬头看你呢。",
        "再往上，风就更好听了！",
    ]

    /// 簇拥安慰的话（错得多时用的，比单人安慰更用力一点）。
    ///
    /// ⚠️ 语气纪律：这里**不提错误本身**（单人那组已经说过了），说的是「我们一起在」。
    nonisolated static let huddleComfortPhrases = [
        "我们都在这儿呢，慢慢来～",
        "一起读，就不难啦！",
        "错几个不算什么，我们陪着你！",
        "来，我们陪你再读一遍。",
    ]

    /// 安静太久时打盹的那句话（不是「睡着」，是困了点个头）。
    nonisolated static let dozingPhrases = [
        "好安静呀……我先打个盹～",
        "等你回来，我眯一会儿。",
        "呼……有点困了，你慢慢想。",
    ]

    /// 捡词叙事：看见词时要出发了。
    nonisolated static let fetchStartPhrases = [
        "咦，那边飘来一个新单词！",
        "等等我，我去把它捡回来！",
        "我的耳朵听到单词落地的声音啦！",
    ]
    /// 捡词叙事：叼着词卡回来展示。
    nonisolated static let fetchDonePhrases = [
        "捡到啦！快看这个词～",
        "回来咯！这个词真漂亮！",
        "新单词到手，收好啦！",
    ]

    /// 首次进入的欢迎词（批次八 · H）：全新学员第一次来，林子的见面礼。
    nonisolated static let welcomePhrases = [
        "欢迎来到语林！",
        "新朋友来啦！这边请～",
        "你来啦！树还小，一起把它养大吧！",
    ]

    /// 每只小动物**独立拥有**一个气泡：`bubbleTexts[i]` 是槽位 i 当前的话（nil = 没在说话）。
    /// 多个气泡可以同时存在；`bubbleStamps[i]` 记录出现序号，序号越大画得越上层（最新出现的永远在最上方）。
    @State var bubbleTexts: [String?] = Array(repeating: nil, count: Self.maxResidents)
    @State var bubbleStamps: [Int] = Array(repeating: 0, count: Self.maxResidents)
    @State var bubbleCounter = 0
    /// 各居民的**持续位移**：游走后停在新位置，不回原位。
    @State var offsets: [CGSize] = Array(repeating: .zero, count: Self.maxResidents)
    /// 鸟类是否正栖在枝桠上。
    @State var perched: [Bool] = Array(repeating: false, count: Self.maxResidents)
    /// 动作触发器（父级递增，LivelyAnimal 变化即执行）。
    @State var actionTicks: [Int] = Array(repeating: 0, count: Self.maxResidents)
    @State var actionKinds: [LivelyAnimalAction] = Array(repeating: .hop, count: Self.maxResidents)
    /// 各槽位的物种（轮换：随机离开/进入）。空时用伪随机初始顺序兜底。
    @State var kinds: [AnimalKind] = []
    /// 各槽位朝向（游走时按移动方向翻转）。
    @State var facings: [CGFloat] = []
    /// 夜晚点右下角表情按钮冒出的「睡觉」气泡（nil = 没在显示）。
    @State private var sleepLine: String?
    /// 连点刷新用：变化即重启 3 秒自动收起计时（与动物气泡同一套逻辑）。
    @State private var sleepTick = 0
    /// 各槽位是否暂离（轮换中「走了还没回来」）。可见 = 槽位在宽度档位内 **且** 没暂离——
    /// 走了之后画面上真的少一只，回来的时间看缘分（错落感的关键，见 `ForestRotationPacing`）。
    @State var away: [Bool] = Array(repeating: false, count: Self.maxResidents)
    /// 捡词叙事进行中（同一时刻只演一场；期间的收词只留树上的叶子回应）。
    @State var isFetchingWord = false
    /// 正在展示的「叼回来的单词卡」（nil = 没有；slot = 哪只小动物叼着）。
    @State var wordCard: (slot: Int, word: String)? = nil
    /// 安静期间已经打过盹了（学习上又有动静时解锁，见 `dozeOffIfQuiet`）。
    @State var hasDozed = false
    /// 正在举牌的居民槽位（批次八 · H 错误举牌；nil = 没在举）。
    @State var signHolder: Int? = nil
    /// 本次举牌对应的脉冲序号：自动收起时对账，防止收掉下一场新举的牌。
    @State var signShownTick = 0
    /// 欢迎演出是否已经演过（onAppear 补演与 onChange 二选一的闸）。
    @State var welcomePlayed = false
    /// 点草地冒出来的花（批次六 · E 可玩彩蛋；上限与挤掉规则见 `GroundFlowerBed`）。
    @State var plantedFlowers: [PlantedFlower] = []
    @State var plantedCounter = 0
    /// 各槽位**当前生效的移动批次**（见 `hopTo`）。
    ///
    /// ⚠️ 活动编排与轮换编排是**两条并发的循环**，它们在同一只居民身上撞车时，
    /// 两个 `hopTo` 会交替写同一个 `offsets[index]` —— 一只动物被两边同时拽，
    /// 画面上就是原地抽搐。批次号让**后发起的意图胜出**、前一个自己退场。
    @State var hopTokens: [Int] = Array(repeating: 0, count: Self.maxResidents)
    @State var hopCounter = 0
    /// **庆祝演出的代际令牌**（#S3-11）。
    ///
    /// ⚠️ `celebrate()` 一次要起 24+ 个错峰 `Task`（三波欢跳 + 三只台词 + 一次收尾），
    /// 它们谁也不持有、也没法取消 —— 而 `try? await Task.sleep` 会把取消错误吞掉，
    /// 就算持有并取消也照样往下走。于是「演出进行到一半、全员已经回家」时，
    /// 剩下的那几个 Task 仍会照常 `trigger(.hop)`，把刚站好的队伍又拽走一只。
    /// 沿用本文件已有的对账风格（`hopTokens` / `bubbleStamps`）：演出开始时领号，
    /// 每个 Task 动手之前先对一次账，**号对不上就直接退场**。
    @State var celebrationToken = 0

    static let maxResidents = 8
    // 各类元素的**上限**：始终按上限创建视图，靠透明度控制显隐。
    // 这样拖动分割线时元素不会突然创建/销毁（那正是画面抖动的来源）。
    private let grassCount = 26
    private let maxBushes = 4
    private let maxFlowers = 7

    /// 稳定伪随机（同 index/salt 永远同值），保证布局不随重绘跳动。
    func pr(_ index: Int, _ salt: Int) -> CGFloat {
        let x = sin(Double(index * 137 + salt * 61)) * 43758.5453
        let frac = x - floor(x)
        return CGFloat(frac)
    }

    /// 物种顺序已收到 `AnimalKind.unlockOrder`（⑦-C③）：预告要能点出「下一位是谁」，
    /// 顺序就不能只活在视图里。

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            // 草坡表面（相对本视图坐标）：坡是鼓包不是直线 —— 谁站在坡上就问坡自己要高度。
            // （从前这里是一条直线：草叶 / 灌木 / 小花 / 小动物 / 对话植物全站在上面，
            // 而坡面中心高出 20pt、两角低下 34pt，于是「中心埋进坡里、两边浮在半空」——
            // 用户看到的「一块一块」正源于此。）
            // ⚠️ 名字仍叫 `groundLine`（它回答的就是「这根线在 x 处的高度」），类型从
            //  CGFloat 变成坡面函数；下游 30 处调用点因此原样不动，只是各自问一次 x。
            let groundLine: ForestGroundSurface = { x in
                ForestSceneGeometry.hillSurfaceY(x: x, bandWidth: width, bandHeight: height)
            }
            let inset: CGFloat = 74
            let span = max(1, width - inset * 2)
            // 量化宽度：一切「离散决策」（数量、个体大小）只在 28pt 档位上变化，
            // 连续量（坐标）仍跟随真实宽度平滑移动 —— 消除拖动时的逐帧重排抖动。
            let step: CGFloat = 28
            let qw = (width / step).rounded() * step
            // 退化档（批次八 · H）：多宽配多少动物 / 灌木 / 小花，收成一个纯函数
            // （正常 / 窄 / 极窄三档，树面板最小 300pt 时只留 1 只居中——林子不空也不挤）。
            let plan = ForestGroundPlan.plan(width: qw, unlocked: unlockedCompanions)
            let count = plan.residents
            let bushCount = plan.bushes
            let flowerCount = plan.flowers
            let order = AnimalKind.unlockOrder

            ZStack(alignment: .bottomLeading) {
                // 批次七 · G：下面这一段（草坡 / 草叶 / 灌木 / 小花 / 点出来的花 / 栖木桠）
                // 全是纯装饰 —— 包成一个 Group 对 VoiceOver 整体隐藏，居民（动物）保留读屏。
                Group {
                    // 草坡：顶沿到坡底一道「空气」渐变（大气透视按景深推，顶沿远一点）
                    // —— 从前是一条硬邦邦的剪纸边，绿的坡冷不丁切进背后的天空里。
                    HillCap()
                        .fill(
                            LinearGradient(
                                colors: [
                                    ForestAerialPerspective.adjust(
                                        theme.hillNear,
                                        depth: ForestSceneGeometry.treeDepth,
                                        haze: theme.aerialHaze),
                                    ForestAerialPerspective.adjust(
                                        theme.hillNear,
                                        depth: ForestSceneGeometry.nearHillDepth,
                                        haze: theme.aerialHaze)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: ForestSceneGeometry.hillCapHeight)

                    // 冬：草坡上的积雪（#626）—— 沿坡面盖的一条 + 被风堆起来的三个雪堆。
                    //
                    // ⚠️ 画在草叶 / 灌木 / 小花**之前**（更下层）：草是从雪里冒出来的。
                    // 反过来（雪盖住草）就成了「草地铺了张白纸」。
                    if theme.season == .winter {
                        ForestSnowField(theme: theme, groundLine: groundLine)
                            .seasonFade()

                        // 冬：雪地上的三个雪人（#627）—— 尖帽 / 红围巾 / 胡萝卜鼻 /
                        // 枝桠臂，**一个半小动物高**（同一个面板里，高矮比得出来）。
                        // 画在草叶之前（与雪地同一层）：草从雪人脚边冒出来。
                        ForestSnowmen(theme: theme, groundLine: groundLine,
                                      quantizedWidth: qw)
                            .seasonFade()
                    }

                    // 秋：大树脚下那片小果园（#624）—— 四棵结着果子的树，
                    // 左两棵右两棵，整体**两个半小动物高**（拿 `ForestGroundPlan`
                    // 那把尺量的，小动物就在同一个画面里，高矮比得出来）。
                    //
                    // ⚠️ 画在草叶 / 灌木 / 小花**之前**（更下层）：草从树根前面
                    // 长出来，树才像种在坡上，不是贴上去的。居民（小动物）在更
                    // 上层 —— 它是拿它们当尺子的，画面上必须能比出来。
                    if theme.season == .autumn {
                        ForestOrchard(theme: theme, groundLine: groundLine,
                                      quantizedWidth: qw)
                            .seasonFade()
                    }

                    // 远处草丛（固定数量，按宽度均布；倾角只跟 index 走，不随宽度乱跳）
                    ForEach(0..<grassCount, id: \.self) { i in
                        grassBlade(x: inset + CGFloat(i) / CGFloat(grassCount - 1) * span,
                                   h: 9 + pr(i, 1) * 11,
                                   w: 2.6 + pr(i, 2) * 1.6,
                                   seed: i,
                                   groundLine: groundLine)
                    }

                    // 灌木丛（增加层次，压住「排排站」的感觉）
                    ForEach(0..<maxBushes, id: \.self) { i in
                        bush(x: inset + pr(i, 12) * span,
                             groundLine: groundLine,
                             seed: i)
                            .opacity(i < bushCount ? 1 : 0)
                            .appAnimation(.reveal, value: bushCount)
                    }

                    // 小花（错落 + 三种花色）
                    ForEach(0..<maxFlowers, id: \.self) { i in
                        flower(x: inset + pr(i, 8) * span,
                               groundLine: groundLine,
                               palette: i % 3)
                            .opacity(i < flowerCount ? 1 : 0)
                            .appAnimation(.reveal, value: flowerCount)
                    }

                    // 春：草地上的蒲公英与蝴蝶（#621）。
                    //
                    // 只在春天长出来 —— 蒲公英要被认出来靠的是「一根茎顶一个球、
                    // 絮是从球上走的」这个因果，蝴蝶靠的是会扇的翅膀与朝向，
                    // 都不是再多撒一层白点（`ForestMotes` 的白天飘絮已经是了）。
                    // ⚠️ 画在居民**之前**（更下层）：蝴蝶飞过时不盖住小动物。
                    // 两者自带 `allowsHitTesting(false)`，不抢任何点击。
                    if theme.season == .spring {
                        ForestDandelions(theme: theme, groundLine: groundLine)
                            .seasonFade()
                        ForestButterflies(theme: theme, groundLine: groundLine)
                            .seasonFade()
                    }

                    // 夏：草地上的叶隙光斑与夏夜流萤（#623）。
                    //
                    // 两个组件各自判日夜（光斑只在白天、流萤只在夜里）——
                    // 夏天的草地因此一天两副样子，正午是筛下来的阳光，夜里是贴着
                    // 草尖飞的虫。这里只判季节，不替它们判日夜。
                    if theme.season == .summer {
                        ForestDapples(theme: theme, groundLine: groundLine)
                            .seasonFade()
                        ForestFireflies(theme: theme, groundLine: groundLine)
                            .seasonFade()

                        // 夏：草尖上的蜻蜓（#635）—— 悬停盯半天、忽然蹿去下一根草尖。
                        //
                        // 夏天白天原本只有一层**看不出形状的**叶隙光斑（一摊摊柔光，
                        // 没有轮廓）—— 蜻蜓补的正是这一档：草尖上有一只认得出来的
                        // 活物。它与流萤同层、按日夜分工（白天蜻蜓 / 夜里流萤）。
                        ForestDragonflies(theme: theme, groundLine: groundLine)
                            .seasonFade()
                    }

                    // 秋：草地上的落叶堆与南瓜（#625）。
                    //
                    // 落叶堆画在草叶 / 小花**之后**（更上层）—— 叶子是**落在草上**
                    // 的，压住草才对；南瓜也是躺在草上的重东西。两者都在居民之前：
                    // 南瓜是拿小动物当尺子的（比它矮一半还多），画面上必须能比出来。
                    // ⚠️ 南瓜不跟风动（风推不动躺着的瓜），会挪的只有堆边那几片散叶。
                    if theme.season == .autumn {
                        ForestLeafPiles(theme: theme, groundLine: groundLine,
                                        quantizedWidth: qw)
                            .seasonFade()
                        ForestPumpkins(theme: theme, groundLine: groundLine,
                                       quantizedWidth: qw)
                            .seasonFade()
                    }

                    // 点草地冒出来的花（批次六 · E）：从点下的位置长出来，挤掉最早的
                    ForEach(plantedFlowers) { planted in
                        flower(x: min(max(planted.x, 16), width - 16),
                               groundLine: groundLine,
                               palette: planted.palette)
                            .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
                    }

                    // 对话种下的植物（2026-09-29 从中间栏搬进林子）：大树下草坪上
                    // 随学员开口一株株长出来，带土丘扎根痕迹与轻微倒向（见 ForestFloraBed）。
                    ForestFloraBed(theme: theme, rounds: conversationRounds, groundLine: groundLine)

                    // 树干底部的两根枝桠栖木（鸟类专用；画在树干透出区域的中心两侧）
                    perchStubs(width: width)
                }
                .accessibilityHidden(true)

                // 林间居民：各物种独立个体，朝向/大小/站位/动与静各不相同
                ForEach(0..<Self.maxResidents, id: \.self) { i in
                    resident(
                        kind: order[i % order.count],
                        index: i,
                        visibleCount: count,
                        span: span,
                        inset: inset,
                        groundLine: groundLine,
                        quantizedWidth: qw
                    )
                }

                // 气泡层：每只小动物一份，统一画在所有居民之上。
                // 层级由出现序号决定 —— 最新出现的气泡 zIndex 最大，不会被任何动物或其他气泡遮挡。
                ForEach(0..<Self.maxResidents, id: \.self) { i in
                    if i < count, !away[i], let text = bubbleTexts[i] {
                        let home = homePosition(index: i, count: count, span: span,
                                                inset: inset, groundLine: groundLine, quantizedWidth: qw)
                        SpeechBubble(text: text, maxWidth: 150)
                            .fixedSize()
                            .position(
                                x: home.x + offsets[i].width,
                                y: home.y + offsets[i].height - home.size * 0.78
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.55, anchor: .bottom)))
                            .zIndex(Double(1000 + bubbleStamps[i]))
                            .allowsHitTesting(false)
                    }
                }

                // 叼回来的单词卡：跟着捡词小动物的头顶走，展示完自动收。
                if let card = wordCard, card.slot < count, !away[card.slot] {
                    let home = homePosition(index: card.slot, count: count, span: span,
                                            inset: inset, groundLine: groundLine, quantizedWidth: qw)
                    CarriedWordCard(word: card.word, theme: theme)
                        .position(
                            x: home.x + offsets[card.slot].width,
                            y: home.y + offsets[card.slot].height - home.size * 1.08
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
                        .zIndex(2000)
                        .allowsHitTesting(false)
                }

                // 错误举牌（批次八 · H）：举在持牌小动物的头顶，5 秒自动收。
                // 夜晚也举——错误不挑时候；牌子只是转述，完整错误在聊天区横幅。
                if let holder = signHolder, holder < count, !away[holder],
                   let headline = errorHeadline {
                    let home = homePosition(index: holder, count: count, span: span,
                                            inset: inset, groundLine: groundLine, quantizedWidth: qw)
                    ForestSignBoard(theme: theme, text: headline)
                        .position(
                            x: home.x + offsets[holder].width,
                            y: home.y - home.size * 0.5 - 40
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
                        .zIndex(2100)
                }
            }
            .frame(width: width, height: height, alignment: .bottomLeading)
            // 档位切换时让位置/大小平滑过渡，而不是瞬移
            .appAnimation(.reveal, value: qw)
            // 初始化物种/朝向状态（轮换的基础）
            .onAppear { ensureResidents(order: order) }
            .onChange(of: count, initial: true) { _, value in
                // 可见居民数：挑角 / 编排都只认这一段（见 `presentResidents`）。
                // `initial: true` —— 首帧就得写进去，否则第一次出幕时它还是 0。
                residentCount = value
                ensureResidents(order: order)
            }
            // 活动编排（宽度或活动开关/频率变化时重启循环，取最新几何与开关值）
            .task(id: "\(qw)-\(activityAllowed)-\(activityFrequency)-\(theme.isNight)") {
                async let life: () = orchestrateLife(count: count, span: span, inset: inset,
                                                     groundLine: groundLine, quantizedWidth: qw,
                                                     width: width, order: order)
                async let rotation: () = orchestrateRotation(count: count, span: span, inset: inset,
                                                             groundLine: groundLine, quantizedWidth: qw,
                                                             order: order)
                _ = await (life, rotation)
            }
            // 关闭活动（设置开关或入夜）：全体回家排排站好（带过渡动画）
            .onChange(of: activityAllowed) { _, allowed in
                if !allowed { sendEveryoneHome() }
            }
            .onChange(of: theme.isNight) { _, night in
                if night {
                    sendEveryoneHome()
                } else {
                    // 天亮了：把「它们在睡觉」的气泡收掉
                    withAnimation(.app(.reveal)) { sleepLine = nil }
                }
            }
            // 今日任务全部完成：全体跳一下 + 冒一句庆祝（外部一天只推一次）
            .onChange(of: celebrationTick) { _, _ in celebrate() }
            // 收词小剧场：一只小动物跑出去叼一张单词卡回来（上一场没演完就只留树上的叶子）
            .onChange(of: wordTick) { _, tick in
                guard tick > 0 else { return }
                Task { await fetchWord(count: count, span: span, inset: inset,
                                       groundLine: groundLine, quantizedWidth: qw) }
            }
            // 纠错安慰：派一只在场的小动物歪头 + 一句温柔的话
            .onChange(of: comfortTick) { _, tick in
                guard tick > 0 else { return }
                comfort()
            }
            // 错得多了：几只一起围过来（同一件事，安慰的分量更足）
            .onChange(of: huddleComfortTick) { _, tick in
                guard tick > 0 else { return }
                huddleComfort()
            }
            // 模块完成：按模块演一段戏（读完想听故事 / 写完在地上划两笔…）
            .onChange(of: moduleTick) { _, tick in
                guard tick > 0, let module = lastModule else { return }
                playModuleSkit(module)
            }
            // 中途退出：目送你走
            .onChange(of: abandonTick) { _, tick in
                guard tick > 0, let module = lastAbandonedModule else { return }
                waveGoodbye(module)
            }
            // 学员开口：最近的一只点点头（「嗯，你在说」）
            .onChange(of: learnerTurnTick) { _, tick in
                guard tick > 0 else { return }
                acknowledgeLearner()
            }
            // 老师开口：几只抬起头听（不用全员，两三只就够像「在听」）
            .onChange(of: teacherTurnTick) { _, tick in
                guard tick > 0 else { return }
                listenUp()
            }
            // 错误举牌（批次八 · H）：老师联系不上，最近的小动物举一块牌子。
            .onChange(of: errorSignTick) { _, tick in
                guard tick > 0 else { return }
                holdUpSign(tick)
            }
            // 首次进入欢迎（批次八 · H）：居民依次跳一圈 + 一句欢迎词。
            // ⚠️ 脉冲可能在地面带上屏**前**就发出（启动流程里记名）——onChange
            // 收不到第一拍，所以 onAppear 里对着已存在的 tick 补演一次（见下）。
            .onChange(of: welcomeTick) { _, tick in
                guard tick > 0 else { return }
                welcomeParty()
            }
            // 连续剧情（#418-C）：舞台判定出幕 → 树上挑角演。
            // ⚠️ 判定（该不该出幕）在 ForestStage，这里不做二次判断 ——
            // 与「簇拥安慰的门槛在舞台」同一条纪律，两处门槛迟早不一致。
            .onChange(of: storyActTick) { _, tick in
                guard tick > 0, let act = lastStoryAct else { return }
                performStoryAct(act)
            }
            // 错误举牌（批次八 · H）：老师联系不上，最近的小动物举一块牌子。
            // 学员又爬上一层（C）：最近的一只小跳一下 + 喊一句。
            .onChange(of: climbFraction) { old, new in
                // 只认**真的向上位移**：进度从库里读回来时也会变（0 → 当前值），
                // 那一次不该演「又上一层」。判据抽成了纯函数，见下。
                guard Self.isRealAscent(old: old, new: new) else { return }
                cheerAscent()
            }
            // 学习上又有动静了 → 解除「已经打过盹」的标记（下次安静还能再演）
            .onChange(of: lastActivityAt) { _, _ in hasDozed = false }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            // 首次进入欢迎的补演：欢迎脉冲在启动流程里发出时本视图可能还没上屏
            //（onChange 只对「出现之后的变化」负责）。tick 已存在而第一拍没演过 → 补上。
            if welcomeTick > 0, !welcomePlayed {
                welcomePlayed = true
                welcomeParty()
            }
        }
        // 点草地（批次六 · E 可玩彩蛋）：落在草地上的点击冒一朵小花。
        // 小动物 / 右下角按钮各自的点击优先级更高，照常工作。
        .gesture(
            SpatialTapGesture().onEnded { value in
                plantFlower(at: value.location.x)
            }
        )
        // 右下角：表情按钮 + 夜晚「睡觉」气泡（右对齐，永远不会溢出面板）
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
                if let sleepLine {
                    SpeechBubble(text: sleepLine, maxWidth: 168)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.55, anchor: .bottom)))
                        .zIndex(5)
                }
                activityButton
            }
            .padding(.trailing, 12)
            .appPadding(.bottom, 10)
        }
        // 与动物气泡一致的收起逻辑：连点会取消上一次计时，停手 3 秒后自动消失
        .task(id: sleepTick) {
            guard sleepLine != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.app(.reveal)) { sleepLine = nil }
        }
        // 验证钩子：--sleep-bubble 时持续冒泡（真实行为由点击触发），便于截图确认气泡不越界
        .task(id: "\(previewSleepBubble)-\(theme.isNight)") {
            guard previewSleepBubble, theme.isNight else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, theme.isNight else { return }
                activityTapped()
            }
        }
    }



    // MARK: 右下角活动开关（与设置联动）

    private var activityButton: some View {
        Button {
            activityTapped()
        } label: {
            Image(systemName: theme.isNight ? "moon.zzz.fill"
                  : (activityAllowed ? "face.smiling" : "face.dashed"))
                .appFont(13, weight: .semibold)
                .foregroundStyle(activityAllowed && !theme.isNight ? theme.accent : theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(theme.surface.opacity(0.9)))
                .overlay(Circle().strokeBorder(theme.divider, lineWidth: 1))
        }
        .buttonStyle(.appPressable)
        .help(activityHelp)
    }

    /// 点击行为：白天 = 活动开关；夜晚 = 冒一句「它们在睡觉」（连点随机换一句）。
    private func activityTapped() {
        guard theme.isNight else {
            onActivityToggle?()
            return
        }
        let pool = Self.sleepPhrases.filter { $0 != sleepLine }
        let next = pool.randomElement() ?? Self.sleepPhrases[0]
        withAnimation(.app(.panel)) { sleepLine = next }
        sleepTick += 1
    }

    private var activityHelp: String {
        if theme.isNight { return "夜深了，小动物们正在睡觉（点一下看看它们的梦话）" }
        return activityAllowed ? "小动物们正在自由活动（点击让它们排排站好）" : "小动物们已安静（点击放它们出来玩）"
    }

    /// 草坡（林间地面带中央那只鼓包）。
    ///
    /// 曲线与 `ForestSceneGeometry.hillSurfaceY` 是**同一条的两种写法**（解析式 ↔
    /// 二次曲线）：鼓包量与坡高都读统一常量，改动不会只落在一侧。
    private struct HillCap: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: rect.midX, y: rect.minY - ForestSceneGeometry.hillCapBulge)
            )
            path.closeSubpath()
            return path
        }
    }
}

/// 小动物「叼回来」的单词卡：圆角小白卡 + 一片小叶 + 单词本体。
/// 纯展示（不吃点击），挂在捡词动物的头顶，展示完由父级收走。
private struct CarriedWordCard: View {
    let word: String
    let theme: ForestTheme

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "leaf.fill")
                .appFont(8, weight: .bold)
                .foregroundStyle(theme.accent)
            Text(word)
                .appFont(11, weight: .bold, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 9)
        .appPadding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.accent.opacity(0.55), lineWidth: 1))
        .shadow(color: theme.shadow, radius: 4, x: 0, y: 2)
    }
}
