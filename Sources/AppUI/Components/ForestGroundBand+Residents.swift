import SwiftUI

// #661 自 TreeCanvas.swift 拆出（2026-10-24）：原文件 2812 行、21 个类型混居，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ForestGroundBand {

// MARK: 居民个体

/// 家位置（与 resident() 完全同一套伪随机，编排与绘制共用）。
func homePosition(index: Int, count: Int, span: CGFloat, inset: CGFloat,
                          groundLine: ForestGroundSurface, quantizedWidth: CGFloat)
    -> (x: CGFloat, y: CGFloat, size: CGFloat) {
    let depth = pr(index, 14)
    // ⚠️ 体型走 `ForestGroundPlan.residentSize`（#624 起与果树同一把尺）：
    // 果树说「两个半小动物高」，量的是这里同一个数，不是另抄一份公式。
    let size = ForestGroundPlan.residentSize(
        quantizedWidth: quantizedWidth, depth: depth, spread: pr(index, 5))
    let pitch = span / CGFloat(max(1, count))
    let jitter = (pr(index, 4) - 0.5) * min(24, pitch * 0.34)
    let x = inset + (CGFloat(index) + 0.5) * pitch + jitter
    let y = groundLine(x) - size * 0.5 - depth * 10 + pr(index, 9) * 6
    return (x, y, size)
}

func resident(kind: AnimalKind, index: Int, visibleCount: Int,
                      span: CGFloat, inset: CGFloat, groundLine: ForestGroundSurface,
                      quantizedWidth: CGFloat) -> some View {
    let visible = index < visibleCount && !away[index]
    let home = homePosition(index: index, count: visibleCount, span: span, inset: inset,
                            groundLine: groundLine, quantizedWidth: quantizedWidth)
    let facing = facingAt(index: index)
    let currentKind = kindAt(index: index, fallback: kind)

    return ZStack {
        // 脚底阴影（落到脚部而不是身体中心；鸟在枝上时收起）
        // ⚠️ 方向走全局光源（`ForestLighting`：太阳右上 → 影子左下）——
        // 从前所有影子笔直朝下，等于默认太阳正在头顶，和天边那颗对不上。
        if !perched[index] {
            let shadow = ForestLighting.shadowOffset(forDepth: ForestSceneGeometry.nearHillDepth)
            Ellipse()
                .fill(theme.shadow)
                .frame(width: home.size * 0.92, height: home.size * 0.15)
                .offset(x: shadow.width, y: home.size * 0.42 + shadow.height)
        }

        LivelyAnimal(
            kind: currentKind,
            isSleeping: theme.isNight,
            size: home.size,
            facing: facing,
            actionTick: actionTicks[index],
            actionKind: actionKinds[index],
            onTap: {
                requestBubble(index)
                onResidentTap?(currentKind)
            },
            onSpontaneousBubble: { requestBubble(index) },
            // 槽位号即初相种子：8 个槽位的初相互不重叠（见 `blinkLead` 的说明），
            // 于是「整排一起眨」变成「一只接一只地眨」。
            blinkPhaseSeed: index,
            // 季节装扮与降水行为（#605）：主题的 season / weather 只改插画层，
            // 顺着环境一路带到每只居民身上。nil（不跟随）= 老样子。
            season: theme.season,
            weather: theme.weather
        )
    }
    .position(x: home.x + offsets[index].width, y: home.y + offsets[index].height)
    .opacity(visible ? 1 : 0)
    .scaleEffect(visible ? 1 : 0.6, anchor: .bottom)
    .allowsHitTesting(visible)
    // 显隐动画认「在不在场」这一个量：宽度档位变化与轮换暂离/回归共用同一条曲线
    .appAnimation(.reveal, value: visible)
}

// MARK: 物种轮换（随机离开 → 新邻居进入）

/// 初始化/对齐各槽位的物种与朝向状态（数量或首次出现时调用）。
func ensureResidents(order: [AnimalKind]) {
    guard kinds.count != Self.maxResidents || facings.count != Self.maxResidents else { return }
    if kinds.isEmpty {
        kinds = (0..<Self.maxResidents).map { order[$0 % order.count] }
    } else {
        kinds = (0..<Self.maxResidents).map { kinds.indices.contains($0) ? kinds[$0] : order[$0 % order.count] }
    }
    if facings.isEmpty {
        facings = (0..<Self.maxResidents).map { pr($0, 3) > 0.5 ? 1 : -1 }
    } else {
        facings = (0..<Self.maxResidents).map { facings.indices.contains($0) ? facings[$0] : 1 }
    }
}

func kindAt(index: Int, fallback: AnimalKind) -> AnimalKind {
    kinds.indices.contains(index) ? kinds[index] : fallback
}

private func facingAt(index: Int) -> CGFloat {
    facings.indices.contains(index) ? facings[index] : 1
}

/// 轮换编排（自然化版）：告别 → 各自看缘分错落回来。
///
/// 与旧版「走一只、紧跟回来一只」的传送带不同：
/// ① 约三成概率**结伴两只**前后脚走（`ForestRotationPacing.groupSize`）；
/// ② 归期各自独立 4–45s——有快得像「提前来」的，也有大半天不见影的，
///    期间画面上真的少一两只（数量动态变化）；
/// ③ 下一批告别前安静 0.5–1.5 个周期，一成概率来一段长歇（留白）。
func orchestrateRotation(count: Int, span: CGFloat, inset: CGFloat,
                                 groundLine: ForestGroundSurface, quantizedWidth: CGFloat,
                                 order: [AnimalKind]) async {
    // ⚠️ 本循环**被取消时**（拖分割线 → `.task(id:)` 重启，或入夜）把还没回来的
    // 居民接回场上：它们此刻 `away = true`，而新的循环只从「在场」的槽位里挑人，
    // 于是这些槽位再也排不到归期 —— 画面上永久少几只，越拖越少。
    // （正常路径是死循环，这个 defer 只在取消 / 退出时跑一次。）
    defer { bringStraysHome() }

    // 个体错峰启动，别开屏就整整齐齐换班
    try? await Task.sleep(for: .seconds(Double.random(in: 8...20)))
    while !Task.isCancelled {
        // 轮换属于「活动」：开关关闭或入夜时静默等待（醒来时全员已被送回家）
        guard activityAllowed, !theme.isNight else {
            try? await Task.sleep(for: .seconds(5))
            continue
        }
        guard count > 0 else { continue }
        let present = (0..<count).filter { !away[$0] }
        guard !present.isEmpty else {
            // 全在「回家路上」：等下一轮（归期循环没跑完不会走到这，兜底而已）
            try? await Task.sleep(for: .seconds(4))
            continue
        }

        // ① 这一批走几只？
        let group = ForestRotationPacing.groupSize(present: present.count,
                                                   roll: Double.random(in: 0..<1))
        let leavers = Array(present.shuffled().prefix(group))

        // ② 告别 + 沿地面走出画面：结伴时前后脚错落动身，不齐步走
        for (offset, index) in leavers.enumerated() {
            if offset > 0 {
                try? await Task.sleep(for: .seconds(
                    ForestRotationPacing.staggerDelay(roll: Double.random(in: 0..<1))))
                guard !Task.isCancelled else { return }
            }
            if bubblesAllowed {
                requestRawBubble(index, pool: Self.leavePhrases)
                try? await Task.sleep(for: .seconds(2.6))
            }
            guard !Task.isCancelled else { return }
            await hopOutOfStage(index, count: count, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
            away[index] = true
        }

        // ③ 归期各自独立：谁先到看缘分（回来顺序与离开顺序刻意打乱）
        for index in leavers.shuffled() {
            try? await Task.sleep(for: .seconds(
                ForestRotationPacing.returnDelay(roll: Double.random(in: 0..<1))))
            guard !Task.isCancelled else { return }
            // 入夜 / 关活动：剩下的不再回来（sendEveryoneHome 已把 away 清掉）
            guard activityAllowed, !theme.isNight else { break }
            await arriveFromEdge(index: index, count: count, span: span, inset: inset,
                                 groundLine: groundLine, quantizedWidth: quantizedWidth,
                                 order: order)
        }

        // ④ 下一批告别前先安静一阵
        try? await Task.sleep(for: .seconds(ForestRotationPacing.nextDepartureDelay(
            frequency: activityFrequency,
            roll: Double.random(in: 0..<1),
            spread: Double.random(in: 0..<1))))
    }
}

/// 把还挂着「暂离」标记的居民接回场上（轮换循环退出 / 被取消时）。
///
/// ⚠️ 只复位**标记**，位置交给 `offsets` 归零（回家）—— 暂离的那只此刻在画外，
/// 直接翻牌显形会凭空多出一只站在草坡边上。
func bringStraysHome() {
    let strays = away.indices.filter { away[$0] }
    guard !strays.isEmpty else { return }
    withAnimation(.app(.panel)) {
        for index in strays {
            away[index] = false
            if offsets.indices.contains(index) { offsets[index] = .zero }
            if perched.indices.contains(index) { perched[index] = false }
        }
    }
}

/// 沿地面走出画面（朝离自家近的一侧边缘小跳离场）。
private func hopOutOfStage(_ index: Int, count: Int, span: CGFloat, inset: CGFloat,
                           groundLine: ForestGroundSurface, quantizedWidth: CGFloat) async {
    let home = homePosition(index: index, count: count, span: span, inset: inset,
                            groundLine: groundLine, quantizedWidth: quantizedWidth)
    let current = offsets[index]
    let bandCenter = inset + span / 2
    let exitLeft = home.x + current.width < bandCenter
    let exitX = exitLeft ? -(inset + 40) : (inset + span + 40) - home.x
    if facings.indices.contains(index) { facings[index] = exitLeft ? -1 : 1 }
    await hopTo(index, target: CGSize(width: exitX, height: current.height),
                steps: 4, hopHeight: 9)
}

/// 一位「新邻居」从离场那一侧的边缘走进来（换物种 → 走回家位 → 打招呼）。
private func arriveFromEdge(index: Int, count: Int, span: CGFloat, inset: CGFloat,
                            groundLine: ForestGroundSurface, quantizedWidth: CGFloat,
                            order: [AnimalKind]) async {
    // 换物种：谁回来是缘分（只保证不是走掉的那位）
    let pool = AnimalKind.allCases.filter { $0 != kindAt(index: index, fallback: order.first ?? .fox) }
    let newKind = pool.randomElement() ?? .rabbit
    if kinds.indices.contains(index) { kinds[index] = newKind }
    // 此刻还在画外（离场位置），现身走进来
    away[index] = false
    if facings.indices.contains(index) {
        facings[index] = offsets[index].width < 0 ? -1 : 1
    }
    try? await Task.sleep(for: .seconds(0.15))
    guard !Task.isCancelled else { return }
    let current = offsets[index]
    await hopTo(index, target: CGSize(width: 0, height: current.height),
                steps: 6, hopHeight: 8)
    if bubblesAllowed {
        requestRawBubble(index, pool: Self.greetPhrases)
    }
}

/// 作废所有在飞的移动批次（入夜 / 关活动用）。
///
/// 只自增计数器不够 —— 在飞的那一批手里拿的正是「当前」批次号；必须把
/// 每个槽位的批次号推到新值，它们才对不上账、自行退场。
func invalidateHops() {
    hopCounter += 1
    hopTokens = Array(repeating: hopCounter, count: Self.maxResidents)
}

/// 多段小跳从当前位置移动到目标位移（跳动前进，而不是平移）。
///
/// ⚠️ **后来者胜出**：每次发起都领一个新批次号并记进 `hopTokens[index]`，
/// 循环里每一步都对一次账 —— 对不上说明期间又有新的移动意图（游走 / 离场 /
/// 归位 / 捡词撞车），本次立刻退出，不再碰 `offsets`。
/// 两个编排循环并发盯上同一只时，没有这个对账就是两边交替写同一个位移。
func hopTo(_ index: Int, target: CGSize, steps: Int, hopHeight: CGFloat) async {
    guard offsets.indices.contains(index), hopTokens.indices.contains(index) else { return }
    hopCounter += 1
    let token = hopCounter
    hopTokens[index] = token
    let start = offsets[index]
    for step in 1...max(1, steps) {
        guard !Task.isCancelled else { return }
        guard hopTokens.indices.contains(index), hopTokens[index] == token else { return }
        let t = Double(step) / Double(steps)
        let x = start.width + (target.width - start.width) * t
        let y = start.height + (target.height - start.height) * t
        // 起跳：横移一段 + 向上抬起
        withAnimation(.app(.press)) {
            offsets[index] = CGSize(width: x, height: y - hopHeight)
        }
        try? await Task.sleep(for: .seconds(0.17))
        // 落地
        withAnimation(.app(.press)) {
            offsets[index] = CGSize(width: x, height: y)
        }
        try? await Task.sleep(for: .seconds(0.13))
    }
}

/// 轮换专用冒泡（不走物种文案池，直接给文案）。
/// 每个小动物持有自己的气泡：新气泡只覆盖**自己**那一句，其他动物的话照常挂着；
/// 出现序号递增 → 最新出现的画在最上层；`hold` 秒后各自独立收起。
func requestRawBubble(_ index: Int, pool: [String], hold: Double = 3) {
    guard !pool.isEmpty, bubbleTexts.indices.contains(index) else { return }
    bubbleCounter += 1
    let stamp = bubbleCounter
    withAnimation(.app(.panel)) {
        bubbleStamps[index] = stamp
        bubbleTexts[index] = pool.randomElement()
    }
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(hold))
        // 期间这只小动物又说了新话（或全体收声）→ 本次收起作废
        guard bubbleStamps.indices.contains(index), bubbleStamps[index] == stamp else { return }
        withAnimation(.app(.reveal)) { bubbleTexts[index] = nil }
    }
}

/// 请求冒泡（点击或自发动作统一入口）：顶层展示，3 秒后自动收起。
///
/// 文案池走 `bubblePhrases(season:weather:)`（#606）：通用句打底、
/// 当季与当天的句子做增量 —— 无季节无天气时逐字等于物种原池。
private func requestBubble(_ index: Int) {
    guard bubblesAllowed else { return }
    let kind = kindAt(index: index, fallback: AnimalKind.allCases[index % AnimalKind.allCases.count])
    requestRawBubble(index, pool: kind.bubblePhrases(season: theme.season, weather: theme.weather))
}
}
