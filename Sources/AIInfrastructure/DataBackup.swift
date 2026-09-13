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
    @discardableResult
    public func export(now: Date = Date()) throws -> Snapshot {
        try manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let stagingRoot = backupDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let payload = stagingRoot.appendingPathComponent(Self.folderName(now: now), isDirectory: true)
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

        let destination = backupDirectory.appendingPathComponent("\(Self.folderName(now: now)).zip")
        try Self.zip(payload: payload, to: destination)
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
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                return Snapshot(
                    url: url,
                    createdAt: values?.creationDate ?? Date.distantPast,
                    sizeBytes: Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 备份总占用。
    public var totalBytes: Int64 {
        snapshots().reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - 内部

    private static func folderName(now: Date) -> String {
        "AI_Language_Coach_备份_\(Self.fileStamp(now))"
    }

    /// 压缩包用什么方式打：macOS 自带的 `ditto`（系统二进制，无第三方依赖）。
    ///
    /// `ditto -c -k --keepParent` 与 Finder 的「压缩」等价，能保住扩展属性。
    private static func zip(payload: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, destination.path]
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw AppError.configuration("无法创建备份压缩包：\(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AppError.configuration("备份压缩失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func manifestText(files: [String], createdAt: Date) -> String {
        let lines = [
            "AI Language Coach 数据备份",
            "导出时间：\(Self.displayStamp(createdAt))",
            "",
            "包含文件：",
        ] + files.map { "  - \($0)" } + [
            "",
            "恢复方式：退出应用，把上面的文件放回数据目录（默认 `.workbuddy/app-config/`），重启即可。",
        ]
        return lines.joined(separator: "\n")
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
