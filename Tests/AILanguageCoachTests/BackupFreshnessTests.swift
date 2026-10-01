import XCTest

@testable import AIInfrastructure
@testable import AppCore
@testable import AppUI

/// 备份新鲜度与自动备份判定（#415）。
///
/// 要钉的是两件事：①「上次备份是 N 天前」的口径与「该不该自动补一份」**共用同一个值**
/// （各算一套就会出现界面说还早、后台天天在备份）；②判定用的是目录里的真实文件，
/// 不是内存里的旧清单（否则同一天开十次应用就是十份）。
final class BackupFreshnessTests: XCTestCase {

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }

    // MARK: - 新鲜度文案与档位

    func testNeverBackedUpIsDue() {
        let status = BackupFreshness.status(latestBackupAt: nil, now: date("2026-10-01 09:00:00"), intervalDays: 7)
        XCTAssertEqual(status.level, .never)
        XCTAssertNil(status.daysSinceLastBackup)
        XCTAssertTrue(status.isDue, "一份都没有，当然该补 —— 这条不成立的话自动备份永远不启动")
        XCTAssertTrue(status.text.contains("还没有备份过"))
    }

    func testDaysAreCalendarDaysNotElapsedHours() {
        // 昨晚 23:30 备份的，第二天早上 08:00 就该算「昨天」—— 用户的直觉是自然日，
        // 按 24 小时算这里只有 8.5 小时，界面会说「今天已备份」。
        let days = BackupFreshness.days(
            since: date("2026-09-30 23:30:00"),
            now: date("2026-10-01 08:00:00"),
            calendar: calendar
        )
        XCTAssertEqual(days, 1)
        XCTAssertEqual(
            BackupFreshness.status(latestBackupAt: date("2026-09-30 23:30:00"),
                                   now: date("2026-10-01 08:00:00"),
                                   intervalDays: 7, calendar: calendar).text,
            "昨天备份过"
        )
    }

    func testSameDayIsFreshAndNeverNegative() {
        let status = BackupFreshness.status(
            latestBackupAt: date("2026-10-01 01:00:00"),
            now: date("2026-10-01 22:00:00"),
            intervalDays: 1,
            calendar: calendar
        )
        XCTAssertEqual(status.text, "今天已备份")
        XCTAssertFalse(status.isDue)

        // 时钟回拨：备份时间落在未来。负数会让「N 天前」变成鬼话，按 0 处理。
        let future = BackupFreshness.days(
            since: date("2026-10-05 10:00:00"),
            now: date("2026-10-01 10:00:00"),
            calendar: calendar
        )
        XCTAssertEqual(future, 0)
    }

    func testDueExactlyAtIntervalNotOneDayLater() {
        let seven = BackupFreshness.status(
            latestBackupAt: date("2026-09-24 10:00:00"),
            now: date("2026-10-01 10:00:00"),
            intervalDays: 7,
            calendar: calendar
        )
        XCTAssertEqual(seven.daysSinceLastBackup, 7)
        XCTAssertTrue(seven.isDue, "正好到间隔那一天就该补：等到第 8 天才补，等于间隔是 8 天")
        XCTAssertEqual(seven.level, .due)

        let six = BackupFreshness.status(
            latestBackupAt: date("2026-09-25 10:00:00"),
            now: date("2026-10-01 10:00:00"),
            intervalDays: 7,
            calendar: calendar
        )
        XCTAssertFalse(six.isDue)
        XCTAssertEqual(six.level, .fresh)
    }

    func testIntervalIsClampedInsteadOfTrusted() {
        // 配成 0 天 = 每次启动都备份一份。夹到 1 天才不会一天开十次就十份。
        let zero = BackupFreshness.status(
            latestBackupAt: date("2026-10-01 10:00:00"),
            now: date("2026-10-01 10:00:00"),
            intervalDays: 0,
            calendar: calendar
        )
        XCTAssertFalse(zero.isDue, "间隔 0 被夹成 1：当天已备份就不该再补")
    }

    // MARK: - 配置层

    func testAutoBackupDefaultsOffAndIntervalSane() {
        let defaults = ProductConfig()
        XCTAssertFalse(defaults.autoBackupEnabled, "默认不开：备份占磁盘，不该替用户做这个决定")
        XCTAssertEqual(defaults.autoBackupIntervalDays, 7)
    }

    func testAutoBackupDecodesLegacyConfigAsDefaults() throws {
        // 老配置没有这两个字段：不能整体作废，也不能因为缺字段就把备份悄悄打开。
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.autoBackupEnabled)
        XCTAssertEqual(decoded.autoBackupIntervalDays, ProductConfig().autoBackupIntervalDays)
    }

    func testAutoBackupIntervalClampedOnDecodeAndInit() throws {
        let decoded = try JSONDecoder().decode(
            ProductConfig.self,
            from: Data(#"{"autoBackupEnabled":true,"autoBackupIntervalDays":9999}"#.utf8)
        )
        XCTAssertEqual(decoded.autoBackupIntervalDays, 30)
        XCTAssertEqual(ProductConfig(autoBackupIntervalDays: 0).autoBackupIntervalDays, 1)
    }

    func testAutoBackupRoundTripKeepsValues() throws {
        var config = ProductConfig()
        config.autoBackupEnabled = true
        config.autoBackupIntervalDays = 14
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.autoBackupEnabled, true)
        XCTAssertEqual(decoded.autoBackupIntervalDays, 14)
    }

    // MARK: - 备份时刻认文件名，不认文件的创建时间（2026-10-01 修）

    /// `creationDate` 是「在本机上被创建的时刻」：从别的机器拷进来、Time Machine 恢复、
    /// 用 `cp` 挪一下，它都变成**刚才** —— 新鲜度于是报「今天刚备份过」，
    /// 而那份其实是几周前的旧包（自动备份被跳过）。时间戳跟着包走，怎么拷都不变。
    func testStampedDateReadsTheTimestampFromTheFileName() {
        let parsed = DataBackup.stampedDate(in: "AI_Language_Coach_备份_20260901-142530.zip")
        XCTAssertNotNil(parsed)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                 from: parsed!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 25)
        XCTAssertEqual(components.second, 30)
        // 带标签的备份（如「手动备份」）形状不同，也要认得出来。
        XCTAssertNotNil(DataBackup.stampedDate(in: "AI_Language_Coach_手动备份_20261001-090000.zip"))
    }

    func testStampedDateReturnsNilInsteadOfAGarbageDate() {
        XCTAssertNil(DataBackup.stampedDate(in: "随便一个文件.zip"))
        XCTAssertNil(DataBackup.stampedDate(in: "备份.zip"))
        XCTAssertNil(DataBackup.stampedDate(in: "AI_Language_Coach_备份_.zip"))
    }

    /// 清单里必须优先用文件名里的时刻，且**不许**用 `distantPast` 兜底 ——
    /// 那会把「几天没备份」算成天文数字，于是每次启动都补一份。
    func testSnapshotListPrefersTheFileNameAndNeverUsesDistantPast() throws {
        let raw = try String(contentsOfFile: "Sources/AIInfrastructure/DataBackup.swift",
                             encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let body = lines.joined(separator: "\n")
        XCTAssertTrue(body.contains("Self.stampedDate(in: url.lastPathComponent)"),
                      "清单没有优先读文件名里的时刻")
        XCTAssertFalse(body.contains("Date.distantPast"),
                       "兜底不许用 distantPast：新鲜度会算成天文数字，于是天天备份")
    }

    /// 「每 N 天补一份」必须**在跨天时也兑现**：macOS 应用常年不退出，
    /// 只在启动那一刻判一次的话，开着一个月就是一个月不备份（界面那句文案是假的）。
    func testAutoBackupIsCheckedWhenTheDayRollsOver() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/AppState.swift", encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        guard let start = lines.firstIndex(where: { $0.contains("func startDayRolloverWatch()") }) else {
            return XCTFail("找不到跨天监察")
        }
        let body = lines[start...].prefix(40).joined(separator: "\n")
        XCTAssertTrue(body.contains("ensureAutoBackupIfNeeded()"),
                      "换天时没有复查自动备份（应用常开就永远不补）")
        XCTAssertTrue(body.contains("ensureAnnualRecapLoaded(force: true)"),
                      "换天时没有重取年度数据（热力图/年轮会停在昨天）")
    }

    /// 年度汇总必须能被强制刷新：此前 `hasAnnualRecap` 没有任何一处复位，
    /// 于是今天练满第 30 天，树根要重启应用才多一圈年轮。
    func testAnnualRecapCanBeInvalidated() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/AppState+Progress.swift",
                             encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let body = lines.joined(separator: "\n")
        XCTAssertTrue(body.contains("ensureAnnualRecapLoaded(force: Bool = false)"),
                      "年度取数要能失效重取")
        XCTAssertTrue(body.contains("(force || !hasAnnualRecap)"),
                      "force 必须真的绕过「已加载过」的短路")
        XCTAssertTrue(body.contains("ensureAnnualRecapLoaded(force: true)"),
                      "练完回来刷新进度时必须顺带刷新年度")
    }
}
