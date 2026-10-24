import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

// MARK: - CoachServices · 模型启停 / 本地服务 / 资源管理（第 27 步）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 模型启动 / 关闭（设置页）

/// 某能力当前是否处于「启动」状态。
///
/// 语义是**用户意图**：应用打开时所有模型默认为启动态（不会被持久化成关闭）。
/// 用户显式关闭与资源管理挂起都算「没在运行」，但恢复路径不同（见 `suspendedKinds`）。
public func isModelRunning(_ kind: AIProviderKind) -> Bool {
    !stoppedKinds.contains(kind) && !suspendedKinds.contains(kind)
}

/// 测试夹具专用：把一个能力直接标成「已关闭」，`isModelRunning` 立刻返回 false。
///
/// ⚠️ 与 `setModelRunning(_:running:false)` 的差别是**不碰任何真实服务**。
/// 默认配置里 `ollama.llm` / `remote.kina-tts` 都是启用态，于是夹具一上手就会
/// 顺着 `ensureLLMReady()` / `playReference()` 去打真服务 —— 实测一条用例
/// 47s 真推理、另一条 30s 真合成，而它们断言的根本不是模型输出。
/// 若改走 `setModelRunning` 关停，它会连带 `syncSiblingLocalServices` 去
/// `pkill` 本机代理（授权闸门一旦被同进程别的用例打开就会真杀），夹具付不起这个代价。
///
/// 存在意义只有一个：让「考试作答零请求」在夹具层可执行。
// periphery:ignore - 只服务于测试夹具，产品路径一律走 setModelRunning
public func markStoppedForTests(_ kind: AIProviderKind) {
    stoppedKinds.insert(kind)
    suspendedKinds.remove(kind)
}

/// 全部能力的启停快照（UI 展示用）。
public func modelRunStates() -> [AIProviderKind: Bool] {
    var result: [AIProviderKind: Bool] = [:]
    for kind in AIProviderKind.allCases { result[kind] = isModelRunning(kind) }
    return result
}

/// 打开 / 关闭一个能力的模型。
///
/// - 本地模型（实现了 `ModelServiceControlling`）：真的把后台服务拉起来 / 停掉。
/// - 云端 / 内置模拟：只做应用层面的开关（外部服务无法被本应用终止）。
///
/// - Returns: 面向用户的一句话说明（告诉用户刚才到底发生了什么）。
@discardableResult
public func setModelRunning(_ kind: AIProviderKind, running: Bool) async throws -> String {
    let configuration = await config.current
    let providerConfig = configuration.resolvedProvider(for: kind)
    let providerName = providerConfig?.userFacingName
    let model = configuration.resolvedModel(for: kind)
    let who = ModelDiagnostics.label(providerName: providerName, model: model)

    if running {
        // 记住点击前的状态：启动失败必须回滚，否则界面会显示「已启动」骗人。
        let wasRunning = isModelRunning(kind)
        stoppedKinds.remove(kind)
        suspendedKinds.remove(kind)
        do {
            // 同时拉起同一能力下的兄弟本地服务（如 Edge-TTS 本地代理），让「启动」按钮
            // 真正覆盖所有本地后端，而不只是当前生效的那个 Provider。
            await self.syncSiblingLocalServices(kind: kind, running: true)
            if let controller = await serviceController(for: kind) {
                try await controller.startModelService()
                await rebootstrap(kind: kind)
                return "\(who) 已启动：后台服务已拉起。"
            }
            await rebootstrap(kind: kind)
            // ⚠️ 应用层面的「启动」不能无条件报成功（2026-09-14 反馈：Key 已失效，
            // 弹窗却写「已启动」）。没有后台服务可拉的能力，启动的实质是
            // 「确认这条链路现在真的可用」——所以这里做一次真实健康探测，
            // 不通就按失败处理（红色弹窗 + 原因），而不是提前弹绿。
            if let health = await currentHealth(for: kind) {
                guard health.isUsable else {
                    throw Self.startFailure(health)
                }
                // 发音评测没有只读探测端点，配置级检查不能冒充「连接已校验」——
                // 弹窗说的话必须与真实发生过的事一致（2026-09-14 的同一条教训）。
                if kind == .pronunciation {
                    return "\(who) 已启用（应用层面）：配置完整，真正的联网校验会在第一次跟读时进行。"
                }
                return "\(who) 已启动（应用层面）：连接校验通过。"
            }
            return "\(who) 已启动（应用层面）。"
        } catch {
            if !wasRunning { stoppedKinds.insert(kind) }
            throw error
        }
    }

    stoppedKinds.insert(kind)
    // 同时停掉同一能力下的兄弟本地服务（如 Edge-TTS 本地代理）。
    await self.syncSiblingLocalServices(kind: kind, running: false)
    if let controller = await serviceController(for: kind) {
        do {
            try await controller.stopModelService()
            return "\(who) 已关闭：后台服务已下线，不再占用资源。"
        } catch {
            // 关闭失败也保持「关闭」状态（应用层面照样不再调用它），但把原因告诉用户。
            throw AppError.unknown(ModelDiagnostics.describe(providerName: providerName, model: model, error: error))
        }
    }
    return "\(who) 已关闭（应用层面）：不会再被调用。"
}

/// 该能力背后可真实启停的服务控制器；不支持时返回 nil。
private func serviceController(for kind: AIProviderKind) async -> (any ModelServiceControlling)? {
    switch kind {
    case .llm: llmProvider as? any ModelServiceControlling
    case .asr: await asr.current as? any ModelServiceControlling
    case .tts: await tts.current as? any ModelServiceControlling
    default: nil
    }
}

/// Edge-TTS 本地代理在配置里的 Provider id（跑在本机 127.0.0.1:8856 的轻量服务）。
private static let edgeTTSProxyProviderID = "remote.kina-tts"

/// 把同一能力下「兄弟本地服务」一并启停。
///
/// 场景：TTS 能力下可能并存多个本地服务（Qwen3 本地 TTS 于 8855、Edge-TTS 本地代理于 8856）。
/// 点 TTS 的「启动 / 关闭」应当同时拉起 / 停掉所有这些本地后端，而不只是当前生效的那一个——
/// 否则选了 Edge 音色、却只在按钮上看到 Qwen3 被控制，代理永远起不来。
///
/// 默认生效 Provider 若本身由 `ModelServiceControlling` 控制器处理（本地主模型），会被跳过以免重复拉起。
/// 兄弟服务失败不影响主链路：例如 Qwen3 起来即可朗读，代理失败不阻断。
private func syncSiblingLocalServices(kind: AIProviderKind, running: Bool) async {
    let configuration = await config.current
    guard let resolvedID = configuration.resolvedProvider(for: kind)?.id else { return }
    let hasController = await serviceController(for: kind) != nil
    for provider in configuration.providers where provider.kind == kind && provider.enabled {
        let hasCommands = !(provider.serviceStartCommand ?? "").isEmpty
            && !(provider.serviceStopCommand ?? "").isEmpty
        guard hasCommands else { continue }
        // ⚠️ 用户点的是「主服务」的启停，兄弟服务的命令同样要过授权闸门（#S2-6）；
        // 没授权就跳过，不在这里报错 —— 那会让一次正常点击变成满屏红字。
        let command = running ? (provider.serviceStartCommand ?? "") : (provider.serviceStopCommand ?? "")
        guard ShellCommandApproval.isApproved(command) else {
            AppLog.info("跳过未授权的兄弟服务命令（\(provider.id)）", category: "service")
            continue
        }
        // 已由主控制器处理的那个（本地主 Provider）跳过，避免重复拉起
        if provider.id == resolvedID, hasController { continue }
        do {
            if running {
                try await LocalServiceControl.start(config: provider)
            } else {
                try await LocalServiceControl.stop(config: provider)
            }
        } catch {
            // 兄弟服务失败不影响主链路，但必须留痕：否则用户点了「关闭」以为进程停了，
            // 实际还占着显存，而任何界面上都看不到原因。
            AppLog.warning(
                "本地服务\(running ? "启动" : "关闭")失败（\(provider.id)）：\(error.localizedDescription)",
                category: "service"
            )
        }
    }
}

/// 开屏自启一个本地服务的结果（#546：自启可见性）。
///
/// 「没起来」必须让用户看得见：未授权 / 失败从前只有日志，用户只会觉得
/// 「朗读没声音」「麦克风用不了」，完全不知道服务根本没起来。
public enum LocalServiceLaunchOutcome: Sendable, Equatable {
    /// 本次启动真的执行了启动命令，且服务已可达。
    case started
    /// 服务本来就在跑（用户自己拉的或上次残留），未执行任何命令。
    case alreadyRunning
    /// 没配启动命令 / 当前选的不是本地 Provider —— 不是每个用户都用本机服务。
    case notConfigured
    /// 启动命令还没得到用户确认（#S2-6）。**带上命令原文**：提示条的动作直接
    /// 把它摆进确认框，不依赖「设置页点启动」—— Edge-TTS 代理没有服务控制器，
    /// 那条路对它只会静默跳过（`syncSiblingLocalServices`），永远弹不出确认框。
    case needsApproval(command: String)
    /// 启动命令执行了但服务没起来（带上原因）。
    case failed(String)
}

/// 应用启动时默认拉起 Edge-TTS 本地代理（remote.kina-tts）：它是免费微软音色（如
/// en-GB-SoniaNeural）的来源，如今跑在本机 127.0.0.1:8856。只处理这一个轻量代理，
/// 不动 Qwen3 等重型本地模型（后者仍由设置页「启动」按钮按需拉起，避免拖慢开屏）。
///
/// 最佳努力、不阻断启动；代理已运行时跳过（脚本幂等，端口被占用直接退出）。
/// - Returns: 本次自启的结果（#546：未授权 / 失败要变成用户可见的提示）。
@discardableResult
public func ensureEdgeTTSProxyOnLaunch() async -> LocalServiceLaunchOutcome {
    let configuration = await config.current
    guard let provider = configuration.providers.first(where: {
        $0.id == Self.edgeTTSProxyProviderID && $0.kind == .tts && $0.enabled
    }) else { return .notConfigured }
    guard let command = provider.serviceStartCommand, !command.isEmpty else { return .notConfigured }
    // ⚠️ 未获用户授权的命令**不执行**（#S2-6）。开屏路径没有任何交互机会，
    // 所以这里只能是「跳过 + 留痕」：执行了就等于让一份备份包里的命令自动开跑。
    guard ShellCommandApproval.isApproved(command) else {
        AppLog.info(
            "开屏未拉起教师语音代理：它的启动命令还没得到你的确认（可在设置里点「启动」后确认）",
            category: "service"
        )
        return .needsApproval(command: command)
    }
    // 端口已被占用（代理在跑）就直接跳过，避免重复拉起
    if let endpoint = provider.endpoint,
       await LocalServiceRunner.waitUntilReachable(endpoint: endpoint, timeout: 1.5, interval: 0.3) {
        return .alreadyRunning
    }
    do {
        try await LocalServiceControl.start(config: provider, reachTimeout: 12)
        return .started
    } catch {
        // 启动失败不阻断应用，但这一次的失败必须留痕：原注释假设「用户会去设置页
        // 再点一次」，而开屏这一次在本次启动内没有任何出口 —— 用户只会觉得
        // 「朗读没声音」，完全不知道代理根本没起来。
        AppLog.warning(
            "开屏拉起教师语音代理失败：\(error.localizedDescription)",
            category: "service"
        )
        return .failed(error.localizedDescription)
    }
}

/// **当前选中的本机语音识别服务**随应用一起起来。
///
/// 用户挑了本机 whisper 做语音识别，进应用后麦克风就该能用 —— 否则每一次冷启动
/// 都要先去设置里点一次「启动」，而这一步连着力都看不出来（模型只是在后台载入）。
///
/// 与 Edge-TTS 代理同一套打法：最佳努力、不阻断开屏；服务已经在跑就直接跳过
/// （whisper 载入几百 MB 权重要十几秒，重复拉一次很贵）。
///
/// - Returns: 本次自启的结果（#546：未授权 / 失败要变成用户可见的提示）。
@discardableResult
public func ensureLocalASROnLaunch() async -> LocalServiceLaunchOutcome {
    let configuration = await config.current
    guard let provider = configuration.resolvedProvider(for: .asr), provider.enabled else { return .notConfigured }
    // ⚠️ 命令要从**补齐后的**配置里取：存量用户的配置文件是加这个字段之前写下的，
    // 合并时整条 provider 替换会把内置默认的命令吞掉（`ConfigStore.merge`）——
    // 不补的话，本机语音识别永远只能靠用户手动点「启动」。
    let launchable = Self.fillServiceCommands(provider)
    guard let command = launchable.serviceStartCommand, !command.isEmpty else { return .notConfigured }
    // ⚠️ 未获授权就不执行（#S2-6），理由同 ensureEdgeTTSProxyOnLaunch。
    guard ShellCommandApproval.isApproved(command) else { return .needsApproval(command: command) }
    guard let endpoint = launchable.endpoint, !endpoint.isEmpty else { return .notConfigured }
    // 端口已经通了（服务在跑）就跳过。
    if await LocalServiceRunner.waitUntilReachable(endpoint: endpoint, timeout: 1.5, interval: 0.3) {
        return .alreadyRunning
    }
    do {
        try await LocalServiceControl.start(config: launchable, reachTimeout: 25)
        return .started
    } catch {
        // 启动失败不阻断应用：用户在设置里点「启动」能看到真实原因。
        return .failed(error.localizedDescription)
    }
}

/// 退出应用：停掉**本进程亲手拉起**的本地服务（自停）。
///
/// 台账来自 `LaunchedLocalServices`：只有启动成功的服务在册；用户自己拉起的服务
/// （启动前就在跑）不在册、退出时不碰；Ollama 的 keep_alive 载入不走启动入口，
/// 同样不会被误停。停止成功即注销，失败留在台账里，下次退出重试。
///
/// 最佳努力、不抛错：单个服务停不掉（未授权 / 超时 / 命令失败）只进摘要，
/// 绝不阻断退出 —— 退出路径没有任何交互机会。
/// - Parameter stopTimeout: 单个停止命令的最长等待秒数。各服务并发执行，总耗时不乘数量。
/// - Returns: 没能停掉的服务摘要（`provider id：原因`，按序排序）；空数组 = 全部停妥或无可停。
public func stopServicesStartedByApp(stopTimeout: TimeInterval = 4) async -> [String] {
    let started = await LaunchedLocalServices.shared.snapshot()
    guard !started.isEmpty else { return [] }
    // 没配停止命令的 Provider（如 Ollama —— 停它等于杀掉用户的常驻应用）不碰。
    let stoppable = started.filter {
        !($0.serviceStopCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let withoutCommand = started.count - stoppable.count
    guard !stoppable.isEmpty else { return [] }

    var leftovers: [String] = []
    await withTaskGroup(of: (String, String?).self) { group in
        for config in stoppable {
            group.addTask {
                // ⚠️ 未授权的命令不执行（#S2-6）：退出路径没有弹确认框的机会，只能跳过。
                guard ShellCommandApproval.isApproved(config.serviceStopCommand ?? "") else {
                    return (config.id, "停止命令还没得到你的确认")
                }
                do {
                    try await LocalServiceControl.stop(config: config, timeout: stopTimeout)
                    return (config.id, nil)
                } catch {
                    return (config.id, error.localizedDescription)
                }
            }
        }
        for await (id, reason) in group {
            if let reason { leftovers.append("\(id)：\(reason)") }
        }
    }

    leftovers.sort()
    let stoppedCount = stoppable.count - leftovers.count
    if leftovers.isEmpty {
        AppLog.info(
            "退出应用：已停止本应用拉起的 \(stoppedCount) 个本地服务"
                + (withoutCommand > 0 ? "（\(withoutCommand) 个未配停止命令，保持原样）" : ""),
            category: "service"
        )
    } else {
        AppLog.warning(
            "退出应用：\(leftovers.count)/\(stoppable.count) 个本地服务未能停止 —— \(leftovers.joined(separator: "；"))",
            category: "service"
        )
    }
    return leftovers
}

/// 该能力当前生效 Provider 的真实健康状态；尚无真实 runtime 的能力返回 nil。
///
/// 「启动」按钮对云端 / 无后台服务的能力必须用**真实探测**说话——
/// 弹窗与实际连通性脱节就是 2026-09-14 反馈的第四组问题。
private func currentHealth(for kind: AIProviderKind) async -> ProviderHealth? {
    switch kind {
    case .llm: await llmHealth()
    case .asr: await asrHealth()
    case .tts: await ttsHealth()
    case .pronunciation: await pronunciationHealth()
    default: nil
    }
}

/// 发音评测的健康状态。
///
/// 配置齐全就当可用，但**不宣称「连接校验通过」**：发音评测没有只读探测端点，
/// 真要验证连通性就得发一段音频（= 花钱）。所以这里只验配置，真实连通性在
/// 第一次跟读时才揭晓——`setModelRunning` 的文案也必须与此一致。
private func pronunciationHealth() async -> ProviderHealth {
    let health = await bootstrapPronunciation()
    return health
}

/// 健康状态 → 抛给「启动」弹窗的错误。
///
/// 用 `AIProviderError` 而不是 `AppError`：失败弹窗走 `ModelDiagnostics.describe`，
/// 它对 `AIProviderError` 会产出「谁 · 配置有误：<服务端原话>」这类完整句子；
/// 传 `AppError` 会多包一层「配置错误：」前缀。注意这里传的是**未加前缀的原始原因**
/// （`userFacingDescription` 自带「配置有误：」，再传就重复了）。
private static func startFailure(_ health: ProviderHealth) -> AIProviderError {
    switch health {
    case .connected:
        return .invalidConfiguration("未知原因")
    case .configurationInvalid(let reason):
        return .invalidConfiguration(reason)
    case .runtimeUnavailable(let reason):
        return .runtimeUnavailable(reason)
    case .modelUnavailable(let model):
        return .modelUnavailable(model)
    case .requestFailed(let reason):
        return .connectionFailed(reason)
    }
}

// MARK: - 资源管理（第 27 步：ModelLifecycleManager 的落点）

/// 资源管理自动挂起一个能力（区别于用户关闭：下次被使用时自动恢复）。
///
/// 本地模型真的把后台服务停掉（复用「关闭」的服务控制链路，如 Ollama `keep_alive:0`）；
/// 云端 / mock 只做应用层面挂起。返回面向用户的一句话说明。
@discardableResult
public func suspendModel(_ kind: AIProviderKind) async throws -> String {
    guard !stoppedKinds.contains(kind) else { return "\(await modelLabel(for: kind)) 已被用户关闭，无需挂起。" }
    guard !suspendedKinds.contains(kind) else { return "\(await modelLabel(for: kind)) 已处于挂起状态。" }

    suspendedKinds.insert(kind)
    if let controller = await serviceController(for: kind) {
        do {
            try await controller.stopModelService()
            return "\(await modelLabel(for: kind)) 已自动挂起：空闲释放资源，需要时会自动恢复。"
        } catch {
            // 停服务失败就退回启动态，避免「服务还在跑却显示挂起」的假状态。
            suspendedKinds.remove(kind)
            throw AppError.unknown("\(await modelLabel(for: kind)) 自动挂起失败：\(error.localizedDescription)")
        }
    }
    return "\(await modelLabel(for: kind)) 已自动挂起（应用层面）：不会再被调用。"
}

/// 若该能力被资源管理挂起，则自动恢复（拉起服务 + 重装配）。返回是否真的执行了恢复。
///
/// 用户显式关闭的能力**不会**在这里被拉起（那是明确意图，交给用户自己点「启动」）。
@discardableResult
public func resumeIfSuspended(_ kind: AIProviderKind) async throws -> Bool {
    guard suspendedKinds.contains(kind) else { return false }
    _ = try await setModelRunning(kind, running: true)
    return true
}

/// 资源管理视角下各能力的快照（供 `ResourcePolicy` 决策）。
public func resourceStates() async -> [ResourcePolicy.ModelState] {
    var states: [ResourcePolicy.ModelState] = []
    for kind in AIProviderKind.allCases {
        // 云端 Provider 挂不挂是外部服务的事，本应用无从「释放内存」；
        // 没有真实服务控制器的（云端 / mock / 未装配）一律视为不可挂起。
        let unloadable = await serviceController(for: kind) != nil
        let idle: Double?
        switch kind {
        case .llm: idle = await llm.idleSeconds
        case .asr: idle = await asr.idleSeconds
        case .tts: idle = await tts.idleSeconds
        default: idle = nil
        }
        states.append(.init(
            kind: kind,
            isUnloadable: unloadable,
            isUserStopped: stoppedKinds.contains(kind),
            isSuspended: suspendedKinds.contains(kind),
            idleSeconds: idle
        ))
    }
    return states
}

/// 执行一次资源巡检：读内存压力 → 策略决策 → 逐个挂起。返回下次巡检间隔（秒）。
///
/// 由 `ModelLifecycleManager` 周期调用；测试可注入假监控直接驱动。
@discardableResult
public func runResourceTick(monitor: any MemoryPressureMonitoring) async -> Double {
    let configuration = await config.current
    let policy = configuration.resourcePolicy
    let idleTimeouts: [AIProviderKind: Double] = {
        var timeouts: [AIProviderKind: Double] = [
            .llm: policy.llmIdleUnloadMinutes * 60,
            .asr: policy.asrIdleUnloadMinutes * 60,
        ]
        if let ttsMinutes = policy.ttsIdleUnloadMinutes {
            timeouts[.tts] = ttsMinutes * 60
        }
        return timeouts
    }()
    let budget = ResourcePolicy.MemoryBudget(minAvailableBytes: policy.minAvailableMemoryMB * 1_048_576)
    let available = monitor.availableMemoryBytes().map(Double.init)
    let states = await resourceStates()
    let decisions = ResourcePolicy.suspendDecisions(
        states: states,
        idleTimeouts: idleTimeouts,
        activeWindowSeconds: policy.activeWindowMinutes * 60,
        budget: budget,
        availableMemoryBytes: available
    )
    for kind in decisions {
        do {
            let message = try await suspendModel(kind)
            AppLog.info("资源管理：\(message)", category: "lifecycle")
        } catch {
            AppLog.warning("资源管理挂起 \(kind.displayName) 失败：\(error.localizedDescription)", category: "lifecycle")
        }
    }
    return policy.tickSeconds
}
}
