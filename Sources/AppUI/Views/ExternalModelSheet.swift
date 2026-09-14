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
    /// 最近一次「确认配置」成功时的选择签名（供应商+模型+推理强度）。
    ///
    /// 用它判断「已应用」这句话还需不需要显示：用户改了任意一项就该收回 ——
    /// 否则界面会谎报「已经生效」。
    @State private var appliedSignature: String?
    /// API Key 输入框的焦点。**显式管理**：AppKit 的失焦不会自动同步回 SwiftUI，
    /// 而「点外面却仍被锁定」正是用户反馈的第一个问题。
    @FocusState private var isKeyFieldFocused: Bool

    /// 该供应商是否免密钥（免密钥时没有 Key 可填，直接拉清单）。
    private var isKeyless: Bool {
        guard let selectedVendor else { return false }
        return state.keylessProviders.contains(selectedVendor)
    }

    private var models: [DiscoveredModel] {
        guard let selectedVendor else { return [] }
        return state.externalModels[selectedVendor] ?? []
    }

    /// 这家厂商是不是**当前生效**的那一家（绿点 / 模型回填的唯一判据）。
    ///
    /// ⚠️ 读 `state.activeProviderIDs` 而不是 `capabilityInfos`：后者不含 `llm`，
    /// 「AI 大脑」那条路上永远查不到，绿点不亮、模型跳回默认（2026-09-14 反馈）。
    private func isInUse(_ vendor: String) -> Bool {
        ExternalModelSelection.isInUse(vendor: vendor, activeProviderID: state.activeProviderIDs[kind])
    }

    /// 这家厂商当前生效的模型（只有生效者是它时才有值）。
    private var activeModelForVendor: String? {
        guard let selectedVendor, isInUse(selectedVendor) else { return nil }
        return state.activeModels[kind]
    }

    /// 下拉当前应当显示的模型：用户的选择优先，其次才是「当前在用的那个」。
    private var effectiveModel: String? {
        chosenModel ?? activeModelForVendor
    }

    /// 下拉要列出的模型：把「在用的模型」补进去，即使这次拉取的结果里没有它。
    private var modelOptions: [DiscoveredModel] {
        let ids = ExternalModelSelection.modelOptions(
            models: models.map(\.id), keeping: effectiveModel
        )
        let titles = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.name) })
        return ids.map { DiscoveredModel(id: $0, name: titles[$0] ?? $0) }
    }

    /// 当前选择的签名（与「已应用」比对）。
    private var currentSignature: String? {
        guard let selectedVendor, let model = effectiveModel, !model.isEmpty else { return nil }
        return ExternalModelSelection.selectionSignature(
            providerID: selectedVendor, model: model, reasoning: reasoning
        )
    }

    private var didApplyCurrentSelection: Bool {
        appliedSignature != nil && appliedSignature == currentSignature
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
                    if !modelOptions.isEmpty { modelStep }
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
        // 点输入框之外的任何地方（按钮 / 下拉 / 空白）都让 Key 输入框交出焦点：
        // 否则光标一直闪，快捷键也一直被打进输入框（用户反馈的第一个问题）。
        .releaseKeyboardFocusOnOutsideClick { isKeyFieldFocused = false }
        // 用 `id:` 跟着**供应商清单**走：清单可能是面板弹出之后才备好的，
        // 没有这个 id，`prepare()` 就只在「清单还是空」的那一帧跑过一次，预选永远不生效。
        .task(id: vendors.map(\.id)) { await prepare() }
        .onChange(of: selectedVendor) { _, vendor in
            guard vendor != nil else { return }
            Task { await refreshSelectionForCurrentVendor() }
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
        let inUse = isInUse(vendor.id)
        return Button {
            selectedVendor = vendor.id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cloud.fill").font(.system(size: 9))
                Text(vendor.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(selected ? Color.white : theme.primaryText)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? theme.accent : theme.surfaceAlt)
            )
            // 绿点 = **正在使用**（当前生效的就是它），不是「有 Key 草稿」。
            // 位置在按钮**右上角**：与名称并排会被长的厂商名挤走，也让「选中态」
            // 和「生效态」在同一水平线上打架；挂到角上两者各占一个维度，一眼可分。
            .overlay(alignment: .topTrailing) {
                if inUse {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        // 用面板底色描一圈，压在按钮边缘时也看得清。
                        .overlay(Circle().strokeBorder(theme.panel, lineWidth: 1.2))
                        .offset(x: 3, y: -3)
                }
            }
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
                        // 显式绑焦点：点外面能收起（见 `releaseKeyboardFocusOnOutsideClick`），
                        // 应用/切换厂商时也能主动放开。
                        .focused($isKeyFieldFocused)
                        .help("API Key 以这个输入框为准：清空即表示不使用该供应商（保存的旧密钥会被清除）。")

                        Button {
                            isKeyFieldFocused = false
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
            Text(fetchActionTitle)
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
                HStack(spacing: 14) {
                    // 「模型：」「推理强度：」——标签负责说明**这个框选什么**，
                    // 值只显示在框里，两者不混在一起。
                    // 控件用应用自己的 `ForestSelect`（系统 Picker 的外观改不动，与整体不搭）。
                    ForestSelect(
                        "模型",
                        icon: kind == .tts ? "waveform" : "cpu",
                        selection: modelSelection,
                        options: modelOptions.map {
                            ForestSelectOption(value: $0.id, title: $0.name)
                        },
                        width: kind == .tts ? 210 : 250
                    )
                    if kind == .llm {
                        ForestSelect(
                            "推理强度",
                            icon: "dial.medium",
                            selection: $reasoning,
                            options: ExternalModelSelection.reasoningOptions().map {
                                ForestSelectOption(value: $0.value, title: $0.label)
                            },
                            width: 108,
                            help: "推理强度越高越慢、也越贵；日常对话用「标准」即可，需要更好解题质量时再调高。"
                        )
                    }
                    Spacer(minLength: 0)
                }
                Text(modelHint)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 模型选择：值是模型 id（`DiscoveredModel.id` 就是发给服务端的模型名）。
    private var modelSelection: Binding<String> {
        Binding(
            get: { effectiveModel ?? modelOptions.first?.id ?? "" },
            set: { chosenModel = $0 }
        )
    }

    private var modelHint: String {
        let unit = kind == .tts ? "音色" : "模型"
        if models.isEmpty {
            // 列表还没拉过、但「当前在用的模型」已知（配置里存着）：说清楚现在用的是什么，
            // 而不是干巴巴地写「共 0 个可用模型」让人以为配置坏了。
            guard let current = effectiveModel else {
                return "尚未获取\(unit)列表：点上面的「\(fetchActionTitle)」。"
            }
            return "当前使用的是 \(current)。点上面的「\(fetchActionTitle)」可拉取该账号下的完整\(unit)列表。"
        }
        let head = "共 \(models.count) 个可用\(unit)。"
        return didApplyCurrentSelection
            ? head + "当前选择已启用。"
            : head + "点右下角「确认配置」才会启用。"
    }

    private var fetchActionTitle: String {
        kind == .tts ? "接入音色列表" : "验证并获取模型"
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
            if didApplyCurrentSelection {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                    Text("已应用到模型卡片")
                        .font(.system(size: 10, design: .rounded))
                }
                .foregroundStyle(Color.green)
            }
            Spacer()

            Button("关闭") { onClose() }
                .font(.system(size: 12, design: .rounded))
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)

            Button {
                Task { await applySelection() }
            } label: {
                Text("确认配置")
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
            .help(canApply ? "保存并启用（面板不会自动关闭，可继续调整）" : "先选好厂商、填好 Key 并拉到模型")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var canApply: Bool {
        guard let selectedVendor else { return false }
        guard !models.isEmpty || effectiveModel != nil else { return false }
        if !isKeylessProvider(selectedVendor), !state.hasKeyDraft(selectedVendor) { return false }
        return !(effectiveModel ?? "").isEmpty
    }

    private func applySelection() async {
        guard let selectedVendor else { return }
        let model = effectiveModel ?? ""
        guard !model.isEmpty else { return }
        // 配置写完就放手焦点：用户接下来多半是去隔壁点关闭，不该被输入框继续吃掉按键。
        isKeyFieldFocused = false
        await state.applyExternalModel(
            kind, providerID: selectedVendor, model: model, reasoningEffort: reasoning
        )
        // ⚠️ **成功也不自动关闭**（用户明确要求）。
        //
        // 面板是「边调边看」的地方：卡片就在它后面，配置生效的结果要不要收、什么时候收，
        // 应该由用户决定。自动消失会让人以为「我的改动没生效 / 是不是被弹没了」。
        // 这里只把「已应用」记下来（与当前选择签名绑定，改了任意一项就自动收回）。
        if (state.externalMessages[selectedVendor] ?? "").contains("已启用") {
            appliedSignature = currentSignature
        }
    }

    // MARK: - 打开时的预置

    private func prepare() async {
        let ids = vendors.map(\.id)
        // 预选**当前生效**的那家：用户点开面板多半是想看/改它，而不是从第一项重新挑。
        //
        // ⚠️ 两个都必须可重复执行：
        // ① 供应商清单常常是面板弹出**之后**才备好的（从「AI 大脑」进来时缓存还是空的），
        //    只在首次 task 里选一次，就会留下「chip 都显示出来了、却一个都没选中」；
        // ② 当前生效者可能在这一轮之后才确定（用户先在面板里配了另一家）。
        let selectionIsStale = selectedVendor == nil
            || !ids.contains(selectedVendor ?? "")
        if selectionIsStale {
            selectedVendor = ExternalModelSelection.preselectedVendor(
                activeProviderID: state.activeProviderIDs[kind],
                lastSelected: state.externalSelectedProvider[kind.rawValue],
                vendors: ids
            )
        }
        // 草稿（推理强度 / 已选模型）只回填一次：重复回填会在用户已经改动之后把它覆盖掉。
        guard !didPrepare else { return }
        didPrepare = true
        await refreshSelectionForCurrentVendor()
    }

    /// 把「这家厂商当前该显示的模型与推理强度」回填进面板。
    ///
    /// 三件事一起做，缺任何一个都会让用户看到「我的选择丢了」：
    /// ① 生效模型回填（只有这家确实是当前生效者时）；
    /// ② 推理强度回填（配置里存的那一档，不认得的档位退回「标准」）；
    /// ③ 若在用的模型不在本次列表里，把它保留在选项里（拉取会整体替换列表）。
    private func refreshSelectionForCurrentVendor() async {
        guard let vendor = selectedVendor else {
            chosenModel = nil
            reasoning = nil
            return
        }
        // 先把上一个厂商的模型草稿清掉：否则「上次选的模型」会被当成「这家在用的模型」
        // 并进选项里，面板看起来像「每家都能选到别家的模型」。
        chosenModel = nil
        reasoning = ExternalModelSelection.normalizedReasoning(
            await state.storedReasoningEffort(providerID: vendor)
        )
        chosenModel = ExternalModelSelection.preselectedModel(
            inUseModel: activeModelForVendor,
            models: modelOptions.map(\.id)
        )
    }
}
