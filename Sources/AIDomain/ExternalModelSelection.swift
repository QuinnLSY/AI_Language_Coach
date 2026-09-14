import Foundation

/// 「外部模型」面板的选择规则（纯函数）。
///
/// 抽出来的原因：面板里有三处**看着像同一件事、其实是三件事**的判断 ——
/// ① 打开面板要预选哪家厂商；② 那家的绿点亮不亮（它是不是**当前生效**者）；
/// ③ 点开一家厂商时，模型下拉该停在哪一项。
///
/// 这三处过去都写成「读 `capabilityInfos[kind]`」，而 `capabilityInfos` 只覆盖
/// asr / tts / vad / embedding / pronunciation 五项 —— **不含 `llm`**。
/// 于是「AI 大脑」这条路径上三条规则同时退化成默认值，用户看到的就是：
/// 打开面板不定位当前供应商、绿点从来不亮、选好的模型跳回列表第一个
/// （2026-09-14 反馈的第三组问题）。
///
/// 现在规则集中在这里，输入换成一个**覆盖全部能力**的 `activeProviderID`，并用单测钉住。
public enum ExternalModelSelection {

    /// 打开面板时预选哪家厂商。
    ///
    /// 顺序：① 该能力**当前生效**的那家（用户点进来多半是想看/改它）；
    /// ② 用户上次在设置页停在哪家（当前生效的是本地模型时用它兜底，不至于每次都从第一项重来）；
    /// ③ 候选第一家。
    public static func preselectedVendor(
        activeProviderID: String?,
        lastSelected: String?,
        vendors: [String]
    ) -> String? {
        if let activeProviderID, vendors.contains(activeProviderID) { return activeProviderID }
        if let lastSelected, vendors.contains(lastSelected) { return lastSelected }
        return vendors.first
    }

    /// 绿点：这家是不是**当前生效**的那一家。
    ///
    /// 语义必须钉死为「生效」而不是「填过 Key」：用户切走之后旧 Key 草稿还在，
    /// 那时候亮绿点会让人以为还在用它（2026-09-13 反馈过同款误解）。
    public static func isInUse(vendor: String, activeProviderID: String?) -> Bool {
        guard let activeProviderID else { return false }
        return activeProviderID == vendor
    }

    /// 点开一家厂商时，模型下拉停在哪一项。
    ///
    /// - Parameter inUseModel: 若这家**就是**当前生效的那家，传它当前生效的模型；否则传 nil。
    ///
    /// ⚠️ 这个参数必须由调用方按「这家是否生效」筛过再传：`selectedModel` 是**按能力**存的
    /// 全局值、不看 Provider，无脑套用会让 DeepSeek 面板显示本地 qwen3:8b。
    public static func preselectedModel(inUseModel: String?, models: [String]) -> String? {
        if let inUseModel, !inUseModel.isEmpty { return inUseModel }
        return models.first
    }

    /// 下拉要列出的选项：**当前在用的模型即便这次没拉回来也必须留着**。
    ///
    /// 拉取会整体替换列表（供应商下线了某个模型、或换了账号），若当前生效的模型恰好不在
    /// 新列表里，下拉就会「跳回默认模型」—— 而它其实还在生效，界面等于在说谎。
    public static func modelOptions(models: [String], keeping current: String?) -> [String] {
        guard let current, !current.isEmpty else { return models }
        guard !models.contains(current) else { return models }
        return [current] + models
    }

    /// 推理强度选项（`nil` = 「标准」，即不额外下发思考参数）。
    public static func reasoningOptions() -> [(value: String?, label: String)] {
        [(nil, "标准"), ("low", "低"), ("medium", "中"), ("high", "高")]
    }

    /// 配置里存的推理强度 → 下拉里**真的能选中**的值。
    ///
    /// 不认得的档位退回「标准」：否则下拉会因为选中值不在选项里而显示成空白，
    /// 用户看到的是「我设过的东西没了」。
    public static func normalizedReasoning(_ stored: String?) -> String? {
        guard let stored else { return nil }
        return reasoningOptions().contains { $0.value == stored } ? stored : nil
    }

    /// 「已应用」的判断口径：供应商 + 模型 + 推理强度**三者一致**才算数。
    ///
    /// 用它来判断按钮旁那句「已应用到模型卡片」还需不需要显示：用户改了任意一项，
    /// 这句话就该收回 —— 否则界面会谎报「已经生效」。
    public static func selectionSignature(
        providerID: String,
        model: String,
        reasoning: String?
    ) -> String {
        "\(providerID)|\(model)|\(reasoning ?? "")"
    }
}
