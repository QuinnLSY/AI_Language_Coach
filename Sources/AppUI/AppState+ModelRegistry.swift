import AIDomain
import AIInterfaces
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 模型管理中心 + 云端调用审计
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 模型管理中心（本地检测 + 外部模型）

    /// 刷新各能力的模型信息快照（设置页打开 / 检测按钮时调用）。
    public func refreshCapabilityInfos() async {
        // 顺手修掉「本地模型名被写进云端供应商」的历史坏配置（只做一次，幂等）。
        // 这种模型名在云端不可能成立，留着只会让界面显示错误、调用必然失败。
        if !didHealCrossProviderModels {
            didHealCrossProviderModels = true
            let healed = await services.healCrossProviderModels()
            if !healed.isEmpty {
                modelHealNotice = "已修好 \(healed.map(\.displayName).joined(separator: "、")) 的配置：清掉云端上错写的本地模型名、关闭了那个外部接口，并切回本地模型"
                    + "（云端没有这个模型，留着只会一直调用失败）。如需改用云端，请在这些能力的「外部模型」里重新验证并选择模型。"
                // ⚠️ 配置换了 Provider，必须重新装配 + 重取健康状态。
                // 否则界面会拿**上一个 Provider 的旧体检结果**去描述新的 Provider——
                // 实测就是刚切回本地，卡片却写着「配置有误：API Key 无效或已过期」。
                if healed.contains(where: { $0 == .asr || $0 == .tts }) {
                    await bootstrapVoice()
                }
                for kind in healed where kind != .asr && kind != .tts {
                    await services.rebootstrap(kind: kind)
                }
            }
        }
        let configuration = await services.configuration
        // ⚠️ 顺手把本地 product 缓存对齐服务端。
        //
        // 这里必须同步：任何写配置的路径（切云端、选模型、启停）结束后都会调本方法，
        // 若缓存留着旧的 activeProviders / selectedModels，之后任何一次 persistProduct
        // （改主题、改语速、点动画开关…）都会用旧缓存**整体回写**，把刚生效的
        // 「已启用云端模型」抹回未配置——实测症状就是卡片显示已启用、实际仍是未配置。
        product = configuration.product
        var result: [AIProviderKind: CapabilityModelInfo] = [:]
        for kind in [AIProviderKind.asr, .tts, .vad, .embedding, .pronunciation] {
            let provider = configuration.resolvedProvider(for: kind)
            // 记忆索引的「本地模型」与「AI 大脑」一致：优先从 runtime 实际发现
            // （本机 Ollama 的嵌入模型 / 云端可选模型），不再是只读 ~/AI_Models 目录。
            let localModels: [LocalModel]
            if kind == .embedding {
                // 记忆索引与 ASR 同构：`~/AI_Models/embedding/` 目录里部署的模型
                // 照常扫描出来（带真实路径，可显示「本地 · 路径」）；
                // 再并入 runtime 实际发现的模型（本机 Ollama 的嵌入模型）。
                // 目录结果在前；Ollama 结果按名字去重后补在后面，
                // 路径用 `ollama://` 合成值——`LocalModel.id` 是 path，空串会撞 id。
                var merged = LocalModelScanner.scan(kind: kind)
                let discovered = await services.availableEmbeddingModels()
                let onDisk = Set(merged.map(\.name))
                for model in discovered where !onDisk.contains(model.name) {
                    merged.append(LocalModel(name: model.name, path: "ollama://\(model.id)"))
                }
                localModels = merged
            } else {
                localModels = LocalModelScanner.scan(kind: kind)
            }

            let healthOK: Bool
            let healthText: String
            switch kind {
            case .asr:
                healthOK = asrHealth.isUsable
                healthText = ModelDiagnostics.describe(
                    providerName: provider?.userFacingName,
                    model: product.selectedModel(for: kind) ?? provider?.model,
                    health: asrHealth
                )
            case .tts:
                healthOK = ttsHealth.isUsable
                healthText = ModelDiagnostics.describe(
                    providerName: provider?.userFacingName,
                    model: product.selectedModel(for: kind) ?? provider?.model,
                    health: ttsHealth
                )
            case .embedding:
                // ⚠️ 别再按「内置模拟」报：默认配置里这条是**真的本地索引**（Ollama + 嵌入模型），
                // 说成模拟会让用户以为这一栏永远关着。这里真的问一次接通没有 ——
                // 每个进程只装配一次，失败就如实说「退回结构化」。
                await services.ensureEmbeddingReady()
                healthOK = await services.isSemanticMemoryEnabled
                if healthOK {
                    // 装配成功 ≠ 现在还能用：Ollama 可能是开屏时在跑、之后被关掉了。
                    // 只报「已接通」会让用户以为检索在走语义，实际早就退回结构化顺序了。
                    embeddingHealth = await services.embeddingHealth()
                    healthText = embeddingHealth.isUsable
                        ? "已接通 · 按与当前话题的相关度取回记忆"
                        : "已启用，但服务当前不可用（\(embeddingHealth.userFacingDescription)）· 暂时按结构化顺序取回"
                } else {
                    healthText = "未接通 · 记忆按结构化顺序取回（不影响练习）"
                }
            case .pronunciation:
                // 发音评测没有独立 runtime：没接云端时走本地规则推断（真实存在），
                // 接了外部 Provider 还没接通就说「等待接入」。不再报「内置模拟」——
                // 没有那种东西，如实说才不会让用户以为有个模拟引擎在跑。
                healthOK = false
                healthText = provider?.runtime == .externalLocalRuntime ? "等待接入" : "本地规则推断 · 未接云端"
            default:
                // 说话检测（vad）没有任何 runtime，设置页已不展示这张卡（去假）；
                // 这里只兜住数据面，文案不再粉饰。
                healthOK = false
                healthText = "暂未启用"
            }

            let current = product.selectedModel(for: kind) ?? provider?.model
            let source: String
            switch provider?.runtime {
            case .remoteAPI:
                // 没选定模型时要说清「现在不会调用任何云端模型」——这是费用护栏的对外口径，
                // 不能让用户以为自己选好了、实际却在打账号里某个没选的模型。
                source = current == nil
                    ? "\(provider?.userFacingName ?? "云端") · 尚未选择模型（不会发起任何调用）"
                    : "\(provider?.userFacingName ?? "云端") 提供的云端模型"
            case .externalLocalRuntime, .ollama:
                if let current, let path = LocalModelScanner.path(of: current, kind: kind) {
                    source = "本地 · \(path)"
                } else if let endpoint = provider?.endpoint {
                    source = "本地服务 · \(endpoint)"
                } else {
                    source = "本地模型"
                }
            default:
                // ⚠️ 只有 runtime 真的是 mock 才叫「内置模拟」。本地嵌入（Ollama）也是非云端
                // runtime，却是一条真链路，写成模拟等于把已接通的功能说成没接。
                if provider?.runtime == .mock {
                    source = "内置模拟（无需配置）"
                } else if let endpoint = provider?.endpoint, !endpoint.isEmpty {
                    source = "本地服务 · \(endpoint)"
                } else {
                    source = provider == nil ? "未配置" : "内置模拟（无需配置）"
                }
            }

            result[kind] = CapabilityModelInfo(
                kind: kind,
                healthOK: healthOK,
                healthText: healthText,
                currentModel: current,
                sourceDescription: source,
                isRemote: provider?.isRemote ?? false,
                providerName: provider?.userFacingName,
                providerID: provider?.id,
                localModels: localModels
            )
        }
        capabilityInfos = result
        // 「各能力当前生效的 Provider / 模型」快照：**覆盖全部能力**（含 llm，
        // 它不在 `capabilityInfos` 里但同样需要）。外部模型面板的预选、绿点、
        // 模型回填与模型卡片的展示都读它，因此必须是「配置里生效的结果」而不是草稿。
        var activeIDs: [AIProviderKind: String] = [:]
        var activeModelNames: [AIProviderKind: String] = [:]
        for kind in AIProviderKind.allCases {
            if let provider = configuration.resolvedProvider(for: kind) {
                activeIDs[kind] = provider.id
            }
            if let model = configuration.resolvedModel(for: kind), !model.isEmpty {
                activeModelNames[kind] = model
            }
        }
        activeProviderIDs = activeIDs
        activeModels = activeModelNames
        spellingNote = await services.spellingCorrectionNote()
        // 顺带刷新云端调用审计：设置页的「对外调用记录」卡片要和模型信息同时是最新的。
        await refreshRemoteCalls()
        // 供应商一变，外发口径就变了：这里顺手重算，避免隐私卡片停留在旧结论上
        //（用户刚切回本地模型，卡片却还写着「正在使用云端服务」是不可接受的）。
        await refreshPrivacy()
    }

    // MARK: - 云端调用审计（费用护栏留痕）

    /// 刷新对外调用审计（打开设置 / 每次模型信息刷新时调用）。
    public func refreshRemoteCalls() async {
        remoteCallSummary = await services.remoteCallSummary()
        remoteCallRecords = await services.recentRemoteCalls(limit: 12)
    }

    /// 清空本次运行的审计记录（磁盘上的留痕保留，便于事后与账单对账）。
    public func clearRemoteCalls() async {
        await services.resetRemoteCalls()
        await refreshRemoteCalls()
    }

    /// 审计文件的绝对路径（用户可直接打开核对）。
    public var remoteCallLogPath: String { CoachServices.remoteCallLogURL().path }

    /// 选择本地检测到的模型（~/AI_Models）：**先把该能力切回本地 Provider**，再设模型。
    ///
    /// 修的就是「切换本地模型后没有关闭外部模型接口、且显示错误」这件事：
    /// 旧实现只调 `setCapabilityModel`，而它写的是「当前生效的 Provider」——
    /// 云端正生效时，就把本地模型名（如 `ggml-small.en`）写进了**云端**供应商，
    /// 云端既没被关掉，界面还显示成「SiliconFlow 语音识别 · ggml-small.en」。
    public func selectLocalModel(_ kind: AIProviderKind, name: String) async {
        do {
            let configuration = await services.configuration
            guard let local = Self.localProvider(for: kind, in: configuration) else {
                throw AppError.configuration("该能力没有可用的本地 Provider，无法切换到本地模型。")
            }
            // ① 真正切到本地：同类其它 Provider 一律停用，云端接口就此关闭。
            try await services.setCapabilityProvider(kind, providerID: local.id)
            // ② 再把模型写到这个本地 Provider 上。
            try await services.setCapabilityModel(kind, model: name)
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        await refreshCapabilityInfos()
    }

    /// 某能力的本地 Provider（非云端那一个）。
    ///
    /// 真实本地 runtime（Ollama / 外部本地服务）优先于 mock：
    /// 记忆索引同时有 `ollama.embedding` 与 `mock.embedding` 时，本地模型选择器
    /// 应当切到 Ollama，而不是把模型名写进 mock（mock 会忽略 model 字段）。
    nonisolated static func localProvider(
        for kind: AIProviderKind,
        in configuration: AppConfiguration
    ) -> ProviderConfig? {
        let locals = configuration.providers.filter { $0.kind == kind && !$0.isRemote }
        if let real = locals.first(where: { $0.runtime != .mock }) { return real }
        return locals.first
    }

    /// 手动填写模型名并应用。
    ///
    /// 名字能在本地扫描结果里找到 → 按「切到本地」处理（顺带关掉云端接口）；
    /// 否则视为给**当前生效的那家**供应商指定模型（本地 / 云端都合法），
    /// 由云端闸门的「模型必须属于该供应商」兜住串线。
    public func applyCustomModel(_ kind: AIProviderKind, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if LocalModelScanner.path(of: trimmed, kind: kind) != nil {
            await selectLocalModel(kind, name: trimmed)
        } else {
            do {
                try await services.setCapabilityModel(kind, model: trimmed)
                bootMessage = nil
            } catch {
                bootMessage = error.localizedDescription
            }
            await refreshCapabilityInfos()
        }
        customModelDrafts[kind.rawValue] = ""
    }

    /// 打开设置页时，按**已保存的配置**回填外部模型草稿。
    ///
    /// 修掉三个「每次都要重来一遍」的痛点（用户实测反馈）：
    /// 1. **API Key 不回填** → 明明存过，界面上却是空框，用户以为丢了、要重新输；
    /// 2. **模型列表只活在「本次点过验证」的内存里** → 重开设置选择器就空了，无法直接切换；
    /// 3. **选中标签默认落在候选第一家** → 而不是用户上次真正在用的那一家。
    ///
    /// 只补**空**的位置：用户当下正在输入的内容不会被配置覆盖。
    public func prefillExternalDrafts() async {
        let configuration = await services.configuration
        for provider in configuration.providers where provider.isRemote {
            let saved = (provider.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Key 草稿按**卡片归属**分开填：语言模型走「云端 Provider」区块（apiKeyDrafts），
            // 其余能力走各自卡片里的「外部模型」区块（externalKeyDrafts）。
            // 两个字典都填会出事：用户在能力卡里清空输入框后，另一个字典里的旧值会把 Key「复活」，
            // 于是又回到「框里空着，应用却还在用旧密钥」——那正是这次要杜绝的行为。
            if !clearedKeyDrafts.contains(provider.id) {
                if provider.kind == .llm {
                    if (apiKeyDrafts[provider.id] ?? "").isEmpty { apiKeyDrafts[provider.id] = saved }
                } else if (externalKeyDrafts[provider.id] ?? "").isEmpty {
                    externalKeyDrafts[provider.id] = saved
                }
            }
            // 指纹只在**输入框里确实有 Key** 时才显示：框是空的就不该出现「当前使用的密钥」，
            // 那会让用户以为应用还在用旧密钥（实测反馈，截图里就是这个状态）。
            externalKeyFingerprints[provider.id] = hasKeyDraft(provider.id) ? provider.keyFingerprint : nil
            // 候选模型 + 该 Provider 当前模型 + 该能力产品层选中的模型：
            // 三者合并去重，保证选择器既能列出历史候选，也能显示「现在用的是哪个」。
            // ⚠️ 语音供应商优先用**音色清单**（friendly 名）：它们的「模型」就是音色，
            // 且静态清单随配置分发——打开设置就能选，不必先点一次「接入音色列表」。
            var models: [DiscoveredModel]
            if provider.kind == .tts, let voices = provider.voices, !voices.isEmpty {
                models = voices.map { voice in
                    DiscoveredModel(id: voice, name: provider.voiceLabel(for: voice) ?? voice)
                }
                if let model = provider.model, !model.isEmpty, !voices.contains(model) {
                    models.insert(DiscoveredModel(id: model, name: model), at: 0)
                }
            } else {
                // 候选模型的来源分两档，**不能混为一谈**：
                //   ① Provider 自己在配置里声明的 model / candidate_models —— 属于它，带上；
                //   ② 产品层当前选中的模型 —— 只有**这家就是这个能力的生效 Provider** 时才带上。
                //
                // ②这个限定是必须的：`product.selectedModel(for:)` 是**按能力**存的全局值，
                // 不看 Provider。无脑并进来，用户打开 DeepSeek 面板就会看到本地 Ollama 的
                // qwen3:8b 被列成「DeepSeek 可用模型」，页脚还写着「共 1 个可用模型」——
                // 既误导选择，也可能真的选中它去发一个必然失败的请求。
                var ids = provider.candidateModels
                if let own = provider.model, !own.isEmpty, !ids.contains(own) {
                    ids.insert(own, at: 0)
                }
                let isActiveForKind = configuration.resolvedProvider(for: provider.kind)?.id == provider.id
                if isActiveForKind,
                   let selected = configuration.product.selectedModel(for: provider.kind),
                   !selected.isEmpty,
                   !ids.contains(selected) {
                    ids.insert(selected, at: 0)
                }
                models = ids.map { DiscoveredModel(id: $0, name: $0) }
            }
            guard !models.isEmpty else { continue }
            if (externalModels[provider.id] ?? []).isEmpty { externalModels[provider.id] = models }
        }
        // 选中标签：优先落在该能力**当前生效**的云端 Provider 上（本地生效则维持原样）。
        for kind in AIProviderKind.allCases {
            guard let active = configuration.resolvedProvider(for: kind), active.isRemote else { continue }
            externalSelectedProvider[kind.rawValue] = active.id
        }
    }

}
