import AppUI
import XCTest

/// #600 领域层：学习节奏三档、丰季偏晴、`lush` 变色纯函数。
final class ForestMomentumTests: XCTestCase {

    // MARK: - 节奏映射

    func testMomentumLevels() {
        // 丰季：连胜 ≥ 7 且今日达标，两个都要。
        XCTAssertEqual(ForestAtmosphere.momentum(streakDays: 7, goalReached: true, hasPracticeToday: true), .flourishing)
        XCTAssertEqual(ForestAtmosphere.momentum(streakDays: 30, goalReached: true, hasPracticeToday: true), .flourishing)
        // 成长：连胜继承自昨天（今天还没开口也算），或今天练过。
        XCTAssertEqual(ForestAtmosphere.momentum(streakDays: 1, goalReached: false, hasPracticeToday: false), .growing)
        XCTAssertEqual(ForestAtmosphere.momentum(streakDays: 0, goalReached: true, hasPracticeToday: true), .growing)
        // 休憩：今天没练、连胜 0。
        XCTAssertEqual(ForestAtmosphere.momentum(streakDays: 0, goalReached: false, hasPracticeToday: false), .resting)
    }

    func testFlourishingRequiresBothStreakAndGoal() {
        // 只答一条不够：底子厚但今天没达标、或今天达标但没连续，都只是「成长」。
        XCTAssertEqual(ForestAtmosphere.momentum(streakDays: 9, goalReached: false, hasPracticeToday: true), .growing)
        XCTAssertEqual(ForestAtmosphere.momentum(streakDays: 2, goalReached: true, hasPracticeToday: true), .growing)
        // 边界：第 7 天整好算丰季（「连续打卡一周」）。
        XCTAssertEqual(ForestAtmosphere.momentum(streakDays: 6, goalReached: true, hasPracticeToday: true), .growing)
    }

    func testNegativeStreakIsTreatedAsResting() {
        // 坏数据不许把节奏推到「成长」：负连胜视同 0。
        XCTAssertEqual(ForestAtmosphere.momentum(streakDays: -3, goalReached: false, hasPracticeToday: false), .resting)
    }

    // MARK: - 丰季偏晴（只动本地兜底模拟）

    func testWeatherBiasOnlyWhenFlourishing() {
        // nil / 成长 / 休憩一律老分布（逐字相等）。
        for day in [1, 8, 60, 67, 180, 360] {
            let baseline = ForestAtmosphere.weather(dayOfYear: day)
            XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: day, momentum: nil), baseline)
            XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: day, momentum: .growing), baseline)
            XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: day, momentum: .resting), baseline)
        }
    }

    func testWeatherBiasDistribution() {
        // 全年精确分布（python 一次性算准，禁心算）：
        // 常态晴 183 / 雨 137 / 雪 46；丰季晴 312 / 雨 41 / 雪 13。
        var baseline = (clear: 0, rain: 0, snow: 0)
        var flourishing = (clear: 0, rain: 0, snow: 0)
        for day in 1...366 {
            switch ForestAtmosphere.weather(dayOfYear: day) {
            case .clear: baseline.clear += 1
            case .rain: baseline.rain += 1
            case .snow: baseline.snow += 1
            }
            switch ForestAtmosphere.weather(dayOfYear: day, momentum: .flourishing) {
            case .clear: flourishing.clear += 1
            case .rain: flourishing.rain += 1
            case .snow: flourishing.snow += 1
            }
        }
        XCTAssertEqual(baseline.clear, 183)
        XCTAssertEqual(baseline.rain, 137)
        XCTAssertEqual(baseline.snow, 46)
        XCTAssertEqual(flourishing.clear, 312)
        XCTAssertEqual(flourishing.rain, 41)
        XCTAssertEqual(flourishing.snow, 13)
        // 偏晴不许把冬天洗干净：丰季仍有 13 个雪天。
        XCTAssertTrue(flourishing.snow > 0, "丰季偏晴 ≠ 全年无雪")
    }

    func testWeatherBiasFlipsSpecificDays() {
        // 散列值落在 50...85 区间的日子在丰季转晴：冬天的小雪天（day 1）、非冬天的雨天（day 60）。
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 1), .snow)
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 1, momentum: .flourishing), .clear)
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 60), .rain)
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 60, momentum: .flourishing), .clear)
        // 散列值 ≥ 85 的日子不动：冬天照旧下雪（day 8）、非冬天照旧下雨（day 67）。
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 8, momentum: .flourishing), .snow)
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 67, momentum: .flourishing), .rain)
    }

    func testWeatherBiasFirstHundredDays() {
        // 前 100 天：常态晴 50 / 雪 30 / 雨 20；丰季晴 85 / 雪 9 / 雨 6。
        var baseline = (clear: 0, rain: 0, snow: 0)
        var flourishing = (clear: 0, rain: 0, snow: 0)
        for day in 1...100 {
            switch ForestAtmosphere.weather(dayOfYear: day) {
            case .clear: baseline.clear += 1
            case .rain: baseline.rain += 1
            case .snow: baseline.snow += 1
            }
            switch ForestAtmosphere.weather(dayOfYear: day, momentum: .flourishing) {
            case .clear: flourishing.clear += 1
            case .rain: flourishing.rain += 1
            case .snow: flourishing.snow += 1
            }
        }
        XCTAssertEqual(baseline.clear, 50)
        XCTAssertEqual(baseline.rain, 20)
        XCTAssertEqual(baseline.snow, 30)
        XCTAssertEqual(flourishing.clear, 85)
        XCTAssertEqual(flourishing.rain, 6)
        XCTAssertEqual(flourishing.snow, 9)
    }

    // MARK: - lush 变色

    func testLushExactValues() {
        // 参考值由独立脚本（python）算出后钉住：同色相、更饱和、更深。
        XCTAssertEqual(ForestAtmosphere.lush(0x4FA96B), 0x41A360) // 夏叶
        XCTAssertEqual(ForestAtmosphere.lush(0x2E7D55), 0x247A4E) // 深叶
        XCTAssertEqual(ForestAtmosphere.lush(0xA8DCC0), 0x8CD9B0) // 远山
        XCTAssertEqual(ForestAtmosphere.lush(0x74C79A), 0x5AC88C) // 中山
        XCTAssertEqual(ForestAtmosphere.lush(0x3F9E67), 0x32995E) // 近山
        XCTAssertEqual(ForestAtmosphere.lush(0x6CC476), 0x52C65F) // 春叶
        XCTAssertEqual(ForestAtmosphere.lush(0xC08A3E), 0xBB812E) // 秋叶
        XCTAssertEqual(ForestAtmosphere.lush(0x7FA8A0), 0x6DA398) // 冬叶
    }

    func testLushLeavesGrayUntouched() {
        // 灰（饱和度为 0）没有「盛」可言，原样返回。
        XCTAssertEqual(ForestAtmosphere.lush(0x808080), 0x808080)
        XCTAssertEqual(ForestAtmosphere.lush(0x000000), 0x000000)
        XCTAssertEqual(ForestAtmosphere.lush(0xFFFFFF), 0xFFFFFF)
    }

    func testLushPreservesHueBoostsSaturationDeepensLightness() {
        // 性质断言（不依赖参考值）：色相不动、饱和度不降、亮度不升，
        // 且对彩色至少有一项严格变化（否则等于没盛）。
        let samples: [UInt32] = [0x4FA96B, 0x2E7D55, 0xA8DCC0, 0x74C79A, 0x3F9E67,
                                 0x6CC476, 0xC08A3E, 0x7FA8A0, 0xBE4E04, 0x6F5CE8]
        for sample in samples {
            let before = hsl(sample)
            let after = hsl(ForestAtmosphere.lush(sample))
            XCTAssertEqual(after.hue, before.hue, accuracy: 3, "色相不该漂：0x\(String(sample, radix: 16))")
            XCTAssertGreaterThanOrEqual(after.saturation, before.saturation - 0.001)
            XCTAssertLessThanOrEqual(after.lightness, before.lightness + 0.001)
            XCTAssertTrue(after.saturation > before.saturation || after.lightness < before.lightness,
                          "盛档必须真的更盛：0x\(String(sample, radix: 16))")
        }
    }

    func testLushIsPure() {
        // 同一个颜色永远变出同一个结果（纯函数，渲染才稳定）。
        XCTAssertEqual(ForestAtmosphere.lush(0x4FA96B), ForestAtmosphere.lush(0x4FA96B))
    }

    // MARK: - 测试侧的 HSL 换算（独立于实现的判据）

    private func hsl(_ hex: UInt32) -> (hue: Double, saturation: Double, lightness: Double) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        let lightness = (maxV + minV) / 2
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if maxV == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxV == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }
}
