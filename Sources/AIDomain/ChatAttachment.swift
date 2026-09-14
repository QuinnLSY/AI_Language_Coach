import Foundation

// MARK: - 聊天附件（图片 / 视频 / 文件）

/// 一条随消息发出的附件（第 3 项需求）。
///
/// 设计要点：
/// - 只存**应用数据目录内的相对路径**，不存绝对路径 —— 换机 / 换项目目录后依然能找回自己的文件，
///   也不会因为记下任意外部路径而让聊天记录指向用户的私人目录（那类引用删除时还会连坐）。
/// - 类型判断（图片 / 视频 / 其它文件）是**纯函数**：把扩展名表放在领域层，
///   适配器与 UI 都不各写一份，免得「同一种后缀在输入框算图片、在气泡里算文件」。
public struct ChatAttachment: Codable, Sendable, Equatable, Identifiable {

    /// 附件大类。决定聊天区怎么渲染（缩略图 / 播放器 / 文件卡）以及能否随请求发给模型。
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case image
        case video
        case file

        public var displayName: String {
            switch self {
            case .image: "图片"
            case .video: "视频"
            case .file: "文件"
            }
        }

        /// 卡片图标（SF Symbol 名，UI 直接用；不写死具体资源）。
        public var systemImage: String {
            switch self {
            case .image: "photo"
            case .video: "film"
            case .file: "doc"
            }
        }
    }

    public let id: UUID
    public var kind: Kind
    /// 原始文件名（展示用，也是「下载」时的默认文件名）。
    public var fileName: String
    public var mimeType: String
    public var byteCount: Int
    /// 应用数据目录内的相对路径，形如 `attachments/<uuid>.png`。
    public var storedPath: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        fileName: String,
        mimeType: String,
        byteCount: Int,
        storedPath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.storedPath = storedPath
        self.createdAt = createdAt
    }

    public var isImage: Bool { kind == .image }
    public var isVideo: Bool { kind == .video }

    /// 体积文案：「820 B」「12.4 KB」「3.1 MB」。二进制单位，与 Finder 口径一致。
    public var sizeText: String {
        let bytes = max(byteCount, 0)
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    /// 扩展名（小写，无点）。存储文件名由它决定。
    public var fileExtension: String {
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? "dat" : ext.lowercased()
    }
}

// MARK: - 类型判定（纯函数）

public enum AttachmentClassifier {

    /// 图片后缀。取值是**文件格式**而非厂商概念，放领域层不违反「零字面量」红线。
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif",
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm",
    ]

    /// 后缀 → 大类（认不出就是普通文件）。
    public static func kind(forExtension ext: String) -> ChatAttachment.Kind {
        let normalized = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if imageExtensions.contains(normalized) { return .image }
        if videoExtensions.contains(normalized) { return .video }
        return .file
    }

    /// 文件名 → 大类。
    public static func kind(forFileName name: String) -> ChatAttachment.Kind {
        kind(forExtension: (name as NSString).pathExtension)
    }

    /// MIME 类型。用于随请求发给模型（缺失时退回 `application/octet-stream`）。
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic", "heif": "image/heic"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "bmp": "image/bmp"
        case "tiff", "tif": "image/tiff"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "m4v": "video/x-m4v"
        case "webm": "video/webm"
        case "mkv": "video/x-matroska"
        case "avi": "video/x-msvideo"
        case "pdf": "application/pdf"
        case "txt", "md": "text/plain"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }

    /// NSOpenPanel 允许的图片类型（按可靠度排序，顺序就是面板里的默认顺序）。
    public static var imageContentTypes: [String] { ["png", "jpeg", "heic", "gif", "webp", "tiff"] }

    /// NSOpenPanel 允许的视频类型。
    public static var videoContentTypes: [String] { ["mp4", "mov", "m4v", "webm"] }
}

// MARK: - 附件体积 / 数量护栏（纯函数）

/// 附件的体积与数量护栏。
///
/// 为什么必须有上限：图片会被**内联成 base64 发进对话请求**（体积约 ×1.37），
/// 一个 50 MB 的文件会变成约 67 MB 的请求体 —— 用户看到的是「发一句话卡了五分钟」，
/// 账单上还多一次昂贵的失败调用。与其让他猜，不如在选文件时就把门槛说清楚。
public enum AttachmentPolicy {

    /// 单个附件体积上限（20 MB）。图片几 MB、短视频十几 MB，都在这个范围内。
    public static let maxBytes = 20 * 1024 * 1024

    /// 一条消息最多带几个附件（主流 Agent 输入框的做法，也避免请求体失控）。
    ///
    /// 定为 10：一次把「几张图 + 几个笔记文件」都放进去是常见用法；
    /// 再多就该考虑分批发送了 —— 托盘放不下也会自动换行，不是靠横向滚动硬塞。
    public static let maxPerMessage = 10

    /// 会**内联进请求**的类型：只有图片。
    ///
    /// 视频与普通文件只作为本地展示 + 文件名提示 —— OpenAI 兼容的 `/chat/completions`
    /// 不接受视频字节（视频有自己的理解 / 生成端点）。需要「视频也发上去」时应当走专用接口，
    /// 而不是把这一条悄悄放宽，让用户以为视频真的被模型看懂了。
    public static func isInlined(kind: ChatAttachment.Kind) -> Bool { kind == .image }

    /// 体积是否放行。
    public static func accepts(byteCount: Int) -> Bool { byteCount > 0 && byteCount <= maxBytes }

    /// 超限时给用户看的原因（nil = 放行）。
    public static func rejectionReason(fileName: String, byteCount: Int) -> String? {
        guard byteCount > 0 else { return "「\(fileName)」是空文件，没有可发送的内容。" }
        guard !accepts(byteCount: byteCount) else { return nil }
        let mb = Double(maxBytes) / 1024 / 1024
        return "「\(fileName)」超过 \(Int(mb)) MB 上限，请压缩后再添加。"
    }

    /// 还能再添加几个（已达上限返回 0）。
    public static func remainingSlots(current: Int) -> Int { max(maxPerMessage - current, 0) }
}
