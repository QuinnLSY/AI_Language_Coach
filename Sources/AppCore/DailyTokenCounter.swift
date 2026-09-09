import Foundation

/// 今日全局 token 用量（侧边栏黑板 / 督促气泡用）。
/// 按天累计，存 UserDefaults；估算值，非精确计费数据。
public enum DailyTokenCounter {

    private static let dateKey = "alc.tokenCounter.date"
    private static let countKey = "alc.tokenCounter.count"

    /// 今天（本地时区）的日期键，如 2026-09-10。跨天自动归零。
    private static var today: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static var defaults: UserDefaults { .standard }

    private static func rollIfNeeded() {
        if defaults.string(forKey: dateKey) != today {
            defaults.set(today, forKey: dateKey)
            defaults.set(0, forKey: countKey)
        }
    }

    /// 今日已用 token（估算）。
    public static func todayTokens() -> Int {
        rollIfNeeded()
        return defaults.integer(forKey: countKey)
    }

    /// 累加今日用量。
    public static func add(_ tokens: Int) {
        guard tokens > 0 else { return }
        rollIfNeeded()
        defaults.set(todayTokens() + tokens, forKey: countKey)
    }
}
