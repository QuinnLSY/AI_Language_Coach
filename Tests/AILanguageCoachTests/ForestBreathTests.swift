@testable import AppUI
import XCTest

/// 白哈气（#628）的规则纯函数。
///
/// 判据只有一条语义：**天冷才哈气**。反证都围绕这条语义的边界。
final class ForestBreathTests: XCTestCase {

    /// 冬天（醒着）：冷空气就是哈气的理由。
    func testBreathShowsInWinter() {
        XCTAssertTrue(
            AnimalBreath.shows(season: .winter, weather: nil, isSleeping: false),
            "冬天的动物不哈气")
        XCTAssertTrue(
            AnimalBreath.shows(season: .winter, weather: .clear, isSleeping: false),
            "冬天的大晴天也冷 —— 照样哈气（学习节奏驱动的天气偏晴时，冬天也可能晴）")
    }

    /// 下雪天：别的季节下雪同样冷。
    func testBreathShowsWhenSnowing() {
        XCTAssertTrue(
            AnimalBreath.shows(season: .summer, weather: .snow, isSleeping: false),
            "下雪天不哈气")
        XCTAssertTrue(
            AnimalBreath.shows(season: nil, weather: .snow, isSleeping: false),
            "下雪天不哈气（没传季节也一样）")
    }

    /// 暖和 + 没下雪：不哈。
    func testNoBreathWhenAwakeAndWarm() {
        XCTAssertFalse(
            AnimalBreath.shows(season: .summer, weather: nil, isSleeping: false),
            "夏天的动物哈气")
        XCTAssertFalse(
            AnimalBreath.shows(season: .spring, weather: .clear, isSleeping: false),
            "春天的动物哈气")
    }

    /// 光下雨不下雪、又不是冬天：不哈（下雨本身不构成「冷」）。
    func testRainAloneDoesNotShowBreath() {
        XCTAssertFalse(
            AnimalBreath.shows(season: .summer, weather: .rain, isSleeping: false),
            "下雨就哈气 —— 那夏雨和冬天的雪一个待遇了")
    }

    /// 睡着不哈：Zzz 已经是睡着的记号，再加一团雾就读成「冒烟」。
    ///
    /// 反证：把 `shows` 开头的 `guard !isSleeping` 删掉 → 红。
    func testSleepingAnimalsDoNotBreathe() {
        for season in [ForestSeason.spring, .summer, .autumn, .winter] {
            XCTAssertFalse(
                AnimalBreath.shows(season: season, weather: nil, isSleeping: true),
                "睡着的动物在哈气（Zzz 边上冒烟）")
            XCTAssertFalse(
                AnimalBreath.shows(season: season, weather: .snow, isSleeping: true),
                "睡着的动物在下雪天哈气")
        }
    }
}
