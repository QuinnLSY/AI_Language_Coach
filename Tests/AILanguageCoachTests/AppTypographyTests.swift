import AppCore
@testable import AppUI
import SwiftUI
import XCTest

/// 排版档位（#416）：字号档 × 界面密度档。
///
/// 判据三块：
/// ①**标准档必须逐字等价**于旧写法 `.font(.system(size:weight:design:))` ——
///   这是「1161 处批量替换无回归」的前提，等价性由 Font 相等直接钉死；
/// ②档位真的改变数值（小≠标准≠大、紧凑≠标准≠宽松），且纵向缩放**不碰横向**；
/// ③配置链路：两个字段能往返、老配置缺字段落回标准档。
final class AppTypographyTests: XCTestCase {

    // MARK: - 标准档等价（改造无回归的基石）

    /// ⚠️ 别用 `Font` 的 `==` 钉「与旧写法等价」：system 字体的相等比较走
    /// provider 盒子，同参数两次构造也可能判不等（实测）。
    /// 「标准档逐字等价」由渲染回归的**像素对比**钉死（TypographyScaleRenderTests），
    /// 这里钉换算本身：标准档不改变基准值、不改变倍率。
    func testStandardTierIsExactlyTheLegacyFont() {
        XCTAssertEqual(AppTypography.standard.size(13), 13)
        XCTAssertEqual(AppTypography.standard.size(11.5), 11.5)
        XCTAssertEqual(AppTypography.standard.textScale, 1)
        XCTAssertEqual(AppTypography.standard.verticalScale, 1)
    }

    func testStandardTierKeepsVerticalSpacingUntouched() {
        XCTAssertEqual(AppTypography.standard.vertical(16), 16)
        XCTAssertEqual(AppTypography.standard.horizontal(16), 16)
    }

    // MARK: - 档位真的改变数值

    func testTypeSizeScalesFontAndClampsToReadableFloor() {
        let large = AppTypography(typeSize: .large, density: .regular)
        XCTAssertEqual(large.size(13), 13 * 1.1, accuracy: 0.001)
        let small = AppTypography(typeSize: .small, density: .regular)
        XCTAssertEqual(small.size(13), 13 * 0.94, accuracy: 0.001)
        // 下限：再小的基准值也不能缩到不可读（负值/0 会直接把 Font 搞炸）。
        XCTAssertEqual(small.size(2), 7, "字号下限必须是 7pt")
        XCTAssertEqual(small.size(-3), 7)
    }

    func testDensityScalesVerticalOnly() {
        let spacious = AppTypography(typeSize: .regular, density: .spacious)
        XCTAssertEqual(spacious.vertical(10), 12, accuracy: 0.001, "纵向要松")
        XCTAssertEqual(spacious.horizontal(10), 10, "横向绝不缩放：定宽卡片会裁字")

        let compact = AppTypography(typeSize: .regular, density: .compact)
        XCTAssertEqual(compact.vertical(10), 8.5, accuracy: 0.001, "纵向要紧")
        XCTAssertEqual(compact.horizontal(10), 10)
    }

    func testAllTiersAreDistinctSoEveryOptionDoesSomething() {
        let scales = FontSizeMode.allCases.map(\.scale)
        XCTAssertEqual(Set(scales).count, FontSizeMode.allCases.count, "字号档之间必须有差异")
        let densities = DensityMode.allCases.map(\.verticalScale)
        XCTAssertEqual(Set(densities).count, DensityMode.allCases.count, "密度档之间必须有差异")
    }

    // MARK: - 配置链路

    func testTypeSizeAndDensityRoundTripThroughConfig() throws {
        var config = ProductConfig()
        config.typeSize = .large
        config.interfaceDensity = .compact
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: data)
        XCTAssertEqual(decoded.typeSize, .large)
        XCTAssertEqual(decoded.interfaceDensity, .compact)
    }

    func testLegacyConfigWithoutTypographyFallsBackToStandard() throws {
        // 老配置没有这两个键：必须落到标准档（= 与改造前逐字一致），而不是解码失败。
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.typeSize, .regular)
        XCTAssertEqual(decoded.interfaceDensity, .regular)
    }

    // MARK: - 接线哨兵（源码级，纯文本比对）

    /// 根视图必须注入排版环境：漏了的话整棵树永远拿标准档，
    /// 设置页切档看着切了、界面纹丝不动（静默失效，正是这类开关最坏的死法）。
    func testMainViewInjectsTypographyRoot() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/Views/MainView.swift", encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains(".appTypographyRoot(typeSize:"), "MainView 没有注入排版档位")
        XCTAssertTrue(text.contains("state.typeSize"), "注入没有接配置态")
        XCTAssertTrue(text.contains("state.interfaceDensity"), "注入没有接密度态")
    }

    /// 设置页必须有档位入口，且两个档都接了持久化 setter。
    func testSettingsHostsTypographyControls() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/Views/SettingsView.swift", encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("setTypeSize"), "字号档没有接 setter")
        XCTAssertTrue(text.contains("setInterfaceDensity"), "密度档没有接 setter")
        XCTAssertTrue(text.contains("FontSizeMode.allCases"), "字号档没有枚举所有选项")
        XCTAssertTrue(text.contains("DensityMode.allCases"), "密度档没有枚举所有选项")
    }
}
