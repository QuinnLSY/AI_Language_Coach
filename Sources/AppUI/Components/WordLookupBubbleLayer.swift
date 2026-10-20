import AIDomain
import SwiftUI

// MARK: - 浮层锚点（preference）

/// 一句话要告诉浮层的全部信息。
///
/// ⚠️ `bounds` 是 `Anchor<CGRect>` 而不是裸 `CGRect`：preference 在**布局前**就传了上去，
/// 那时还不知道句子在界面上的确切位置。浮层在自己的 `GeometryReader` 里解算 `Anchor`，
/// 得到的是**当前这一刻**的矩形 —— 聊天区滚动、窗口拉伸都会跟着变，气泡因此是贴着文字走的。
struct WordLookupAnchor: Equatable {
    /// 这句话的身份：浮层靠它认出「这次位置是谁报的」。
    let sentenceID: UUID
    let bounds: Anchor<CGRect>
    /// 被划过的那块文字在句子里的位置（**句子自身坐标系**，左上原点）。
    let wordRect: CGRect
    /// 按窗口算出来的可视边界（同样是句子自身坐标系）。
    let space: WordLookupSpace
}

enum WordLookupAnchorKey: PreferenceKey {
    static var defaultValue: WordLookupAnchor? { nil }

    /// 同一时刻只有一句话在显示气泡，但多句话都可能把值传上来；
    /// 取最后一个非 nil 的，最终由浮层校验 `sentenceID` 说话。
    static func reduce(value: inout WordLookupAnchor?, nextValue: () -> WordLookupAnchor?) {
        if let next = nextValue() { value = next }
    }
}

// MARK: - 环境注入

private struct WordLookupPresenterKey: EnvironmentKey {
    static var defaultValue: WordLookupBubblePresenter? { nil }
}

extension EnvironmentValues {
    /// 有浮层时句子把气泡交给浮层画；没有（离屏渲染 / 没挂浮层的页面）就退回句内 overlay。
    var wordLookupPresenter: WordLookupBubblePresenter? {
        get { self[WordLookupPresenterKey.self] }
        set { self[WordLookupPresenterKey.self] = newValue }
    }
}

// MARK: - 气泡动作

/// 气泡上的按钮要做什么（由页面在探测时一并交给 presenter，避免浮层去认识 `AppState`）。
public struct WordLookupBubbleActions {
    public var onSpeak: (String) -> Void
    public var onStopSpeak: () -> Void
    public var isSpeaking: (String) -> Bool
    public var onOpenDictionary: (String) -> Void
    public var onAddToReview: (String) -> Void
    /// 查不到时在卡片上直接重查。
    public var onRetryLookup: (String) -> Void
    /// 气泡真正收起（AppState 清掉当前划词卡）。
    public var onDismiss: () -> Void
    /// 「去词典查 / 加入复习」当前绑的键（#619；空 = 气泡不显示那行提示）。
    public var openDictionaryHint: String
    public var addReviewHint: String

    public init(
        onSpeak: @escaping (String) -> Void = { _ in },
        onStopSpeak: @escaping () -> Void = {},
        isSpeaking: @escaping (String) -> Bool = { _ in false },
        onOpenDictionary: @escaping (String) -> Void = { _ in },
        onAddToReview: @escaping (String) -> Void = { _ in },
        onRetryLookup: @escaping (String) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {},
        openDictionaryHint: String = "",
        addReviewHint: String = ""
    ) {
        self.onSpeak = onSpeak
        self.onStopSpeak = onStopSpeak
        self.isSpeaking = isSpeaking
        self.onOpenDictionary = onOpenDictionary
        self.onAddToReview = onAddToReview
        self.onRetryLookup = onRetryLookup
        self.onDismiss = onDismiss
        self.openDictionaryHint = openDictionaryHint
        self.addReviewHint = addReviewHint
    }
}

// MARK: - Presenter

/// 划词气泡的浮层状态机（整份 App 一份，由 `AppState` 持有并注入环境）。
///
/// 收起规则原先住在 `WordLookupSentence` 里。气泡一旦挪出句子，**鼠标不在句子上也可能在气泡上**，
/// 所以「谁说了算」必须集中到一个地方：句子只负责报告「探测到了 / 探测结束了」，
/// 剩下的宽限期、要不要收、由谁拥有，全在这里判。
@MainActor
@Observable
public final class WordLookupBubblePresenter {

    public struct Request {
        public let sentenceID: UUID
        public var card: WordLookupCard
        public var actions: WordLookupBubbleActions
        public var isSpeaking: Bool
    }

    /// 当前要显示的气泡（nil = 没有）。
    public private(set) var request: Request?

    /// 最后一次「探测到了」的那句话：卡的内容是异步来的，来之前先记住归谁。
    private var activeSentenceID: UUID?
    private var activeWord: String?
    private var activeActions: WordLookupBubbleActions?

    /// 鼠标从词挪向气泡按钮要经过一段夜路：没有这道宽限期，气泡会在半途收起、按钮永远点不到。
    private static let graceSeconds: Double = 0.35

    private var graceTask: Task<Void, Never>?
    private var pointerOnBubble = false

    /// 鼠标是不是正停在气泡上 —— 这段时间里**卡片说话，句子闭嘴**
    /// （句子那侧据此丢弃探测，见 `WordLookupSentence.handle`）。
    public var isPointerOnBubble: Bool { pointerOnBubble }

    public init() {}

    /// 句子报告「探测到了」。
    ///
    /// `card` 允许为 nil：内容是异步取回来的（本地词库几乎瞬时，问模型要几秒），
    /// 探测的这一刻往往还没有结果，稍后由 `AppState` 用 `updateCard` 补上。
    public func present(
        sentenceID: UUID,
        word: String,
        card: WordLookupCard?,
        actions: WordLookupBubbleActions
    ) {
        // ⚠️ 鼠标停在气泡上时，句子说什么都不算：那是**卡片的**操作时间。
        // 少了这一条，卡片挡住的词会把卡片内容换掉（用户实测报障的「穿透」）。
        guard !pointerOnBubble else { return }
        graceTask?.cancel()
        graceTask = nil
        activeSentenceID = sentenceID
        activeWord = word
        activeActions = actions
        // 换到一句还没出结果的词：先收掉上一张卡，别让旧词的释义挂在新词上。
        updateRequest(card)
    }

    /// 卡的内容到了（或换了）→ 补给当前这句话。
    ///
    /// ⚠️ 必须校验是不是同一批词：`AppState` 的划词卡是**共享状态**（ mulit lookup 共用一个），
    /// 鼠标扫过一行会连着触发好几次探测，晚到的旧结果不能盖在新词上。
    public func updateCard(_ card: WordLookupCard?) {
        guard activeSentenceID != nil else { return }
        guard let card, let word = activeWord, card.matches(word) else {
            updateRequest(nil)
            return
        }
        updateRequest(card)
    }

    private func updateRequest(_ card: WordLookupCard?) {
        guard let sentenceID = activeSentenceID, let actions = activeActions, let card else {
            request = nil
            return
        }
        request = Request(
            sentenceID: sentenceID,
            card: card,
            actions: actions,
            isSpeaking: actions.isSpeaking(card.text)
        )
    }

    /// 句子报告「探测结束了」。真正收起要等宽限期（这段时间鼠标可能正挪向气泡）。
    public func beginGrace(ownedBy sentenceID: UUID) {
        guard request?.sentenceID == sentenceID, !pointerOnBubble else { return }
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.graceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // 类本身就是 `@MainActor`，这个 `Task` 继承它的隔离域 → 不需要 `await`
            // （写了反而触发「no 'async' operations occur within 'await' expression」）。
            self?.finishGrace(ownedBy: sentenceID)
        }
    }

    /// 鼠标进 / 出气泡本身（气泡脱离句子后，这是唯一还能挽留它的信号）。
    public func setPointerOnBubble(_ on: Bool) {
        pointerOnBubble = on
        if on {
            graceTask?.cancel()
            graceTask = nil
        } else if let sentenceID = request?.sentenceID {
            beginGrace(ownedBy: sentenceID)
        }
    }

    /// 朗读状态变了（点了朗读 / 播放结束）→ 按钮跟着变。
    public func refreshSpeaking() {
        guard var current = request else { return }
        let speaking = current.actions.isSpeaking(current.card.text)
        guard speaking != current.isSpeaking else { return }
        current.isSpeaking = speaking
        request = current
    }

    /// 立刻收起（切换页面、打开面板等场景）。
    public func hide() {
        graceTask?.cancel()
        graceTask = nil
        pointerOnBubble = false
        clear()
    }

    private func finishGrace(ownedBy sentenceID: UUID) {
        guard request?.sentenceID == sentenceID, !pointerOnBubble else { return }
        clear()
    }

    private func clear() {
        let action = request?.actions.onDismiss
        request = nil
        // 卡片没了，指针自然也不再「在气泡上」——否则下次划词会被这条卡住。
        pointerOnBubble = false
        action?()
    }
}

// MARK: - 浮层 View

/// 把气泡画在**页面最外层**。
///
/// 为什么不是句子的 overlay：句子住在 `ScrollView` 里，句内 overlay 会被滚动容器裁掉
/// （聊天区还给整块内容加了 `mask` 做渐隐），也会被后面声明的兄弟视图盖住 ——
/// `zIndex` 只在同一个父容器里比大小，跨到滚动列表这一层就不管用了。
private struct WordLookupBubbleOverlay: ViewModifier {

    @Environment(\.wordLookupPresenter) private var presenter
    @State private var bubbleSize: CGSize = .zero

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(WordLookupAnchorKey.self) { anchor in
            // 透明区域不参与命中测试（不能挡住底下的点击），所以这里不能垫一层 `Color.clear`。
            if let presenter, let request = presenter.request, let anchor,
               anchor.sentenceID == request.sentenceID {
                bubble(request: request, anchor: anchor)
                    .transition(.opacity)
                    .appAnimation(.press, value: anchor.sentenceID)
            }
        }
    }

    private func bubble(request: WordLookupBubblePresenter.Request, anchor: WordLookupAnchor) -> some View {
        GeometryReader { geo in
            let frame = geo[anchor.bounds]
            let size = bubbleSize == .zero
                ? CGSize(width: WordLookupBubble.maxWidth, height: WordLookupBubble.fallbackHeight)
                : bubbleSize
            let origin = WordLookupLayerPlacement.origin(
                anchor: anchor.wordRect,
                space: anchor.space,
                sourceFrameInLayer: frame,
                bubble: size
            )
            WordLookupBubble(
                card: request.card,
                isSpeaking: request.isSpeaking,
                onSpeak: { request.actions.onSpeak(request.card.text) },
                onStopSpeak: { request.actions.onStopSpeak() },
                onOpenDictionary: { request.actions.onOpenDictionary(request.card.text) },
                onAddToReview: { request.actions.onAddToReview(request.card.text) },
                onRetryLookup: { request.actions.onRetryLookup(request.card.text) },
                dictionaryHint: request.actions.openDictionaryHint,
                addReviewHint: request.actions.addReviewHint
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
            // 报出「这块被气泡盖住了」：下面文本视图的悬停与整窗光标都要按它闭嘴
            // （SwiftUI 浮层不是 NSView，命中测试看不见它 —— 见 `WindowOverlayOcclusion`）。
            .windowOverlayOcclusion()
            // ⚠️ 必须在 `.offset` **之前**：气泡浮在滚动区之上，鼠标停在它上面时滚轮会被浮层吃掉，
            // 页面就滚不动了 —— 这道透传把滚轮转交给下方的滚动视图。
            // 顺序反了会静默失效（见 `ScrollWheelPassthrough` 的说明）。
            .scrollWheelPassthrough()
            .offset(x: origin.x, y: origin.y)
            .onHover { presenter?.setPointerOnBubble($0) }
        }
    }
}

extension View {
    /// 在这一层之上承载划词气泡（挂得越高，能盖住气泡的东西越少）。
    func wordLookupBubbleOverlay() -> some View {
        modifier(WordLookupBubbleOverlay())
    }
}
