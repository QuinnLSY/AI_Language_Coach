import AIDomain
import AppCore
import SwiftUI

// #663 自 ChatView.swift 拆出（2026-10-24）：原文件 2896 行、单结构体 + 5 个尾部类型，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ChatView {

    /// 每条消息上方的时间戳：`9月9日 周三 18:57`（仅间隔 > 5 分钟才出现）。
    func timestamp(_ date: Date) -> some View {
        Text(Self.stamp(date))
            .appFont(10, design: .rounded)
            .foregroundStyle(theme.secondaryText.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .center)
            .appPadding(.top, 4)
    }

    /// 手写格式化：避免 DateFormatter 的 locale/并发坑，输出顺序固定为「月日 周 时分」。
    public nonisolated static func stamp(_ date: Date) -> String {
        Timestamps.stamp(date)
    }

    var emptyHint: some View {
        let copy = PeriodGreeting.emptyStateLines(hour: Calendar.current.component(.hour, from: Date()))
        return VStack(spacing: 10) {
            CuteAnimalView(kind: studentKind, isSleeping: theme.isNight, size: 92, accessory: studentAccessory)
            Text(copy.greeting)
                .appFont(15, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Text(copy.invite)
                .appFont(14, design: .rounded)
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// 「继续上次对话」：引导卡第一位的那颗按钮（2026-10-14 改造）。
    ///
    /// 为什么它是主操作：点一下就走完整流程（总结上次的练习 → 换段 / 续做情景 →
    /// 带着复盘开场），正是「打开应用接着上次练」那条需求；话题卡们只是备选。
    ///
    /// ⚠️ 底色 / 悬停色 / 描边与话题卡**完全同源**（2026-10-14 第二次报障）：
    /// 之前它用强调色（accent）打底，于是同一屏里并排两种底色的卡，看着像两套控件。
    /// 它本来就是话题卡列表里的**第一项**，靠位置说话就够了，不该靠变色说话 ——
    /// 变色只会让用户以为「这个跟下面那些不是一回事」。
    ///
    /// ⚠️ 不画禁用态：点击后 `isPreparingOpening` 会把整块空态换成等待卡
    /// （见 `ChatEmptyStateRule.showsInvitation`），按钮根本不在屏幕上；
    /// 连点也有 `continueLastConversation` 里的重入守卫接着。
    var continueLastButton: some View {
        let isHovered = continueLastHovered || forcedHoveredContinueLast
        return Button {
            onContinueLast?()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.uturn.forward")
                    .appFont(12)
                    .foregroundStyle(theme.accent)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text("继续上次对话")
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Text("老师先总结上次练的内容，再接着聊")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.right")
                    .appFont(9)
                    .foregroundStyle(theme.secondaryText)
                    .opacity(isHovered ? 1 : 0.55)
            }
            .appPadding(.horizontal, 12)
            .appPadding(.vertical, 9)
            .frame(maxWidth: KickoffRow.width, alignment: .leading)
            // ⚠️ 这三个值与 `KickoffRow.kickoffButton` 必须逐字一致（同一张底卡）：
            // 底色 surface、悬停 selection 0.4、描边 divider 0.5。改一处就得改两处，
            // `ContinueLastButtonRenderTests` 用**同一夹具渲染两张卡**的像素差钉着。
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? theme.selection.opacity(0.4) : theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(theme.divider, lineWidth: 0.5)
                    )
            )
        }
        // 同话题卡：按压反馈由 MainView 根上的 `.appPressable` 统一注入。
        .onHover { inside in continueLastHovered = inside }
        .accessibilityLabel("继续上次对话，老师先总结上次练的内容，再接着聊")
    }

    func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
            Text(message)
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Spacer()
        }
        .appPadding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.warning.opacity(0.14))
        )
    }

    func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        // 悬停态：鼠标在哪一条上（真机由 `onHover` 写，离屏由参数注入 —— 见 `forcedHoveredMessageID`）。
        let isHovered = hoveredMessageID == message.id || forcedHoveredMessageID == message.id
        // 「重新生成」得有一条可重跑的问题：这条回复之前必须有学员说过话。
        // 老师主动开场那一条前面没有学员，按钮只能是死的（点不动的按钮比没有按钮更让人困惑，
        // 所以这里把它的可用性算出来，交给按钮自己显示成禁用态）。
        let canRegenerate: Bool = {
            guard !isUser,
                  let index = chat.visibleMessages.firstIndex(where: { $0.id == message.id })
            else { return false }
            return chat.visibleMessages[..<index].contains { $0.role == .user }
        }()
        return HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 36) }
            if !isUser {
                CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30, bobbing: false)
            }
            bubbleColumn(message, isUser: isUser, isHovered: isHovered, canRegenerate: canRegenerate)
            if isUser {
                CuteAnimalView(kind: studentKind, isSleeping: false, size: 28, accessory: .student)
            }
            if !isUser { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// 气泡那一列（正文 + 译文 + 纠错 + 动作行），编辑态与正常态二选一。
    ///
    /// ⚠️ 悬停判定区钉在**这一整块**上（气泡 + 三颗图标 + 译文 + 纠错），
    /// 但**不含**头像与外侧留白 —— 用户 2026-09-23 的口径是「整体判定区」，
    /// 指的就是这一块；把整行（含 `Spacer` 的空白）都算进来的话，
    /// 鼠标飘到对话区左边那一大片空里图标也亮着，那是噪声不是反馈。
    @ViewBuilder
    private func bubbleColumn(
        _ message: ChatMessage,
        isUser: Bool,
        isHovered: Bool,
        canRegenerate: Bool
    ) -> some View {
        let corrections = isUser ? [] : (chat.correctionsByMessage[message.id] ?? [])
        let translation = chat.translationsByMessage[message.id]
        let isTranslating = chat.translatingMessageIDs.contains(message.id)
        // 编辑态：气泡**整条换成一条独立输入框**（与产品给的参考图一致）。
        // 这一条消息本身没有被改动 —— 取消就还是原来那句话，草稿存在 `editingDraft` 里。
        if isUser, isEditing(message) {
            MessageEditBox(
                text: editBinding(for: message),
                onCancel: { cancelEditing() },
                onSend: { commitEditing(message) }
            )
        } else {
            // 学员气泡靠右 → 内容列 .trailing；老师靠左 → .leading。
            // ⚠️ 译文卡片**不挂任何宽度 frame**：裸 HStack[Text] 是「内容自然宽度、
            // 超宽自动换行」，与正文气泡完全同构；挂了 `frame(maxWidth: .infinity)`
            // 才会变成弹性视图、与 Spacer 平分宽度把正文挤向中间（第一轮翻车根因），
            // 挂了 `frame(width: 量宽)` 则会撑出行宽（第二轮翻车根因）。
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                // 思考过程：对话卡片内嵌的折叠面板，正文在其下方。
                if !isUser, let reasoning = message.reasoning, !reasoning.isEmpty {
                    ThinkingPanel(reasoning: reasoning, isStreaming: false)
                }
                // 附件排在正文**上方**：和主流 Agent 一致 —— 先看到「我发了什么」，
                // 再读配的那句话，读起来是「这张图 + 这句话」而不是反过来。
                ForEach(message.attachments) { attachment in
                    MessageAttachmentView(
                        attachment: attachment,
                        fileURL: attachmentLocation?(attachment)
                    ) {
                        onDownloadAttachment?(attachment)
                    }
                }
                // 气泡本体：翻译按钮贴在气泡外侧（学员在左 / 老师在右），
                // 这一层 HStack 用 .bottom 对齐 —— 按钮因此**始终与气泡底线齐平**，
                // 下方再挂纠错卡或朗读按钮也不会把它拽下去。
                //
                // 只有附件、没打字时不出空气泡：一个空圆角框看起来像渲染坏了。
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .bottom, spacing: 6) {
                        if isUser {
                            TranslateButton(isOn: translation != nil, isLoading: isTranslating) {
                                Task { await onTranslate?(message.id) }
                            }
                        }
                        MarkdownText(message.content, fontSize: 14, color: theme.primaryText, lookup: wordLookup)
                            // #2 二轮（用户 2026-09-24）：学员气泡的地板宽度 = 它自己那三颗
                            // 图标行的整宽（64 − 左右内边距 28 = 36）。极短的一句（"Ok."）
                            // 否则会缩得比动作行还窄，看着像被压瘪了。
                            // 老师气泡不设：它下面那一排（朗读 / 语速 / 复制 / 重答）更宽，
                            // 拿哪一颗当基准都是猜。
                            .frame(
                                minWidth: isUser ? LearnerBubbleActionRow.minimumBubbleContentWidth : nil,
                                alignment: .leading
                            )
                            .padding(.horizontal, 14)
                            .appPadding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(isUser ? theme.bubbleUser : theme.bubbleCoach)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(theme.divider, lineWidth: 1)
                            )
                        if !isUser {
                            TranslateButton(isOn: translation != nil, isLoading: isTranslating) {
                                Task { await onTranslate?(message.id) }
                            }
                        }
                    }
                }
                if let translation {
                    translationCard(translation, isUser: isUser)
                }
                ForEach(corrections) { correction in
                    correctionCard(correction)
                }
                // 老师气泡的底部动作行：朗读 / 语速 / 复制 / 重新生成。
                //
                // ⚠️ 顺序按产品要求：复制与重新生成**排在语速按钮右边**，且**始终显示**
                // （与学员气泡「悬停才浮现」相反 —— 这两颗不改动对话内容，
                //  而「老师这句没听懂 / 没答好」是最常发生的即时需求）。
                if !isUser {
                    HStack(spacing: 6) {
                        if let onSpeakTap {
                            SpeakButton(text: message.content,
                                        phase: speakingText == message.content ? speechPhase : .idle,
                                        action: onSpeakTap,
                                        onStop: onStopSpeak)
                            if onSpeechRateChange != nil {
                                SpeechRateMenu(rate: speechRate) { rate in onSpeechRateChange?(rate) }
                            }
                        }
                        CoachBubbleActionRow(
                            text: message.content,
                            isEnabled: canMutateMessages && canRegenerate,
                            onRegenerate: { onRegenerateReply?(message.id) }
                        )
                        Spacer(minLength: 0)
                    }
                }
                // 学员气泡的动作行：贴在气泡**下方**、右对齐（与老师气泡同一排法）。
                //
                // ⚠️ 为什么不在气泡**里面**：叠在右下角时，短句的最后一行文字末尾会被
                // 那三颗盖住（出图实测；用户看过图之后把位置定在了气泡外）。
                // ⚠️ 为什么用「常驻占位 + 只改透明度」而不是 `if isHovered`：后者会让
                // 气泡在鼠标进入的瞬间长高、整段对话跟着上下跳；占位高度恒定，跳就不可能发生。
                // ⚠️ 三颗**常驻**（未悬停 30%、悬停 100%），不再 `allowsHitTesting(false)`：
                // 「看得见」与「点得动」必须是同一件事 —— 看得见却点不动是最气人的那种 UI。
                // 误点由删除那一颗的确认框兜住（`DeleteConfirmation`）。
                if isUser {
                    LearnerBubbleActionRow(
                        text: message.content,
                        isEnabled: canMutateMessages,
                        onDelete: { deleteConfirmation.request(message.id) },
                        onEdit: { beginEditing(message) }
                    )
                    .opacity(isHovered ? 1 : Self.learnerActionIdleOpacity)
                    .appAnimation(.press, value: isHovered)
                }
            }
            // ⚠️ 判定区就是**这一整块**（气泡 + 三颗图标 + 译文 + 纠错）：
            // 用户口径是「整体判定区」，而不是只认气泡本体。
            // `contentShape` 不能省：块内的行间距（6pt 那条缝）本来不可命中，
            // 鼠标从气泡往图标那一条移过去时会先掉出判定区 —— 图标闪一下再亮，很难看。
            .contentShape(Rectangle())
            .onHover { inside in updateHover(inside, on: message) }
        }
    }

    /// 这条消息此刻是不是在就地编辑（真机由 `editingMessageID` 写，离屏由参数注入）。
    private func isEditing(_ message: ChatMessage) -> Bool {
        editingMessageID == message.id || forcedEditingMessageID == message.id
    }

    /// 编辑框的草稿绑定。
    ///
    /// ⚠️ 离屏注入的那条走 `.constant`：出图只关心「长什么样」，
    /// 而这个分支在真机上永远不会进（`forcedEditingMessageID` 默认 nil）。
    private func editBinding(for message: ChatMessage) -> Binding<String> {
        if forcedEditingMessageID == message.id, let forced = forcedEditingDraft {
            return .constant(forced)
        }
        return $editingDraft
    }

    /// 悬停进 / 出。    ///
    /// ⚠️ 移出时**只在「当前悬停的还是我」时才清**：从 A 滑到 B 时，A 的 `mouseExited`
    /// 完全可能晚于 B 的 `mouseEntered`，无脑置 nil 会把 B 刚点亮的按钮又灭掉。
    private func updateHover(_ inside: Bool, on message: ChatMessage) {
        if inside {
            hoveredMessageID = message.id
        } else if hoveredMessageID == message.id {
            hoveredMessageID = nil
        }
    }

    /// 进入气泡就地编辑：草稿取**当前正文**，取消时原文一字不动。
    private func beginEditing(_ message: ChatMessage) {
        editingDraft = message.content
        editingMessageID = message.id
    }

    private func cancelEditing() {
        editingMessageID = nil
        editingDraft = ""
    }

    /// 提交编辑：先收起输入框，再交给上层「截断其后 + 重发」。
    ///
    /// ⚠️ 顺序不能反。反过来的话，重发生成已经开始、而编辑框还挂在屏幕上，
    /// 用户会以为没点上，然后再点一次 —— 那就是第二次截断与第二次生成。
    private func commitEditing(_ message: ChatMessage) {
        let text = editingDraft
        cancelEditing()
        onResendEditedMessage?(message.id, text)
    }

    /// 译文卡片：默认不显示，点翻译按钮才出现在气泡下方。
    ///
    /// 对齐跟随**内容列**（学员 .trailing / 老师 .leading）：
    /// 学员译文与正文气泡**右缘对齐**（正文位置不动，译文出现在其下方）；
    /// 老师译文左对齐。两侧因此永不重叠，一眼就能分出这句话是谁说的。
    ///
    /// ⚠️ 布局与正文气泡**完全同构**（2026-09-11 定版）：不做任何宽度测量、
    /// 不挂任何 `frame(width:)` —— 内容自然宽度、超过可用宽度自动换行，
    /// 可用宽度与正文气泡一模一样（同处一个 VStack，收到同一个宽度提案）。
    /// 只保留两处刻意差异：底色不同、多一个引号图标。
    /// 历史教训：量宽方案（自然宽 ×1.04、动态上限）连续翻车 —— 忘减内边距就
    /// 把整行撑出窗口。Text 本来就会在提案宽度处换行，根本不需要手工量。
    private func translationCard(_ text: String, isUser: Bool) -> some View {
        HStack(alignment: .top, spacing: Self.translationMarkGap) {
            if isUser {
                translationText(text)
                translationMark(isUser: isUser)
            } else {
                translationMark(isUser: isUser)
                translationText(text)
            }
        }
        .padding(.horizontal, Self.translationPadding)
        .appPadding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.28), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// 引号方向跟着卡片走：老师在**左**用左引号，学员在**右**用右引号。
    private func translationMark(isUser: Bool) -> some View {
        Image(systemName: isUser ? "quote.closing" : "quote.opening")
            .appFont(9, weight: .semibold)
            .foregroundStyle(theme.accent)
            .appPadding(.top, 2)
    }

    private func translationText(_ text: String) -> some View {
        Text(text)
            .appFont(12, design: .rounded)
            .foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

}
