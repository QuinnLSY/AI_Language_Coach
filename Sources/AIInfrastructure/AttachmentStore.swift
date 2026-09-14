import AIDomain
import AppCore
import Foundation

/// 聊天附件仓库：把用户选中的文件**复制**进应用数据目录，并以相对路径登记。
///
/// 与 `VoiceProfileStore` 同款理由：不记外部绝对路径。
/// 原文件可能被移动 / 删除 / 在云端盘上被驱逐，那时聊天记录里的图片会变成空白框却查不出原因；
/// 复制进应用自己的目录后，附件的生命周期可控（删消息 = 可一并清理），
/// 也不会让「曾经发过一张图」变成对用户私有目录的长期引用。
public actor AttachmentStore {

    public static let shared = AttachmentStore()

    /// 默认附件目录（`<用户数据目录>/attachments`）。
    ///
    /// 暴露成静态量是为了让**所有**需要定位附件的代码都走同一个根，
    /// 而不是各自拼一次 `userDataDirectory().appendingPathComponent("attachments")`：
    /// 那种各拼各的写法一旦有一处写错（少一层目录 / 多一个斜杠），
    /// 表现是「预览图显示得出来、发给模型却是空的」——两边都「看起来正常」，极难定位。
    public static var defaultDirectory: URL {
        AppPaths.userDataDirectory().appendingPathComponent("attachments", isDirectory: true)
    }

    private let directory: URL
    private let fileManager: FileManager

    /// - Parameter directory: 附件目录；默认 `<用户数据目录>/attachments`（测试可注入临时目录）。
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory
    }

    public var storageDirectory: URL { directory }

    /// 把外部文件复制进来并登记成一个附件。
    ///
    /// - 文件名冲突不可能发生：存储名用新 UUID，原始名只留作展示与下载默认名。
    /// - 体积上限由调用方把关（`AttachmentPolicy`），本层只负责搬运。
    public func importFile(at sourceURL: URL) throws -> ChatAttachment {
        let name = sourceURL.lastPathComponent
        let kind = AttachmentClassifier.kind(forFileName: name)
        let ext = (name as NSString).pathExtension.isEmpty
            ? "dat"
            : (name as NSString).pathExtension.lowercased()

        let size = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            throw AppError.storage("这个文件是空的，没有可发送的内容：\(name)")
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let storedName = "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(storedName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw AppError.storage("复制附件失败：\(error.localizedDescription)")
        }

        return ChatAttachment(
            kind: kind,
            fileName: name,
            mimeType: AttachmentClassifier.mimeType(forExtension: ext),
            byteCount: size,
            storedPath: "attachments/\(storedName)"
        )
    }

    /// 附件的定位规则（唯一口径）：落库的 `storedPath` 带 `attachments/` 前缀是为了**自解释**，
    /// 真正定位时只取文件名，再拼到仓库自己的目录上。
    ///
    /// 这样做的两个理由：
    /// ① 仓库目录可以被注入成临时目录（测试），定位规则不会跟着漂；
    /// ② 同时兼容带前缀与不带前缀两种写法，将来改存储布局不会让老记录找不到文件。
    ///
    /// `nonisolated` 的理由：它只做字符串处理、不碰 actor 状态，
    /// 因此 UI 可以在渲染时**同步**调用 —— 否则视图就得为一个纯字符串操作用 async。
    public nonisolated static func fileName(of storedPath: String) -> String {
        (storedPath as NSString).lastPathComponent
    }

    /// 附件在本机的位置。文件已被清理时返回 nil（UI 据此显示「文件已不可用」）。
    public func fileURL(for attachment: ChatAttachment) -> URL? {
        let name = Self.fileName(of: attachment.storedPath)
        guard !name.isEmpty, name != "/" else { return nil }
        let url = directory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// 读取附件内容（发给多模态模型时用）。读不到返回 nil。
    public func data(for attachment: ChatAttachment) -> Data? {
        guard let url = fileURL(for: attachment) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 删除附件本体。删除失败不抛错（清理是尽力而为，不该阻断用户操作）。
    @discardableResult
    public func remove(_ attachment: ChatAttachment) -> Bool {
        guard let url = fileURL(for: attachment) else { return false }
        return (try? fileManager.removeItem(at: url)) != nil
    }

    /// 全量体检：列出目录里没有任何消息引用的孤儿文件（设置页清理用）。
    ///
    /// ⚠️ `referenced` 允许传 `storedPath`（带 `attachments/` 前缀）**或**裸文件名 ——
    /// 这里统一取末段再比较。不归一的话，调用方只要传错一格（传了带前缀的形态），
    /// 全部在用附件都会被判成孤儿，而清理是不可逆的。
    public func orphanFiles(referenced: Set<String>) -> [URL] {
        let live = Set(referenced.map { Self.fileName(of: $0) })
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { !live.contains($0.lastPathComponent) }
    }
}

