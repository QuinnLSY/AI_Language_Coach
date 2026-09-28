import SwiftUI

/// 林间空地的生长表（批次四 · B，纯函数、可单测）。
///
/// 中间栏（对话区）脚下那片空地：**学员每开口一次，地上就多一株**。
/// 聊着聊着身后长出一片小花小草 —— 「你说过的每句话都在这片林子里留下了东西」。
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

/// 中间栏脚下那片空地。
///
/// 动效预算（设计拍板：全场最低，比侧栏连胜飞鸟还低）：
/// - **没有**循环动画（无 `repeatForever`、无常驻定时器）—— 阅读区不许有东西一直在动；
/// - 只在「新长出一株」的那一刻有一次入场（走动效 token，减动态效果打开时整段失效）。
public struct GladeFloor: View {

    let theme: ForestTheme
    /// 学员开口的次数（= 空地上长了几株）。
    let rounds: Int
    /// 空地高度（植物贴着底边往上长）。
    var height: CGFloat = 46

    public init(theme: ForestTheme, rounds: Int, height: CGFloat = 46) {
        self.theme = theme
        self.rounds = rounds
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            let plants = GladeGrowth.plants(rounds: rounds)
            ZStack(alignment: .bottomLeading) {
                ForEach(plants) { plant in
                    sprout(plant)
                        // 底边往上长：y 用空地底部减去半个身位，别浮在半空
                        .position(x: plant.x * proxy.size.width,
                                  y: proxy.size.height - 8 * plant.scale)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // 新长一株时的入场（同一份 token；「减弱动态效果」下自动静止）
            .appAnimation(.reveal, value: plants.count)
        }
        .frame(height: height)
        // 极淡：它是背景，不是内容
        .opacity(0.62)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func sprout(_ plant: GladeGrowth.Plant) -> some View {
        switch plant.kind {
        case .flowerWarm, .flowerPale:
            flower(pale: plant.kind == .flowerPale, scale: plant.scale)
        case .mushroom:
            mushroom(scale: plant.scale)
        case .fern:
            fern(scale: plant.scale)
        case .clover:
            clover(scale: plant.scale)
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
