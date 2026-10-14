import AIDomain
import AIInterfaces
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 气泡翻译 + 聊天附件
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 气泡翻译

    /// 取某条消息的译文（再点一次收起）。走按需翻译 + 有界缓存，不进对话历史。
    public func translateMessage(_ id: UUID) async {
        await chat.translate(messageID: id)
    }

    /// 关闭翻译失败提示。
    public func clearTranslationNotice() { chat.clearTranslationError() }

    // MARK: - 气泡上的动作：删除 / 编辑重发 / 重新生成

    /// 这条对话现在改不改得动。
    ///
    /// 考试模式下不改：考卷的题号、已作答记录都按消息顺序推，删掉中间一条
    /// 会让「现在是第几题」与考卷对不上 —— 那种错在考试中途是不该出现的。
    public var canMutateChatMessages: Bool { examRunner == nil }

    /// 删掉一条学员消息（连同它的老师回复）。
    public func deleteChatMessage(_ id: UUID) {
        guard canMutateChatMessages else { return }
        chat.deleteMessage(id)
        refreshAfterMessageMutation()
    }

    /// 气泡内编辑后重发：从此处重新开始对话。
    public func resendEditedChatMessage(_ id: UUID, text: String) {
        guard canMutateChatMessages else { return }
        chat.resendEditedMessage(id, text: text)
        refreshAfterMessageMutation()
    }

    /// 重新生成某条老师回复。
    public func regenerateChatReply(to id: UUID) {
        guard canMutateChatMessages else { return }
        chat.regenerateReply(to: id)
        refreshAfterMessageMutation()
    }

    /// 消息被删改之后，把「今天的练习量」重新算一遍。
    ///
    /// 练习时长与条数都是从消息时间戳推出来的（`ProgressAggregator`），
    /// 所以删掉几条消息之后，黑板上的分钟数必须跟着回落 ——
    /// 不刷新的表现是「删了两句，今日练习还是 12 分钟」。
    private func refreshAfterMessageMutation() {
        Task { await refreshTodayPanel(force: true) }
    }

    // MARK: - 聊天附件（第 3 项需求）

    /// 把用户选中的文件导入待发区。
    ///
    /// 逐个导入、逐个报错：一批里有一个超大文件时，其余的文件照样要能加上 ——
    /// 不能因为第 3 个失败就把前 2 个一起丢掉。
    public func addAttachments(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImportingAttachments = true
        defer { isImportingAttachments = false }
        var failures: [String] = []
        var added = 0
        for url in urls {
            guard AttachmentPolicy.remainingSlots(current: pendingAttachments.count) > 0 else {
                failures.append("一条消息最多带 \(AttachmentPolicy.maxPerMessage) 个附件。")
                break
            }
            do {
                let attachment = try await services.importAttachment(from: url)
                pendingAttachments.append(attachment)
                added += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if failures.isEmpty {
            attachmentNotice = nil
        } else {
            attachmentNotice = failures.joined(separator: "\n")
        }
        _ = added
    }

    /// 移除一个待发附件（文件本体一并清理 —— 用户明确删掉了它，留着只是垃圾）。
    public func removePendingAttachment(_ id: UUID) async {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = pendingAttachments.remove(at: index)
        await services.removeAttachment(attachment)
    }

    /// 清空待发附件（发送后调用；**不删文件**，消息里还要用它）。
    public func clearPendingAttachments() {
        pendingAttachments.removeAll()
        attachmentNotice = nil
    }

    public func clearAttachmentNotice() { attachmentNotice = nil }

    /// 收起「已保存」回执，并撤销自动收起的计划。
    public func clearAttachmentSaveNotice() {
        attachmentSaveNoticeTask?.cancel()
        attachmentSaveNoticeTask = nil
        attachmentSaveNotice = nil
    }

    /// 保存回执展示几秒后自己收起。
    ///
    /// 与「导入失败」提示的区别：失败提示要用户读完再走（必须手动关），
    /// 成功回执只是一句「刚才那下成了」，赖着不走会变成噪音。
    func scheduleAttachmentSaveNoticeDismissal() {
        attachmentSaveNoticeTask?.cancel()
        guard attachmentSaveNotice != nil else {
            attachmentSaveNoticeTask = nil
            return
        }
        attachmentSaveNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.attachmentSaveNotice = nil
            self?.attachmentSaveNoticeTask = nil
        }
    }

    /// 附件在本机的位置（渲染用；不做存在性检查 —— 文件可能在运行期间被清理，
    /// 那正是「文件已不可用」应当被看到的时候）。
    public func attachmentLocation(for attachment: ChatAttachment) -> URL {
        chat.attachmentLocation(for: attachment)
    }

    /// 下载附件：「另存为」到用户选的位置。结果如实说出来。
    @discardableResult
    public func downloadAttachment(_ attachment: ChatAttachment) -> Bool {
        let url = attachmentLocation(for: attachment)
        let saved = AttachmentExporter.save(attachment: attachment, from: url)
        attachmentSaveNotice = saved ? "已保存「\(attachment.fileName)」。" : nil
        scheduleAttachmentSaveNoticeDismissal()
        return saved
    }

    /// 发送一条消息（**带上待发附件**，随后清空待发区）。
    ///
    /// 收成一个方法而不是让 View 自己「先读 pending 再 send 再 clear」：
    /// 那三步任何一步忘掉，都会表现为「带图发出去、下一句又把同一张图重发一遍」。
    @discardableResult
    public func sendChat(_ text: String) -> Bool {
        let attachments = pendingAttachments
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        guard llmStoppedNotice == nil else { return false }
        // 考试模式：这一句是**作答**。先记进考卷（含实际用时）并推进到下一问，
        // 老师这一轮拿到的题号才是对的那一题（顺序颠倒会一直问同一问）。
        if examRunner != nil, !trimmed.isEmpty {
            submitExamAnswer(trimmed)
        }
        pendingAttachments.removeAll()
        attachmentNotice = nil
        // 学员开口了：这一轮会话归他 —— 「继续上次对话」那一轮不许再动会话
        // （见 `continueLastConversation` 的让位规则）。
        learnerEngagedThisLaunch = true
        // 恢复出来的历史还按在手里（启动时按住，等「继续上次对话」决策）：
        // 学员先开口时必须揭开 —— 否则他的话进了内存却不上屏
        // （`visibleMessages` 仍为空），表现是「我打了一句，屏幕上什么都没有」。
        chat.revealRestoredHistory()
        // 复盘回执是「你不在的时候我把上一段收好了」，说给**还没开口**的人听。
        // 学员一开始说下一句，它就过期了 —— 留在屏幕上只会挡住对话。
        practiceNotice = nil
        // 抢在老师前面说话：那句还在后台生成的开场白立刻让位。
        // ⚠️ `ChatService.send` 只在 `isGreeting` 时主动撤招呼，而后台开场期间
        // `isGenerating` 也可能是 true —— 不主动撤，这句话会被 `guard !isGenerating`
        // **静默丢掉**，表现为「我打了一句，屏幕上什么都没有」。
        if isPreparingOpening, chat.isGenerating { chat.cancel() }
        // 附件随消息落库：`chat.send` 内部会把整条消息（含附件）写进数据库。
        chat.send(trimmed, attachments: attachments)
        return true
    }

    public func refreshStatus() async {
        health = await services.llmHealth()
        // 当前模型读不读图：带图说话时要不要提醒「老师看不到这张图」。
        llmSupportsVision = await services.llmSupportsVision()
        let models = await services.availableLLMModels()
        availableModels = models.filter { !$0.isEmbeddingOnly }
        activeProvider = await services.activeLLMProvider()
        if activeProvider == nil { selectedProviderID = "" } else if !isActiveProviderRemote || selectedProviderID.isEmpty {
            selectedProviderID = activeProvider?.id ?? selectedProviderID
        }
        if let current = await services.currentLLMModel() {
            modelDraft = current
        } else {
            modelDraft = availableModels.first?.id ?? ""
        }
        // 上下文窗口：优先取 runtime 发现的当前模型长度，其次配置值。
        let configured = await services.contextWindow()
        contextLimit = availableModels.first(where: { $0.id == modelDraft })?.contextLength ?? configured
        // 生效模型的推理强度（头部胶囊展示用）。
        activeReasoningEffort = await services.activeReasoningEffort()
        // 「AI 大脑」当前生效的 Provider / 模型也要进快照：外部模型面板与模型卡片都读它。
        // （`refreshCapabilityInfos` 覆盖另外五项能力，这里补 llm。）
        if let provider = activeProvider {
            activeProviderIDs[.llm] = provider.id
        } else {
            activeProviderIDs[.llm] = nil
        }
        if !modelDraft.isEmpty { activeModels[.llm] = modelDraft }
        // 关键：同步本地 product 缓存。否则切换 Provider 后，任何一次 persistProduct
        // 都会用旧缓存回写配置，把 activeProviders/apiKey 决策抹掉（重启回到 qwen3 的根源）。
        product = await services.configuration.product
    }

}
