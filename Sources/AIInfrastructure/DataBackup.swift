import AppCore
import Foundation

/// 学习数据的导出与备份。
///
/// 为什么不直接复制一个文件夹就算备份：
/// - WAL 模式下 `learning.db` 本身**不完整**，必须带上 `-wal`（否则恢复出来的库缺最近的内容）；
/// - 光有库不够，用户放进学到了哪一关还依赖 `config.json`；
/// - 一份备份要能自己说清「什么时候、装了什么」，所以打包成带时间戳的 zip + 随附清单。
///
/// 导出目录固定在项目空间 `.workbuddy/backups/`（不进 git，和用户数据同级）。
public actor DataBackup {

    /// 一份已存在的备份。
    public struct Snapshot: Sendable, Identifiable, Equatable {
        public let url: URL
        public let createdAt: Date
        public let sizeBytes: Int64

        public init(url: URL, createdAt: Date, sizeBytes: Int64) {
            self.url = url
            self.createdAt = createdAt
            self.sizeBytes = sizeBytes
        }

        public var id: String { url.path }

        /// 人类可读的体积：`1.2 MB`。
        public var sizeDisplay: String {
            ByteFormatter.string(UInt64(max(0, sizeBytes)))
        }
    }

    /// 被打包的文件（相对数据目录）。
    public static let exportedFiles = ["learning.db", "learning.db-wal", "learning.db-shm", "config.json", "remote-calls.jsonl"]

    private let manager: FileManager
    private let dataDirectory: URL
    private let backupDirectory: URL

    public init(
        dataDirectory: URL = AppPaths.userDataDirectory(),
        backupDirectory: URL? = nil
    ) {
        self.manager = .default
        self.dataDirectory = dataDirectory
        self.backupDirectory = backupDirectory ?? Self.defaultBackupDirectory(dataDirectory: dataDirectory)
    }

    public static func defaultBackupDirectory(dataDirectory: URL = AppPaths.userDataDirectory()) -> URL {
        dataDirectory
            .deletingLastPathComponent() // .workbuddy/app-config → .workbuddy
            .appendingPathComponent("backups", isDirectory: true)
    }

    /// 备份目录（UI 展示用）。
    public var directory: URL { backupDirectory }

    // MARK: - 导出

    /// 导出一份完整备份，返回 zip 位置。
    ///
    /// 目录里没有的文件自动跳过（例如还没到 Journals 的全新安装），
    /// 但一个文件都凑不出来时**报错**——空 zip 会让人误以为备份成功了。
    /// `label` 用于特殊场合的标记（例如恢复前的自动留底：「恢复前」）。
    ///
    /// ⚠️ `async` 是刻意的（#S3-3）：打包要等 `ditto`，而等待期间绝不能堵住本 actor 的执行器。
    @discardableResult
    public func export(now: Date = Date(), label: String? = nil) async throws -> Snapshot {
        try manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let stagingRoot = backupDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let payload = stagingRoot.appendingPathComponent(Self.folderName(now: now, label: label), isDirectory: true)
        defer { try? manager.removeItem(at: stagingRoot) }
        try manager.createDirectory(at: payload, withIntermediateDirectories: true)

        var manifest: [String] = []
        for name in Self.exportedFiles {
            let source = dataDirectory.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            try manager.copyItem(at: source, to: payload.appendingPathComponent(name))
            manifest.append(name)
        }

        guard !manifest.isEmpty else {
            throw AppError.configuration("没有可备份的数据文件（\(dataDirectory.path)）")
        }

        let note = Self.manifestText(files: manifest, createdAt: now)
        try note.write(
            to: payload.appendingPathComponent("备份说明.txt"),
            atomically: true,
            encoding: .utf8
        )

        let destination = backupDirectory.appendingPathComponent("\(Self.folderName(now: now, label: label)).zip")
        try await Self.zip(payload: payload, to: destination)
        let values = try destination.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        return Snapshot(
            url: destination,
            createdAt: values.creationDate ?? now,
            sizeBytes: Int64(values.fileSize ?? 0)
        )
    }

    // MARK: - 清单

    /// 已有备份，**新的在前**。
    public func snapshots() -> [Snapshot] {
        guard let entries = try? manager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "zip" }
            .compactMap { url in
                let values = try? url.resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
                )
                return Snapshot(
                    url: url,
                    // ⚠️ 文件名里的时刻是**真相**（见 `stampedDate(in:)`）：`creationDate`
                    // 在拷贝 / Time Machine 恢复之后会变成「刚才」，新鲜度就全错了。
                    createdAt: Self.stampedDate(in: url.lastPathComponent)
                        ?? values?.creationDate
                        ?? values?.contentModificationDate
                        ?? Date(),
                    sizeBytes: Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 备份总占用。
    public var totalBytes: Int64 {
        snapshots().reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - 保留策略（自动备份不能无限堆积）

    /// 自动备份的保留上限：超出的最旧包会被清掉。
    ///
    /// 为什么要有上限：自动备份按间隔天数为单位补文件，**从不覆盖旧的** ——
    /// 不设上限的话，一份包按 10 MB 算，每天一包一年就是 3.6 GB，磁盘被一个
    /// 用户从没打开过的目录悄悄吃满。12 份 × 最短间隔 3 天 ≈ 一个多月的后悔药，够用。
    public static let maxKeptBackups = 12

    /// 清理旧备份：按文件名时间戳保留最近 `keeping` 份，其余**移进废纸篓**（可恢复）。
    ///
    /// - Returns: 实际清掉的份数。不足 `keeping` 份时返回 0。
    @discardableResult
    public func prune(keeping: Int = DataBackup.maxKeptBackups) throws -> Int {
        let limit = max(keeping, 1)
        // ⚠️ 只清**本应用自己产的**包（#S2-11）。外部拷进来的包文件名没有时间戳，
        // 新鲜度只能退回文件属性 —— 那就是「拷进来的那一刻」，通常正好是最新的，
        // 于是它们永远排在最前，而清理是从最旧开始砍：被砍掉的反而是本应用的正常
        // 自动备份，目录长期只增不减。用户特意留下的包不该被自动回收。
        let ours = snapshots().filter { Self.stampedDate(in: $0.url.lastPathComponent) != nil }
        guard ours.count > limit else { return 0 }
        var removed = 0
        for snapshot in ours.suffix(ours.count - limit) {
            try manager.trashItem(at: snapshot.url, resultingItemURL: nil)
            removed += 1
        }
        return removed
    }

    /// 删除一份备份（**进废纸篓**，不是直接抹掉 —— 删备份不该比删库更危险）。
    ///
    /// 只认备份目录里的 zip：路径校验挡住「拿别处的文件路径来删」的误用。
    public func deleteBackup(at url: URL) throws {
        guard url.pathExtension == "zip",
              url.deletingLastPathComponent().standardizedFileURL == backupDirectory.standardizedFileURL
        else {
            throw AppError.configuration("只能删除备份目录（\(backupDirectory.lastPathComponent)/）里的压缩包")
        }
        guard manager.fileExists(atPath: url.path) else { return }
        try manager.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - 内部

    /// 数据目录里有没有**任何**可备份的文件。
    ///
    /// 「清除前留底」用它判断要不要留底：`:memory:` 库 / 全新目录根本没有
    /// 落盘文件可保护 —— 这时留不了底也不该拦着清除，否则内存库永远清不动。
    public func hasAnythingToExport() -> Bool {
        Self.exportedFiles.contains {
            manager.fileExists(atPath: dataDirectory.appendingPathComponent($0).path)
        }
    }

    private static func folderName(now: Date, label: String? = nil) -> String {
        let base = "AI_Language_Coach_备份_\(Self.fileStamp(now))"
        guard let label, !label.isEmpty else { return base }
        return "AI_Language_Coach_\(label)备份_\(Self.fileStamp(now))"
    }

    /// 压缩包用什么方式打：macOS 自带的 `ditto`（系统二进制，无第三方依赖）。
    ///
    /// `ditto -c -k --keepParent` 与 Finder 的「压缩」等价，能保住扩展属性。
    private static func zip(payload: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let result = try await runDitto(
            ["-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, destination.path],
            action: "创建备份压缩包"
        )
        guard result.status == 0 else {
            throw AppError.configuration("备份压缩失败：\(result.output)")
        }
    }

    /// 跑一次 `ditto` 并等它结束（#S3-3）。
    ///
    /// ⚠️ 走 `ProcessRunner` 而不是就地 `waitUntilExit()`：本类是个 actor，它的执行器就是
    /// Swift 并发线程池里的一条线程，`waitUntilExit()` 会**把它堵住** —— 池子只有内核数量级
    /// 条线程，堵几条足以把整个应用的并发拖停。打包动辄十几秒，这类阻塞不能留在并发线程池上。
    ///
    /// 超时给得宽：备份包可能上百 MB，`ditto` 慢起来是十几秒级的事。
    private static func runDitto(_ arguments: [String], action: String) async throws -> ProcessRunner.Result {
        do {
            return try await ProcessRunner.run(
                executable: "/usr/bin/ditto",
                arguments: arguments,
                timeout: dittoTimeout
            )
        } catch let failure as ProcessRunner.Failure {
            // 底层英文文案不进用户界面：这里按「动作 + 后果」重新说一遍（动作名只写这一次）。
            switch failure {
            case .launchFailed(let reason): throw AppError.configuration("无法\(action)：\(reason)")
            case .timedOut(let seconds, _): throw AppError.configuration("\(action)超过 \(seconds) 秒仍未结束")
            case .cancelled: throw AppError.configuration("\(action)被中断")
            }
        }
    }

    /// `ditto` 的等待上限（秒）。打包 / 解包共用。
    private static let dittoTimeout: TimeInterval = 120

    /// ⚠️ internal 而非 private：清单里那段「含明文 API Key」的提示是**安全告知**，
    /// 得能直接单测钉住（`BackupsBoundaryTests`），private 就只能靠哨兵读源码。
    static func manifestText(files: [String], createdAt: Date) -> String {
        // ⚠️ 这一包里有**明文 API Key**（#S2-2）。产品口径是「保守：不剥离、只明示」——
        // 剥离会让「换机后模型不用重配」这个备份的核心价值消失，而偷偷打进去才危险。
        // 所以每次导出都把这句话写进包内的清单里：包自己会跟着走到哪里，提醒就跟到哪里。
        let keyWarning: [String] = files.contains("config.json") ? [
            "",
            "⚠️ 安全提示：本包内的 config.json **明文保存着你在设置里填的 API Key**。",
            "   请当作密码保管，不要发给他人、不要上传到公开网盘或聊天工具。",
        ] : []
        let lines = [
            "AI Language Coach 数据备份",
            "导出时间：\(Self.displayStamp(createdAt))",
            "",
            "包含文件：",
        ] + files.map { "  - \($0)" } + [
            "",
            "恢复方式：在设置里选「导入备份」，或退出应用后把上面的文件放回数据目录（默认 `.workbuddy/app-config/`），重启即可。",
        ] + keyWarning
        return lines.joined(separator: "\n")
    }

    // MARK: - 导入与恢复（换机迁移 / 误删恢复）

    /// 一份备份经校验后的构成。导入确认框要如实展示替换范围，不能含糊地说「恢复数据」。
    public struct ImportPlan: Sendable, Equatable {
        /// 学习库（可带 `-wal` / `-shm` 伴生文件）。
        public let includesDatabase: Bool
        /// 配置（学到哪一关、模型、主题都在这里）。
        public let includesConfig: Bool
        /// 模型调用留痕。
        public let includesCallLog: Bool

        public var fileNames: [String] {
            var names: [String] = []
            if includesDatabase {
                names.append("学习库")
            }
            if includesConfig {
                names.append("配置")
            }
            if includesCallLog {
                names.append("调用留痕")
            }
            return names
        }

        /// 给用户的替换范围说明：`学习库、配置`。
        public var scopeDescription: String {
            fileNames.isEmpty ? "（空）" : fileNames.joined(separator: "、")
        }
    }

    /// 待恢复文件的暂存目录：应用在**下次启动、打开学习库之前**把这里的内容替换进去。
    ///
    /// 为什么不当场换：`learning.db` 正被 WAL 连接占用，活连接底下换文件轻则损坏、
    /// 重则把当前库也搭进去。落暂存 + 重启应用，是唯一能保证「绝不部分覆盖」的路径。
    public static func pendingRestoreDirectory(dataDirectory: URL = AppPaths.userDataDirectory()) -> URL {
        dataDirectory.appendingPathComponent(".restore-pending", isDirectory: true)
    }

    /// 校验一份备份压缩包：能解开、有学习库且真是 SQLite 文件、配置若是 JSON 必须合法。
    ///
    /// 坏包在这里就被拦下并给出明确原因——绝不走到「替换了一半才发现不对」。
    public func inspectBackup(at url: URL) async throws -> ImportPlan {
        let staging = try await Self.unpackBackup(at: url)
        defer { try? manager.removeItem(at: staging) }
        return try Self.validatePayload(in: staging)
    }

    /// 三步走：校验 → 把当前数据再自动备份一份（覆盖前的后悔药）→ 把新文件落进暂存目录。
    ///
    /// 任何一步失败都不会动现有数据；暂存里的内容要等**重启**才真正生效。
    @discardableResult
    public func stageRestore(at url: URL, now: Date = Date()) async throws -> ImportPlan {
        let plan = try await inspectBackup(at: url)

        // 覆盖前的后悔药：当前数据（哪怕已经有点糟）先打包留底。
        _ = try await export(now: now, label: "恢复前")

        // 校验产物从解包现场直接搬进暂存（不再二次解压）。
        let staging = try await Self.unpackBackup(at: url)
        defer { try? manager.removeItem(at: staging) }
        let payload = try Self.validatePayload(in: staging)

        let pending = Self.pendingRestoreDirectory(dataDirectory: dataDirectory)
        // ⚠️ 这里原来是 `try?`：清不掉时下一句 createDirectory 对「已存在」不报错，
        // 于是上一次残留的文件（可能是另一个备份包的学习库）与本次新拷的混在同一目录，
        // 后面按文件名扫到谁算谁 —— 恢复出来的可能是上一次那个包。
        if manager.fileExists(atPath: pending.path) {
            do {
                try manager.removeItem(at: pending)
            } catch {
                throw AppError.storage(
                    "上一次的恢复暂存没清掉，已中止本次恢复（你的当前数据原样未动）：\(error.localizedDescription)"
                )
            }
        }
        try manager.createDirectory(at: pending, withIntermediateDirectories: true)

        var copied: [String] = []
        for name in Self.exportedFiles {
            guard let source = try Self.locateFile(named: name, in: staging) else { continue }
            let destination = pending.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: source, to: destination)
            copied.append(name)
        }
        guard copied.contains("learning.db") || copied.contains("config.json") else {
            try? manager.removeItem(at: pending)
            throw AppError.configuration("备份里没有可恢复的文件")
        }

        let note = [
            "待恢复内容：\(copied.joined(separator: "、"))",
            "校验结果：\(payload.scopeDescription)",
            "生效方式：重启应用时自动替换，替换完成前不会打开学习库。",
        ].joined(separator: "\n")
        try note.write(to: pending.appendingPathComponent("恢复说明.txt"), atomically: true, encoding: .utf8)
        return plan
    }

    /// 启动早期应用待恢复内容（必须在打开学习库**之前**调用）。
    ///
    /// 返回给用户看的说明；nil = 没有待恢复内容。应用失败同样返回说明（如实报错），
    /// 不抛异常——恢复失败不该让应用起不来。
    public static func applyPendingRestoreIfNeeded(
        dataDirectory: URL = AppPaths.userDataDirectory()
    ) -> String? {
        let pending = pendingRestoreDirectory(dataDirectory: dataDirectory)
        let fm = FileManager.default
        guard fm.fileExists(atPath: pending.path) else { return nil }

        // ⚠️ 替换下来的旧文件**改名留存**，恢复全部成功后才删（#S2-4）。
        // 原来这里是 `removeItem` 永久删除：中途 `copyItem` 失败就是「旧库已删、
        // 新库半拷」，用户既没有退路也看不见发生了什么。同卷改名是原子的，
        // 留存期间它也不在 SQLite 找得到的位置上，不会污染新库。
        var displaced: [URL] = []
        let stamp = Self.fileStamp(Date())
        func displace(_ url: URL) throws {
            guard fm.fileExists(atPath: url.path) else { return }
            let target = Self.displacedName(for: url, stamp: stamp)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: url, to: target)
            displaced.append(target)
        }

        func finish(_ note: String, removePending: Bool) -> String? {
            var suffix = ""
            if !displaced.isEmpty {
                if removePending {
                    // 恢复成功了：留存这时才是多余的垃圾，清掉。
                    for url in displaced { try? fm.removeItem(at: url) }
                    displaced = []
                } else {
                    let list = displaced.map(\.lastPathComponent).joined(separator: "、")
                    suffix = "\n\n替换下来的旧文件我留着了（恢复失败，别丢）：\(list)"
                }
            }
            guard removePending else { return note + suffix }
            // ⚠️ 原来是 `try?`：暂存清不掉的话它**还留在那儿**，下次启动会再恢复一遍
            // 同一份旧备份，把用户这两天的学习记录又覆盖回去。清不掉必须说出来。
            do {
                try fm.removeItem(at: pending)
                return note + suffix
            } catch {
                return note
                    + suffix
                    + "\n\n⚠️ 恢复暂存目录没清掉（\(error.localizedDescription)）：下次启动会再恢复一次这份旧备份，"
                    + "请手动删除 \(pending.path)"
            }
        }

        // 备份里的库文件；没带的伴生文件（旧 WAL/SHM）必须删——不同库的 WAL 拼在一起是毒药。
        var dbFiles: [String] = []
        var configFile = false
        for name in exportedFiles {
            let source = pending.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            switch name {
            case "learning.db", "learning.db-wal", "learning.db-shm":
                dbFiles.append(name)
            case "config.json":
                configFile = true
            default:
                break
            }
        }
        guard !dbFiles.isEmpty || configFile else {
            return finish("恢复失败：暂存目录里没有可恢复的文件（已跳过）。", removePending: true)
        }

        do {
            if !dbFiles.isEmpty {
                // 伴生文件一律先清：备份没带 = 旧的必须删（不同库的 WAL 是毒药）；
                // 备份带了 = copyItem 不覆盖已存在目标，也必须先让位。
                for companion in ["learning.db-wal", "learning.db-shm"] {
                    let url = dataDirectory.appendingPathComponent(companion)
                    guard fm.fileExists(atPath: url.path) else { continue }
                    // 让不动就中止：上面刚说过「不同库的 WAL 是毒药」，残留的旧 WAL
                    // 会让新库打不开或内容错乱，而原来这里报的是「已从备份恢复」。
                    do {
                        try displace(url)
                    } catch {
                        throw AppError.storage(
                            "旧库的伴生文件移不开（\(companion)），已中止恢复以免污染新库：\(error.localizedDescription)"
                        )
                    }
                }
                let target = dataDirectory.appendingPathComponent("learning.db")
                if fm.fileExists(atPath: target.path) {
                    try displace(target)
                }
                for name in dbFiles {
                    try fm.copyItem(
                        at: pending.appendingPathComponent(name),
                        to: dataDirectory.appendingPathComponent(name)
                    )
                }
            }
            if configFile {
                let target = dataDirectory.appendingPathComponent("config.json")
                if fm.fileExists(atPath: target.path) {
                    try displace(target)
                }
                try fm.copyItem(
                    at: pending.appendingPathComponent("config.json"),
                    to: target
                )
            }
            let replaced = (dbFiles.isEmpty ? [] : ["学习库"]) + (configFile ? ["配置"] : [])
            return finish("已从备份恢复：替换了 \(replaced.joined(separator: "、"))。", removePending: true)
        } catch {
            return finish("恢复失败：\(error.localizedDescription)（暂存已保留，可重试或手动处理）。", removePending: false)
        }
    }

    /// 替换下来的旧文件的留存名：`.replaced-<时刻>-<原名>`。
    ///
    /// 同一个数据目录里，`learning.db-wal` / `learning.db-shm` 这两个名字**必须**腾空
    /// （SQLite 会按这两个名字找伴生文件），所以前缀一个点、换个名，既躲开 SQLite 的
    /// 视线，又留在原地可捞。
    static func displacedName(for url: URL, stamp: String) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".replaced-\(stamp)-\(url.lastPathComponent)")
    }

    // MARK: - 导入内部件

    /// 解开备份 zip 到临时目录。zip 布局兼容两种：带父文件夹（本应用导出的）与散装在根目录。
    private static func unpackBackup(at url: URL) async throws -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            throw AppError.configuration("找不到备份文件：\(url.lastPathComponent)")
        }
        let staging = Self.inspectContainer().appendingPathComponent("contents", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        let result = try await runDitto(["-x", "-k", url.path, staging.path], action: "读取备份")
        guard result.status == 0 else {
            try? manager.removeItem(at: staging)
            throw AppError.configuration("备份压缩包已损坏，无法读取：\(result.output)")
        }
        // ⚠️ 解包**不能只信 ditto 的内部行为**（#S2-3）：条目路径、条目数、解压体积
        // 全靠它拦不住就等于没有边界 —— 一个构造过的包就能把文件写到暂存目录之外
        // （Zip Slip），或解压出一个撑爆磁盘的包。解压完立刻自审，不合格就地清掉。
        do {
            try auditUnpackedTree(at: staging)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        return staging
    }

    /// 解包现场的**专属容器目录**：解开的东西一律落在它的 `contents/` 里。
    ///
    /// ⚠️ 为什么要多这一层（#S2-3）：只检查「解包目录里每个条目的路径都在解包目录内」
    /// 是**抓不到 Zip Slip 的** —— 真逃出去的文件（zip 里的 `../evil`）根本不在解包目录里，
    /// 枚举它自然枚举不到，那条判据永远绿（实测把它删掉，测试照样通过）。
    /// 改成「解包目录专属一个空容器」，事后核对容器里除了 `contents/` 什么都没多，
    /// 才真能抓到同级的逃逸。更深的 `../../` 那类仍由 `ditto` 自己拒绝，
    /// 我们不重复实现一个 zip 解析器。
    private static func inspectContainer() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-inspect-\(UUID().uuidString)", isDirectory: true)
    }

    /// 解包后的安全校验（纯文件系统自审，不依赖 `ditto` 的行为）。
    ///
    /// 三道闸：容器里没多出东西（Zip Slip 同级逃逸）、不含符号链接、条目数与解压体积有上限。
    ///
    /// ⚠️ internal 而非 private：这是安全边界本身，必须能被单测直接打到每一道的正反两面
    /// （`BackupsBoundaryTests`），private 就只能靠读源码猜它拦没拦住。
    static func auditUnpackedTree(at staging: URL) throws {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey]
        guard let enumerator = manager.enumerator(at: staging, includingPropertiesForKeys: Array(keys)) else {
            throw AppError.configuration("备份内容无法遍历，已拒绝恢复")
        }
        var count = 0
        var total: Int64 = 0
        while let element = enumerator.nextObject() as? URL {
            count += 1
            guard count <= maxUnpackedEntries else {
                throw AppError.configuration(
                    "备份里的条目超过 \(maxUnpackedEntries) 项，不是正常备份，已拒绝恢复"
                )
            }
            let values = try? element.resourceValues(forKeys: keys)
            guard values?.isSymbolicLink != true else {
                throw AppError.configuration("备份里含符号链接，已拒绝恢复")
            }
            // ⚠️ 这里曾还有一条「每个条目的路径都必须落在解包目录内」的检查，**已删**：
            // 真逃出去的文件不在解包目录里，枚举它枚举不到 → 那条检查永远绿、根本
            // 拦不住任何东西（实测删掉它测试照样通过）；而它能触发的唯一情形
            // （符号链接指向外部）已经被上面那一条拦掉了。留着一个不可验证的闸
            // 只会让人以为「路径逃逸已经被覆盖」。
            if values?.isDirectory != true {
                total += Int64(values?.fileSize ?? 0)
                guard total <= maxUnpackedBytes else {
                    throw AppError.configuration(
                        "备份解压后超过 \(ByteFormatter.string(UInt64(maxUnpackedBytes)))，已拒绝恢复"
                    )
                }
            }
        }
        // 容器里除了解包目录只允许有「解包目录自己」—— 每多出来一个都是逃出去的。
        let container = staging.deletingLastPathComponent()
        let siblings = (try? manager.contentsOfDirectory(atPath: container.path))?
            .filter { $0 != staging.lastPathComponent } ?? []
        guard siblings.isEmpty else {
            throw AppError.configuration(
                "备份里有 \(siblings.count) 项内容被写到解包目录之外"
                    + "（\(siblings.prefix(3).joined(separator: "、"))），已拒绝恢复"
            )
        }
    }

    /// 解包后条目数上限（本应用导出的是 5~7 个文件，留足余量）。
    public static let maxUnpackedEntries = 2_000
    /// 解压后总体积上限：学习库上百 MB 是常态，512 MB 足够宽，又不至于撑爆磁盘。
    public static let maxUnpackedBytes: Int64 = 512 * 1024 * 1024

    /// 在解包现场找文件（兼容带父文件夹的布局），找不到返回 nil。
    private static func locateFile(named name: String, in staging: URL) throws -> URL? {
        let enumerator = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil)
        var hits: [URL] = []
        while let element = enumerator?.nextObject() as? URL {
            if element.lastPathComponent == name { hits.append(element) }
        }
        guard hits.count > 1 else { return hits.first }
        throw AppError.configuration("备份里出现了多个 \(name)，文件不可信")
    }

    /// 备份内 `config.json` 的读取上限（8 MB）。
    ///
    /// 真实配置是几十 KB 量级，8 MB 已是「绝不可能是正常配置」的量级。定这个上限是因为
    /// 校验发生在**用户确认导入之前** —— 不能让一个塞了几百 MB JSON 的包，在用户只是「看了一眼」
    /// 的时候就撑爆内存（同一个函数里读 SQLite 就只取 16 字节头，标准要一致）。
    static let maxConfigBytes = 8 * 1024 * 1024

    /// 按 `limit` 上限读文件；**超过上限返回 `nil`**（调用方据此拒绝导入）。
    ///
    /// 多读 1 字节即可判出「不止这么大」—— 既不用把大文件读全，也不必真造一个几百 MB 的包。
    /// 抽成独立函数是为了这条判据**能被单测**（`validatePayload` 本身是 private）。
    static func readCapped(_ url: URL, limit: Int) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: max(limit, 0) + 1) ?? Data()
        return data.count <= limit ? data : nil
    }

    /// 校验解包出来的内容：必须有学习库（且真是 SQLite），config.json 若在必须是合法 JSON。
    private static func validatePayload(in staging: URL) throws -> ImportPlan {
        var includesDatabase = false
        if let db = try locateFile(named: "learning.db", in: staging) {
            // 只读文件头 16 字节判格式，不整读（库可能上百 MB）。
            let handle = try FileHandle(forReadingFrom: db)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 16) ?? Data()
            guard header == Data("SQLite format 3\u{0}".utf8) else {
                throw AppError.configuration("备份里的学习库不是有效的 SQLite 文件，已拒绝恢复")
            }
            includesDatabase = true
        }

        var includesConfig = false
        if let config = try locateFile(named: "config.json", in: staging) {
            // ⚠️ 按上限读（见 `readCapped`）：这一步跑在用户确认导入**之前**，
            // 整读一份几百 MB 的 JSON 就是一处没有上限的内存风险。
            guard let raw = try Self.readCapped(config, limit: Self.maxConfigBytes) else {
                throw AppError.configuration(
                    "备份里的配置文件超过 \(Self.maxConfigBytes / 1024 / 1024) MB，已拒绝恢复"
                )
            }
            guard let object = try? JSONSerialization.jsonObject(with: raw), object is [String: Any] else {
                throw AppError.configuration("备份里的配置文件不是有效的 JSON，已拒绝恢复")
            }
            includesConfig = true
        }

        guard includesDatabase || includesConfig else {
            throw AppError.configuration("备份里既没有学习库也没有配置，没有可恢复的内容")
        }

        let includesCallLog = (try? locateFile(named: "remote-calls.jsonl", in: staging)) != nil
        return ImportPlan(
            includesDatabase: includesDatabase,
            includesConfig: includesConfig,
            includesCallLog: includesCallLog
        )
    }

    /// 从备份文件名里把**备份时刻**读回来（纯函数，便于单测）。
    ///
    /// 为什么认文件名不认 `creationDate`（2026-10-01 修）：后者是「文件在本机上被创建的
    /// 时刻」—— 从另一台机器拷进来、用 Time Machine / `cp` 恢复，它就变成**刚才**，
    /// 于是新鲜度报「今天刚备份过」，而那份其实是几周前的旧包（自动备份被跳过）。
    /// 时间戳是 `export` 那一刻写进名字里的，跟着包走，怎么拷都不变。
    ///
    /// ⚠️ 读不出来返回 nil，由调用方退回文件属性 —— 绝不兜 `Date.distantPast`：
    /// 那会把「几天没备份」算成天文数字，于是每次启动都补一份。
    static func stampedDate(in filename: String) -> Date? {
        let name = (filename as NSString).deletingPathExtension
        // `fileStamp` 的形状：8 位日期 + 「-」 + 6 位时间，恒在文件名末尾。
        guard name.count >= 15 else { return nil }
        let tail = String(name.suffix(15))
        guard tail[tail.index(tail.startIndex, offsetBy: 8)] == "-" else { return nil }
        let datePart = String(tail.prefix(8))
        let timePart = String(tail.suffix(6))
        guard datePart.allSatisfy(\.isNumber), timePart.allSatisfy(\.isNumber) else { return nil }
        func int(_ text: Substring) -> Int { Int(text) ?? 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let components = DateComponents(
            calendar: calendar,
            year: int(datePart.prefix(4)),
            month: int(datePart.dropFirst(4).prefix(2)),
            day: int(datePart.dropFirst(6).prefix(2)),
            hour: int(timePart.prefix(2)),
            minute: int(timePart.dropFirst(2).prefix(2)),
            second: int(timePart.dropFirst(4).prefix(2))
        )
        return components.date
    }

    private static func fileStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        func pad(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "\(pad(components.year))\(pad(components.month))\(pad(components.day))-\(pad(components.hour))\(pad(components.minute))\(pad(components.second))"
    }

    private static func displayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
