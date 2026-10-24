import SwiftUI

// #661 自 TreeCanvas.swift 拆出（2026-10-24）：原文件 2812 行、21 个类型混居，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
// MARK: - 树干 / 树冠

struct TrunkShape: Shape {
    /// 树干尖离画布顶多远（默认 130 = 从前那套；有课程关卡时要压进树冠里，
    /// 否则树冠回到树顶之后，树干尖会从叶子上方戳出来一截）。
    var tipY: CGFloat = 130
    /// 成熟度 0…1（#601：树干跟着总进度变粗细）。1 = 改动前的宽度。
    var growth: Double = 1

    func path(in rect: CGRect) -> Path {
        let widths = TreeGrowth.trunkWidths(growth: growth)
        let bottomWidth = rect.width * widths.bottom
        let topWidth = rect.width * widths.top
        let tip = rect.minY + tipY
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - bottomWidth / 2, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX - topWidth / 2, y: tip),
            control: CGPoint(x: rect.midX - bottomWidth * 0.44, y: rect.midY)
        )
        path.addLine(to: CGPoint(x: rect.midX + topWidth / 2, y: tip))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + bottomWidth / 2, y: rect.maxY),
            control: CGPoint(x: rect.midX + bottomWidth * 0.44, y: rect.midY)
        )
        path.closeSubpath()
        return path
    }
}

struct Canopy: View {
    let theme: ForestTheme
    /// 树冠茂密度 0…1（已得星 / 需求星）：只做视觉变换（整体放大），不动布局。
    var density: Double = 0
    /// 枝头果实数量（= 已得星，封顶到 `FruitLayer.placements`）。
    var fruitCount: Int = 0
    /// 通关仪式脉冲：变化时抖三抖（独立于常驻摇摆的第二层旋转）。
    var shakeTick: Int = 0

    @State private var shakeAngle: Double = 0
    @Environment(\.appMotion) private var motion

    var body: some View {
        // 画框宽度：果实环的风 x 要取画布中心（与树冠各层同一个波位）。
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // 树冠本体：四层枝叶 + 枝干骨架 + 统一光。
                //
                // ⚠️ 这里曾经是「四颗团块并成一道路径、只填一次色」（`CanopyMass`）——
                // 那套修法消灭了交界弧线（「一块一块」），代价是把**层次**一起消灭了：
                // 整幅树冠只剩一层渐变，于是用户看到的就是「一团绿」。
                // 现在的结构与配色全在 `TreeCrownArt.swift`，本结构只负责仪式抖动。
                //
                // ⚠️ 常驻摇摆**不在这里**：第 5 版起风按层吹（`TreeCrown` 里四层
                // 各自的 `WindSway`，用户 2026-10-18：「不要一整个树冠一起摇动」）。
                // 从前那颗整冠 `.rotationEffect` + `loopAnimation` 已删 —— 留着
                // 就是「分层上面再叠一个整冠旋转」，两层运动互相打架。
                TreeCrown(theme: theme)

                // 果实：挂着的一整圈，比单层叶重、比整冠轻 —— 增益取四层
                // 中间一档，跟着轻轻欠身，不脱离它挂在下面的那层叶。
                WindSway(
                    x: size.width * 0.5,
                    height: CanopyLayout.windHeight,
                    gain: 0.5,
                    rotationGain: 0.18
                ) {
                    FruitLayer(theme: theme, count: fruitCount)
                }
            }
            .scaleEffect(TreeGrowth.crownScale(growth: density), anchor: .bottom)
            // 仪式抖动：通关时抖三抖（幅度远大于常驻摇摆，一眼区分）。
            // 两套 modifier 叠加互不打架：仪式是整冠的一次性旋转，常驻摇摆在
            // 各层内部，早已各自的 transform 里算完。
            .rotationEffect(.degrees(shakeAngle), anchor: .bottom)
            .onChange(of: shakeTick) { _, tick in
                guard tick > 0, !motion.reduceMotion else { return }
                runCeremonyShake()
            }
        }
    }

    /// 通关仪式：树冠抖三抖（幅度远大于常驻摇摆的 ±1.6°，一眼区分）。
    private func runCeremonyShake() {
        let swings: [(Double, Double)] = [(2.6, 0.16), (-2.2, 0.16), (1.6, 0.15), (-1.0, 0.15), (0, 0.2)]
        Task { @MainActor in
            for (angle, duration) in swings {
                withAnimation(.easeInOut(duration: duration)) { shakeAngle = angle }
                try? await Task.sleep(for: .seconds(duration))
            }
            shakeAngle = 0
        }
    }
}

/// 星星物化成果实：总进度看得见、摸得着（数量 = 已得星，封顶到果位表）。
/// 新果实从同一侧长出来——数量变化即弹入，`appAnimation` 自己尊重动效档。
/// （internal：果位表与稳定性约束被 `ForestEventTests` 直接钉住。）
struct FruitLayer: View {
    let theme: ForestTheme
    let count: Int

    /// 果位表（相对画框中心；挂在**中层 + 前层**叶团的下缘；加果时按序取用）。
    /// ⚠️ 稳定位置：同 index 永远同位，重绘不跳动。
    /// ⚠️ 每个果位都要落在某个叶团轮廓的**内侧**留 ≥8pt —— 挂到沿外就悬空一颗。
    /// 轮廓表在 `CanopyLayout`（`TreeCrownArt.swift`）：改那张表之后，用
    /// `CanopyLayout.silhouetteBounds` 复核冠幅、再出离屏图肉眼确认；
    /// （`ForestEventTests` 钉住数量 / 边界 / 两两距离）。
    ///
    /// 2026-10-18 随树冠第 7 版重校准：冠心从帧心（150）上移到 102（+裙摆两圈），
    /// 旧表 16 个位置有 5 个垂到冠外 5–25pt。新表按「冠幅 0.94（外档）/ 0.72
    /// （内档）」沿各方向重算 —— 注意偏移是相对**帧心**不是冠心，两者相差 48pt，
    /// 换算差一个符号（新冠心上移 → 同一顶果位的帧系 y 要 **减** 48）。
    nonisolated static let placements: [(Double, Double)] = [
        // 外档：绕下缘一圈（从右肩起，顺时针扫到左肩）
        (155, 9), (132, 63), (87, 102), (30, 121), (-30, 121), (-87, 102), (-132, 63), (-155, 9),
        // 内档：错半步收进来一档（果实有前有后，不成一个正圆）
        (112, 17), (85, 54), (45, 76), (0, 84), (-45, 76), (-85, 54), (-112, 17), (-120, -27),
    ]

    var body: some View {
        ForEach(0..<Self.placements.count, id: \.self) { index in
            if index < count {
                fruit(at: index)
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }
        }
        .appAnimation(.reveal, value: count)
    }

    /// 一颗果实：金黄果身 + 高光 + 一片小叶（金色沿用花蕊的既有色，不引入新色板）。
    private func fruit(at index: Int) -> some View {
        let p = Self.placements[index]
        return ZStack {
            Circle().fill(Color(hex: 0xF7B32B)).frame(width: 9, height: 9)
            Circle().fill(Color.white.opacity(0.35)).frame(width: 3, height: 3)
                .offset(x: -1.5, y: -1.5)
            Ellipse()
                .fill(theme.foliageDeep)
                .frame(width: 5, height: 2.6)
                .offset(x: 2.4, y: -5)
                .rotationEffect(.degrees(-28))
        }
        .offset(x: p.0, y: p.1)
    }
}


struct BranchShape: Shape {
    let from: CGPoint
    let to: CGPoint
    let side: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(
            to: to,
            control: CGPoint(x: from.x + side * abs(to.x - from.x) * 0.45, y: from.y - 34)
        )
        return path
    }
}

struct Leaves: View {
    let theme: ForestTheme

    private static let placements: [(Double, Double, Double)] = [
        (0.12, 0.44, -18), (0.20, 0.62, 22), (0.30, 0.38, -12),
        (0.42, 0.70, 16), (0.55, 0.50, -24), (0.68, 0.64, 14),
        (0.78, 0.42, -16), (0.88, 0.58, 20),
    ]

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<Self.placements.count, id: \.self) { index in
                let item = Self.placements[index]
                LeafShape()
                    .fill(theme.foliage.opacity(0.85))
                    .frame(width: 26, height: 14)
                    .rotationEffect(.degrees(item.2))
                    .position(
                        x: proxy.size.width / 2 + CGFloat(item.0 - 0.5) * proxy.size.width * 0.22,
                        y: proxy.size.height * item.1
                    )
            }
        }
    }
}

struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
