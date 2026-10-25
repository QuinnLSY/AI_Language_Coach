import AIDomain
import AppCore
import CryptoKit
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

    /// 内容寻址带来的代价：**多个附件可能共用同一个文件**。
    /// 于是「删掉一个附件」不能再无条件清文件 —— 得先知道还有没有别人拿着它。
    ///
    /// 记的是「本进程把某个存储名交出去过几次」，而不是全局引用表：
    /// 跨进程的那部分（历史消息引用了哪个文件）本进程无从得知，
    /// 那就一律按「有人引用」处理，保守不清。
    private var handOutCounts: [String: Int] = [:]

    /// 本进程**亲手复制进来**的存储名。
    ///
    /// 只有这一批是可以放心清的：它是本次启动才诞生的，
    /// 此前不可能有任何历史消息引用它。命中去重（文件已存在）的那些不算 ——
    /// 它可能正被上一次启动发出去的消息引用着。
    private var selfCopied: Set<String> = []

    /// - Parameter directory: 附件目录；默认 `<用户数据目录>/attachments`（测试可注入临时目录）。
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory
    }

    public var storageDirectory: URL { directory }

    /// 把外部文件复制进来并登记成一个附件。
    ///
    /// ⚠️ **存储名由内容决定**（`SHA256(内容).扩展名`），不是随机 UUID：
    /// 同一张图被反复发送时只会落一份，而不是每次都复制一份
    /// （实测同一张 1.9 MB 的图被存了两遍）。命中即复用，不再复制。
    ///
    /// - 体积上限由调用方把关（`AttachmentPolicy`，20 MB），本层只负责搬运与取名。
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

        let digest = try Self.contentDigest(of: sourceURL)
        let storedName = "\(digest).\(ext)"

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(storedName)
        // 同名文件存在 ≠ 内容一样只看名字就已经够了：**再核一次体积**，
        // 上一次复制被打断留下的半截文件不会被当成可用的那份复用。
        let existingSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        if existingSize != size {
            do {
                try fileManager.copyItem(at: sourceURL, to: destination)
            } catch {
                throw AppError.storage("复制附件失败：\(error.localizedDescription)")
            }
            selfCopied.insert(storedName)
        }
        handOutCounts[storedName, default: 0] += 1

        return ChatAttachment(
            kind: kind,
            fileName: name,
            mimeType: AttachmentClassifier.mimeType(forExtension: ext),
            byteCount: size,
            storedPath: "attachments/\(storedName)"
        )
    }

    /// 文件内容的 SHA-256。
    ///
    /// ⚠️ **不能用 `StableFingerprint`**：它是 32 位 FNV，两个不同的文件只要撞一次，
    /// 后发的那张图就会被静默吞掉（消息里挂着别人的图，且查不出原因）。
    /// 内容寻址必须抗碰撞，所以这里用 SHA-256 —— 哪怕因此多读一遍文件。
    private nonisolated static func contentDigest(of url: URL) throws -> String {
        // 上限 20 MB（AttachmentPolicy），整读一次是可接受的；
        // 不用 `.mappedIfSafe`：映射期间文件被改动会直接把进程带走（SIGBUS）。
        guard let data = try? Data(contentsOf: url) else {
            throw AppError.storage("读不出这个附件的内容：\(url.lastPathComponent)")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
    ///
    /// ⚠️ 走废纸篓而不是 `removeItem`（#S2-13）：附件是用户攒下来的东西，
    /// 点错一次不该永久消失；废纸篓不可用时 `TrashItem` 内部会回落并落日志。
    ///
    /// ⚠️ **共用文件不清**（内容寻址的代价）：同一张图发过一次之后再被加进待发区，
    /// 两条记录指向同一个文件。这时删掉待发区那一条，若顺手把文件清了，
    /// 上一条已发出的消息就变成「本地文件已不可用」——用户没删过它。
    /// 所以只有「本进程亲手复制的、且没有别人还拿着」才真的清。
    @discardableResult
    public func remove(_ attachment: ChatAttachment) -> Bool {
        let name = Self.fileName(of: attachment.storedPath)
        guard !name.isEmpty, name != "/" else { return false }
        guard let url = fileURL(for: attachment) else { return false }

        let remaining = (handOutCounts[name] ?? 0) - 1
        handOutCounts[name] = max(remaining, 0)
        if remaining > 0 { return false }
        // 不是本进程复制进来的：它可能正被历史消息引用着，本进程无从核实 —— 保守留着。
        guard selfCopied.contains(name) else { return false }
        selfCopied.remove(name)
        return TrashItem.delete(url)
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

