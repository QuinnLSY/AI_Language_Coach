import AIDomain
import AIInterfaces
import AppCore
import AppKit
import SwiftUI

// #662 自 SettingsView.swift 拆出（2026-10-24）：原文件 3227 行、单结构体 22 个 MARK 段，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

extension SettingsView {
    // MARK: - 教师朗读（已并入模型管理中心的教师语音板块）

    /// 语音服务的在线状态 + 重新检测 + 最近错误。
    ///
    /// 原来是独立「语音」卡片的头部。卡片合并进模型管理中心后，这段仍然要有：
    /// 它是唯一能一眼看到「识别 / 教师朗读 现在通不通」的地方。
    var voiceServiceStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                voiceStatusDot("识别", state.asrHealth)
                voiceStatusDot("教师朗读", state.ttsHealth)
                Spacer()
                Button {
                    Task { await state.bootstrapVoice() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.appPressable)
                .help("重新检测语音服务")
                .accessibilityLabel("重新检测语音服务")
            }

            if let error = state.voiceError {
                Text(error)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.warning)
            }

            // 语音链路的费用口径：拼写纠正在说完一句话后自动发生，用户看不见，
            // 所以必须写出来——云端语言模型下一律跳过，语音输入不会产生 token 费用。
            if !state.spellingNote.isEmpty {
                Text(state.spellingNote)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .appPadding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt.opacity(0.6)))
    }

    // MARK: - 克隆音色（第 24 步：音色定制与克隆）

    /// 音色克隆：显式授权 + 本地参考音频 + 启用时可见提示。
    ///
    /// 需求原文（Phase 24）就是这几条，界面上一步都不能省：
    /// 授权说明必填、参考音频只能从本机选、启用后必须看得见正在用哪个克隆音色。
    /// 至于「怎么拿参考音频做克隆」属于 runtime 的实现 —— 应用只交给它一个通用音色标识。
    @ViewBuilder
    var clonedVoiceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(theme.divider.opacity(0.6))

            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .appFont(11)
                    .foregroundStyle(theme.accent)
                Text("克隆音色")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 4)
                Text(state.voiceCloningSupported ? "当前供应商支持克隆" : "当前供应商未声明支持克隆")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(state.voiceCloningSupported ? theme.accent : theme.secondaryText)
            }

            Text("只用本人或已获授权的声音。参考音频会复制进本机应用目录，不上传；启用后老师就用它朗读。")
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let indicator = state.activeVoiceIndicator {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .appFont(10)
                        .foregroundStyle(theme.accent)
                    Text(indicator)
                        .appFont(11, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 4)
                    Button("切回内置") { Task { await state.deactivateClonedVoice() } }
                        .buttonStyle(.appPressable)
                        .appFont(10, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.accent)
                }
                .padding(.horizontal, 8)
                .appPadding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent.opacity(0.10)))
            }

            let cloned = state.voiceProfiles.filter(\.isCloned)
            if cloned.isEmpty, pendingReferenceURL == nil {
                Text("还没有克隆音色。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(cloned) { profile in
                clonedVoiceRow(profile)
            }

            if let url = pendingReferenceURL {
                pendingVoiceForm(referenceURL: url)
            } else {
                Button {
                    pickReferenceAudio()
                } label: {
                    Label("从本地音频新建…", systemImage: "plus.circle")
                        .appFont(11, weight: .semibold, design: .rounded)
                }
                .buttonStyle(.appPressable)
                .foregroundStyle(theme.accent)
            }

            if let notice = state.voiceProfileNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .appFont(10)
                        .foregroundStyle(theme.accent)
                    Text(notice)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        state.clearVoiceProfileNotice()
                    } label: {
                        Image(systemName: "xmark").appFont(9)
                    }
                    .buttonStyle(.appPressable)
                    .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    /// 一条克隆音色档案：启用 / 停用 / 删除。
    @ViewBuilder
    private func clonedVoiceRow(_ profile: VoiceProfile) -> some View {
        let isActive = state.activeClonedVoice?.id == profile.id
        HStack(spacing: 8) {
            Image(systemName: isActive ? "waveform.circle.fill" : "waveform.circle")
                .appFont(13)
                .foregroundStyle(isActive ? theme.accent : theme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Text(profile.consent?.statement ?? "")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(isActive ? "停用" : "启用") {
                Task {
                    if isActive {
                        await state.deactivateClonedVoice()
                    } else {
                        await state.activateClonedVoice(id: profile.id)
                    }
                }
            }
            .buttonStyle(.appPressable)
            .appFont(11, weight: .semibold, design: .rounded)
            .foregroundStyle(isActive ? theme.secondaryText : theme.accent)

            Button {
                Task { await state.deleteClonedVoice(id: profile.id) }
            } label: {
                Image(systemName: "trash").appFont(10)
            }
            .buttonStyle(.appPressable)
            .foregroundStyle(theme.secondaryText)
            .help("删除这个音色档案")
            .accessibilityLabel("删除音色档案：\(profile.displayName)")
        }
    }

    /// 新建表单：音频已选定，等用户填名字与授权说明。
    @ViewBuilder
    private func pendingVoiceForm(referenceURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(referenceURL.lastPathComponent)
                .appFont(10, design: .monospaced)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("音色名字（如「我的声音」）", text: $pendingVoiceName)
                .textFieldStyle(.roundedBorder)
                .appFont(12, design: .rounded)
            TextField("授权说明：声音来源与使用范围（必填）", text: $pendingConsent)
                .textFieldStyle(.roundedBorder)
                .appFont(12, design: .rounded)
            HStack(spacing: 10) {
                Button("保存") {
                    let url = referenceURL
                    Task {
                        await state.createClonedVoice(
                            name: pendingVoiceName,
                            referenceURL: url,
                            consentStatement: pendingConsent
                        )
                        pendingReferenceURL = nil
                        pendingVoiceName = ""
                        pendingConsent = ""
                    }
                }
                .appFont(11, weight: .semibold, design: .rounded)
                .disabled(pendingVoiceName.trimmingCharacters(in: .whitespaces).isEmpty
                          || pendingConsent.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("取消") {
                    pendingReferenceURL = nil
                    pendingVoiceName = ""
                    pendingConsent = ""
                }
                .buttonStyle(.appPressable)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
            }
        }
        .appPadding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.surfaceAlt))
    }

    /// 选择参考音频：只认本机文件 —— 面板给不出 URL 之外的来源，
    /// 从入口上就堵死了「填一个远端地址做克隆」这条路。
    private func pickReferenceAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择一段本地录音作为参考音频（仅使用本人或已获授权的声音）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingVoiceName = ""
        pendingConsent = ""
        pendingReferenceURL = url
    }

    /// 老师朗读的行为设置：音色 / 语速 / 自动朗读。
    ///
    /// 从原独立「语音」卡片整体搬进**教师语音**能力区块——模型与朗读行为放在一起，
    /// 配完模型顺手就能调「怎么读」，不用在两个卡片之间来回找。
    @ViewBuilder
    var teacherVoiceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(theme.divider.opacity(0.6))

            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .appFont(11)
                    .foregroundStyle(theme.accent)
                Text("老师怎么读")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }

            // 教师音色 + 自动试听小喇叭
            HStack(spacing: 10) {
                ForestSelect(
                    "老师的声音",
                    icon: "waveform",
                    selection: Binding(
                        get: { state.teacherVoice },
                        set: { voice in Task { await state.setVoice(voice) } }
                    ),
                    options: teacherVoiceOptions,
                    width: 170,
                    help: "教师朗读时使用的声音；云端音色由供应商决定，切换后会自动重读。"
                )

                // 小喇叭：开启后切换音色自动试听
                Button {
                    Task { await state.setVoicePreview(!state.voicePreviewEnabled) }
                } label: {
                    Image(systemName: state.voicePreviewEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .appFont(12, weight: .semibold)
                        .foregroundStyle(state.voicePreviewEnabled ? theme.accent : theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.surfaceAlt))
                        .overlay(Circle().strokeBorder(state.voicePreviewEnabled ? theme.accent.opacity(0.4) : theme.divider, lineWidth: 1))
                }
                .buttonStyle(.appPressable)
                .help(state.voicePreviewEnabled ? "自动试听已开启：切换音色即朗读示例（点此关闭）" : "自动试听已关闭（点此开启，切换音色即朗读示例）")

                // 立即试听
                Button {
                    Task { await state.speak("Nice to meet you!") }
                } label: {
                    Image(systemName: "play.circle")
                        .appFont(14)
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.appPressable)
                .help("立即试听当前音色")
            }

            // 朗读语速：与对话区「听老师读」右侧的选择器共用同一份配置。
            // 档位行的排版抽在 `SpeechToneRow` 里（与下面的调门共用一份配方，
            // 也正因为抽出来了，它才能被离屏渲染用例单独出图）。
            SpeechToneRow(
                title: "朗读语速",
                options: SpeechRate.allCases.map { option in
                    .init(
                        value: option.rawValue,
                        label: option.label,
                        help: "以 \(option.label) 语速朗读",
                        isSelected: isSelected(rate: option)
                    )
                },
                onSelect: { option in Task { await state.setSpeechRate(option.value) } }
            )

            // 朗读调门：与语速是**两条独立的旋钮** —— 语速改快慢、调门改音高，互不影响。
            // 它由**播放侧**实现（`AVAudioUnitTimePitch.pitch`），所以不依赖任何供应商能力，恒可用；
            // 四条语音链路没有一条给得出音高参数，走合成侧就是「做完也没效果」。
            SpeechToneRow(
                title: "朗读调门",
                options: SpeechPitch.allCases.map { option in
                    .init(
                        value: option.rawValue,
                        label: option.label,
                        help: "以\(option.detail)朗读（只改音高、不改快慢）",
                        isSelected: isSelected(pitch: option)
                    )
                },
                onSelect: { option in Task { await state.setSpeechPitch(option.value) } }
            )

            // 朗读语气（风格 / 情感）：**只有供应商真给了候选值才渲染**。
            // 今天四条语音链路都没有这两个字段位，所以这一段在真机上是空的 ——
            // 这不是没接通，而是接通之后如实沉默；供应商一支持，这里就自己亮起来
            // （判定与取值表都在 `TeacherVoiceTone.controls` 这个纯函数里，视图不做判断）。
            ForEach(TeacherVoiceTone.controls(
                options: state.speechToneOptions,
                selectedStyle: state.speechStyle,
                selectedEmotion: state.speechEmotion
            )) { control in
                ForestSelect(
                    control.title,
                    icon: "theatermasks",
                    selection: Binding(
                        get: { control.selected ?? TeacherVoiceTone.unspecified },
                        set: { value in
                            Task { await state.setSpeechTone(control.capability, value) }
                        }
                    ),
                    options: [ForestSelectOption(value: TeacherVoiceTone.unspecified, title: "不指定")]
                        + control.options.map { ForestSelectOption(value: $0, title: $0) },
                    // 宽度**量**出来（候选值长短由供应商决定，写死会被截成省略号，
                    // 而截断在控件的几何空档里看不出来 —— 2026-09-14 的「语速不显示」就是这么来的）。
                    width: ForestSelect<String>.Metrics.regular
                        .widthFitting([ "不指定" ] + control.options),
                    help: control.help
                )
            }

            Toggle("老师回复后自动朗读", isOn: Binding(
                get: { state.autoSpeak },
                set: { enabled in Task { await state.setAutoSpeak(enabled) } }
            ))
            .appFont(13, design: .rounded)

            // 朗读方式随当前生效的语音模型自动切换，在这里说清楚，免得用户以为是 bug。
            Text("\(state.speechDelivery.explanation)在聊天框点 🎤 说话，松开后文字会填进输入框；每条老师回复下方可点「听老师读」，右侧小胶囊可切换朗读语速（只改快慢、不变音调），调门与语气则在上面这一组里调。")
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(3)

            // 供应商语音能力**如实写在设置页**：这四个能力位（克隆 / 风格 / 情感 / 原生音高）
            // 以前在整仓里没有任何读点，配置里声明了也没人看得见，等于不存在。
            // ⚠️ 什么都没声明时整行不显示 —— 「未声明」不该被显示成「支持：无」这种看着像故障的话。
            if let summary = state.voiceCapabilities.voiceCapabilitySummary {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .appFont(10)
                        .foregroundStyle(theme.accent)
                    Text("当前供应商支持：\(summary)")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 语速档位是否当前选中（浮点比较留容差）。
    private func isSelected(rate: SpeechRate) -> Bool {
        abs(SpeechRate.nearest(to: state.speechRate).rawValue - rate.rawValue) < 0.01
    }

    /// 调门档位是否当前选中。**先落到最近档再比** —— 配置被手改成 `1.4` 时，
    /// 界面上「高 1」那一档该亮着，而不是一档都不亮（那种画面看起来像控件坏了）。
    private func isSelected(pitch: SpeechPitch) -> Bool {
        abs(SpeechPitch.nearest(to: state.speechPitch).rawValue - pitch.rawValue) < 0.01
    }

    private func voiceStatusDot(_ title: String, _ health: ProviderHealth) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(health.isUsable ? Color.green : theme.warning)
                .frame(width: 8, height: 8)
            Text("\(title) · \(health.userFacingDescription)")
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.secondaryText)
        }
    }
}
