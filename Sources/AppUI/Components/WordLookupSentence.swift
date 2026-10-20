import AIDomain
import AppKit
import SwiftUI

/// 划词要用到的一组回调（页面从 `AppState` 递过来，组件本身不认识 `AppState`）。
///
/// 收成一个结构体而不是六个参数：查词页、跟读页、练习页三处都要传同一套东西，
/// 每加一个动作（比如以后加「收藏到自定义词单」）就要改三处签名，迟早漏一处。
public struct WordLookupContext {
    public var card: (String) -> WordLookupCard?
    public var onProbe: (String) -> Void
    public var onDismiss: () -> Void
    public var onSpeak: (String) -> Void
    public var onStopSpeak: () -> Void
    public var isSpeaking: (String) -> Bool
    public var onOpenDictionary: (String) -> Void
    public var onAddToReview: (String) -> Void
    /// 查不到时在卡片上直接重查（不必重新划词 / 进词典页）。
    public var onRetryLookup: (String) -> Void
    /// 「去词典查」当前绑的键（#619；空 = 不显示那行提示）。
    public var openDictionaryHint: String
    /// 「加入复习」当前绑的键（#619；空 = 不显示那行提示）。
    public var addReviewHint: String

    public init(
        card: @escaping (String) -> WordLookupCard?,
        onProbe: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void = {},
        onSpeak: @escaping (String) -> Void = { _ in },
        onStopSpeak: @escaping () -> Void = {},
        isSpeaking: @escaping (String) -> Bool = { _ in false },
        onOpenDictionary: @escaping (String) -> Void = { _ in },
        onAddToReview: @escaping (String) -> Void = { _ in },
        onRetryLookup: @escaping (String) -> Void = { _ in },
        openDictionaryHint: String = "",
        addReviewHint: String = ""
    ) {
        self.card = card
        self.onProbe = onProbe
        self.onDismiss = onDismiss
        self.onSpeak = onSpeak
        self.onStopSpeak = onStopSpeak
        self.isSpeaking = isSpeaking
        self.onOpenDictionary = onOpenDictionary
        self.onAddToReview = onAddToReview
        self.onRetryLookup = onRetryLookup
        self.openDictionaryHint = openDictionaryHint
        self.addReviewHint = addReviewHint
    }
}

/// 「可划词的英文句子」：把 `WordLookupText`（AppKit 文本视图）与划词气泡接在一起。
///
/// 页面上凡是英文成句的地方（查词的固定搭配与例句、跟读的参考句、练习的纠错句与气泡正文）
/// 都用它，因此气泡的取数、摆位、收起规则只有这一份实现。
public struct WordLookupSentence: View {

    @Environment(\.forestTheme) private var theme

    /// 三选一的文本来源。**样式要等 `body` 才算得出来**：
    /// 默认前景色是主题色，而 `@Environment` 在 `init` 里读不到 —— 在 init 里
    /// 写死一个颜色等于把深浅色适配丢掉。
    private enum Source {
        case plain(String, fontSize: CGFloat, weight: NSFont.Weight, italic: Bool, color: Color?, lineSpacing: CGFloat)
        case markdownInline(
            String, fontSize: CGFloat, weight: NSFont.Weight, color: Color, lineSpacing: CGFloat
        )
        case attributed(NSAttributedString)
    }

    private let source: Source
    /// 取气泡内容（由页面从 `AppState` 里递过来；返回 nil = 这次还没结果，气泡不出现）。
    private let card: (String) -> WordLookupCard?
    private let onProbe: (String) -> Void
    private let onDismiss: () -> Void
    private let onSpeak: (String) -> Void
    private let onStopSpeak: () -> Void
    private let isSpeaking: (String) -> Bool
    private let onOpenDictionary: (String) -> Void
    private let onAddToReview: (String) -> Void
    private let onRetryLookup: (String) -> Void
    /// 「去词典查 / 加入复习」当前绑的键（#619，气泡底部提示行读它）。
    private let openDictionaryHint: String
    private let addReviewHint: String
    /// 悬停要不要出气泡（阅读正文关掉，只认拖选 —— #233）。
    private let isHoverLookupEnabled: Bool
    /// 光标形状（I 型 / 箭头），语义见 `WordLookupTextView.showsIBeamCursor`。
    private let showsIBeamCursor: Bool

    @State private var sentenceID = UUID()
    @State private var probe: WordLookupProbe?
    /// **浮层模式下要记住的最后一次探测**：鼠标已经挪到气泡上时句子的探测早就结束了，
    /// 但浮层还得知道把气泡摆在哪 —— 忘了它，气泡会在宽限期里失去位置。
    @State private var lastProbe: WordLookupProbe?
    @State private var bubbleSize: CGSize = .zero
    /// 光标是不是在气泡上（决定「移出句子」时收不收起）。
    @State private var isPointerOnBubble = false
    @State private var dismissal: Task<Void, Never>?

    @Environment(\.wordLookupPresenter) private var presenter

    /// 从句子移出到气泡之间的**宽限期**。
    ///
    /// ⚠️ 没有它这个气泡就没法用：气泡贴在词的旁边（间距 6pt），鼠标从词挪到气泡按钮上的
    /// 途中必然离开句子 → 立刻收起 → 按钮永远点不到。宽限期刚好覆盖这段移动。
    private static let dismissalGraceSeconds: Double = 0.35

    /// 纯文本句子（例句 / 固定搭配 / 跟读参考句）。
    public init(
        text: String,
        fontSize: CGFloat = 12,
        weight: NSFont.Weight = .regular,
        italic: Bool = false,
        color: Color? = nil,
        lineSpacing: CGFloat = 2,
        context: WordLookupContext,
        hoverLookupEnabled: Bool = true,
        showsIBeamCursor: Bool = true
    ) {
        self.init(
            source: .plain(
                text, fontSize: fontSize, weight: weight, italic: italic,
                color: color, lineSpacing: lineSpacing
            ),
            context: context,
            hoverLookupEnabled: hoverLookupEnabled,
            showsIBeamCursor: showsIBeamCursor
        )
    }

    /// 行内 markdown 句子（对话气泡正文：保留粗体 / 斜体 / 行内代码）。
    public init(
        markdownInline: String,
        fontSize: CGFloat = 14,
        weight: NSFont.Weight = .regular,
        color: Color,
        lineSpacing: CGFloat = 3,
        context: WordLookupContext
    ) {
        self.init(
            source: .markdownInline(
                markdownInline, fontSize: fontSize, weight: weight,
                color: color, lineSpacing: lineSpacing
            ),
            context: context
        )
    }

    /// 已经是富文本（不再转换）。
    public init(
        attributed: NSAttributedString,
        context: WordLookupContext,
        hoverLookupEnabled: Bool = true,
        showsIBeamCursor: Bool = true
    ) {
        self.init(
            source: .attributed(attributed),
            context: context,
            hoverLookupEnabled: hoverLookupEnabled,
            showsIBeamCursor: showsIBeamCursor
        )
    }

    private init(
        source: Source,
        context: WordLookupContext,
        hoverLookupEnabled: Bool = true,
        showsIBeamCursor: Bool = true
    ) {
        self.source = source
        self.card = context.card
        self.onProbe = context.onProbe
        self.onDismiss = context.onDismiss
        self.onSpeak = context.onSpeak
        self.onStopSpeak = context.onStopSpeak
        self.isSpeaking = context.isSpeaking
        self.onOpenDictionary = context.onOpenDictionary
        self.onAddToReview = context.onAddToReview
        self.onRetryLookup = context.onRetryLookup
        self.openDictionaryHint = context.openDictionaryHint
        self.addReviewHint = context.addReviewHint
        self.isHoverLookupEnabled = hoverLookupEnabled
        self.showsIBeamCursor = showsIBeamCursor
    }

    public var body: some View {
        // ⚠️ **这一句必须留在 body 里**（2026-09-21 阅读页划词报障的根因）。
        //
        // `anchorPreference` 的 transform 要到**布局期**才跑，而布局期不登记观察依赖 ——
        // 卡是异步取回来的（问本地词库 / 模型都要等），探测那一刻 `presenter.request`
        // 还是 nil，于是那次算出来的锚点是 nil；等卡真的到了，**没有任何东西会让这一句
        // 重算锚点**，浮层手上只有一个陈旧的 nil，气泡拿不到位置就永远不出现。
        // 实测症状：第一句划词「探测上报了、卡也回来了，锚点历史里却只有 nil」；
        // 用户看到的是「划第一个词不翻译，划第二个词才翻译」。
        //
        // 在 body 里读一次、再把值**捕获进** transform：body 一重算，锚点必然跟着重算。
        let bubbleOwner = presenter?.request?.sentenceID
        return WordLookupText(
            attributed: resolved(),
            onProbe: { newProbe in
                handle(newProbe)
            },
            isHoverLookupEnabled: isHoverLookupEnabled,
            showsIBeamCursor: showsIBeamCursor
        )
        // ① 气泡由页面顶层的浮层画（默认路径）：浮层在被挂载的那一层之上，
        //    `ScrollView` 的裁剪与后面兄弟视图（下一条消息）都盖不到它。
        .anchorPreference(key: WordLookupAnchorKey.self, value: .bounds) { anchor in
            // ⚠️ **只有当前气泡的主人**才上报位置。
            //
            // 曾经写成「只要有 `lastProbe` 就上报」，并且靠 `onChange` 在失去所有权时清掉它 ——
            // 那条路有个致命的坑：划过下一个词时，气泡会先被撤下（卡还在异步取），
            // `request` 变成 nil，这次 onChange 就把 `lastProbe` 抹了；等卡取回来，
            // 位置已经没了 → 浮层无从摆位 → **气泡再也不出现**，用户必须先移出句子重划
            // （实测报障：悬停一词后再移到相邻词上不浮现）。改成按需判断之后，
            // 别的句子留着旧位置也无害（浮层的 reduce 取最后一个非 nil，非主人一律不抛）。
            guard bubbleOwner == sentenceID, let lastProbe else { return nil }
            return WordLookupAnchor(
                sentenceID: sentenceID, bounds: anchor,
                wordRect: lastProbe.rect, space: lastProbe.space
            )
        }
        // ② 没有浮层时（离屏渲染测试 / 没挂浮层的页面）退回原来的句内 overlay：
        //    overlay 不参与父视图尺寸计算，若放进 ZStack，一张 268pt 宽的气泡会把整行撑开。
        .overlay(alignment: .topLeading) { localBubble }
        // 抬起一层：卡片里后面的兄弟视图（下一个例句）不能盖住气泡。
        .zIndex(localBubbleSize > 0 ? 1 : 0)
    }

    /// 这套动作交给浮层（气泡上的按钮由浮层代理，位置由本句上报）。
    private var bubbleActions: WordLookupBubbleActions {
        WordLookupBubbleActions(
            onSpeak: onSpeak,
            onStopSpeak: onStopSpeak,
            isSpeaking: isSpeaking,
            onOpenDictionary: onOpenDictionary,
            onAddToReview: onAddToReview,
            onRetryLookup: onRetryLookup,
            onDismiss: onDismiss,
            openDictionaryHint: openDictionaryHint,
            addReviewHint: addReviewHint
        )
    }

    /// 句内兜底的气泡（**只有没挂浮层时才出现**）。
    @ViewBuilder
    private var localBubble: some View {
        if presenter == nil, let probe, let data = card(probe.text) {
            WordLookupBubble(
                card: data,
                isSpeaking: isSpeaking(data.text),
                onSpeak: { onSpeak(data.text) },
                onStopSpeak: onStopSpeak,
                onOpenDictionary: { onOpenDictionary(data.text) },
                onAddToReview: { onAddToReview(data.text) },
                onRetryLookup: { onRetryLookup(data.text) },
                dictionaryHint: openDictionaryHint,
                addReviewHint: addReviewHint
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
            // 报出「这块被气泡盖住了」：下面文本视图的悬停与整窗光标都要按它闭嘴
            // （SwiftUI 浮层不是 NSView，命中测试看不见它 —— 见 `WindowOverlayOcclusion`）。
            .windowOverlayOcclusion()
            .offset(x: placement(for: probe).x, y: placement(for: probe).y)
            .onHover { hovering in
                isPointerOnBubble = hovering
                // 光标离开气泡：宽限期后再收起（这段时间里若划到别的词，新探测会取消它）。
                if !hovering { scheduleDismissal() }
            }
            .transition(.opacity)
        }
    }

    /// 有/无气泡（用来决定要不要抬起一层；`ViewBuilder` 的结果不好直接问大小，故 preprocessing）。
    private var localBubbleSize: CGFloat {
        presenter == nil && probe != nil ? 1 : 0
    }

    /// 按主题色把文本真正做出来。
    private func resolved() -> NSAttributedString {
        switch source {
        case let .plain(text, fontSize, weight, italic, color, lineSpacing):
            return WordLookupTextBuilder.plain(
                text,
                fontSize: fontSize,
                weight: weight,
                italic: italic,
                color: NSColor(color ?? theme.primaryText.opacity(0.92)),
                lineSpacing: lineSpacing
            )
        case let .markdownInline(markdown, fontSize, weight, color, lineSpacing):
            return WordLookupTextBuilder.inlineMarkdown(
                markdown,
                fontSize: fontSize,
                weight: weight,
                color: NSColor(color),
                lineSpacing: lineSpacing
            )
        case let .attributed(attributed):
            return attributed
        }
    }

    // MARK: - 探测

    private func handle(_ newProbe: WordLookupProbe?) {
        // ⚠️ **卡片挡着时不认划词**（用户实测报障的「穿透」）。
        //
        // 文本视图那一侧已经按几何挡过一次（`WordLookupTextView.mouseMoved`），这里再挡一次
        // 是因为**不止悬停一条路**：拖选（`textViewDidChangeSelection`）同样会送探测上来，
        // 而拖选是跟着鼠标走的，鼠标完全可以拖到卡片底下。语义上也只有这一句最准：
        // 「鼠标在卡片上时，句子说话不算」。
        if let presenter {
            if let newProbe {
                guard !presenter.isPointerOnBubble else { return }
                lastProbe = newProbe
                probe = newProbe
                onProbe(newProbe.text)
                presenter.present(
                    sentenceID: sentenceID,
                    word: newProbe.text,
                    card: card(newProbe.text),
                    actions: bubbleActions
                )
            } else {
                probe = nil
                presenter.beginGrace(ownedBy: sentenceID)
            }
            return
        }
        // 句内兜底：维持原来的探测计时。
        if let newProbe {
            guard !isPointerOnBubble else { return }
            dismissal?.cancel()
            dismissal = nil
            probe = newProbe
            onProbe(newProbe.text)
            return
        }
        scheduleDismissal()
    }

    /// 收起要等一小会儿：鼠标正从词挪向气泡按钮时不能把气泡撤掉。
    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.dismissalGraceSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled, !isPointerOnBubble else { return }
            probe = nil
            bubbleSize = .zero
            onDismiss()
        }
    }

    /// 气泡摆位（纯函数在 `WordBubblePlacement` 里，这里只把参数凑齐）。
    private func placement(for probe: WordLookupProbe) -> CGPoint {
        let size = bubbleSize == .zero
            ? CGSize(width: WordLookupBubble.maxWidth, height: 84)
            : bubbleSize
        return WordBubblePlacement.origin(anchor: probe.rect, bubble: size, space: probe.space)
    }
}

/// 便捷包装：**有划词上下文就用可划词的文本，没有就退回普通 `Text`**。
///
/// 离屏渲染与单测里常常没有 `AppState`（也就没有上下文），这条路必须还在，
/// 否则所有只关心排版的既有测试都会被拖进划词链路。
struct LookupText: View {

    @Environment(\.forestTheme) private var theme

    let text: String
    var fontSize: CGFloat = 12
    var weight: NSFont.Weight = .regular
    var italic: Bool = false
    var color: Color?
    var lineSpacing: CGFloat = 2
    let context: WordLookupContext?
    /// 悬停不出气泡（阅读正文 = 只认拖选，#233）。
    var hoverLookupEnabled: Bool = true
    /// 光标形状（I 型 / 箭头），语义见 `WordLookupTextView.showsIBeamCursor`。
    var showsIBeamCursor: Bool = true

    var body: some View {
        if let context {
            WordLookupSentence(
                text: text,
                fontSize: fontSize,
                weight: weight,
                italic: italic,
                color: color,
                lineSpacing: lineSpacing,
                context: context,
                hoverLookupEnabled: hoverLookupEnabled,
                showsIBeamCursor: showsIBeamCursor
            )
        } else {
            Text(text)
                .appFont(fontSize, design: .rounded)
                .italic(italic)
                .foregroundStyle(color ?? theme.primaryText.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(lineSpacing)
        }
    }
}
