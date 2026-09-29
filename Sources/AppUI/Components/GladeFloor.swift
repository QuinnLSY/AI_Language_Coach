import SwiftUI

/// 林间空地的生长表（批次四 · B，纯函数、可单测）。
///
/// **学员每开口一次，林子里就多一株**。聊着聊着大树下长出一片小花小草 ——
/// 「你说过的每句话都在这片林子里留下了东西」。
///
/// 2026-09-29 用户口径调整：植物**长在成长之树的大树下草坪上**（林间地面带），
/// 不再画在中间栏聊天区（悬浮在对话上挡视线，看着像贴图而不是种出来的）。
///
/// 为什么是纯函数：同一轮次数必须长出**同一片**空地。视图会随滚动、换页重绘，
/// 随机一抖就是「花在跳位置」，而确定性伪随机（按 index 取）保证重绘不动。
public enum GladeGrowth {

    /// 空地上会长什么。
    public enum Kind: String, CaseIterable, Sendable, Equatable {
        case flowerWarm
        case flowerPale
        case mushroom
        case fern
        case clover
    }

    /// 一株植物。
    public struct Plant: Equatable, Identifiable, Sendable {
        /// 生长序号（同时当 id：位置与种类都只由它决定）。
        public let index: Int
        public let kind: Kind
        /// 横向位置（0...1，相对空地宽度）。
        public let x: CGFloat
        public let scale: CGFloat

        public var id: Int { index }

        public init(index: Int, kind: Kind, x: CGFloat, scale: CGFloat) {
            self.index = index
            self.kind = kind
            self.x = x
            self.scale = scale
        }

        /// 轻微的倒向（-7°…7°，度）：种下去的植株总有点朝向，
        /// 直挺挺立在草坪上像贴图（2026-09-29 用户口径「要有轻微的方向」）。
        /// 由 index 决定 —— 与位置同一套确定性伪随机，重绘不动。
        public var tiltDegrees: CGFloat {
            (pseudo(index, 17) - 0.5) * 14
        }
    }

    /// 空地上最多几株。
    ///
    /// 12 是「看得出一片」与「糊成一片」的分界：再多就分不出是花还是噪点了。
    public static let maxPlants = 12

    /// 稳定伪随机（同 index/salt 永远同值）——与地面草坡同一套做法。
    static func pseudo(_ index: Int, _ salt: Int) -> CGFloat {
        let x = sin(Double(index * 137 + salt * 61)) * 43758.5453
        return CGFloat(x - floor(x))
    }

    /// 第 `rounds` 轮之后空地上长着什么（超出上限就停在上限）。
    ///
    /// ⚠️ 只增不减：换会话 / 删消息会让轮次回落，那时画面理应变回稀疏，
    /// 所以这里直接按当前轮次重算，不做「记住最大值」——那会让空地和对话对不上。
    public static func plants(rounds: Int) -> [Plant] {
        let count = min(max(rounds, 0), maxPlants)
        guard count > 0 else { return [] }
        let kinds = Kind.allCases
        return (0..<count).map { i in
            let kind = kinds[Int(pseudo(i, 3) * CGFloat(kinds.count)) % kinds.count]
            // 两端各留一点边，别贴着气泡边缘长出来
            let x = 0.07 + pseudo(i, 7) * 0.86
            let scale = 0.78 + pseudo(i, 13) * 0.42
            return Plant(index: i, kind: kind, x: x, scale: scale)
        }
    }
}

/// 林间地面带上「对话种下的植物」：大树下草坪上的一株株小花小草。
///
/// 三件「种出来了」的视觉痕迹（2026-09-29 用户口径：**有栽种扎根的痕迹，
/// 不是像贴图一样悬浮在图层上**）：
/// 1. 根部一圈**土丘**（比草坪深一档的颜色，椭圆压在茎底）；
/// 2. 植株带**轻微倒向**（`Plant.tiltDegrees`，由生长序号决定）；
/// 3. 植株脚下一点**落地阴影**（与草坡上其他物件同一套 theme.shadow）。
///
/// 动效预算：没有循环动画；只在「新长出一株」的那一刻有一次入场
/// （走动效 token，减动态效果打开时整段失效）。
struct ForestFloraBed: View {

    let theme: ForestTheme
    /// 学员开口的次数（= 草坪上长了几株）。
    let rounds: Int
    /// 草坪表面线（**宿主坐标系**：与地面带的草坡 / 灌木 / 小花同一根线，
    /// 植株的土丘就压在这条线上 —— 各算各的迟早出现「花浮在半空」）。
    let groundLine: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let plants = GladeGrowth.plants(rounds: rounds)
            ZStack(alignment: .bottomLeading) {
                ForEach(plants) { plant in
                    sprout(plant)
                        .position(
                            x: 16 + plant.x * max(0, proxy.size.width - 32),
                            y: groundLine - 2
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // 新长一株时的入场（同一份 token；「减弱动态效果」下自动静止）
            .appAnimation(.reveal, value: plants.count)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func sprout(_ plant: GladeGrowth.Plant) -> some View {
        let body = floraBody(plant)
        VStack(spacing: 0) {
            body
                .rotationEffect(.degrees(plant.tiltDegrees), anchor: .bottom)
            // 土丘：比草坪深一档的椭圆压在茎底 —— 「这里是种下去的」。
            Ellipse()
                .fill(theme.hillNear.opacity(0.55))
                .frame(width: 14 * plant.scale + 6, height: 4.5 * plant.scale + 1.5)
                .overlay(
                    Ellipse()
                        .fill(theme.shadow.opacity(0.5))
                        .frame(width: 9 * plant.scale + 4, height: 2.6 * plant.scale + 0.8)
                        .offset(y: -0.8)
                )
        }
        // 底部锚点落在草坪线上：.position 给的是视图中心，先把土丘一半的高度抬回来。
        .offset(y: -(4.5 * plant.scale + 1.5) / 2)
        .shadow(color: theme.shadow, radius: 2.4, x: 0, y: 1.6)
    }

    /// 植株本体（种类画法与原 GladeFloor 一致，整体放大一档：
    /// 林间地面带 150pt 高，还按聊天区 46pt 那个小身量长就看不见了）。
    @ViewBuilder
    private func floraBody(_ plant: GladeGrowth.Plant) -> some View {
        let scale = plant.scale * 1.7
        switch plant.kind {
        case .flowerWarm, .flowerPale:
            flower(pale: plant.kind == .flowerPale, scale: scale)
        case .mushroom:
            mushroom(scale: scale)
        case .fern:
            fern(scale: scale)
        case .clover:
            clover(scale: scale)
        }
    }

    private func flower(pale: Bool, scale: CGFloat) -> some View {
        let petal = pale ? theme.star : theme.accentAlt
        return ZStack {
            Capsule()
                .fill(theme.foliageDeep)
                .frame(width: 1.6, height: 9)
                .offset(y: 5)
            ForEach(0..<5, id: \.self) { petalIndex in
                Ellipse()
                    .fill(petal)
                    .frame(width: 4.2, height: 2.8)
                    .offset(y: -3)
                    .rotationEffect(.degrees(Double(petalIndex) * 72))
            }
            Circle()
                .fill(theme.glow)
                .frame(width: 3.4, height: 3.4)
        }
        .scaleEffect(scale)
    }

    private func mushroom(scale: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(theme.star)
                .frame(width: 3.2, height: 6)
                .offset(y: 4)
            HalfDome()
                .fill(theme.accentAlt)
                .frame(width: 9, height: 5.5)
                .offset(y: -0.5)
        }
        .scaleEffect(scale)
    }

    private func fern(scale: CGFloat) -> some View {
        ZStack {
            ForEach(-1...1, id: \.self) { side in
                Ellipse()
                    .fill(theme.foliage)
                    .frame(width: 4.5, height: 9)
                    .rotationEffect(.degrees(Double(side) * 26))
                    .offset(y: -2)
            }
        }
        .scaleEffect(scale)
    }

    private func clover(scale: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(theme.foliageDeep)
                .frame(width: 1.4, height: 7)
                .offset(y: 4)
            ForEach(0..<3, id: \.self) { leaf in
                Circle()
                    .fill(theme.foliage)
                    .frame(width: 4.2, height: 4.2)
                    .offset(x: CGFloat(leaf - 1) * 3.2, y: -2.4 - abs(CGFloat(leaf - 1)) * 0.6)
            }
        }
        .scaleEffect(scale)
    }
}

/// 蘑菇伞（上半个椭圆）。
private struct HalfDome: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6)
        )
        path.closeSubpath()
        return path
    }
}
