import AIDomain
import AIInfrastructure
import AppKit
import XCTest
@testable import AppUI

/// #233 写作 / 阅读进学习记录 + 阅读当天多篇固定展示 + 段落排版（全纯函数与内存库）。
final class ReadingRecordTests: XCTestCase {

    private func makePassage(dayKey: Int) -> ReadingPassage {
        ReadingReviewRule.parse(
            """
            title: The Lighthouse Cat
            passage: Mimo lived in a lighthouse.
            Every morning she chased the gulls.

            One stormy night, a boat knocked on the rocks.
            q: Where did Mimo live?
            opt: In a school. || In a lighthouse. || On a farm. || In a boat.
            answer: 1
            quote: Mimo lived in a lighthouse.
            explain: 首句直接说明。
            trap: 其余选项无原文依据。
            """,
            dayKey: dayKey
        )
    }

    // MARK: 落库往返（内存库）

    func testReadingRoundtripAcrossDaysAndRestart() async throws {
        let db = try LearningDatabase.inMemory()
        var first = StoredReading(passage: makePassage(dayKey: 100), createdAt: Date(timeIntervalSince1970: 1_000))
        first.choices = [0: 1]
        let second = StoredReading(passage: makePassage(dayKey: 100), createdAt: Date(timeIntervalSince1970: 2_000))
        let otherDay = StoredReading(passage: makePassage(dayKey: 101), createdAt: Date(timeIntervalSince1970: 3_000))
        try await db.saveReading(first)
        try await db.saveReading(second)
        try await db.saveReading(otherDay)

        // 同一天按时间正序（编号 1、2…），别的日子不串。
        let stored = try await db.readings(dayKey: 100)
        XCTAssertEqual(stored.map(\.id), [first.id, second.id])
        XCTAssertEqual(stored[0].choices, [0: 1])
        XCTAssertFalse(stored[0].isReviewed)

        // 交卷后整体覆盖写：状态与判分都跟着走。
        first.isReviewed = true
        first.choices = [0: 1]
        XCTAssertEqual(first.correctCount(), 1)
        try await db.saveReading(first)
        let reread = try await db.readings(dayKey: 100)
        XCTAssertEqual(reread.count, 2)
        XCTAssertTrue(reread[0].isReviewed)
        let stamps = try await db.readingStamps(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(stamps.count, 1)
        XCTAssertEqual(stamps.first?.correct, 1)
        XCTAssertEqual(stamps.first?.total, 1)
    }

    func testWritingStampsRoundtrip() async throws {
        let db = try LearningDatabase.inMemory()
        try await db.appendWritingEntry(title: "Write an email", score: 82, wordCount: 96, createdAt: Date(timeIntervalSince1970: 5_000))
        try await db.appendWritingEntry(title: "Diary", score: nil, wordCount: 40, createdAt: Date(timeIntervalSince1970: 6_000))
        let stamps = try await db.writingStamps(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(stamps.count, 2)
        XCTAssertEqual(stamps[0].score, 82)
        XCTAssertNil(stamps[1].score)
        XCTAssertEqual(stamps[1].wordCount, 40)
    }

    // MARK: 进度折算（纯函数）

    private func day(_ offset: Int, calendar: Calendar, now: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    func testDailyActivityCarriesWritingAndReading() {
        let calendar = Calendar.current
        let now = Date()
        let day0 = day(0, calendar: calendar, now: now)
        let activity = ProgressAggregator.dailyActivity(
            days: [day0],
            calendar: calendar,
            messages: [],
            writings: [
                WritingStamp(score: 80, wordCount: 90, createdAt: day0.addingTimeInterval(3_600)),
                WritingStamp(score: 90, wordCount: 110, createdAt: day0.addingTimeInterval(7_200)),
            ],
            readings: [
                ReadingStamp(correct: 3, total: 4, createdAt: day0.addingTimeInterval(10_800)),
            ]
        )
        XCTAssertEqual(activity.count, 1)
        let day0Activity = activity[0]
        XCTAssertEqual(day0Activity.writings, 2)
        XCTAssertEqual(day0Activity.writingScore, 85)
        XCTAssertEqual(day0Activity.writingWords, 200)
        XCTAssertEqual(day0Activity.readings, 1)
        XCTAssertEqual(day0Activity.readingCorrect, 3)
        XCTAssertEqual(day0Activity.readingQuestions, 4)
        // 只写了作文的一天也算「练过」。
        XCTAssertTrue(day0Activity.hasPractice)
    }

    func testWeeklyInsightCountsWritingAndReading() {
        let calendar = Calendar.current
        let now = Date()
        let monday = ProgressAggregator.monday(of: calendar.startOfDay(for: now), calendar: calendar)
        let thisWeek = calendar.date(byAdding: .day, value: 1, to: monday)!
        let lastWeek = calendar.date(byAdding: .day, value: -6, to: monday)!
        let activity = ProgressAggregator.dailyActivity(
            days: [lastWeek, thisWeek],
            calendar: calendar,
            messages: [],
            writings: [WritingStamp(score: 70, wordCount: 80, createdAt: thisWeek.addingTimeInterval(3_600))],
            readings: [
                ReadingStamp(correct: 2, total: 3, createdAt: thisWeek.addingTimeInterval(7_200)),
                ReadingStamp(correct: 1, total: 3, createdAt: lastWeek.addingTimeInterval(3_600)),
            ]
        )
        let insight = ProgressAggregator.weeklyInsight(days: activity, now: now, calendar: calendar)
        XCTAssertNotNil(insight)
        XCTAssertEqual(insight?.weekWriting, 1)
        XCTAssertEqual(insight?.weekReading, 1)
    }

    func testAnnualRecapDetailMentionsWritingAndReading() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let activity = ProgressAggregator.dailyActivity(
            days: [today],
            calendar: calendar,
            messages: [],
            writings: [WritingStamp(score: 88, wordCount: 100, createdAt: today.addingTimeInterval(3_600))],
            readings: [ReadingStamp(correct: 4, total: 5, createdAt: today.addingTimeInterval(7_200))]
        )
        let recap = AnnualRecapBuilder.build(days: activity, now: now, calendar: calendar)
        let detail = recap.weeks.flatMap { $0 }.compactMap { $0 }.last?.detailText(calendar: calendar) ?? ""
        XCTAssertTrue(detail.contains("写作 1 篇"), detail)
        XCTAssertTrue(detail.contains("均分 88"), detail)
        XCTAssertTrue(detail.contains("阅读 1 篇"), detail)
        XCTAssertTrue(detail.contains("答对 4/5"), detail)
    }

    // MARK: 段落排版（阅读正文）

    func testParagraphLayoutIndentsFirstLineAndKeepsParagraphs() {
        let attributed = ReadingParagraphText.make(
            "First paragraph starts here.\nSecond paragraph follows.\n\nThird after a blank line.",
            fontSize: 13,
            color: NSColor.black,
            lineSpacing: 4
        )
        let plain = attributed.string
        XCTAssertTrue(plain.contains("First paragraph starts here."))
        XCTAssertTrue(plain.contains("Third after a blank line."))
        // 三段两换行：段落没被解析器或排版吃掉。
        XCTAssertEqual(plain.components(separatedBy: "\n").count - 1, 2)
        // 第一段首行缩进 > 0。
        let firstStyle = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(firstStyle?.firstLineHeadIndent ?? 0, 13 * 1.6, accuracy: 0.5)
        // 第二段（换行之后）带段前距。
        let secondIndex = (plain as NSString).range(of: "Second paragraph").location
        XCTAssertGreaterThan(secondIndex, 0)
        let secondStyle = attributed.attribute(.paragraphStyle, at: secondIndex, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(secondStyle?.paragraphSpacingBefore ?? 0, 0)
        XCTAssertGreaterThan(secondStyle?.firstLineHeadIndent ?? 0, 0)
    }

    func testParagraphLayoutTrimsEdgeBlankLines() {
        let attributed = ReadingParagraphText.make(
            "\n\nOnly one paragraph.\n\n",
            fontSize: 13,
            color: NSColor.black,
            lineSpacing: 2
        )
        XCTAssertFalse(attributed.string.hasPrefix("\n"))
        XCTAssertFalse(attributed.string.hasSuffix("\n"))
    }

    // MARK: StoredReading 判分口径

    func testStoredReadingCorrectCountUsesGrader() {
        let passage = makePassage(dayKey: 7)
        var entry = StoredReading(passage: passage, choices: [0: 0])
        XCTAssertEqual(entry.correctCount(), 0)
        entry.choices = [0: 1]
        XCTAssertEqual(entry.correctCount(), 1)
        XCTAssertEqual(entry.passage.questions.count, 1)
    }
}
