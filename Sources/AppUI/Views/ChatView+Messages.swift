import AIDomain
import SwiftUI

// #663 自 ChatView.swift 拆出（2026-10-24）：原文件 2896 行、单结构体 + 5 个尾部类型，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ChatView {

    // MARK: - 消息区

    /// 老师**真的被叫来了**、正要说话：点「继续上次对话」后的整段（总结上次 → 写开场白），
    /// 或正在生成开场白。
    ///
    /// ⚠️ 这里**不含** `isBooting`（2026-10-14 报障）：启动装配那几秒属于「本地服务在拉起来」，
    /// 开屏已经不再自动开场，老师根本没被叫来 —— 挂一张「老师正在准备…」等于无中生有一条
    /// 老师发言（那张卡与老师的消息气泡同形），用户看到的就是「一打开老师先发起对话、
    /// 过一会儿又被引导卡顶掉」。装配期直接显示引导卡。
    var isTeacherPreparing: Bool { chat.isGreeting || isPreparingOpening }

    /// 等待卡上的真实阶段。两个信号的分界线都不是猜的：
    /// 总结上次（`isPreparingOpening`）→ 写开场白（`chat.isGreeting`）。
    ///
    /// ⚠️ `chat.isGreeting` 必须排在前面判：总结与写开场白同属一次「继续上次对话」，
    /// 复盘跑完紧接着就是生成 —— 顺序反了的话，开场白那半程会一直显示「正在总结上次的练习」。
    private var waitStage: TeacherWaitStage {
        if chat.isGreeting { return .greeting }
        return .reviewing
    }

    @ViewBuilder
    var messageArea: some View {
        // ⚠️ 判据走 `ChatEmptyStateRule`（纯函数、有单测）：这条逻辑漏一个条件，
        // 界面就开始说谎 —— 开屏装配那几秒到底该给引导卡还是等待卡，正是这条判据说了算。
        if ChatEmptyStateRule.showsInvitation(
            messageCount: chat.visibleMessages.count,
            hasStreamingText: !chat.streamingText.isEmpty,
            hasStreamingReasoning: !chat.streamingReasoning.isEmpty,
            isGenerating: chat.isGenerating,
            isTeacherPreparing: isTeacherPreparing
        ) {
            // 空态：小动物相对整个对话区垂直居中。
            GeometryReader { geo in
                VStack(spacing: 14) {
                    emptyHint
                    // 「继续上次对话」（2026-10-14 改造）：引导卡第一位。
                    // 开屏不再自动开场 —— 点了它才进入「总结上次 → 发起聊天」。
                    if canContinueLast {
                        continueLastButton
                    }
                    KickoffRow(
                        suggestions: kickoffs,
                        onPick: onKickoff,
                        forcedHoveredID: forcedHoveredKickoffID
                    )
                    // 碎片热身（⑦-B②）：话题卡回答「说什么」，
                    // 这一张回答「还没想好说什么，先动起来」。
                    WarmUpCard(
                        plan: warmUpPlan,
                        progress: warmUp,
                        notice: warmUpNotice,
                        stepScore: warmUpStepScore,
                        heardText: warmUpHeardText,
                        isRecording: isWarmUpRecording,
                        isBusy: isWarmUpBusy,
                        onStart: { onStartWarmUp?() },
                        onGrade: { remembered in onGradeWarmUpWord?(remembered) },
                        onPlaySentence: { onPlayWarmUpSentence?() },
                        onToggleRecording: { onToggleWarmUpRecording?() },
                        onContinue: { onContinueWarmUp?() },
                        onSkip: { onSkipWarmUpStep?() },
                        onSendSpoken: { onSendWarmUpSpoken?() },
                        onDismiss: { onDismissWarmUp?() },
                        onDismissNotice: { onDismissWarmUpNotice?() }
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // LazyVStack：长会话只渲染屏幕内外的少量气泡（历史几十上百条时
                    // 一次性全部搭出来是滚动卡顿的主因）。间距与对齐和原 VStack 一致。
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(chat.visibleMessages.enumerated()), id: \.element.id) { index, message in
                            VStack(alignment: .leading, spacing: 6) {
                                // 距上一条超过 5 分钟才显示时间戳；首条消息必显示。
                                if index == 0
                                    || message.createdAt.timeIntervalSince(chat.visibleMessages[index - 1].createdAt) > timestampGap {
                                    timestamp(message.createdAt)
                                }
                                bubble(message)
                            }
                            .id(message.id.uuidString)
                            // 新消息从底部推入（#357）：看得出来「刚到」，而不是凭空出现。
                            // 移除保持纯淡出 —— 换会话时整列表退场，滑动会乱。
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }

                        // 判据同样走纯函数：`isTeacherPreparing` 那两段（总结上次 / 写开场白）
                        // 里 `isGenerating` 都是 false，漏掉就是引导卡赖着不走。
                        if ChatEmptyStateRule.showsPendingCard(
                            isGenerating: chat.isGenerating,
                            isTeacherPreparing: isTeacherPreparing
                        ) {
                            pendingCard
                                .id("streaming")
                        }

                        if let errorMessage = chat.errorMessage {
                            errorBanner(errorMessage)
                        }
                    }
                    .padding(.horizontal, 18)
                    .appPadding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 消息插入/移除的动画事务（#357）：没有它，上面的 .transition
                    // 从不带动画、新消息是瞬间蹦出来的。挂在 count 上 —— 追加新消息
                    // 与换会话重置列表都会触发；换会话时旧行纯淡出（见行的 asymmetric）。
                    .appAnimation(.reveal, value: chat.visibleMessages.count)
                }
                // 内容不足一屏时不硬弹（#360）：空会话 / 只有一两条时上下拖动
                // 会把整段内容拽起来又弹回去，像皮筋。basedOnSize 只在真的
                // 能滚的时候才允许回弹。
                .scrollBounceBehavior(.basedOnSize)
                // 需求 2：聊天区上翻时，输入框**正上方**出现快速回底按钮，
                // 并且输入框上方那一条文字有轻微虚化（见 `messageFadeMask`）。
                .mask { messageFadeMask }
                .overlay(alignment: .bottom) { jumpToBottomButton(proxy) }
                // 「在上翻吗」由滚动几何量决定，不靠监听手势：
                // 触控板惯性滚动、拖滚动条、程序化 scrollTo 都会更新 contentOffset，
                // 只有读几何量才三种情况都跟得上。
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    ChatScrollMetrics.distanceFromBottom(
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height,
                        contentOffsetY: geometry.contentOffset.y,
                        bottomInset: geometry.contentInsets.bottom
                    )
                } action: { _, distance in
                    isScrolledUp = ChatScrollMetrics.shouldOfferJumpToBottom(
                        distanceFromBottom: distance
                    )
                }
                // S4-1：跟着滚到底**只在没上翻时**做。三处原先都是无条件 `scrollToBottom`，
                // 于是生成回复期间上翻看历史，每来一个 token 就被拽回底部 ——
                // 上翻阅在生成期间完全不可用。
                .onChange(of: chat.visibleMessages.count) { _, _ in
                    autoScrollIfFollowing(
                        proxy,
                        // 自己刚发出一条：即使之前在上翻也拉到底（那是他要看的东西）。
                        userSentMessage: chat.visibleMessages.last?.role == .user
                    )
                }
                .onChange(of: chat.streamingText) { autoScrollIfFollowing(proxy, userSentMessage: false) }
                .onChange(of: chat.streamingReasoning) { _, _ in
                    // 思考阶段也保持滚动到底（面板自动跟随最新内容）
                    if chat.streamingText.isEmpty {
                        autoScrollIfFollowing(proxy, userSentMessage: false)
                    }
                }
                .task {
                    // #6：练习页是 if/else 切出来的 —— 从别的页面回来时本视图是
                    // **重建**的，ScrollView 初始停在对话开头。等一帧让消息真正
                    // 落位，再**无动画**定位到最后（带动画会从顶飞到底，更糟）。
                    await positionAtLatestOnAppear(proxy)
                }
            }
        }
    }

    /// 内容变化时的自动跟滚（S4-1）：**用户上翻就暂停跟随**。
    ///
    /// 口径是纯函数（`ChatScrollMetrics.shouldAutoScrollOnContentChange`），
    /// 这里只负责把当前状态喂进去 —— 判据写在视图里就没法把边界值钉死。
    private func autoScrollIfFollowing(_ proxy: ScrollViewProxy, userSentMessage: Bool) {
        guard ChatScrollMetrics.shouldAutoScrollOnContentChange(
            isScrolledUp: isScrolledUp, userSentMessage: userSentMessage
        ) else { return }
        scrollToBottom(proxy)
    }

    /// 「回到底部」按钮：与主流 Agent 一致 —— 一条消息都没错过时不出现，
    /// 一旦上翻就浮在**输入框正上方居中**，点一下回到最新。
    @ViewBuilder
    private func jumpToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        if isScrolledUp {
            Button {
                // 不在这里手工把 `isScrolledUp` 置回 false：滚动过程本身会持续上报距离，
                // 越滚越近时它会自然跨过阈值。手工抢先置位反而会在动画途中闪一下。
                scrollToBottom(proxy)
            } label: {
                Image(systemName: "arrow.down")
                    .appFont(12, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.surface))
                    .overlay(Circle().strokeBorder(theme.divider, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.14), radius: 4, y: 2)
            }
            .buttonStyle(.appPressable)
            .help("回到最新消息")
            .appPadding(.bottom, 10)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    /// 输入框上方那层「轻微虚化」：把聊天区最底下的一条渐隐掉。
    ///
    /// 用**渐变蒙版**而不是盖一块底色：对话框的背景是 `surfaceAlt.opacity(0.35)`
    /// 叠在窗口底色上，想在日夜两套主题下都配出一模一样的实色几乎不可能，
    /// 一旦差一点就会看到一条色带。蒙版是让文字自己淡出、露出**它本来就在的那层背景**，
    /// 天然不可能有色差。
    private var messageFadeMask: some View {
        GeometryReader { geometry in
            let start = ChatScrollMetrics.fadeStartFraction(containerHeight: geometry.size.height)
            ZStack {
                // 没上翻时这一层是实心黑 → 蒙版全开（完全不虚化）；
                // 上翻时它淡到 0，只剩下面那层渐变 → 底部渐隐。
                //
                // ⚠️ 必须这样叠，不能只留渐变：`mask` 按 **alpha** 生效，
                // 若底层也是半透明，两层会在合成时互相「补」回来（alpha 混合是
                // out = top + bottom×(1-top)）→ 渐隐根本看不出来。
                Color.black.opacity(isScrolledUp ? 0 : 1)
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: start),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(isScrolledUp ? 1 : 0)
            }
            .appAnimation(.reveal, value: isScrolledUp)
        }
    }

    /// 生成中该显示哪张卡：老师开场白 / 启动装配 → 等待卡；其余 → 流式卡。
    ///
    /// 两者不合并：等待卡报的是「已等待 N 秒」这个事实，而流式卡兜底的那三个跳点
    /// 从第一秒起就没有变化，用户看到的「卡住」与「在算」是同一种样子。
    @ViewBuilder
    private var pendingCard: some View {
        if isTeacherPreparing {
            // 真实阶段：总结上次 → 生成开场白。分界线是
            // `isPreparingOpening` / `chat.isGreeting` 这两个真实信号，不是按秒数编的。
            TeacherPreparingCard(
                teacherKind: teacherKind,
                stage: waitStage
            )
        } else {
            streamingCard
        }
    }

    /// 生成中的卡片：思考面板（实时增长）+ 流式正文。
    @ViewBuilder
    private var streamingCard: some View {
        let streamingMessage = ChatMessage(role: .assistant, content: chat.streamingText)
        if !chat.streamingReasoning.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30, bobbing: false)
                ThinkingPanel(reasoning: chat.streamingReasoning, isStreaming: chat.streamingText.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !chat.streamingText.isEmpty {
            bubble(streamingMessage)
        } else if chat.isThinking {
            HStack(spacing: 8) {
                CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30, bobbing: false)
                Text("思考中…")
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                TypingDots(color: theme.secondaryText)
            }
        } else {
            HStack(spacing: 8) {
                CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30, bobbing: false)
                TypingDots(color: theme.secondaryText)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target: String? = chat.isGenerating ? "streaming" : chat.visibleMessages.last?.id.uuidString
        guard let target else { return }
        if animated {
            withAnimation(.app(.reveal)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    /// #6：进入练习页时的落位。睡一拍等首帧布局完成（消息尺寸还是估算值时
    /// `scrollTo` 会停在中途），然后无动画直落底部。
    private func positionAtLatestOnAppear(_ proxy: ScrollViewProxy) async {
        try? await Task.sleep(nanoseconds: 120_000_000)
        scrollToBottom(proxy, animated: false)
        // LazyVStack 的到场项是按需搭的：第一跳之后中段气泡才陆续建出来，
        // 估算高度会漂 —— 补一跳落准（两次都无动画，用户看不出过程）。
        try? await Task.sleep(nanoseconds: 120_000_000)
        scrollToBottom(proxy, animated: false)
    }

}
