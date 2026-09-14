import AIDomain
import AIInterfaces
import AppCore
import SwiftUI

/// 「外部模型」统一接入面板（需求 1）。
///
/// 需求原文：把外部调用收成**一个**「外部模型」入口 —— 点开选厂商 → 填该厂商的 API Key →
/// 确认后按**该厂商自己的规则**拉出这个 Key 能用的模型 → 选模型与可配置项（推理强度等）→ 完成接入。
///
/// 为什么必须收成一个入口，而不是继续在卡片里给每家放一个按钮：
/// 兼容格式只会越加越多（OpenAI / AgnesAI / DeepSeek / OpenRouter / Groq / SiliconFlow…），
/// 每加一家就多一个按钮，卡片会被标签行撑爆；而用户真正要做的动作**每一条都一模一样**。
/// 所以把「选哪家」降级成面板里的第一步，卡片上永远只有一个按钮。
///
/// 面板只做编排，**不自己做网络与配置写入**：
/// 拉模型走 `AppState.fetchExternalModels`、落配置走 `AppState.applyExternalModel`，
/// 于是「Key 以输入框为唯一真相」「空框 = 清除旧密钥」这些规则在两条入口上是同一份实现。
struct ExternalModelSheet: View {

    @Environment(\.forestTheme) private var theme

    let kind: AIProviderKind
    /// 该能力可用的外部供应商（id + 展示名，来自配置）。
    let vendors: [(id: String, name: String)]
    let state: AppState
    /// 关闭面板。
    var onClose: () -> Void

    @State private var selectedVendor: String?
    @State private var chosenModel: String?
    @State private var reasoning: String?
    @State private var didPrepare = false

    /// 该供应商是否免密钥（免密钥时没有 Key 可填，直接拉清单）。
    private var isKeyless: Bool {
        guard let selectedVendor else { return false }
        return state.keylessProviders.contains(selectedVendor)
    }

    private var models: [DiscoveredModel] {
        guard let selectedVendor else { return [] }
        return state.externalModels[selectedVendor] ?? []
    }

    private var statusMessage: String? {
        guard let selectedVendor else { return nil }
        return state.externalMessages[selectedVendor]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    vendorStep
                    if selectedVendor != nil { credentialStep }
                    if !models.isEmpty { modelStep }
                    if let statusMessage { statusLine(statusMessage) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(theme.divider)
            footer
        }
        .frame(width: 560, height: 600)
        .background(theme.panel)
        // 用 `id:` 跟着**供应商清单**走：清单可能是面板弹出之后才备好的，
        // 没有这个 id，`prepare()` 就只在「清单还是空」的那一帧跑过一次，预选永远不生效。
        .task(id: vendors.map(\.id)) { await prepare() }
        .onChange(of: selectedVendor) { _, vendor in
            guard let vendor else { return }
            chosenModel = nil
            reasoning = nil
            Task {
                reasoning = await state.storedReasoningEffort(providerID: vendor)
                chosenModel = state.capabilityInfos[kind]?.providerID == vendor
                    ? state.capabilityInfos[kind]?.currentModel
                    : nil
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 15))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("接入外部模型")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("用于「\(kind.displayName)」· 选厂商 → 填 API Key → 选模型")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    // MARK: - ① 选择厂商

    private var vendorStep: some View {
        VStack(alignment: .leading, spacing: 9) {
            stepTitle(index: "1", text: "选择 API 厂商")
            if vendors.isEmpty {
                Text("该能力暂未配置外部供应商。")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            } else {
                // 流式布局：厂商再多也只是换行，不会把卡片撑爆。
                // （需求 1 的原始痛点正是「兼容格式一多，按钮就排不下」。）
                FlowRow(spacing: 8) {
                    ForEach(vendors, id: \.id) { vendor in
                        vendorChip(vendor)
                    }
                }
            }
        }
    }

    private func vendorChip(_ vendor: (id: String, name: String)) -> some View {
        let selected = selectedVendor == vendor.id
        let inUse = state.capabilityInfos[kind]?.providerID == vendor.id
        return Button {
            selectedVendor = vendor.id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cloud.fill").font(.system(size: 9))
                Text(vendor.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                if inUse {
                    // 绿点 = **正在使用**（当前生效的就是它），不是「有 Key 草稿」。
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(selected ? Color.white : theme.primaryText)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? theme.accent : theme.surfaceAlt)
            )
        }
        .buttonStyle(.plain)
        .help(inUse ? "\(vendor.name)：当前正在使用" : "选择 \(vendor.name)")
    }

    private func isKeylessProvider(_ id: String) -> Bool { state.keylessProviders.contains(id) }

    // MARK: - ② API Key

    @ViewBuilder
    private var credentialStep: some View {
        if let selectedVendor {
            VStack(alignment: .leading, spacing: 9) {
                stepTitle(index: "2", text: isKeyless ? "确认接入" : "填写 API Key")
                if isKeyless {
                    HStack(spacing: 8) {
                        Button {
                            Task { await state.fetchExternalModels(kind: kind, providerID: selectedVendor) }
                        } label: {
                            fetchLabel
                        }
                        .buttonStyle(.plain)
                        .disabled(state.isFetchingExternal)
                        Text("免密钥公共服务，无需 API Key")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField("粘贴 \(vendorName(selectedVendor)) 的 API Key", text: Binding(
                            get: { state.keyDraft(for: selectedVendor) },
                            set: { state.setKeyDraft($0, providerID: selectedVendor, kind: kind) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .rounded))
                        .help("API Key 以这个输入框为准：清空即表示不使用该供应商（保存的旧密钥会被清除）。")

                        Button {
                            Task { await state.fetchExternalModels(kind: kind, providerID: selectedVendor) }
                        } label: {
                            fetchLabel
                        }
                        .buttonStyle(.plain)
                        .disabled(state.isFetchingExternal)
                    }
                    // 指纹只在**框里确实有 Key** 时显示：框空着却写「当前使用的密钥」，
                    // 用户会以为应用还在用旧密钥（那是实测反馈过的状态）。
                    if state.hasKeyDraft(selectedVendor),
                       let fingerprint = state.externalKeyFingerprints[selectedVendor] {
                        Text("当前使用的密钥：\(fingerprint)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Text("Key 只存在本机配置里，不会随对话内容外发。填入后点左侧按钮验证并拉取该账号可用的模型。")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private var fetchLabel: some View {
        HStack(spacing: 5) {
            if state.isFetchingExternal {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: kind == .tts ? "antenna.radiowaves.left.and.right" : "key.horizontal")
            }
            Text(kind == .tts ? "接入音色列表" : "验证并获取模型")
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(theme.accent)
    }

    private func vendorName(_ id: String) -> String {
        vendors.first { $0.id == id }?.name ?? id
    }

    // MARK: - ③ 模型与可配置项

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 9) {
            stepTitle(index: "3", text: kind == .tts ? "选择音色" : "选择模型与参数")

            if selectedVendor != nil {
                HStack(spacing: 10) {
                    modelPicker
                    if kind == .llm { reasoningPicker }
                    Spacer()
                }
                Text("共 \(models.count) 个可用\(kind == .tts ? "音色" : "模型")。点右下角「完成接入」才会启用。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 模型下拉。类型检查器对「Picker + ForEach + tag」这种嵌套很敏感，
    /// 单独拆出来可以避免整块 `body` 触发 "unable to type-check in reasonable time"。
    private var modelPicker: some View {
        let selection = Binding<String>(
            get: { chosenModel ?? models.first?.id ?? "" },
            set: { chosenModel = $0 }
        )
        return Picker("模型", selection: selection) {
            ForEach(models) { model in
                Text(model.name).tag(model.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
    }

    private var reasoningPicker: some View {
        Picker("推理强度", selection: $reasoning) {
            Text("标准").tag(String?.none)
            Text("低").tag(String?.some("low"))
            Text("中").tag(String?.some("medium"))
            Text("高").tag(String?.some("high"))
        }
        .labelsHidden()
        .frame(maxWidth: 120)
        .help("推理强度越高越慢、也越贵；日常对话用「标准」即可，需要更好解题质量时再调高。")
    }

    private func stepTitle(index: String, text: String) -> some View {
        HStack(spacing: 6) {
            Text(index)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(theme.accent))
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
        }
    }

    private func statusLine(_ message: String) -> some View {
        let ok = message.contains("成功") || message.contains("已启用")
        return Text(message)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(ok ? Color.green : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("取消", action: onClose)
                .font(.system(size: 12, design: .rounded))
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)

            Button {
                Task { await applyAndMaybeClose() }
            } label: {
                Text("完成接入")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(canApply ? theme.accent : theme.divider)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canApply)
            .help(canApply ? "保存并启用" : "先选好厂商、填好 Key 并拉到模型")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var canApply: Bool {
        guard let selectedVendor else { return false }
        guard !models.isEmpty else { return false }
        if !isKeylessProvider(selectedVendor), !state.hasKeyDraft(selectedVendor) { return false }
        return !(chosenModel ?? models.first?.id ?? "").isEmpty
    }

    private func applyAndMaybeClose() async {
        guard let selectedVendor else { return }
        let model = chosenModel ?? models.first?.id ?? ""
        guard !model.isEmpty else { return }
        await state.applyExternalModel(
            kind, providerID: selectedVendor, model: model, reasoningEffort: reasoning
        )
        // 只有真成功了才关闭：失败时如果也关掉，用户会失去唯一的反馈现场。
        let message = state.externalMessages[selectedVendor] ?? ""
        if message.contains("已启用") { onClose() }
    }

    // MARK: - 打开时的预置

    private func prepare() async {
        // 预选**当前生效**的那家：用户点开面板多半是想看/改它，而不是从第一项重新挑。
        //
        // ⚠️ 预选必须**可重复执行**，不能只做一次：`vendors` 常常是面板弹出**之后**才备好的
        // （从「AI 大脑」进来时供应商缓存还是空的，面板先拿到空数组）。只在首次 task 里选一次，
        // 就会留下「厂商 chip 都显示出来了、却一个都没选中」——用户还得手动多点一下。
        let selectionIsStale = selectedVendor == nil
            || !vendors.contains { $0.id == selectedVendor }
        if selectionIsStale {
            if let active = state.capabilityInfos[kind]?.providerID,
               vendors.contains(where: { $0.id == active }) {
                selectedVendor = active
            } else {
                selectedVendor = vendors.first?.id
            }
        }
        // 草稿（推理强度 / 已选模型）只回填一次：重复回填会在用户已经改动之后把它覆盖掉。
        guard !didPrepare else { return }
        didPrepare = true
        if let selectedVendor {
            reasoning = await state.storedReasoningEffort(providerID: selectedVendor)
            if state.capabilityInfos[kind]?.providerID == selectedVendor {
                chosenModel = state.capabilityInfos[kind]?.currentModel
            }
        }
    }
}
