import AIDomain
import SwiftUI

// #663 自 ChatView.swift 拆出（2026-10-24）：原文件 2896 行、单结构体 + 5 个尾部类型，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ChatView {

    /// 输入框：空着的时候用浅灰字**轮换**展示预设提问（点发送即发送当前这一条）。
    ///
    /// 多行规则见 `MultilineComposerField` / `ComposerMetrics`：
    /// 固定行宽、超宽换行、向上拓宽、最多 5 行，超过则只显示最后 5 行 + 下拉条
    /// （未超过 5 行时**不显示**下拉条）。
    ///
    /// ⚠️ 这里**不再自带底色与描边**：它已经是 `composer` 圆角矩形的上段，
    /// 再画一层框就会出现「框里套框」，上下两段也分不开了。
    var inputField: some View {
        ZStack(alignment: .topLeading) {
            MultilineComposerField(
                text: $input,
                measuredHeight: $inputHeight,
                isFocused: $isInputFocused,
                textColor: NSColor(theme.primaryText),
                insertionColor: NSColor(theme.accent),
                onSubmit: { send() }
            )
            // ⚠️ frame 的高度就是**滚动的可视区**高度，必须与上报值**一模一样**：
            // 曾经在这里额外 +20（想给文字留上下呼吸位），结果可视区比封顶高 20pt，
            // 「最多 5 行」实际显示成 6 行 —— 呼吸位由外层 `.appPadding(.vertical, 10)` 给，
            // 不能再叠一层，否则封顶形同虚设。
            .frame(height: max(inputHeight, ComposerMetrics.lineHeight(fontSize: 14)))
            .padding(.horizontal, 14)
            .appPadding(.vertical, 10)

            // 轮换占位提示（考试模式不显示：考场上出现一句现成的话，
            // 学员会以为把那句念出来就算答过了 —— 口径与原 `currentStarterQuestion` 一致）。
            if input.isEmpty, exam == nil {
                RollingStarterQuestionView(rotator: rotator, isGenerating: chat.isGenerating)
                    .padding(.leading, 14)
                    .padding(.trailing, 20)
                    .appPadding(.top, 10)
                    .allowsHitTesting(false)
            }

            // 考试模式：输入框里写的是「这一问的要求」，不是一句可以照念的话。
            if input.isEmpty, let exam {
                Text(Self.examComposerHint(exam))
                    .appFont(13, design: .rounded)
                    .foregroundStyle(theme.secondaryText.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 14)
                    .padding(.trailing, 20)
                    .appPadding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 能不能发送：模型被关闭时一律不行；否则「有手打内容」「有待发附件」「有预设提问」都行。
    ///
    /// ⚠️ 这里用 **index-free** 判断（exam == nil 且有预设即 true），不读轮换下标：
    /// `canSend` 在父 body 里求值，读了下标父级就会订阅它，状态下沉就白做了。
    var canSend: Bool {
        guard modelStoppedNotice == nil else { return false }
        if !pendingAttachments.isEmpty { return true }
        if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return exam == nil && !starterQuestions.isEmpty
    }

    /// 这一整段语音不要了：不识别、不填进输入框（识别已经开始的，结果作废）。
    ///
    /// 为什么单开一颗：麦克风按钮的语义是「停止并**识别**」，所以「我刚才是说错了」
    /// 原本没有出口，只能让它识别完、再把输入框里的字删掉。
    ///
    /// ⚠️ 取消要把输入框退回**本段语音之前**的样子（`voiceMerge.prefix`）：
    /// 流式结果已经往里面写过字了。但**用户手改的部分要留着** —— 他只说「这段语音不要」，
    /// 没说「把我打的字也删掉」。所以退的是「前缀」，而不是整段复原成录音前的快照。
    var cancelVoiceButton: some View {
        Button {
            stopMergingVoice()
            onCancelVoiceInput?()
        } label: {
            Image(systemName: "xmark")
                .appFont(12, weight: .semibold)
                .modifier(ComposerButtonChrome(
                    tint: theme.secondaryText,
                    fill: theme.surfaceAlt,
                    border: theme.divider
                ))
        }
        .buttonStyle(.appPressable)
        .help(voicePhase.isBusy ? "放弃这次识别（已识别的结果不会填进输入框）" : "取消这次录音（不识别、不填入输入框）")
        .accessibilityLabel("取消语音输入")
    }

    /// 结束本段语音的写入并复原输入框：识别结果不再回流，语音段本身被摘掉。
    func stopMergingVoice() {
        isMergingVoice = false
        input = voiceMerge.prefix
        voiceMerge = VoiceMergeState()
    }

    /// 麦克风按钮：点击说话 → 录音期间流式出字 → 再点识别并纠正拼写后定稿。
    ///
    /// ⚠️ 三件事**全部由 `voicePhase` 决定**（`primaryAction`）：
    /// 以前只有「录音中 / 否则」两个分支，识别期间 `isRecording` 仍为 true
    /// 而在途的是识别 —— 用户点一下想「停」，落进的却是「停止并再识别一次」，
    /// 第二次 `recorder.stop()` 拿到空音频，报出假的「没有录到声音」。
    /// 现在识别中点击的语义是**放弃这次识别**（服务端请求掐不断，但结果可以作废）。
    var micButton: some View {
        Button {
            switch voicePhase.primaryAction {
            case .start:
                // 记住本段语音之前的内容：流式结果只追加在它后面。
                voiceMerge = VoiceMergeState(prefix: input)
                isMergingVoice = true
                Task { @MainActor in await onMicStart?() }
            case .stopAndTranscribe:
                // 先断开流式回流，随后**定稿文本走同一套合并规则**：
                // 用户在录音期间改过的字不会被这一下抹掉。
                isMergingVoice = false
                Task { @MainActor in
                    if let text = await onMicStop?(), !text.isEmpty {
                        applyVoiceText(text)
                    }
                    isInputFocused = true
                }
            case .cancelTranscribe:
                stopMergingVoice()
                onCancelVoiceInput?()
            }
        } label: {
            Group {
                if voicePhase.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: voicePhase.isCapturing ? "waveform" : "mic.fill")
                        .appFont(14, weight: .semibold)
                        // 录音中波形做迭代变色（#358）：不用 ProgressView 也看得出「正在采」。
                        .symbolEffect(.variableColor.iterative, options: .repeating,
                                      isActive: voicePhase.isCapturing)
                }
            }
            // ⚠️ 尺寸/形状/描边全部来自 `ComposerButtonChrome`（与「+」同一份）：
            // 需求要求这两个按钮外观一致，各自写一套样式迟早会漂。
            .modifier(ComposerButtonChrome(
                tint: voicePhase == .idle ? theme.accent : Color.red,
                fill: voicePhase == .idle ? theme.surfaceAlt : Color.red.opacity(0.12),
                border: voicePhase == .idle ? theme.divider : Color.red.opacity(0.5)
            ))
        }
        .buttonStyle(.appPressable)
        .help(Self.micButtonHelp(voicePhase))
        .accessibilityLabel(Self.micButtonAccessibilityLabel(voicePhase))
    }

    /// 主按钮的悬停说明（按阶段说清「点下去会发生什么」）。
    ///
    /// `nonisolated`：纯查表、不碰任何视图状态，却会被 `View` 的 `@MainActor` 连坐成
    /// 主 actor 隔离 —— 那样测试与非隔离上下文都用不了（见 MEMORY 的标准修法①）。
    nonisolated static func micButtonHelp(_ phase: VoiceInputPhase) -> String {
        switch phase {
        case .idle: return "点击说话"
        case .recording: return "停止并识别"
        case .transcribing: return "放弃这次识别"
        }
    }

    /// VoiceOver 文案：识别中这颗按钮读成「取消录音」会误导 —— 那时麦克风早就关了。
    nonisolated static func micButtonAccessibilityLabel(_ phase: VoiceInputPhase) -> String {
        switch phase {
        case .idle: return "语音输入"
        case .recording: return "停止录音并识别"
        case .transcribing: return "放弃这次识别"
        }
    }

}
