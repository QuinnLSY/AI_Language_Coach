import AIDomain
import AppCore
import Foundation

/// 今日跟读句子的落盘缓存（`.workbuddy/app-config/shadowing-daily.json`）。
///
/// 为什么必须有这一层：句子是**当天现生成**的，而模型调用要几秒到几十秒。
/// 没有缓存的话，「切走跟读页再切回来」「重启应用」都会重生成一遍 ——
/// 用户会看到自己练到一半的句子全换掉，这与「练一句就像一句」的用法直接冲突。
///
/// 与 `DictionaryBookStore` / `VoiceProfileStore` 同构：一个 actor 管一份 JSON，
/// 写入只有一条路。读不出来（文件不存在 / 写坏）一律当作「今天还没生成」，**不删不改名** ——
/// 大不了重生成一次，绝不能顺手把文件清掉。
public actor ShadowingDailyStore {

    public static let shared = ShadowingDailyStore()

    /// 落盘内容：日期 + 学习语言 + 句子。
    ///
    /// 带上 `language`：用户切换学习语言后，昨天那份中文→英的句子对今天毫无意义，
    /// 但日期键是新的、看着「有缓存」。语言一变就作废，比按日期作废更准。
    public struct Snapshot: Codable, Equatable {
        public var day: String
        public var language: String
        public var drills: [ShadowingDrill]

        public init(day: String, language: String, drills: [ShadowingDrill]) {
            self.day = day
            self.language = language
            self.drills = drills
        }
    }

    private let fileURL: URL
    private var snapshot: Snapshot?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.userDataDirectory()
            .appendingPathComponent("shadowing-daily.json")
        self.snapshot = Self.read(from: self.fileURL)
    }

    /// 这一天的句子（日期或语言不匹配 → nil）。
    public func drills(day: String, language: String) -> [ShadowingDrill]? {
        guard let snapshot,
              snapshot.day == day,
              snapshot.language.caseInsensitiveCompare(language) == .orderedSame,
              !snapshot.drills.isEmpty
        else { return nil }
        return snapshot.drills
    }

    /// 覆盖写入（同一天只留最新一份）。
    public func save(day: String, language: String, drills: [ShadowingDrill]) {
        guard !drills.isEmpty else { return }
        let next = Snapshot(day: day, language: language, drills: drills)
        snapshot = next
        Self.write(next, to: fileURL)
    }

    /// 清空（换学习语言 / 用户要求重新生成时用）。
    public func clear() {
        snapshot = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 私有

    private static func read(from url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func write(_ snapshot: Snapshot, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
