import AIInterfaces
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 模型启停 / Provider 切换
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 模型启停（设置页「启动 / 关闭」）

    /// 启动 / 关闭某能力的模型。
    ///
    /// - 本地模型：真的把后台服务拉起 / 停掉（Ollama 载入或卸载模型；语音服务执行配置里的启停命令）。
    /// - 云端 / 内置模型：只做应用层面的开关（外部服务无法被本应用终止）。
    ///
    /// 结果只走顶部弹框（绿=成功 / 红=失败并说明原因），不再塞在设置页卡片里。
    public func setModelRunning(_ kind: AIProviderKind, running: Bool) async {
        guard !modelSwitching.contains(kind) else { return }
        modelSwitching.insert(kind)
        defer { modelSwitching.remove(kind) }
        let label = await services.modelLabel(for: kind)
        do {
            let message = try await services.setModelRunning(kind, running: running)
            showModelToast(message, isSuccess: true)
        } catch {
            let reason = ModelDiagnostics.describe(label: label, error: error)
            showModelToast("\(running ? "启动" : "关闭")失败 · \(reason)", isSuccess: false)
        }
        modelRunStates = await services.modelRunStates()
        await refreshStatus()
        if kind == .asr || kind == .tts { await bootstrapVoice() }
        await refreshCapabilityInfos()
    }

    /// 顶部弹框：成功为绿、失败为红，展示后自动向上收起。
    /// 失败文案更长，多留一点时间让人读完。
    public func showModelToast(_ message: String, isSuccess: Bool) {
        toastDismissTask?.cancel()
        withAnimation(.app(.panel)) {
            modelToast = ModelToast(message: message, isSuccess: isSuccess)
        }
        let duration: ContinuousClock.Duration = isSuccess ? .seconds(2) : .seconds(4)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismissModelToast()
        }
    }

    /// 立刻收起启停弹框（点叉 / 自动到时共用）。
    @MainActor
    public func dismissModelToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        withAnimation(.app(.reveal)) { modelToast = nil }
    }

    /// 对话模型跑在哪儿：本地 = local，云端 = cloud（设置页卡片右上角的状态前缀）。
    public var llmLocationLabel: String { isActiveProviderRemote ? "cloud" : "local" }

    /// 模型提供商卡片右上角那一行：`local.llm · qwen3:8b 已就绪`。
    ///
    /// 前缀说明模型跑在本机还是云端（`local` / `cloud`），后缀是健康状态，
    /// 用户一眼知道自己正在跟哪个模型说话。
    public var llmProviderStatusLine: String {
        let head = "\(llmLocationLabel).llm"
        let model = currentModelName
        let who = (model?.isEmpty ?? true) ? head : "\(head) · \(model ?? "")"
        return ModelDiagnostics.describe(label: who, health: health)
    }

    /// 生效 LLM 的「已就绪 / 连接失败」文案（**带上模型名**，用户一眼知道是哪个模型）。
    public var llmHealthDescription: String {
        ModelDiagnostics.describe(
            providerName: activeProvider?.userFacingName,
            model: currentModelName,
            health: health
        )
    }

    /// 对话模型被关闭时的提示（nil = 正常可对话）。对话区常驻展示。
    public var llmStoppedNotice: String? {
        guard !isModelRunning(.llm) else { return nil }
        return ModelDiagnostics.stoppedHint(
            providerName: activeProvider?.userFacingName,
            model: currentModelName
        )
    }

    /// 刷新今日 token 用量（每次回复完成 / 打开侧边栏时调用）。
    public func refreshTodayTokens() {
        todayTokens = DailyTokenCounter.todayTokens()
    }

    // MARK: - 模型 Provider（本地 / 云端切换）

    /// API Key 解析：**只认输入框**（见 `keyDraft`）。
    func resolvedAPIKey(for providerID: String) async -> String {
        keyDraft(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 设置页：切换选中的 Provider 标签（仅改 UI，不生效）。
    public func selectProviderTab(_ id: String) {
        selectedProviderID = id
        remoteMessage = nil
        reasoningEffortDraft = id == activeProvider?.id ? activeProvider?.reasoningEffort : reasoningEffortDraft
    }

    /// 设置页：激活某个 Provider（本地或云端）。
    ///
    /// 先把输入框里的 Key 落进配置（空 = 清除该供应商的密钥），再切换。
    /// 于是「框里没填 Key」就不可能启用云端——不会出现「已启用却用着旧 Key」的状态。
    public func activateProvider(_ id: String) async {
        do {
            await syncKeyDraft(id, kind: .llm)
            try await services.switchLLMProvider(id)
            bootMessage = nil
            remoteMessage = nil
        } catch {
            remoteMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    /// 设置页：保存云端配置（API Key + 模型 + 推理强度）并激活。
    ///
    /// Key 以输入框为准（空 = 清除），所以「保存」这个动作同时也承担「不再记住这把 Key」。
    /// ⚠️ 与外部模型面板同一条认证闸门：同一把 Key 刚验证成功过才免二次探测，
    /// 否则先真实验证——不过就整路失败，卡片维持原样（2026-09-14 反馈）。
    public func applyRemoteProvider(model: String) async {
        let hasKey = await syncKeyDraft(selectedProviderID, kind: .llm)
        guard hasKey else {
            remoteMessage = "请先填写 API Key。输入框为空时应用不会使用任何已保存的旧密钥，该供应商的密钥已清除。"
            await refreshStatus()
            return
        }
        let apiKey = await resolvedAPIKey(for: selectedProviderID)
        do {
            try await validateExternalKeyIfNeeded(
                kind: .llm, providerID: selectedProviderID, apiKey: apiKey, keyless: false
            )
            try await services.applyRemoteProvider(
                providerID: selectedProviderID,
                apiKey: apiKey,
                model: model,
                reasoningEffort: reasoningEffortDraft,
                kind: .llm
            )
            bootMessage = nil
            externalKeyFingerprints[selectedProviderID] = await remoteKeyFingerprint(providerID: selectedProviderID)
            await refreshStatus()
            // 成功文案与真实健康状态同源（与外部模型面板一致，见 `applyExternalModel`）。
            remoteMessage = health.isUsable
                ? "已启用云端模型 \(model)"
                : health.userFacingDescription
        } catch {
            remoteMessage = error.localizedDescription
        }
        await refreshStatus()
    }

}
