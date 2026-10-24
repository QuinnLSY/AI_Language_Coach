import AIDomain
import AIInterfaces
import AIInfrastructure
import AIProviders
import AppCore
import Foundation

// MARK: - CoachServices · 语音能力面与克隆音色（第 24 步）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
/// 音色能否启用 / 为什么不能（第 24 步）：把产品口径（显式授权 / 本地文件 / 供应商能力）
/// 落到一处，UI 与测试都只认它。返回空数组 = 可以启用。
public func voiceAccessViolations(for profile: VoiceProfile) async -> [VoiceAccessPolicy.Violation] {
    let supportsCloning = await ttsSupportsVoiceCloning()
    return VoiceAccessPolicy.violations(for: profile, providerSupportsCloning: supportsCloning)
}

/// 当前音色的可见提示（克隆音色必须让用户看得见；nil = 内置音色，无需提示）。
public func voiceActiveIndicator(for profile: VoiceProfile) -> String? {
    VoiceAccessPolicy.activeIndicator(for: profile)
}

// MARK: - 克隆音色（第 24 步）

/// 当前 TTS 供应商**真正可用**的语音能力（音色克隆 / 风格 / 情感 / 音高原生）。
///
/// **实现为权威**：答案一律来自「真正会去做这次合成的那个实现」的 `capabilities()`
/// （那里面已经是 `配置声明 ∩ 实现天花板`，见 `ProviderCapabilities.effectiveVoiceCapabilities`），
/// 配置自报**不能**单独把结论变成「支持」。
///
/// ⚠️ 这条是**唯一**的能力判定入口：`ttsSupportsVoiceCloning()` 取它的一位，
/// 设置页的能力徽标与语气入口也读它。分开各判一套的结果就是「设置页说支持、点了报错」
/// （false capability —— 早先正是「配置声明为真就直接算真」造成的）。
///
/// 尚未装配时按同一个工厂造一个、喂同一份配置再问 ——
/// 既不拿「还没装配」当「不支持」，也不让判定依赖装配时机。
public func ttsVoiceCapabilities() async -> ProviderCapabilities {
    guard let provider = await config.current.resolvedProvider(for: .tts) else {
        return ProviderCapabilities()
    }
    if let live = await tts.current {
        return live.capabilities()
    }
    let adapter = Self.makeTTSProvider(provider)
    try? await adapter.initialize(config: provider)
    return adapter.capabilities()
}

/// 当前 TTS 供应商是否支持音色克隆。
public func ttsSupportsVoiceCloning() async -> Bool {
    await ttsVoiceCapabilities().voiceCloning
}

/// 当前供应商给出的朗读语气候选值（风格 / 情感）。
///
/// 空数组 = 不支持，设置页据此**不渲染**该选择器（宁可没有入口，也不给假入口）。
///
/// ⚠️ 判据是**配置**（能力声明 ∩ 请求形态天花板），而不是上面的 `capabilities()`：
/// 后者只回答「能不能」，回答不出「能的话有哪些取值」。候选值只有供应商知道，应用编不出来。
/// 两者职责不重叠：一个管闸门，一个管取值表。
public func ttsSpeechToneOptions(for capability: VoiceCapability) async -> [String] {
    guard let provider = await config.current.resolvedProvider(for: .tts) else { return [] }
    return provider.toneOptions(for: capability)
}

/// 本次朗读要用的语气：**用户选定值 ∩ 供应商可用能力**，未声明的部分一律为 nil。
///
/// 收在服务层而不是各朗读入口：与音色（`effectiveSpeechVoiceSelection`）同一条理由 ——
/// 六个朗读调用点各判一套，必然出现「对话区发了语气、跟读示范没发」这类一半生效。
/// 未声明的能力返回 nil 还顺带让合成缓存键稳定（供应商不支持时恒定是 `none` 那一份）。
public func effectiveSpeechTone() async -> SpeechTone {
    let configuration = await config.current
    guard let provider = configuration.resolvedProvider(for: .tts) else { return .none }
    let product = configuration.product
    return SpeechTone(
        style: provider.toneOptions(for: .style).isEmpty ? nil : product.speechStyle,
        emotion: provider.toneOptions(for: .emotion).isEmpty ? nil : product.speechEmotion
    )
}

/// 全部音色档案。
public func voiceProfiles() async -> [VoiceProfile] { await voiceProfileStore.all }

/// 发音评测这一次到底是「实测」还是「推断」——配置体检那一行用。
///
/// 报告里也带 `phonemeSource`（那是一次评测的结果），这里说的是**通道现在挂没挂上**：
/// 用户问「为什么我的音素分看着像估的」，答案在通道这一层。
public func pronunciationChannelSummary() async -> String {
    await pronunciation.hasAcousticChannel
        ? "声学通道已挂载 · 音素评分走实测"
        : "没有声学通道 · 音素评分走规则推断（如需实测请在上方接入云端发音评测）"
}

/// 音色档案文件的位置（设置页「数据存放位置」展示 + 「在 Finder 中打开」用）。
///
/// 音色档案是**用户资产**（参考音频 + 授权留痕），与 `config.json` 分开放，
/// 所以位置要单独告诉用户，别让他以为「配置在哪它就在哪」。
public func voiceProfilesLocation() async -> URL { await voiceProfileStore.storageLocation }

/// 当前启用的**克隆**音色档案（nil = 用内置音色）。
public func activeClonedVoice() async -> VoiceProfile? {
    guard let id = await config.current.product.activeVoiceProfileID else { return nil }
    return await voiceProfileStore.profile(id: id)
}

/// 朗读时实际要传给 TTS runtime 的音色选择（克隆音色真正生效的唯一落点）。
///
/// 返回的是**通用音色标识 + 参考音频**：给 runtime 的是「这是谁的音色 + 参考音频在哪」，
/// 至于它内部怎么用（缓存音色 / 每次现场克隆）属于 runtime 的实现。
/// 应用侧因此不出现任何厂商专属调用手段 —— 这正是 Phase 24 的红线。
///
/// ⚠️ 只给一个档案 id 是**不够**的：那是应用本地生成的 UUID，任何 provider 都无法
/// 据此还原音色，那样「已启用克隆音色」就只是个看起来生效的开关。
public func effectiveSpeechVoiceSelection() async -> SpeechVoiceSelection {
    let configuration = await config.current
    guard let id = configuration.product.activeVoiceProfileID,
          let profile = await voiceProfileStore.profile(id: id),
          // 只有克隆音色才带参考音频；内置音色即使误登在档案里也不该走克隆链路。
          profile.isCloned,
          let reference = profile.referenceAudioPath,
          !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .builtin(configuration.product.teacherVoice)
    }
    return SpeechVoiceSelection(
        voice: profile.id,
        referenceAudioPath: reference,
        referenceText: profile.referenceText
    )
}

/// 朗读用的音色标识（内置音色名，或克隆音色档案 id）。
///
/// 只有需要「名字」的场景（诊断、日志、UI 文案）才用它；**真正朗读请走
/// `effectiveSpeechVoiceSelection()`** —— 单给名字会丢掉克隆所需的参考音频。
public func effectiveSpeechVoice() async -> String {
    await effectiveSpeechVoiceSelection().voice
}

/// 保存（新增 / 覆盖）一份音色档案。这里**只存不校验**：
/// 校验发生在启用时（`activateVoiceProfile`），因为「能不能用」取决于当时的供应商能力。
public func saveVoiceProfile(_ profile: VoiceProfile) async throws {
    try await voiceProfileStore.upsert(profile)
}

// MARK: - 音色档案：参考音频 / 启用 / 停用

/// 把用户选中的参考音频**复制**进应用数据目录，返回新路径。
///
/// 为什么必须复制而不是记下原路径：
/// 原文件可能被移动 / 删除 / 在云端盘上被驱逐，那时克隆音色会莫名其妙地失效却查不出原因；
/// 而且「引用任意外部路径」本身就是「拿别人的音频做克隆」的入口，
/// 复制进应用自己的目录后，来源与生命周期都可控（删档案时可一并清理）。
/// 把选中的参考音频**复制**进音色资产目录，返回落盘后的路径。
///
/// 目录取自 `VoiceProfileStore.referenceAudioDirectory`（与 `voice-profiles.json` 同处一室），
/// 而不是在这里自己拼 `AppPaths.userDataDirectory()` —— 后者会让测试进程
/// 无论怎么注入仓库都照样写真实数据目录。
public func importVoiceReference(from sourceURL: URL) async throws -> String {
    let manager = FileManager.default
    // ⚠️ 体积护栏：这一路原来是「连扩展名以外什么都不查」就 `copyItem`。
    // 选到一个 4 GB 的音频，写满的是**应用自己的数据目录** —— 学习库与配置跟它同处一室，
    // 写挂的不只是这一个文件。与聊天附件一样，超限要在这里给出可读理由。
    if let byteCount = ImportLimitPolicy.byteCount(ofFileAt: sourceURL),
       let reason = ImportLimitPolicy.voiceReferenceRejectionReason(
           fileName: sourceURL.lastPathComponent, byteCount: byteCount
       ) {
        throw AppError.configuration(reason)
    }
    let directory = await voiceProfileStore.referenceAudioDirectory
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension.lowercased()
    let destination = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    if manager.fileExists(atPath: destination.path) {
        try manager.removeItem(at: destination)
    }
    do {
        try manager.copyItem(at: sourceURL, to: destination)
    } catch {
        // `FileManager` 抛的是系统原文（英文、不说在干什么）。**动作名由这一层写**：
        // 只有这里知道刚才是为了「保存这个音色」在搬文件；留给 UI 的 catch 去猜，
        // 它就只能再补一句「保存音色失败：」，而 `saveVoiceProfile` 那一路
        // 底层早就写着「保存音色档案失败：」—— 两句动作名叠在一起就是三个冒号。
        throw AppError.storage(
            "没能把这个音频文件读进来（\(sourceURL.lastPathComponent)）：\(error.localizedDescription)"
        )
    }
    return destination.path
}

/// 删除音色档案；若它正是当前启用的那个，一并停用 ——
/// 否则配置里会留下一个指向不存在档案的 id，表现为「朗读时音色突然变回内置」却查不出原因。
public func deleteVoiceProfile(id: String) async throws {
    _ = try await voiceProfileStore.remove(id: id)
    if await config.current.product.activeVoiceProfileID == id {
        try await config.mutateProduct { $0.activeVoiceProfileID = nil }
    }
}

/// 启用克隆音色。**违反合规口径就直接抛错**并带上可读原因，
/// 绝不「先启用再说」—— `VoiceAccessPolicy` 是不可绕过的硬闸门。
public func activateVoiceProfile(id: String) async throws {
    guard let profile = await voiceProfileStore.profile(id: id) else {
        throw AppError.configuration("找不到这个音色档案。")
    }
    let violations = await voiceAccessViolations(for: profile)
    guard violations.isEmpty else {
        throw AppError.configuration(violations.map(\.userMessage).joined(separator: " "))
    }
    try await config.mutateProduct { $0.activeVoiceProfileID = id }
}

/// 停用克隆音色（回到内置音色）。
public func deactivateClonedVoice() async throws {
    try await config.mutateProduct { $0.activeVoiceProfileID = nil }
}
}
