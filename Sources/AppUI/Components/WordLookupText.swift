import AIDomain
import AppKit
import SwiftUI

/// 一次划词（悬停 / 拖选）的上报内容。
public struct WordLookupProbe: Equatable {
    /// 划到的文字（悬停 = 一个词；拖选 = 选中的一段）。
    public var text: String
    /// 这段文字在文本视图里的位置（**视图自身坐标系，左上原点**）。
    public var rect: CGRect
    /// 锚点四周的可视边界（按窗口算，见 `WordLookupSpace`）。
    public var space: WordLookupSpace
    /// true = 拖选出来的，false = 悬停。
    public var isSelection: Bool

    public init(text: String, rect: CGRect, space: WordLookupSpace, isSelection: Bool) {
        self.text = text
        self.rect = rect
        self.space = space
        self.isSelection = isSelection
    }
}

// MARK: - 文本构造

/// 把一段文字做成可划词的富文本。
///
/// 两条路都归这里：
/// - `plain`：例句 / 固定搭配 / 跟读参考句（纯文本，样式整体统一）；
/// - `inlineMarkdown`：对话气泡正文 —— **保留粗体 / 斜体 / 行内代码**。
///   这一段不能退化成纯文本：老师回复里的加粗恰恰是要点，划词把字划没了就得不偿失。
public enum WordLookupTextBuilder {

    /// 圆润字体（与全应用的 `design: .rounded` 同款）；取不到就退回系统字体。
    public static func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        // ⚠️ AppKit 侧没有 `NSFont.withDesign`（那是 SwiftUI 的 API）：圆润体只能从
        // `NSFontDescriptor` 绕一圈；绕不出来就退回系统字体，绝不为了字形让文本出不来。
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if let rounded = descriptor.withDesign(.rounded) { descriptor = rounded }
        var font = NSFont(descriptor: descriptor, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            let italicDescriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: italicDescriptor, size: size) ?? font
        }
        return font
    }

    public static func paragraphStyle(lineSpacing: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return paragraph
    }

    public static func plain(
        _ text: String,
        fontSize: CGFloat,
        weight: NSFont.Weight = .regular,
        italic: Bool = false,
        color: NSColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font(size: fontSize, weight: weight, italic: italic),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle(lineSpacing: lineSpacing),
            ]
        )
    }

    /// 行内 markdown → 富文本（保留粗体 / 斜体 / 行内代码）。
    ///
    /// 逐 run 取 `inlinePresentationIntent`，而不是直接桥接 `NSAttributedString(AttributedString)`：
    /// 桥接过来的字体是系统默认体，还要再整体覆盖一遍，反而把粗体覆盖掉（实测会变成一坨普通字）。
    public static func inlineMarkdown(
        _ markdown: String,
        fontSize: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        guard let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return plain(markdown, fontSize: fontSize, weight: weight, color: color, lineSpacing: lineSpacing)
        }
        let paragraph = paragraphStyle(lineSpacing: lineSpacing)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont: NSFont
            if intent.contains(.code) {
                runFont = NSFont.monospacedSystemFont(ofSize: max(fontSize - 1, 8), weight: .regular)
            } else if intent.contains(.stronglyEmphasized) {
                runFont = font(size: fontSize, weight: .bold)
            } else if intent.contains(.emphasized) {
                runFont = font(size: fontSize, weight: weight, italic: true)
            } else {
                runFont = font(size: fontSize, weight: weight)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(
                NSAttributedString(
                    string: String(parsed[run.range].characters),
                    attributes: attributes
                )
            )
        }
        return result
    }
}

// MARK: - 只读文本视图（悬停 / 拖选的来源）

/// 承载英文句子的 `NSTextView`：**能选、不能改**，并把「光标停在哪、选中了哪段」上报出去。
///
/// 为什么必须是真 `NSTextView`，而不是把句子拆成一堆 `Text` 各自 `onHover`：
/// 用户要的是**拖选短语**（「划词」本来就是选一段）。逐词 `Text` 之间没有选区概念 ——
/// 跨词拖动时每个词各自收到 hover，拼不出一段连续的选择，「所划单词」也就无从谈起。
/// 真文本视图一次就同时给出「悬停到哪个词」和「选中了哪一段」两种事实。
final class WordLookupTextView: NSTextView, NSTextViewDelegate {

    /// 上报探测结果（nil = 收起气泡）。
    var onProbe: ((WordLookupProbe?) -> Void)?

    /// 悬停要不要出气泡。
    ///
    /// 阅读页正文（#233）必须关掉：阅读时鼠标习惯性跟着读进度走，
    /// 悬停就翻译会把阅读体验搅了 —— 那里**只认拖选**（选区路径不受此开关影响）。
    var isHoverLookupEnabled = true

    /// 鼠标光标要不要用 I 型插入符（可选中文本的 AppKit 默认）。
    ///
    /// ⚠️ 这个开关**不靠光标矩形生效** —— 见下面的 `resetCursorRects` 空实现。
    /// 整窗光标由 `CursorPolicy` 按命中测试裁决（命中谁，谁说话），
    /// 本属性只是「这台文本视图算不算可插入区」的口径来源。
    var showsIBeamCursor = true

    /// **一根光标矩形都不登记**。
    ///
    /// ⚠️ 三条实测教训叠出来的结论（#233 四轮）：
    /// ① AppKit 在窗口派发鼠标事件时按**光标矩形表**落光标，而且这一步发生在
    ///    `NSEvent` 本地监视器之后 —— 只要我们登记了矩形，它就把裁决盖回去
    ///    （实机截屏：题干行按钮处仍是插入符）；
    /// ② 矩形表**不理会视图遮挡**：正文挂了 I 型矩形，骑在它上方的划词卡片也跟着显示插入符；
    /// ③ 在卡片里垫一层箭头矩形也没用 —— 兄弟视图不在 `cursorUpdate` 的响应链上。
    /// 于是这里彻底交权：不登记矩形，光标只由 `CursorGuard` + `CursorPolicy` 决定。
    /// 退一步说，就算守卫没装上，这里也只是回落到系统默认箭头，不会退化出插入符。
    override func resetCursorRects() {
        // 故意留空：见上面说明。
    }

    override func cursorUpdate(with event: NSEvent) {
        // 光标更新事件走的是命中视图的响应链，与光标矩形是两条独立机制，这边也按口径走。
        (showsIBeamCursor ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    /// 悬停多久算「停在这个词上」（秒）。
    ///
    /// ⚠️ 这个值不是手感偏好，是**花钱的闸门**：气泡内容可能要问模型（词库没有的词），
    /// 鼠标一扫而过时每个词都发一次请求。实测 0.22 秒足够区分「扫过去」与「停下来看」。
    static let hoverDwellSeconds: Double = 0.22
    /// 拖选结束后多久去取内容（拖动过程本身会不停改选区，只在停下之后取一次）。
    static let selectionDwellSeconds: Double = 0.28

    private var dwellTask: Task<Void, Never>?
    private var trackingArea_: NSTrackingArea?
    /// 上一次上报的悬停词（同一个词不重复上报 / 不重复请求）。
    private var lastHoverWord = ""
    /// 已经写过一次内容（首次必须写，之后只在内容变了才写）。
    private var appliedText = ""

    // MARK: 尺寸

    /// 视图被 SwiftUI 改尺寸时，把容器宽度**同步**成新的宽度。
    ///
    /// ⚠️ 容器宽度归我们自己管（`widthTracksTextView = false`），因为 `sizeThatFits`
    /// 要在 SwiftUI 定 frame **之前**按给定宽度量一遍；交给 TextKit 自动跟随的话，
    /// 那时视图宽度还是 0（实测：手写的 `containerSize` 会被当场改回 0，第一趟量出
    /// 自然宽度 0，`sizeThatFits` 于是返回一个 900 多点的荒谬高度，整块文本塌成空白）。
    /// 代价是布局要用对宽度 —— 由这里跟 `sizeThatFits` 两处共同保证。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // ⚠️ SwiftUI 最后给出的 frame 才是真正会被画出来的宽度 —— 容器必须以它为准确。
        // `sizeThatFits` 期间设的宽度只用于测量，拿去和这里的宽度比大小会留下陈旧值
        // （实测：某次中间测量时 SwiftUI 提出宽度 0，于是记下 1，之后的帧宽再被这个
        // 「最小值」一直压着，整段文本最后按 1pt 宽排版，画出来只有一个点）。
        syncContainerWidth(to: newSize.width)
    }

    func syncContainerWidth(to width: CGFloat) {
        guard let container = textContainer, width > 0 else { return }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
    }

    // MARK: 事件

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea_ { removeTrackingArea(trackingArea_) }
        // `.inVisibleRect`：滚动 / 改尺寸时由 AppKit 自动跟随，不需要手工重设 rect。
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea_ = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 窗口默认不派发「只移动不点击」的鼠标事件，鼠标一划过就什么都收不到。
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // ⚠️ 鼠标落在**浮层**（划词卡片）上：这里的整条悬停链路当场闭嘴。
        //
        // SwiftUI 画的气泡不是 `NSView`，`NSTrackingArea` 与命中测试都看不见它 ——
        // 卡片骑在文本上时，本视图照样收到 `mouseMoved`，于是把卡片**挡住的词**又探测一遍：
        // 卡片内容被换掉、还可能白发一次查词请求。用户实测报障（答案卡片上能穿透）。
        // 判据是几何（`WindowOverlayOcclusion`），不依赖 SwiftUI 的 hover 状态 ——
        // 后者要等下一帧才生效，第一帧仍会漏一次。
        guard !WindowOverlayOcclusion.covers(event.locationInWindow, in: window) else {
            // 记住「没停在任何一个词上」：从卡片回到文字上时，同一个词也要能重新探测。
            lastHoverWord = ""
            return
        }
        // 悬停关闭（如阅读正文）：一动不动地扫过也不出气泡、不排计时。
        guard isHoverLookupEnabled else { return }
        // 有选区时以选区为准：拖动过程中光标必然划过一堆词，不能让悬停把选区顶掉。
        guard selectedRange().length == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let word = word(at: point)
        guard word != lastHoverWord else { return }
        lastHoverWord = word
        cancelDwell()
        guard !word.isEmpty else {
            onProbe?(nil)
            return
        }
        let anchor = rectForWord(at: point) ?? .zero
        scheduleDwell(Self.hoverDwellSeconds) { [weak self] in
            guard let self else { return }
            self.onProbe?(
                WordLookupProbe(
                    text: word,
                    rect: anchor,
                    space: self.visibleSpace(),
                    isSelection: false
                )
            )
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        cancelDwell()
        lastHoverWord = ""
        // 悬停关闭时不抢收气泡：收起只由选区变化（重新划 / 点空白）驱动。
        guard isHoverLookupEnabled else { return }
        guard selectedRange().length == 0 else { return }
        onProbe?(nil)
    }

    // MARK: 选区

    func textViewDidChangeSelection(_ notification: Notification) {
        cancelDwell()
        let range = selectedRange()
        guard range.length > 0 else {
            lastHoverWord = ""
            onProbe?(nil)
            return
        }
        let raw = (string as NSString).substring(with: range)
        let text = WordLookupQuery.normalize(raw)
        guard !text.isEmpty, let anchor = rectFor(range: range) else {
            onProbe?(nil)
            return
        }
        let space = visibleSpace()
        scheduleDwell(Self.selectionDwellSeconds) { [weak self] in
            guard let self else { return }
            self.onProbe?(
                WordLookupProbe(text: text, rect: anchor, space: space, isSelection: true)
            )
        }
    }

    // MARK: 内容

    /// 写入内容与样式（**内容没变就不动**）。
    ///
    /// ⚠️ 流式回复每秒会重画十几次，每次都无条件重设 `textStorage` 会把选区清掉 ——
    /// 用户看到的是「划到一半，选的词自己没了」，光标位置也跟着跳。
    func apply(_ attributed: NSAttributedString) {
        guard appliedText != attributed.string else { return }
        let previous = selectedRange()
        let length = (attributed.string as NSString).length
        textStorage?.setAttributedString(attributed)
        appliedText = attributed.string
        // 文字变短时旧下标会越界，夹回末尾。
        let location = min(previous.location, length)
        setSelectedRange(NSRange(location: location, length: 0))
    }

    // MARK: 几何

    /// 光标处那个词（光标不在词上 → 空串）。
    ///
    /// 用「点 → 字形 → 字符」三级换算，而不是 `characterIndexForInsertion(at:)`：
    /// 后者给的是**插入点**，停在词的后半截时会返回词尾之后的下标，那个位置已经是空格，
    /// 结果就是「鼠标明明在一个词上，气泡却不出来」（用户视角：时灵时不灵）。
    private func glyph(at point: NSPoint) -> (glyph: Int, rect: CGRect, container: NSTextContainer)? {
        guard let container = textContainer, let layout = layoutManager else { return nil }
        let inContainer = CGPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(
            for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyph < layout.numberOfGlyphs else { return nil }
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        // 行末右侧那一大片空白也属于「最接近的字形」：横向不在字形里就不算划到词。
        guard inContainer.x >= rect.minX - 1, inContainer.x <= rect.maxX + 1 else { return nil }
        return (glyph, rect, container)
    }

    private func word(at point: NSPoint) -> String {
        guard let hit = glyph(at: point), let layout = layoutManager else { return "" }
        var start = 0
        var end = 0
        guard tokenRange(atGlyph: hit.glyph, layout: layout, start: &start, end: &end) else {
            return ""
        }
        return (string as NSString).substring(with: NSRange(location: start, length: end - start + 1))
    }

    private func rectForWord(at point: NSPoint) -> CGRect? {
        guard let hit = glyph(at: point), let layout = layoutManager else { return nil }
        var start = 0
        var end = 0
        guard tokenRange(atGlyph: hit.glyph, layout: layout, start: &start, end: &end) else {
            return nil
        }
        return rectFor(range: NSRange(location: start, length: end - start + 1))
    }

    /// 字形 → 它所属的「词」的字符范围（前后扩到词边界）。
    private func tokenRange(
        atGlyph glyph: Int,
        layout: NSLayoutManager,
        start: inout Int,
        end: inout Int
    ) -> Bool {
        let index = layout.characterIndexForGlyph(at: glyph)
        let characters = Array(string)
        guard characters.indices.contains(index), WordLookupQuery.isWordCharacter(characters[index]) else {
            return false
        }
        start = index
        while start > 0, WordLookupQuery.isWordCharacter(characters[start - 1]) { start -= 1 }
        end = index
        while end + 1 < characters.count, WordLookupQuery.isWordCharacter(characters[end + 1]) { end += 1 }
        return true
    }

    /// 一个字符范围在视图里的矩形（左上原点，与 SwiftUI 同向）。
    private func rectFor(range: NSRange) -> CGRect? {
        guard let container = textContainer, let layout = layoutManager else { return nil }
        let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return rect
    }

    /// 可视边界（窗口）在本视图坐标系里的位置。
    ///
    /// 页面嵌在 `ScrollView` 里，因此**视图自己的 bounds 不是可视边界**：
    /// 句子卡很小，气泡往往要伸到卡片外面去。按窗口算出来的边界可能落在 bounds 之外
    /// （负数 / 大于高度都合法），`WordBubblePlacement` 正是用它们把气泡夹回屏幕内。
    private func visibleSpace() -> WordLookupSpace {
        guard let window, let content = window.contentView else {
            return .fallback(size: bounds.size)
        }
        let inWindow = convert(bounds, to: nil)
        let contentBounds = content.bounds
        return WordLookupSpace(
            topLimit: inWindow.maxY - contentBounds.maxY,
            bottomLimit: inWindow.maxY - contentBounds.minY,
            leftLimit: contentBounds.minX - inWindow.minX,
            rightLimit: contentBounds.maxX - inWindow.minX
        )
    }

    // MARK: 私有

    /// 延时执行（可取消）。用 `Task` 而不是 `Timer`：拖动选区时 runloop 在
    /// eventTracking 模式，定时器要等拖动结束才响，而这里需要「停下 0.28 秒」就取数。
    private func scheduleDwell(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        dwellTask?.cancel()
        dwellTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
    }
}

// MARK: - SwiftUI 包装

/// 可划词的文本（AppKit 侧）。
///
/// 高度由 TextKit 的 `usedRect` 决定：中英混排 + 换行后的真实高度只有它能给，
/// 靠字符数估算会出现「最后一行被切一半」。
struct WordLookupText: NSViewRepresentable {

    let attributed: NSAttributedString
    var onProbe: (WordLookupProbe?) -> Void
    var isHoverLookupEnabled = true
    /// 光标形状（I 型插入符 / 箭头），语义见 `WordLookupTextView.showsIBeamCursor`。
    var showsIBeamCursor = true

    func makeNSView(context: Context) -> WordLookupTextView {
        let view = WordLookupTextView(frame: .zero)
        view.delegate = view
        view.onProbe = onProbe
        view.isHoverLookupEnabled = isHoverLookupEnabled
        view.showsIBeamCursor = showsIBeamCursor
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.allowsUndo = false
        view.usesFindPanel = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // ⚠️ 宽度**不跟着视图走**：`sizeThatFits` 要在 SwiftUI 定 frame 之前先量一遍，
        // 那时视图宽度还是 0，自动跟随会把刚设好的容器宽度当场改回 0（实测）。
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: 0, height: 0)
        view.apply(attributed)
        return view
    }

    func updateNSView(_ nsView: WordLookupTextView, context: Context) {
        nsView.onProbe = onProbe
        nsView.isHoverLookupEnabled = isHoverLookupEnabled
        nsView.showsIBeamCursor = showsIBeamCursor
        nsView.apply(attributed)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WordLookupTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        // 两趟量：先量这句话的**自然宽度**，能一行放下就一行；放不下时才按可用宽度折行。
        //
        // ⚠️ 这一趟不能省：`NSViewRepresentable` 没有 `Text` 那种「理想宽度」，
        // 直接返回可用宽度会让它变成一个贪心视图 —— 聊天气泡会被拉满整行。
        //
        // ⚠️ 自然宽度**不能用 TextKit 量**（老写法把容器设成 `greatestFiniteMagnitude`
        //    再读 `usedRect`）：超大容器宽度下 `usedRect` 会把**容器宽度原样返回**
        //    （实测拿到 10,000,000）。于是「自然宽度」变成天文数字，凡是向它要理想宽度的
        //    地方跟着一起崩 —— `fixedSize(horizontal: true)` 的固定搭配那一行会把文本视图
        //    撑成一千万点宽，整张查词卡片排版塌成空白（用户实测报障）。按 `boundingRect`
        //    量才是真的按内容算。
        let naturalWidth = Self.naturalWidth(of: attributed)

        let width: CGFloat
        if let requested = proposal.width, requested < Self.unboundedWidth {
            // 有真实可用宽度：**沿用老口径**（等价于「用满可用宽度」）——
            // 聊天气泡、例句、跟读参考句的排版都建立在这条路径上，本此不动它。
            width = max(requested, Self.minimumWidth)
        } else {
            // 不限宽（`fixedSize(horizontal: true)`，或父视图没给宽度）：**就是它了**，
            // 回真实内容宽度 —— 固定搭配后面的中文译文才能紧贴着排（这是那处 `.fixedSize`
            // 想要的语义），同时不会再撑出一千万点的怪物宽度。
            width = max(naturalWidth, Self.minimumWidth)
        }

        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width, height: Self.contentHeight(of: attributed, width: width, usedHeight: used.height))
    }

    /// 这段富文本在给定宽度下的**排版高度**（取三者最大：实时量 / TextKit 现值 / 一行地板）。
    ///
    /// ⚠️ 高度的权威是 `NSAttributedString.boundingRect`，**不是** `layoutManager.usedRect`：
    /// 容器宽度刚被改掉时（进页换篇、拖窗口、分栏动画），`ensureLayout` 之后 `usedRect`
    /// 仍可能返回**旧宽度下的陈旧高度**（实测：548 宽排好后把容器改到 2630，`usedRect`
    /// 原样吐 146 不动）——SwiftUI 拿这个矮高度定 frame，正文按新宽度重排成更多行，
    /// 最后一行就被卡片裁掉（阅读短文实测报障）。`boundingRect` 每次现量，不背 TextKit 的账。
    static func contentHeight(of attributed: NSAttributedString, width: CGFloat, usedHeight: CGFloat) -> CGFloat {
        let measured = ceil(
            attributed.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
        )
        // 空内容时量出来是 0：留一行高，避免卡片塌成一条缝。
        let single = attributed.length > 0
            ? (attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 14
            : 14
        return max(measured, ceil(usedHeight), single * 1.25)
    }

    /// 这句话的**自然（不折行）宽度** —— 按内容算，不受容器宽度干扰。
    static func naturalWidth(of attributed: NSAttributedString) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        return ceil(
            attributed.boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width
        )
    }

    /// 宽度下限：给 0 会让布局彻底退化。
    static let minimumWidth: CGFloat = 1

    /// 「不限宽」的分界。任何真实窗口 / 分栏都远窄于此，拿它当分界既够安全、
    /// 又不会把正常的有限宽度误判成无限。
    static let unboundedWidth: CGFloat = 1_000_000
}
