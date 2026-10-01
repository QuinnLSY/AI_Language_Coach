import SwiftUI

// MARK: - 骨架屏（2026-09-27 第三批 #359）

/// 骨架条：内容没到时先摆出来的一根**固定尺寸**的纯色圆角条。
///
/// 为什么不用转圈：转圈只说「在等」，骨架屏同时说了「等到了会长什么样、
/// 大概多大一块」—— 长文 / 每日句子这类等待（5–20s 一次真实模型调用），
/// 知道版式比知道「在转」安心得多。
///
/// 两条纪律：
/// 1. **不用真数据占位**：骨架块是固定宽高的纯色条，绝不把假文本画进去
///    （假文本会被当成真内容读）。
/// 2. **布局必须与动效档位无关**：shimmer 只动 overlay，「减弱动态效果」下
///    骨架**静止但同版式**（渲染回归钉这条：两种档位下高度必须一字不差）。
struct SkeletonBar: View {

    @Environment(\.forestTheme) private var theme

    /// 条宽；`nil` = 占满可用宽度（段落里的长句）。
    let width: CGFloat?
    var height: CGFloat = 10

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        shape
            .fill(theme.hover)
            .modifier(ShimmerEffect(cornerRadius: height / 2))
            .frame(width: width, height: height)
    }
}

// MARK: - Shimmer

/// 掠过骨架条的一道高光。**只做 overlay**：不参与布局，开不动效只是好看，
/// 开「减弱动态效果」就整层不画（静止的骨架条本身已经把「在加载」说清楚了）。
struct ShimmerEffect: ViewModifier {

    @Environment(\.appMotion) private var motion
    @Environment(\.forestTheme) private var theme
    @State private var phase: CGFloat = -1.4

    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                // 只判空不绑定：绑定的值在 body 里没地方用（动画在 onAppear 起），
                // `if let` 不绑定会被 Swift 6 判成 no-usage 警告。
                if motion.loopAnimation(.linear(duration: 1.6)) != nil {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, theme.primaryText.opacity(0.10), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.7)
                        .offset(x: phase * geo.size.width)
                        .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .onAppear {
                guard let sweep = motion.loopAnimation(.linear(duration: 1.6)) else { return }
                phase = -1.4
                withAnimation(sweep.repeatForever(autoreverses: false)) { phase = 1.4 }
            }
    }
}

// MARK: - 阅读页骨架

/// 阅读页「老师正在写今天的短文」的骨架版式：标题 + 三段正文 + 一行选项块。
///
/// 块的宽度是**写死的节奏**（长短交替），不是随机数 —— 离屏渲染回归需要确定布局，
/// 而且每次刷新都在变的骨架比没有骨架更让人不安。
struct SkeletonReadingCard: View {

    @Environment(\.forestTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBar(width: 168, height: 14)
            ForEach(0..<3, id: \.self) { paragraph in
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBar(width: nil, height: 9)
                    SkeletonBar(width: nil, height: 9)
                    SkeletonBar(width: paragraphWidths[paragraph], height: 9)
                }
            }
            HStack(spacing: 10) {
                SkeletonBar(width: 132, height: 24)
                SkeletonBar(width: 158, height: 24)
            }
            .appPadding(.top, 2)
        }
        .appPadding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
        )
        // 读屏直接读事实，别把一根根骨架条念一遍。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("老师正在写今天的短文")
    }

    /// 三段正文各自末行的宽度节奏（短 / 长 / 中）。
    private var paragraphWidths: [CGFloat?] { [nil, 220, 300] }
}

// MARK: - 跟读页骨架

/// 跟读页「正在生成今天的句子」的骨架版式：小标题 + 两行句子 + 一排操作胶囊。
struct SkeletonShadowingCard: View {

    @Environment(\.forestTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBar(width: 110, height: 11)
            SkeletonBar(width: nil, height: 13)
            SkeletonBar(width: 260, height: 13)
            HStack(spacing: 10) {
                SkeletonBar(width: 92, height: 26)
                SkeletonBar(width: 92, height: 26)
                SkeletonBar(width: 92, height: 26)
            }
            .appPadding(.top, 2)
        }
        .appPadding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在生成今天的跟读句子")
    }
}
