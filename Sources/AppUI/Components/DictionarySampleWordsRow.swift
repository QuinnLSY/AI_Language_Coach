import SwiftUI

/// 一排「铺满整行」的胶囊：能放几个放几个，再把剩下的宽度平摊进间距里。
///
/// 为什么不用 `FlowRow`（那个是换行的流水布局，`sizeThatFits` 只返回最宽一项的宽度）：
/// 用户口径是「推荐词要**铺满一行**」—— 流水布局永远在左边挤成一小撮，右边留一大片空白。
/// 这里改成「按可用宽度决定放几个 + 把富余宽度摊进间距」，整行两端就都贴住了。
///
/// 放不下的子视图**不参与布局**（SwiftUI 允许只摆放一部分）—— 调用方因此可以一次给足候选词，
/// 由宽度说话：宽窗口多显示几个，窄窗口少显示几个。
struct JustifiedRow: Layout {

    /// 胶囊之间的基础间距。
    var spacing: CGFloat = 8
    /// 摊开后的间距上限：词少的时候不至于被摊得七零八落。
    var maxSpacing: CGFloat = 34

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let available = proposal.width ?? 0
        let count = self.count(sizes: sizes, available: available)
        let natural = sizes.prefix(count).reduce(CGFloat.zero) { $0 + $1.width }
            + spacing * CGFloat(max(count - 1, 0))
        // 宽度有界时**占满**（富余的宽度由 `placeSubviews` 摊进间距），无界时按自然宽度。
        return CGSize(
            width: available.isFinite && available > 0 ? available : natural,
            height: sizes.prefix(max(count, 1)).map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let count = self.count(sizes: sizes, available: bounds.width)
        guard count > 0 else { return }
        let used = sizes.prefix(count).reduce(CGFloat.zero) { $0 + $1.width }
        // ⚠️ 余量必须**先扣掉基础间距要占的位置**（`spacing * (count-1)`），
        //    否则摊到每道缝里的是「余量 + 基础间距」，整排会比可用宽度宽出
        //    `(count-1) * spacing` —— 实测就是右侧最后一颗被卡片切掉。
        let base = spacing * CGFloat(max(count - 1, 0))
        let leftover = max(bounds.width - used - base, 0)
        let gap: CGFloat = count > 1
            ? min(spacing + leftover / CGFloat(count - 1), maxSpacing)
            : 0
        var x = bounds.minX
        for index in 0..<count {
            let size = sizes[index]
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.minY + (bounds.height - size.height) / 2),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + gap
        }
        // ⚠️ 放不下的**必须显式摆掉**：`Layout` 允许只摆放一部分，但没被摆放的子视图
        //    会被 SwiftUI 按默认位置**堆在容器正中**（14 颗只摆 7 颗时，另外 7 颗就在
        //    正中间叠成一团黑，实机与离屏渲染都复现）。
        //    摆到容器左边**一整排宽再加一截**的位置：既给了它们一个 0 尺寸的提箱
        //    （不画内容），又落在窗口之外 —— 留在近处（哪怕只偏几个 pt）会露出一小截
        //    被压成省略号「…」的深色墨点。
        for index in count..<sizes.count {
            subviews[index].place(
                at: CGPoint(x: bounds.minX - bounds.width - 100, y: bounds.minY),
                anchor: .topLeading,
                proposal: .zero
            )
        }
    }

    /// 一行里放得下几个。宽度无界（还没量出来）时全放；一个都放不下时也给 1 个 ——
    /// 宁可让最前面那颗稍微溢出，也不要整行空白。
    private func count(sizes: [CGSize], available: CGFloat) -> Int {
        guard !sizes.isEmpty else { return 0 }
        guard available.isFinite, available > 0 else { return sizes.count }
        var used: CGFloat = 0
        var count = 0
        for size in sizes {
            let next = used + (count == 0 ? 0 : spacing) + size.width
            if next > available, count > 0 { break }
            used = next
            count += 1
        }
        return count
    }
}

/// 空查询页的「试试这些词」：一排铺满整行的胶囊，**每 10 秒换一批**（整排错落翻下去 → 换词 → 翻上来）。
///
/// 三件事是用户口径里的硬要求：
/// ① 铺满一行（`JustifiedRow`）；
/// ② 每 10 秒随机轮换（词池由 `AppState.dictionarySamplePool` 随机抽好，这里只按序取，不重复）；
/// ③ 换的时候要**看得出来在换** —— 直接改文字会显得「页面自己在抖」，所以做成一排错落的翻牌。
struct DictionarySampleWordsRow: View {

    /// 轮换词池（随机、去重由上游保证）。
    let words: [String]
    let onPick: (String) -> Void

    /// 一屏最多画几颗：具体画几颗由布局按可用宽度定，这里只是「给足候选」。
    private static let batch = 14
    /// 轮换间隔（秒）。
    private static let interval: Double = 10
    /// 每颗胶囊之间的错落（秒）：第 index 颗晚 `index * stagger` 出发。
    private static let stagger: Double = 0.035
    private static let flipDuration: Double = 0.26
    /// 整排翻下去要多久（等它全部淡出，再换词，才不会看到「文字当场跳变」）。
    private static var swapDelay: Double {
        flipDuration + stagger * Double(batch - 1)
    }

    @State private var shown: [String] = []
    @State private var cursor = 0
    /// 轮换相位：true = 这一排正在翻下去（透明 + 上移）。
    @State private var flipped = false
    /// 鼠标正停在哪一颗上（用户口径：**悬停要有边缘高亮表示选中**）。
    @State private var hoveredWord: String?

    var body: some View {
        JustifiedRow(spacing: 8) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, word in
                chip(word)
                    .opacity(flipped ? 0 : 1)
                    .offset(y: flipped ? -9 : 0)
                    .animation(
                        .easeInOut(duration: Self.flipDuration).delay(Double(index) * Self.stagger),
                        value: flipped
                    )
            }
        }
        // 词池就绪（或换了一批）→ 先把第一排铺上。
        .task(id: words) {
            guard shown.isEmpty, !words.isEmpty else { return }
            shown = take(Self.batch)
        }
        .task { await rotateLoop() }
    }

    private func chip(_ word: String) -> some View {
        let hovered = hoveredWord == word
        return SampleWordChip(word: word, hovered: hovered) { onPick(word) }
            .onHover { inside in
                // 只在真的换了颗时改状态：鼠标在**同一颗**上反复进出（子视图重绘会触发）
                // 不该把高亮抖掉。
                if inside {
                    hoveredWord = word
                } else if hoveredWord == word {
                    hoveredWord = nil
                }
            }
            .appAnimation(.press, value: hovered)
            .help("查「\(word)」")
    }

    /// 每 10 秒换一批。页面不在了（`task` 被取消）就自然停下。
    private func rotateLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.interval))
            guard !Task.isCancelled else { return }
            await rotate()
        }
    }

    private func rotate() async {
        guard !words.isEmpty else { return }
        withAnimation(.easeInOut(duration: Self.flipDuration)) { flipped = true }
        try? await Task.sleep(for: .seconds(Self.swapDelay))
        guard !Task.isCancelled else {
            flipped = false
            return
        }
        shown = take(Self.batch)
        withAnimation(.easeInOut(duration: Self.flipDuration)) { flipped = false }
    }

    /// 从词池里按序取一批，**切到尾巴就绕回开头接着取**。一批之内不重样，
    /// 整池走完才会重复 —— 比每轮各自随机更不容易出现「刚见过又来了」。
    ///
    /// ⚠️ 一定要**绕回**、不能取到尾巴就少给几个：这批词是要铺满整行的
    /// （`JustifiedRow` 按可用宽度决定放几个），少给几个就会让整行在右侧缺一块。
    private func take(_ count: Int) -> [String] {
        guard !words.isEmpty else { return [] }
        let size = min(count, words.count)
        let batch = (0..<size).map { words[(cursor + $0) % words.count] }
        cursor = (cursor + size) % words.count
        return batch
    }
}

/// 一颗推荐词胶囊。
///
/// `hovered` **由外面传进来**（和 `DictionaryBookCard(isHovered:)` 同一套路）：
/// 悬停态可注入，离屏渲染才验得了「边缘高亮」这一条 —— 本机没法可靠地给 SwiftUI 合成悬停。
///
/// 高亮只动两样：**描边**与**底色浓度**。两样都用 `theme.accent`
/// （主题令牌里 `accent` 正是给文字/图标/描边/淡底用的，不能拿来当实心底）。
/// 不去改尺寸（放大 / 加外发光）—— 这排胶囊是按可用宽度铺满的，
/// 动尺寸会让相邻两颗在视觉上贴到一起。
struct SampleWordChip: View {

    @Environment(\.forestTheme) private var theme

    let word: String
    let hovered: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(word)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.accent.opacity(hovered ? 0.22 : 0.12)))
                .overlay(
                    // 描边一直画着、只改透明度：避免出现「多出一圈」的布局抖动。
                    Capsule().strokeBorder(
                        theme.accent.opacity(hovered ? 0.9 : 0), lineWidth: 1.5
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.appPressable)
        .help("查「\(word)」")
    }
}
