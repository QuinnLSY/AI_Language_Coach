import AIDomain
import SwiftUI

// #663 自 ChatView.swift 拆出（2026-10-24）：原文件 2896 行、单结构体 + 5 个尾部类型，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ChatView {

    // MARK: - 输入区信息显示

    /// 「本地模型 · qwen3:8b」
    var contextSummary: String {
        var parts: [String] = []
        if !providerLabel.isEmpty { parts.append(providerLabel) }
        if let modelName, !modelName.isEmpty { parts.append(modelName) }
        return parts.joined(separator: " · ")
    }

    var contextDescription: String {
        let used = chat.estimatedContextTokens
        if let contextLimit, contextLimit > 0 {
            let fraction = min(Double(used) / Double(contextLimit), 1)
            return "上下文 ≈\(Self.tokenCount(used)) / \(Self.tokenCount(contextLimit))（\(Int(fraction * 100))%）"
        }
        return "上下文 ≈\(Self.tokenCount(used)) tokens"
    }

    /// token 数缩写：1234 → 1.2k。
    public nonisolated static func tokenCount(_ tokens: Int) -> String {
        tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)"
    }

    /// 考场态输入框的占位提示：说清「第几问、要答多长」，不提供可以照念的句子。
    static func examComposerHint(_ exam: ExamBarModel) -> String {
        if exam.minimumWords > 0 {
            return "第 \(exam.questionNumber)/\(exam.totalQuestions) 问 · 至少 \(exam.minimumWords) 词，答完自动进下一题"
        }
        return "第 \(exam.questionNumber)/\(exam.totalQuestions) 问 · 答完自动进下一题"
    }

    func send() {
        // 生成中按回车：**什么都不做**（输入原样留着）。
        // 这时 `ChatService.send` 会被自己的 `guard !isGenerating` 挡下，而下面那句
        // `input = ""` 已经执行 —— 用户打的那句就这么没了，还以为是发失败。
        // 那颗按钮此刻的语义是「停止」，回车不该替它决定。
        // ⚠️ 例外必须放行：老师正在**打招呼**时是可以抢话的（`ChatService.send` 专门
        // 撤掉招呼来接这一句，注释写着「绝不能让这句话石沉大海」），而那也是一次生成。
        guard !chat.isGenerating || chat.isGreeting else { return }
        // 对话模型被关闭时，输入不丢、也不发出去；用户按提示启动模型即可。
        guard modelStoppedNotice == nil else { return }
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空着点发送 = 发送当前轮换到的预设提问（浅灰那条）；只带附件不带文字时不再兜底提问。
        // ⚠️ 在 action 闭包里读 rotator（闭包不订阅）—— 取的是「此刻」轮换到的那条。
        let text: String
        if !typed.isEmpty {
            text = typed
        } else if pendingAttachments.isEmpty {
            text = exam == nil ? (rotator.current ?? "") : ""
        } else {
            text = ""
        }
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        // 还在录音 / 识别时点发送：先把这一段语音收掉（不识别、不填入）。
        // ⚠️ 必须**停麦克风**，不能只断开回流：以前这里只清 `isMergingVoice`，
        // 麦克风继续开着，用户接着说的话会被录进一个已经发出去的消息里，
        // 而且那颗主按钮还显示「录音中」——他以为自己没发出去。
        if voicePhase != .idle {
            stopMergingVoice()
            onCancelVoiceInput?()
        }
        // 手打与语音一视同仁：发出去后输入框彻底清空。
        // 同时丢弃本段语音的位置记忆 —— 否则「还录着音就点发送」时，
        // 下一轮流式结果会按旧前缀把内容原样填回来。
        input = ""
        isMergingVoice = false
        voiceMerge = VoiceMergeState()
        // 发送（含附件）收在 AppState 里：视图不自己拼「取附件 + 清空」的顺序，
        // 那个顺序漏一步就会「下一句把同一张图重发一遍」。
        if let onSend {
            onSend(text)
        } else {
            chat.send(text)
        }
        isInputFocused = true
    }
}
