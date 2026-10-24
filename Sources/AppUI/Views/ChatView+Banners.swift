import SwiftUI

// #663 自 ChatView.swift 拆出（2026-10-24）：原文件 2896 行、单结构体 + 5 个尾部类型，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ChatView {

    // MARK: - 输入区

    /// 对话模型被关闭时的常驻提示：用户一开始打字就能看到「该启动哪个模型」。
    func modelStoppedBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .appFont(12)
                .foregroundStyle(.red)
            Text(message)
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .appPadding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .appPadding(.top, 10)
    }

    /// 语音输入失败提示（录音/识别出错时贴在输入框上方，可关闭）。
    /// 没有它时，点麦克风失败在对话区是**完全静默**的，用户只会觉得「没反应」。
    @ViewBuilder
    var voiceErrorBanner: some View {
        if let voiceError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .appFont(11)
                    .foregroundStyle(theme.warning)
                Text(voiceError)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissVoiceError?()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
                .help("关闭提示")
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.warning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.warning.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .appPadding(.top, 10)
            .transition(.opacity)
        }
    }

    /// 翻译失败提示（贴在输入框上方，可关闭）。
    @ViewBuilder
    var translationErrorBanner: some View {
        if let translationError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .appFont(11)
                    .foregroundStyle(theme.warning)
                Text(translationError)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissTranslationError?()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
                .help("关闭提示")
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.warning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.warning.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .appPadding(.top, 10)
            .transition(.opacity)
        }
    }

    /// 附件提示（超限 / 导入失败）：说清楚哪个文件为什么没加上，可关闭。
    @ViewBuilder
    var attachmentErrorBanner: some View {
        if let attachmentNotice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .appFont(11)
                    .foregroundStyle(theme.warning)
                Text(attachmentNotice)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissAttachmentNotice?()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
                .help("关闭提示")
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.warning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.warning.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .appPadding(.top, 10)
            .transition(.opacity)
        }
    }

    /// 「当前模型不读图」的提醒。
    ///
    /// 适配器对这类模型的降级是「把图片换成一句『附了一张图 xxx.png』」——**合理但静默**：
    /// 用户以为老师看见了照片，其实只看见文件名。带图之前先说实话。
    @ViewBuilder
    var visionFallbackHint: some View {
        if !llmSupportsVision, pendingAttachments.contains(where: { $0.isImage }) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "eye.slash.fill")
                    .appFont(10)
                    .foregroundStyle(theme.warning)
                Text("当前模型不读图：这些图片会以文件名告诉老师。想让它真的看图，去设置里换一个声明了视觉能力的模型。")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    /// 附件下载成功的回执。与「导入失败」共用一套外观骨架，但语气是**成功**：
    /// 下载是个没有界面变化的动作（文件落到了用户自己挑的目录里），不给回执，
    /// 用户只能去 Finder 里翻，翻不到就会以为没成功、再点一次。
    @ViewBuilder
    var attachmentSavedBanner: some View {
        if let attachmentSaveNotice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .appFont(11)
                    .foregroundStyle(.green)
                Text(attachmentSaveNotice)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissAttachmentSaveNotice?()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
                .help("关闭回执")
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.green.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .appPadding(.top, 10)
            .transition(.opacity)
        }
    }

}
