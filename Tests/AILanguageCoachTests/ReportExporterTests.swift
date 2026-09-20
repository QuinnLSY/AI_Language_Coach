import AIDomain
import AIInfrastructure
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 学习报告导出（#210）：离屏渲染 PNG 的产品能力回归。
///
/// 断言只钉三件事：数据非空、尺寸正确、PNG 格式合法——渲染质量本身
/// 已由 `AnnualRecapRenderTests` 等离屏回归守着，这里不重复。
@MainActor
final class ReportExporterTests: XCTestCase {

    private func solidRecap() -> AnnualRecap {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let slots = AnnualRecapBuilder.daySlots(now: now, calendar: calendar)
        let days = slots.map { day in
            DailyActivity(day: day, seconds: 20 * 60, messages: 10, shadowingAttempts: 3, vocabularyReviewed: 2)
        }
        return AnnualRecapBuilder.build(days: days, goalMinutes: 15, now: now, calendar: calendar)
    }

    private func assertValidPNG(_ data: Data, expectedWidth: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertGreaterThan(data.count, 10_000, "导出的图不该是一张几乎空白的图", file: file, line: line)
        // PNG 魔数：89 50 4E 47。
        XCTAssertEqual([UInt8](data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], file: file, line: line)
        // IHDR 里的像素宽（大端）：等于导出宽度 × backing scale（2x 屏出 2x 图，更清晰）。
        let pngWidth = Int(data[data.index(data.startIndex, offsetBy: 16)])
            << 24 | Int(data[data.index(data.startIndex, offsetBy: 17)]) << 16
            | Int(data[data.index(data.startIndex, offsetBy: 18)]) << 8
            | Int(data[data.index(data.startIndex, offsetBy: 19)])
        let scale = pngWidth > Int(expectedWidth) ? 2 : 1
        XCTAssertEqual(CGFloat(pngWidth), expectedWidth * CGFloat(scale), accuracy: 1, file: file, line: line)
    }

    func testAnnualRecapPNGIsNonEmptyAndCorrectWidth() throws {
        for day in [true, false] {
            let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
            let data = try XCTUnwrap(
                ReportExporter.annualRecapPNG(recap: solidRecap(), theme: theme),
                "\(day ? "日" : "夜")档导出必须成功"
            )
            try assertValidPNG(data, expectedWidth: ReportExporter.defaultWidth)
        }
    }

    func testExportHonoursCustomWidth() throws {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let data = try XCTUnwrap(
            ReportExporter.annualRecapPNG(recap: solidRecap(), theme: theme, width: 500)
        )
        try assertValidPNG(data, expectedWidth: 500)
    }
}
