import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

// MARK: - CoachServices · 聊天附件 / 拼写纠正 / 翻译 / 预设提问
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {

// MARK: - 聊天附件（图片 / 视频 / 文件）

/// 把用户选中的文件复制进附件目录并登记。**体积护栏在这里把关**：
/// 超限时抛可读错误，而不是让用户等到「发一句话卡了五分钟」才发现。
public func importAttachment(from url: URL) async throws -> ChatAttachment {
    let name = url.lastPathComponent
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if let reason = AttachmentPolicy.rejectionReason(fileName: name, byteCount: size) {
        throw AppError.configuration(reason)
    }
    return try await attachmentStore.importFile(at: url)
}

/// 读取附件内容（多模态请求内联图片时用）。
public func attachmentData(for attachment: ChatAttachment) async -> Data? {
    await attachmentStore.data(for: attachment)
}

/// 删除附件本体（移除待发附件 / 清理时调用）。
public func removeAttachment(_ attachment: ChatAttachment) async {
    _ = await attachmentStore.remove(attachment)
}

/// 附件目录（设置页「在 Finder 中打开」用）。
public var attachmentDirectory: URL {
    get async { await attachmentStore.storageDirectory }
}

// MARK: - 语音拼写纠正 / 气泡翻译 / 预设提问

/// 语音识别结果的拼写纠正（**仅语音输入使用**；手打内容一律不经过这里）。
///
/// 失败/模型不可用时返回原文——语音输入不能被纠正步骤卡住。
///
/// ⚠️ **只在本地语言模型上执行**。拼写纠正是「用户说完一句话」之后**自动**发生的，
/// 用户既看不到、也不会预期它产生费用。如果语言模型是云端（按 token 计费），
/// 一次语音输入就会多打一次云端请求 —— 本次事故里「点的是语音，账单里却出现
/// 大量语言模型（glm 之类）」正是这条链路。所以云端一律跳过（直接返回原文），
/// 语音输入的云端费用因此变得可推算：一次录音 = 一次识别，仅此而已。
public func correctSpelling(_ text: String) async -> String {
    guard isModelRunning(.llm) else { return text }
    let configuration = await config.current
    let provider = configuration.resolvedProvider(for: .llm)
    guard provider?.isRemote != true else { return text }
    let options = SpellingCorrectionService.Options(
        model: configuration.resolvedModel(for: .llm),
        temperature: 0,
        maxTokens: min(provider?.maxTokens ?? 256, 256),
        learningLanguage: promptLanguage(configuration)
    )
    return await spellingCorrector.correct(text, options: options)
}

/// 拼写纠正当前的执行口径（设置页展示用，让「为什么没有纠正」有据可查）。
public func spellingCorrectionNote() async -> String {
    let configuration = await config.current
    guard let provider = configuration.resolvedProvider(for: .llm) else {
        return "语音输入暂不做拼写纠正：还没有可用的语言模型。"
    }
    if provider.isRemote {
        return "已跳过拼写纠正：它发生在语音输入之后，云端按 token 计费会产生你看不见的费用。切到本地语言模型后自动启用。"
    }
    return "拼写纠正使用本地语言模型，不产生云端费用。"
}

/// 把一条对话内容翻译成学员的母语（**按需**：点翻译按钮才调用）。
/// 结果有界缓存，重复点开不再产生请求；译文不进对话历史，不占上下文。
public func translate(_ text: String, targetLanguage: String) async throws -> String {
    guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
    try await ensureLLMReady()
    let configuration = await config.current
    let provider = configuration.resolvedProvider(for: .llm)
    let options = TranslationService.Options(
        model: configuration.resolvedModel(for: .llm),
        temperature: 0,
        maxTokens: min(provider?.maxTokens ?? 512, 512)
    )
    return try await translator.translate(text, targetLanguage: targetLanguage, options: options)
}

/// 输入框的预设学员提问（数据来自资源文件，代码零硬编码）。
public func starterQuestions() async -> [String] {
    StarterQuestionCatalog.bundled()
}
}
