import SwiftUI
import AIDomain

// #661 自 TreeCanvas.swift 拆出（2026-10-24）：原文件 2812 行、21 个类型混居，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ForestGroundBand {

// MARK: 庆祝（今日任务全部完成）

/// 今日任务全部完成时小动物冒的话（轮换，避免每次都是同一句）。
static let celebrationPhrases = [
    "今天的任务都完成啦！",
    "好棒！明天也一起来～",
    "你今天真认真，我看见了！",
    "任务全清！去休息一下吧～",
]

/// 全体错落欢跳（跳好几下）+ 前几只错落冒庆祝气泡。
///
/// ⚠️ 只递 `actionTicks`（`LivelyAnimal` 靠它变化触发动作），不自己写动画 ——
/// 身体动画归 `LivelyAnimal`，气泡层级归本视图，两边各管各的才不会打架。
/// ⚠️ 只点**在场**的居民：轮换暂离的槽位不演戏、不冒泡。
///
/// 2026-09-29 用户报障「只是集体跳了一下，然后同时冒出气泡」：
/// 改成**三波**欢跳 —— 每只按位次错开 0.18s、波与波隔 0.85s，同一只前后要跳三下；
/// 气泡也按位次错开 0.7s 陆续冒出来（齐刷刷同帧冒泡看着像贴图，不像一群活的）。
/// 夜晚 / 活动被关（`activityAllowed` 已含「配置 && 白天」）只冒气泡不跳——
/// 睡着的小动物被吵醒跳就不礼貌了，但庆祝的话还是要说。
func celebrate() {
    // 领号：这次演出的一切都挂在这个号上；期间只要有人递号（回家 / 重新庆祝），
    // 剩下的 Task 一动手就对不上账、自行退场（#S3-11）。
    celebrationToken += 1
    let token = celebrationToken
    let present = presentResidents
    if activityAllowed {
        for wave in 0..<3 {
            for (order, index) in present.enumerated() {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Double(wave) * 0.85 + Double(order) * 0.18))
                    guard celebrationToken == token else { return }
                    trigger(index, action: .hop)
                }
            }
        }
    }
    // 只让前三只在场的说话：八只同时冒泡会糊成一片；错落着冒才有「你一句我一句」的感觉。
    let bubbled = Array(present.prefix(3))
    // 派号与出场分开：**先同步派号**，出场顺序才与序号递增一致（zIndex 靠序号），
    // 也才能把这几个号冻结成常量交给收尾 Task 去对账 —— 让每个 Task 自己派号的话，
    // 收尾那一个根本不知道要收哪几个（原先它是无差别清空的，会连带清掉别人的话）。
    var plan: [(index: Int, stamp: Int)] = []
    for index in bubbled {
        bubbleCounter += 1
        bubbleStamps[index] = bubbleCounter
        plan.append((index: index, stamp: bubbleCounter))
    }
    let bubblePlan = plan
    for (order, entry) in bubblePlan.enumerated() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(order) * 0.7))
            guard celebrationToken == token,
                  bubbleStamps.indices.contains(entry.index),
                  bubbleStamps[entry.index] == entry.stamp else { return }
            withAnimation(.app(.panel)) {
                bubbleTexts[entry.index] =
                    Self.celebrationPhrases[(entry.index + celebrationTick) % Self.celebrationPhrases.count]
            }
        }
    }
    Task { @MainActor in
        // 最后一句话冒出来的时刻 + 3s 展示期，一起收。
        try? await Task.sleep(for: .seconds(Double(bubblePlan.count - 1) * 0.7 + 3))
        guard celebrationToken == token else { return }
        // 只收**自己那一批**的号：期间这只被点了、或换过一句，就不是我们的泡泡了。
        for entry in bubblePlan {
            guard bubbleStamps.indices.contains(entry.index),
                  bubbleStamps[entry.index] == entry.stamp else { continue }
            withAnimation(.app(.reveal)) { bubbleTexts[entry.index] = nil }
        }
    }
}

// MARK: 小剧场（批次二：双人社交 / 歪头安慰 / 捡词叙事）

/// 双人社交：挑 x 距离最近的一对邻居，要么结对摇摆（跳舞），要么一问一答。
/// 只剩一只时就给它一段独舞，不让社交意图落空。
func socialise(count: Int, span: CGFloat, inset: CGFloat,
                       groundLine: ForestGroundSurface, quantizedWidth: CGFloat) async {
    let present = (0..<count).filter { !away[$0] }
    let xs = present.reduce(into: [Int: CGFloat]()) { result, index in
        let home = homePosition(index: index, count: count, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
        result[index] = home.x + offsets[index].width
    }
    if let pair = ForestTheatrePacing.closestPair(x: xs, present: present) {
        if Bool.random() {
            // 结对跳舞：两只同时摇摆，同步的节奏就是舞步
            trigger(pair.0, action: .wiggle)
            trigger(pair.1, action: .wiggle)
            if bubblesAllowed, Bool.random() {
                requestRawBubble(pair.0, pool: ["跳个舞吧！"])
            }
        } else {
            await performDialogue(pair)
        }
    } else if let only = present.first {
        trigger(only, action: .wiggle)
    }
}

/// 一问一答：按 `ForestTheatrePacing.dialogueCues` 的节拍，两只邻居交替把脚本说完。
private func performDialogue(_ pair: (Int, Int)) async {
    guard bubblesAllowed, let script = Self.dialogueScripts.randomElement() else { return }
    let cues = ForestTheatrePacing.dialogueCues(lineCount: script.count)
    for (i, cue) in cues.enumerated() {
        if i > 0 {
            try? await Task.sleep(for: .seconds(cue.start - cues[i - 1].start))
            guard !Task.isCancelled else { return }
        }
        let speaker = i.isMultiple(of: 2) ? pair.0 : pair.1
        requestRawBubble(speaker, pool: [script[i]], hold: cue.hold)
    }
}

/// 歪头安慰：纠错后派一只在场的小动物歪歪头，说句温柔的话。
/// ⚠️ 只点在场的居民；安慰语固定轮换（连续纠错不会每次都是同一句）。
func comfort() {
    guard activityAllowed, !theme.isNight, bubblesAllowed else { return }
    let present = presentResidents
    guard let index = present.randomElement() else { return }
    trigger(index, action: .tilt)
    requestRawBubble(index, pool: Self.comfortPhrases)
}

/// 这一次 `climbFraction` 的变化算不算「真的往上爬了一层」。
///
/// 三条否定，每条都是一次真实会发生的事：
/// - **没动**（`new == old`）：同一帧被 SwiftUI 重算，不是学习事件；
/// - **往下走**：进度回退（如重置闯关）时，小动物不该跳起来叫好；
/// - **从 0 起步**（`old == 0`）：进度刚从库里读回来填上初始值，
///   那一次变化是「加载」不是「攀爬」——不演，否则每次开屏都要演一遍。
///
/// 剩下一个极小阈值 0.0004：把浮点噪声和「几乎没动」一起挡掉。
/// 抽成纯函数是为了能单测（`onChange` 闭包没法直接测）。
nonisolated static func isRealAscent(old: Double, new: Double) -> Bool {
    guard old > 0 else { return false }
    return new > old + 0.0004
}

/// 学员往上爬了一层：最近的一只小跳两下 + 一句招呼。
///
/// 为什么挑「最近的一只」而不是随便一只：学员在树干上，离树干最近的那只
/// 就是「就在他脚下」的那只，抬头就能看见他 —— 远处那几只抬头是看不到的。
/// 这里没有几何可算（调用点在 `body` 之外），退一步取栈顶第一只：
/// 地面带的排布本来就是从树干向两侧铺开的。
func cheerAscent() {
    guard activityAllowed, !theme.isNight else { return }
    let present = presentResidents
    guard let index = present.first else { return }
    trigger(index, action: .hop)
    Task { @MainActor in
        // 两下才像"高兴"，一下更像绊了一下
        try? await Task.sleep(for: .seconds(0.3))
        guard !Task.isCancelled else { return }
        trigger(index, action: .hop)
    }
    if bubblesAllowed {
        requestRawBubble(index, pool: Self.ascentPhrases)
    }
}

// MARK: 边界状态（批次八 · H）

/// 首次进入欢迎：居民从左到右依次跳一圈（像点名报到），队头冒一句欢迎词。
/// 夜晚 / 活动被关时**只冒气泡不跳**——睡着的小动物被吵醒跳就不礼貌了。
func welcomeParty() {
    welcomePlayed = true
    let present = presentResidents
    if activityAllowed, !theme.isNight {
        for (order, index) in present.enumerated() {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Double(order) * 0.35))
                trigger(index, action: .hop)
            }
        }
    }
    if let first = present.first {
        requestRawBubble(first, pool: Self.welcomePhrases, hold: 3.6)
    }
}

/// 错误举牌：最近的一只在场小动物举起牌子，5 秒后自己收。
///
/// 夜晚也举（错误不挑时候）；牌子举在头顶，详情在聊天区横幅——这里只喊一嗓子。
func holdUpSign(_ tick: Int) {
    guard let headline = errorHeadline, !headline.isEmpty else { return }
    guard let index = presentResidents.first else { return }
    signShownTick = tick
    withAnimation(.app(.panel)) { signHolder = index }
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(5))
        // 期间又出了新错（新一轮举牌）→ 本次收起作废，由新一轮自己收。
        guard signHolder == index, signShownTick == tick else { return }
        withAnimation(.app(.reveal)) { signHolder = nil }
    }
}

// MARK: 分模块回应（批次四 · A）

/// 簇拥安慰：一轮错得多了，几只一起围过来（不是一只歪头了事）。
///
/// ⚠️ 与 `comfort()` 只差「几只」和台词分量 —— 判据（错几条）在 `ForestStage`，
/// 这里不做二次判断，免得两处门槛不一致。
func huddleComfort() {
    guard activityAllowed, !theme.isNight else { return }
    let present = presentResidents
    guard !present.isEmpty else { return }
    // 最多三只：再多就不是安慰，是围观的
    let cast = Array(present.shuffled().prefix(min(3, present.count)))
    for index in cast {
        trigger(index, action: .tilt)
        if bubblesAllowed {
            requestRawBubble(index, pool: Self.huddleComfortPhrases)
        }
    }
}

/// 模块完成戏码：按 `ForestModuleSkit` 派 1–2 只，演这个模块的动作与台词。
func playModuleSkit(_ module: PracticeModule) {
    guard activityAllowed, !theme.isNight else { return }
    let present = presentResidents
    guard !present.isEmpty else { return }
    let cast = Array(present.shuffled().prefix(ForestModuleSkit.castSize(for: module)))
    for index in cast {
        trigger(index, action: ForestModuleSkit.action(for: module))
    }
    // 只让领衔的那只说话：两只同时冒同一句会像复读机。
    if bubblesAllowed, let lead = cast.first {
        requestRawBubble(lead, pool: ForestModuleSkit.lines(for: module))
    }
}

/// 中途退出：目送你走。
///
/// 动作选 `shake`（左右摆 = 挥手），台词走 `farewellLines` —— 语气上
/// 不评判、不催促，退出不是失败。
func waveGoodbye(_ module: PracticeModule) {
    guard activityAllowed, !theme.isNight else { return }
    let present = presentResidents
    guard !present.isEmpty else { return }
    let cast = Array(present.shuffled().prefix(min(2, present.count)))
    for index in cast {
        trigger(index, action: .shake)
    }
    if bubblesAllowed, let lead = cast.first {
        requestRawBubble(lead, pool: ForestModuleSkit.farewellLines(for: module))
    }
}

/// 学员开口：最近的一只点点头（「嗯，你在说」）。
///
/// ⚠️ 判「最近」看的是**画面上的 x**，不是槽位号：草坡上站位是错落的，
/// 槽位相邻的两只未必挨着。
func acknowledgeLearner() {
    guard activityAllowed, !theme.isNight else { return }
    let present = presentResidents
    guard let index = present.randomElement() else { return }
    trigger(index, action: .nod)
}

/// 老师开口：两三只抬起头听（全员一起抬头反而像受惊）。
func listenUp() {
    guard activityAllowed, !theme.isNight else { return }
    let present = presentResidents
    guard !present.isEmpty else { return }
    let cast = Array(present.shuffled().prefix(min(2, present.count)))
    for index in cast {
        trigger(index, action: .listen)
    }
}

// MARK: 连续剧情（#418-C）

/// 各幕的台词池（每幕自己的语气，别混用）。
private static let storyLines: [ForestStoryArc.Act: [String]] = [
    .harvest: ["枝头又结果子啦！", "看，那是你攒下的星星。"],
    .encore: ["还想再来一段？先让我热热身！", "通关了还练，佩服佩服！"],
    .focus: ["你练得真专注，我都不好意思打闹了。", "这么认真，我陪你一块儿。"],
]

/// 演一幕：主角演动作 + 冒一句幕词。
///
/// ⚠️ **演员绑定**：这一轮学习里的各幕由同一位领衔（`storyLead`）——
/// 剧情感来自「是同一个小伙伴在陪你」，每次换角就成了随机点播。
/// 主角暂离（轮换出去了）就换角重绑，不能让画外的角色凭空演戏。
/// 夜晚 / 活动被关时不演（舞台的记账照走，这一幕会话里就此错过）。
func performStoryAct(_ act: ForestStoryArc.Act) {
    guard activityAllowed, !theme.isNight else { return }
    let present = presentResidents
    if let lead = storyLead, !present.contains(lead) { storyLead = nil }
    let lead = storyLead ?? present.randomElement()
    if storyLead == nil { storyLead = lead }
    guard let lead else { return }
    switch act {
    case .harvest: trigger(lead, action: .hop)
    case .encore: trigger(lead, action: .wiggle)
    case .focus: trigger(lead, action: .nod)
    }
    if bubblesAllowed, let lines = Self.storyLines[act] {
        requestRawBubble(lead, pool: lines)
    }
}

/// 安静太久了：有谁打个盹（不是「睡着」，是困了点个头）。
///
/// 由**既有心跳**判时间差（`lastActivityAt` 距今），因此不需要新增任何定时器；
/// `hasDozed` 保证安静期间只演一次，直到学习上又有动静才解锁。
func dozeOffIfQuiet() {
    guard activityAllowed, !theme.isNight, !hasDozed else { return }
    let quiet = Date().timeIntervalSince(lastActivityAt)
    guard quiet >= ForestStage.idleThresholdSeconds else { return }
    let present = presentResidents
    guard let index = present.randomElement() else { return }
    hasDozed = true
    trigger(index, action: .nod)
    if bubblesAllowed {
        requestRawBubble(index, pool: Self.dozingPhrases)
    }
}

/// 捡词具象叙事：看见新词 → 跑出画面 → 叼一张单词卡回来展示。
///
/// 「事事有回应」的具象版——收词不只是飘一片叶子，而是森林里真的有谁
/// 为这件事跑了一趟。上一场没演完时新事件只留树上的叶子回应（不排队、不叠加）。
func fetchWord(count: Int, span: CGFloat, inset: CGFloat,
                       groundLine: ForestGroundSurface, quantizedWidth: CGFloat) async {
    guard activityAllowed, !theme.isNight, !isFetchingWord, let word = wordPayload else { return }
    // 只派**在场且站在草地上**的居民（枝上的鸟不接这活）
    let present = (0..<count).filter { !away[$0] && !perched[$0] }
    guard let fetcher = present.randomElement() else { return }

    isFetchingWord = true
    defer {
        isFetchingWord = false
        // 捡到一半被打断时这位可能正站在画外（`away` 已置真）—— 接回来，
        // 否则它这一趟就再没机会回来，草坡上永久少一只。
        bringStraysHome()
    }

    // ① 看见词：先冒一句「我去捡」，动身
    if bubblesAllowed {
        requestRawBubble(fetcher, pool: Self.fetchStartPhrases, hold: ForestTheatrePacing.fetchNoticeSeconds)
    }
    try? await Task.sleep(for: .seconds(ForestTheatrePacing.fetchNoticeSeconds))
    guard !Task.isCancelled else { return }

    // ② 跑出画面（朝离自家近的一侧），短暂消失翻找
    let home = homePosition(index: fetcher, count: count, span: span, inset: inset,
                            groundLine: groundLine, quantizedWidth: quantizedWidth)
    let exitLeft = home.x + offsets[fetcher].width < inset + span / 2
    if facings.indices.contains(fetcher) { facings[fetcher] = exitLeft ? -1 : 1 }
    let exitX = exitLeft ? -(inset + 40) : (inset + span + 40) - home.x
    await hopTo(fetcher, target: CGSize(width: exitX, height: offsets[fetcher].height),
                steps: 3, hopHeight: 8)
    guard !Task.isCancelled else { return }
    away[fetcher] = true
    try? await Task.sleep(for: .seconds(ForestTheatrePacing.fetchLingerSeconds))
    guard !Task.isCancelled else { return }

    // ③ 叼着词卡现身，走回家
    away[fetcher] = false
    wordCard = (fetcher, word)
    withAnimation(.app(.reveal)) {
        if facings.indices.contains(fetcher) { facings[fetcher] = exitLeft ? 1 : -1 }
    }
    try? await Task.sleep(for: .seconds(0.2))
    guard !Task.isCancelled else { return }
    await hopTo(fetcher, target: .zero, steps: 5, hopHeight: 8)
    guard !Task.isCancelled else { return }

    // ④ 展示：冒一句炫耀 + 词卡挂一会儿，然后各自收场
    if bubblesAllowed {
        requestRawBubble(fetcher, pool: Self.fetchDonePhrases)
    }
    try? await Task.sleep(for: .seconds(ForestTheatrePacing.wordCardHoldSeconds))
    guard !Task.isCancelled else { return }
    withAnimation(.app(.reveal)) { wordCard = nil }
}

}
