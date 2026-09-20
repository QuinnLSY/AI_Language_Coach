import AIDomain
import XCTest

/// #228 每周小结与月环比：
/// - `ProgressAggregator.weeklyInsight` 的切片口径（周一起算、月从 1 号起算）；
/// - 月环比的样本门槛（上月不足 5 分钟 / 数据没覆盖到上月 → nil，绝不拿 0% 冒充）。
final class ProgressInsightTests: XCTestCase {

    /// 固定时区 + 固定「现在」，避免跨时区 / 跨天导致的偶发失败。
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    /// 2026-09-16 是周三。
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 20))!
    }

    private func day(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    /// 一天的活动（只关心时长 / 纠错 / 新增词）。
    private func activity(_ date: Date, seconds: TimeInterval = 0, corrections: Int = 0, words: Int = 0) -> DailyActivity {
        DailyActivity(day: date, seconds: seconds, corrections: corrections, vocabularyAdded: words)
    }

    func testWeekSlicesStartFromMonday() {
        // 本周一 = 9/14；上周 = 9/7–9/13。9/16（周三）落在本周。
        let days = [
            activity(day(9, 13), seconds: 600, corrections: 3),   // 上周日
            activity(day(9, 14), seconds: 300, corrections: 1),   // 本周一
            activity(day(9, 15), seconds: 120, corrections: 2, words: 4),
            activity(day(9, 16), seconds: 60),                    // 今天
        ]
        let insight = ProgressAggregator.weeklyInsight(days: days, now: now, calendar: calendar)
        XCTAssertNotNil(insight)
        XCTAssertEqual(insight?.weekSeconds ?? 0, 480)            // 300 + 120 + 60
        XCTAssertEqual(insight?.lastWeekSeconds ?? 0, 600)
        XCTAssertEqual(insight?.weekCorrections ?? -1, 3)
        XCTAssertEqual(insight?.lastWeekCorrections ?? -1, 3)
        XCTAssertEqual(insight?.weekNewWords ?? -1, 4)
    }

    func testMonthSlicesCoverWholeLastMonth() {
        // 8 月 31 天：每天 100 秒 = 3100 秒；9 月 1–16：每天 200 秒 = 3200 秒。
        var days: [DailyActivity] = []
        for d in 1...31 { days.append(activity(day(8, d), seconds: 100)) }
        for d in 1...16 { days.append(activity(day(9, d), seconds: 200)) }
        let insight = ProgressAggregator.weeklyInsight(days: days, now: now, calendar: calendar)
        XCTAssertEqual(insight?.monthSeconds ?? 0, 3200)
        XCTAssertEqual(insight?.lastMonthSeconds ?? 0, 3100)
        let percent = insight?.monthChangePercent
        XCTAssertNotNil(percent)
        XCTAssertEqual(percent ?? 0, (3200.0 - 3100.0) / 3100.0 * 100, accuracy: 0.001)
    }

    func testMonthChangeInsufficientWhenLastMonthTooSmall() {
        // 上月只练了 60 秒（< 5 分钟门槛）→ 样本不足，不给环比。
        var days: [DailyActivity] = [activity(day(8, 20), seconds: 60)]
        for d in 1...16 { days.append(activity(day(9, d), seconds: 200)) }
        let insight = ProgressAggregator.weeklyInsight(days: days, now: now, calendar: calendar)
        XCTAssertNotNil(insight)
        XCTAssertNil(insight?.monthChangePercent)
    }

    func testMonthChangeInsufficientWhenHistoryNotCovered() {
        // 数据最早只到 9/10 —— 覆盖不到上月 1 号，环比必须缺席。
        var days: [DailyActivity] = []
        for d in 1...31 { days.append(activity(day(8, d), seconds: 300)) }
        for d in 1...16 { days.append(activity(day(9, d), seconds: 300)) }
        // 把窗口掐到 9/10 之后（覆盖不到上月 1 号）。
        days = days.filter { $0.day >= day(9, 10) }
        XCTAssertEqual(days.count, 7)
        let insight = ProgressAggregator.weeklyInsight(days: days, now: now, calendar: calendar)
        XCTAssertEqual(insight?.isMonthSampleSufficient, false)
        XCTAssertNil(insight?.monthChangePercent)
    }

    func testEmptyActivityReturnsNil() {
        XCTAssertNil(ProgressAggregator.weeklyInsight(days: [], now: now, calendar: calendar))
    }

    func testMondayCalculation() {
        // 2026-09-16 周三 → 本周一 9/14。
        let monday = ProgressAggregator.monday(of: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2)
        XCTAssertEqual(calendar.component(.day, from: monday), 14)
    }
}
