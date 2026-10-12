import XCTest

@testable import AIDomain

/// ⑦-D 今日战绩海报的**编排规则**（纯函数）。
///
/// 钉的是三件会悄悄说谎的事：
/// - 没练那天**不给图**（海报是要发出去的，每个数字都是承诺）；
/// - 时长太短时不报「练了 12 秒」，改说做了什么；
/// - 连续 0 天不写「连续 0 天」。
final class DailyPosterTests: XCTestCase {

    // MARK: - ① 没练就不给图

    func testNoPracticeMeansNoPoster() {
        let empty = DailyActivity(day: Self.day)
        XCTAssertNil(
            DailyPoster.make(date: Self.day, activity: empty, streakDays: 3, goalMinutes: 10, goalReached: false),
            "今天没练过就不该有一张海报 —— 发一张「练了 0 分钟」的图是在替用户难堪"
        )
    }

    /// 只背了几个词也算练过（口径与年度图那格、连续天数一致）。
    func testVocabularyOnlyStillCountsAsPractice() {
        let activity = DailyActivity(day: Self.day, vocabularyReviewed: 6)
        let poster = DailyPoster.make(date: Self.day, activity: activity, streakDays: 1, goalMinutes: 10, goalReached: false)
        XCTAssertNotNil(poster, "只背单词的那天是真的练过")
        XCTAssertEqual(poster?.headline, "今天复习 6 个词")
    }

    // MARK: - ② 主标题

    func testHeadlineUsesDurationWhenLongEnough() {
        let activity = DailyActivity(day: Self.day, seconds: 12 * 60 + 30)
        let poster = Self.poster(activity)
        XCTAssertEqual(poster?.headline, "今天练了 12 分 30 秒")
    }

    /// 只练了十几秒：说「练了 12 秒」是在替用户难堪，该说他**做了什么**。
    func testShortDayHeadlineDescribesWhatWasDone() {
        let activity = DailyActivity(day: Self.day, seconds: 12, messages: 4)
        XCTAssertEqual(Self.poster(activity)?.headline, "今天对话 4 轮")
    }

    func testShortDayFallsBackToAStub() {
        // 有练习记录但既没时长也没任何一项 >0（比如只做了一次不计数的操作）。
        let activity = DailyActivity(day: Self.day, seconds: 5)
        XCTAssertEqual(Self.poster(activity)?.headline, "今天开了个头")
    }

    // MARK: - ③ 数据行

    func testMetricsSkipZeroRows() {
        let activity = DailyActivity(day: Self.day, seconds: 600, messages: 8, readings: 2)
        let rows = Self.poster(activity)?.metrics ?? []
        XCTAssertEqual(rows.map(\.title), ["对话", "阅读"], "没做的那几项不许凑数")
        XCTAssertEqual(rows.map(\.value), ["8 轮", "2 篇"])
    }

    func testMetricsAreCapped() {
        let activity = DailyActivity(
            day: Self.day, seconds: 600,
            messages: 8, shadowingAttempts: 5,
            vocabularyAdded: 2, vocabularyReviewed: 3,
            writings: 1, readings: 4
        )
        XCTAssertEqual(Self.poster(activity)?.metrics.count, DailyPoster.maxMetrics,
                       "摆满六行就不是战绩卡了，是体检报告")
    }

    // MARK: - ④ 副标与收尾

    func testSubheadSkipsZeroStreak() {
        let activity = DailyActivity(day: Self.day, seconds: 600)
        XCTAssertEqual(Self.poster(activity, streakDays: 0)?.subhead, "",
                       "「连续 0 天」不该由分享出去的那张图替用户说")
        XCTAssertEqual(Self.poster(activity, streakDays: 1)?.subhead, "连续第 1 天")
        XCTAssertEqual(Self.poster(activity, streakDays: 5)?.subhead, "连续练习 5 天")
    }

    func testClosingPrefersGoalThenStreak() {
        let activity = DailyActivity(day: Self.day, seconds: 600)
        XCTAssertEqual(Self.poster(activity, streakDays: 1, goalMinutes: 15, goalReached: true)?.closing,
                       "今天的目标（15 分钟）达成了")
        XCTAssertEqual(Self.poster(activity, streakDays: 9, goalMinutes: 15, goalReached: false)?.closing,
                       "已经连续 9 天，节奏稳住了")
        XCTAssertEqual(Self.poster(activity, streakDays: 2, goalMinutes: 15, goalReached: false)?.closing,
                       "明天接着来")
    }

    /// 目标分钟数是插出来的：改了保底口径，海报上的数字必须跟着变。
    func testGoalMinutesIsInterpolated() {
        let activity = DailyActivity(day: Self.day, seconds: 600)
        XCTAssertEqual(Self.poster(activity, streakDays: 1, goalMinutes: 5, goalReached: true)?.closing,
                       "今天的目标（5 分钟）达成了")
    }

    // MARK: - ⑤ 日期

    func testDateTextIsChineseMonthAndDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 10))!
        XCTAssertEqual(DailyPoster.dateText(date), "10 月 13 日")
    }

    // MARK: - 工装

    private static var day: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private static func poster(
        _ activity: DailyActivity,
        streakDays: Int = 1,
        goalMinutes: Int = 10,
        goalReached: Bool = false
    ) -> DailyPoster? {
        DailyPoster.make(
            date: day,
            activity: activity,
            streakDays: streakDays,
            goalMinutes: goalMinutes,
            goalReached: goalReached
        )
    }
}
