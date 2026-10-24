import SwiftUI

// #661 自 TreeCanvas.swift 拆出（2026-10-24）：原文件 2812 行、21 个类型混居，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ForestGroundBand {

// MARK: 活动编排（唯一的心跳：游走 / 跳 / 摇 / 飞枝）

func orchestrateLife(count: Int, span: CGFloat, inset: CGFloat, groundLine: ForestGroundSurface,
                             quantizedWidth: CGFloat, width: CGFloat,
                             order: [AnimalKind]) async {
    // 个体错峰启动，避免整排动物同时动作
    try? await Task.sleep(for: .seconds(Double.random(in: 3...6)))
    while !Task.isCancelled {
        // 动作间隔由活动频率决定：0 → ~12s，1 → ~4s（再叠加随机抖动）。
        //
        // ⚠️ **每轮重算**：写在循环外就成了一个固定节拍器，八只动物会踩着同一个
        // 鼓点动（注释里的「随机抖动」也就只剩开跑前那一次）。频率钳回 0…1，
        // 免得配置里存了个越界值把间隔算成负数（`Task.sleep` 负数是立刻返回 → 忙循环）。
        let clampedFrequency = min(max(activityFrequency, 0), 1)
        let interval = max(1.5, 12 - clampedFrequency * 8) * Double.random(in: 0.8...1.25)
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled, activityAllowed, !theme.isNight else { continue }
        guard count > 0 else { continue }
        // 人是不是走开了？安静太久就有谁打个盹（判时间差，零新增定时器）
        dozeOffIfQuiet()
        // 只在**在场**的居民里挑：轮换暂离的槽位不能「凭空演戏」
        //
        // ⚠️ 谁上场按**当前物种的活跃度**加权，且判「爱不爱飞」看的是当前物种
        // （`kindAt`）—— 早先看的是初始 `order`，轮换换过人之后性格就串了味。
        let present = (0..<count).filter { !away[$0] }
        guard let index = AnimalPersonaBook.pick(kinds: kinds, present: present,
                                                 roll: Double.random(in: 0..<1)) else { continue }
        let kind = kindAt(index: index, fallback: order[index % order.count])
        let persona = AnimalPersonaBook.persona(for: kind)

        if persona.favorsPerch && !perched[index] && Int.random(in: 0..<10) < 3 {
            // 鸟类：飞上枝桠，停留一阵（期间会小幅挪动），再飞回草地
            await flyToPerch(index, count: count, span: span, inset: inset,
                             groundLine: groundLine, quantizedWidth: quantizedWidth, width: width)
            // 枝上小憩：随机停留 + 小幅挪动
            let stay = Int.random(in: 1...2)
            for _ in 0..<stay {
                try? await Task.sleep(for: .seconds(Double.random(in: 4...8)))
                guard !Task.isCancelled, activityAllowed, !theme.isNight else { break }
                if Bool.random() { shuffleOnPerch(index) }
            }
            try? await Task.sleep(for: .seconds(Double.random(in: 3...6)))
            guard !Task.isCancelled else { return }
            await flyBackToGrass(index)
        } else if perched[index] {
            // 已在枝上：要么小幅挪动，要么飞回草地
            if Bool.random() {
                shuffleOnPerch(index)
            } else {
                await flyBackToGrass(index)
            }
        } else {
            // 地面：游走 / 跳 / 摇 / 独角戏 / 双人社交（结对舞或一问一答）
            //
            // 跳与摇这两档也会「改演招牌动作」—— 兔子更爱蹦、考拉爱打盹，
            // 就靠 `AnimalPersonaBook.action` 那三成概率。
            let roll = Int.random(in: 0..<10)
            let signatureRoll = Double.random(in: 0..<1)
            if roll < 4 {
                wander(index, count: count, span: span, inset: inset,
                       groundLine: groundLine, quantizedWidth: quantizedWidth)
            } else if roll < 6 {
                trigger(index, action: AnimalPersonaBook.action(for: kind, roll: signatureRoll,
                                                                fallback: .hop))
            } else if roll < 8 {
                trigger(index, action: AnimalPersonaBook.action(for: kind, roll: signatureRoll,
                                                                fallback: .shake))
            } else if roll == 8 {
                // 独角戏：从本物种的偏好池里抽（wiggle 只留给双人舞）
                trigger(index, action: AnimalPersonaBook.soloAction(for: kind, roll: signatureRoll))
            } else {
                await socialise(count: count, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
            }
        }
    }
}

/// 触发一次动作（具体演哪个由 `LivelyAnimalAction` 语义表决定）。
func trigger(_ index: Int, action: LivelyAnimalAction) {
    actionKinds[index] = action
    actionTicks[index] += 1
}

/// 地面游走：在草地范围内累计位移（走到哪停在哪），跳动前进，不会走出草坡。
private func wander(_ index: Int, count: Int, span: CGFloat, inset: CGFloat,
                    groundLine: ForestGroundSurface, quantizedWidth: CGFloat) {
    let home = homePosition(index: index, count: count, span: span, inset: inset,
                            groundLine: groundLine, quantizedWidth: quantizedWidth)
    let current = offsets[index]
    // 左右各留出草坡内边距，纵向限制在坡面附近
    let slackLeft = home.x - inset * 0.45
    let slackRight = (inset + span + inset * 0.45) - home.x
    let nx = min(max(current.width + CGFloat.random(in: -24...24), -slackLeft), slackRight)
    let ny = min(max(current.height + CGFloat.random(in: -16...6), -20), 7)
    // 按移动方向转身
    if facings.indices.contains(index), abs(nx - current.width) > 2 {
        facings[index] = nx > current.width ? 1 : -1
    }
    Task { await hopTo(index, target: CGSize(width: nx, height: ny), steps: 3, hopHeight: 7) }
}

/// 枝桠位置（相对树干中心对称两根）。
private func perchPoint(_ k: Int, width: CGFloat) -> CGPoint {
    CGPoint(x: width * 0.5 + (k == 0 ? -1 : 1) * width * 0.085,
            y: 22 + CGFloat(k) * 16)
}

/// 树干底部的枝桠栖木（视觉上接住飞上来的鸟）。
@ViewBuilder
func perchStubs(width: CGFloat) -> some View {
    ForEach(0..<2, id: \.self) { k in
        let point = perchPoint(k, width: width)
        Capsule()
            .fill(theme.trunkShade.opacity(0.9))
            .frame(width: 36, height: 5)
            .rotationEffect(.degrees(k == 0 ? -6 : 6))
            .position(point)
    }
}

/// 鸟类飞上枝桠。
private func flyToPerch(_ index: Int, count: Int, span: CGFloat, inset: CGFloat,
                        groundLine: ForestGroundSurface, quantizedWidth: CGFloat, width: CGFloat) async {
    let home = homePosition(index: index, count: count, span: span, inset: inset,
                            groundLine: groundLine, quantizedWidth: quantizedWidth)
    let perch = perchPoint(Int.random(in: 0..<2), width: width)
    withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) {
        offsets[index] = CGSize(width: perch.x - home.x, height: perch.y - home.y - 4)
        perched[index] = true
    }
}

/// 在枝上小幅挪动（沿枝 ±10pt）。
///
/// ⚠️ 这里**只**用 `index`：挪动是相对当前 `offsets` 的增量，位置由 `flyToPerch` 决定。
/// 早先签名里挂着一串几何入参（count / span / inset / groundLine / quantizedWidth / width）
/// 却一个都不用，4 个调用点还逐次算好传进来 —— 读签名的人会以为它在重新定位。
private func shuffleOnPerch(_ index: Int) {
    let delta = CGFloat.random(in: -10...10)
    withAnimation(.easeInOut(duration: 0.5)) {
        offsets[index].width += delta
    }
}

/// 飞回草地（直接回家，`offsets` 归零）。
private func flyBackToGrass(_ index: Int) async {
    withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) {
        offsets[index] = .zero
        perched[index] = false
    }
}

/// 全体回家排排站好（关闭活动 / 入夜时调用，带过渡动画）。
/// ⚠️ 暂离状态一并清掉：轮换循环醒来看到的是「全员到场」，不会有人卡在画外。
func sendEveryoneHome() {
    // 作废所有在飞的移动：否则离场/游走那趟 `hopTo` 会在「回家」之后继续写
    // `offsets`，把刚站好的队伍又拽走一只（入夜那一刻最容易看见）。
    invalidateHops()
    // 庆祝演出同样要作废（#S3-11）：它剩下的那些错峰 Task 不归 `hopTokens` 管，
    // 不递令牌的话「回家」之后还会有人跳一下、冒一句。
    celebrationToken += 1
    withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
        for i in 0..<Self.maxResidents {
            offsets[i] = .zero
            perched[i] = false
            away[i] = false
        }
        clearAllBubbles()
    }
}

/// 收起所有小动物的气泡（各自独立，互不干扰）。
private func clearAllBubbles() {
    bubbleCounter += 1     // 作废所有在飞的自动收起任务
    for i in bubbleTexts.indices { bubbleTexts[i] = nil }
}

}
