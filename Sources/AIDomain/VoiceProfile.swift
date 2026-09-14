import Foundation

/// 教师音色档案（第 24 步：声纹定制与克隆）。
///
/// 这一步**产品口径比技术更重要**：克隆音色默认关闭、必须显式授权、只处理本地文件、
/// 启用时要有明确提示。所以先把这套「合规地基」定下来（纯逻辑、可单测）；
/// 至于用哪个克隆模型（GPT-SoVITS / Qwen3-TTS / Chatterbox）属于后续接入，
/// 不会改变这里的规则。
public struct VoiceProfile: Sendable, Equatable, Identifiable, Codable {

    public enum Kind: String, Sendable, Equatable, Codable {
        /// 内置音色（随模型发布，无需授权）。
        case builtin
        /// 克隆 / 自定义音色（必须授权 + 本地参考音频）。
        case cloned
    }

    public var id: String
    public var displayName: String
    public var kind: Kind
    /// 参考音频路径。克隆音色必需，且**必须是本地文件**（不接受 URL）。
    public var referenceAudioPath: String?
    /// 参考文本（可选：部分模型做音色克隆时需要）。
    public var referenceText: String?
    /// 授权记录。克隆音色必需。
    public var consent: VoiceConsent?
    public var createdAt: Date

    public init(
        id: String,
        displayName: String,
        kind: Kind = .builtin,
        referenceAudioPath: String? = nil,
        referenceText: String? = nil,
        consent: VoiceConsent? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.referenceAudioPath = referenceAudioPath
        self.referenceText = referenceText
        self.consent = consent
        self.createdAt = createdAt
    }

    public var isCloned: Bool { kind == .cloned }
}

/// 克隆用声的**显式授权**记录。
///
/// 没有这份记录就不允许启用克隆音色 —— 这是不可绕过的前置条件（见 `VoiceAccessPolicy`）。
public struct VoiceConsent: Sendable, Equatable, Codable {
    /// 用户对使用范围的声明（如「本人声音」「已获对方书面同意」）。
    public var statement: String
    public var grantedAt: Date

    public init(statement: String, grantedAt: Date = Date()) {
        self.statement = statement
        self.grantedAt = grantedAt
    }

    public var isUsable: Bool { !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - 可用性规则（纯函数）

/// 音色可用性规则：把第 24 步的产品口径收成可单测的纯函数。
///
/// 规则来源（Implementation Plan §28 Phase 24）：
/// - explicit user consent（显式授权）
/// - only user-owned or authorized voices（只用本人或已授权的声音）
/// - local processing by default（默认本地处理 → 参考音频必须是本地文件）
/// - no third-party voice cloning workflow（不接第三方克隆流程）
public enum VoiceAccessPolicy {

    /// 违反项。每项都带可读文案，便于直接提示用户而不是吞掉。
    public enum Violation: String, Sendable, Equatable, CaseIterable {
        case missingConsent
        case emptyConsent
        case missingReference
        case referenceNotLocal
        case providerNotCloningCapable

        public var userMessage: String {
            switch self {
            case .missingConsent: "克隆音色需要先确认授权（仅使用本人或已获授权的声音）。"
            case .emptyConsent: "授权说明不能为空，请写明声音来源与使用范围。"
            case .missingReference: "克隆音色需要一段本地参考音频。"
            case .referenceNotLocal: "参考音频必须是本地文件 —— 不接入第三方音频地址。"
            case .providerNotCloningCapable: "当前语音供应商不支持音色克隆。"
            }
        }
    }

    /// 是否必须先有授权（内置音色不需要）。
    public static func requiresConsent(_ profile: VoiceProfile) -> Bool { profile.isCloned }

    /// 校验音色能否被启用。**返回空数组 = 可以启用**。
    ///
    /// - Parameter providerSupportsCloning: 当前 TTS 供应商是否自报 `voiceCloning` 能力。
    ///   内置音色不看这个（播放不需要克隆能力）。
    public static func violations(
        for profile: VoiceProfile,
        providerSupportsCloning: Bool
    ) -> [Violation] {
        guard profile.isCloned else { return [] }
        var result: [Violation] = []
        guard let consent = profile.consent else {
            return [.missingConsent]
        }
        if !consent.isUsable { result.append(.emptyConsent) }
        guard let reference = profile.referenceAudioPath,
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result.append(.missingReference)
            return result
        }
        if !isLocalPath(reference) { result.append(.referenceNotLocal) }
        if !providerSupportsCloning { result.append(.providerNotCloningCapable) }
        return result
    }

    /// 启用时的**可见提示**（nil = 普通内置音色，无需提示）。
    ///
    /// 产品要求「clear indication when a cloned/custom voice is active」——
    /// 用户任何时候都该知道自己在听的是克隆音色。
    public static func activeIndicator(for profile: VoiceProfile) -> String? {
        guard profile.isCloned else { return nil }
        return "正在使用克隆音色「\(profile.displayName)」"
    }

    /// 参考音频是否指向本地文件：带 scheme 的（http/https/ftp/file...）一律不算。
    ///
    /// 只认朴素文件路径与 `file://` —— 前者是本地录制/导入的正常形态，
    /// 后者仍是本机文件；其它 scheme 说明有人在往远端指，直接拒绝。
    public static func isLocalPath(_ reference: String) -> Bool {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty else {
            // 没有 scheme = 朴素本地路径
            return !trimmed.hasPrefix("//")
        }
        return scheme.lowercased() == "file"
    }
}
