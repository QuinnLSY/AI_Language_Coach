import AppCore
import XCTest
@testable import AppUI

/// 动物季节 / 天气专属气泡语言（#606）单测。
///
/// 覆盖四件事：
/// 1. 每个物种 × 每一季都有两句非空、不重复的应景文案（漏一季 = 那个季节的动物说不上话）；
/// 2. 每种降水天气各一句；**晴没有专属句**（「晴」不配台词，同 `AnimalWeatherBehavior`）；
/// 3. 季节 / 天气句与物种通用池**不重复**（否则同一只动物会「换着词说同一句话」）；
/// 4. 合成池权重：通用句打底为主，季节句 ×3 做增量；无季节无天气时逐字等于原池。
final class AnimalSeasonalPhrasesTests: XCTestCase {

    // MARK: - 季节文案

    /// 八物种 × 四季全覆盖，每季两句、两句互不相同、都不为空。
    func testEverySpeciesHasTwoLinesPerSeason() {
        for kind in AnimalKind.allCases {
            for season in ForestSeason.allCases {
                let lines = kind.seasonalPhrases(season: season)
                XCTAssertEqual(lines.count, 2, "\(kind.displayName) 的\(season.displayName)季应有两句")
                for line in lines {
                    XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).isEmpty,
                                   "\(kind.displayName) 的\(season.displayName)季有空句")
                }
                XCTAssertNotEqual(lines[0], lines[1], "同一季的两句不许重复")
            }
        }
    }

    /// 季节句不许撞通用池：增量是「多几句话」，不是「换套词重说一遍」。
    func testSeasonalLinesNeverOverlapWithGenericPhrases() {
        for kind in AnimalKind.allCases {
            let generic = Set(kind.phrases)
            for season in ForestSeason.allCases {
                for line in kind.seasonalPhrases(season: season) {
                    XCTAssertFalse(generic.contains(line),
                                   "\(kind.displayName) 的\(season.displayName)季句子与通用池重复：\(line)")
                }
            }
        }
    }

    // MARK: - 天气文案

    /// 下雨 / 下雪各一句（非空）；晴一句都没有。
    func testWeatherLinesFollowPrecipitationOnly() {
        for kind in AnimalKind.allCases {
            XCTAssertEqual(kind.weatherPhrases(weather: .rain).count, 1,
                           "\(kind.displayName) 的下雨天应有一句")
            XCTAssertEqual(kind.weatherPhrases(weather: .snow).count, 1,
                           "\(kind.displayName) 的下雪天应有一句")
            XCTAssertTrue(kind.weatherPhrases(weather: .clear).isEmpty,
                          "晴天没有专属台词（判据同 AnimalWeatherBehavior.forWeather）")
            for line in kind.weatherPhrases(weather: .rain) + kind.weatherPhrases(weather: .snow) {
                XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(kind.displayName) 的降水句有空串")
            }
        }
    }

    // MARK: - 合成池

    /// 无季节无天气：合成池**逐字等于**物种原池（老行为一个字节不变）。
    func testPlainPoolEqualsGenericPhrases() {
        for kind in AnimalKind.allCases {
            XCTAssertEqual(kind.bubblePhrases(season: nil, weather: nil), kind.phrases)
            // 晴同样不带来任何增量（「晴」不是手动档也不配台词）
            XCTAssertEqual(kind.bubblePhrases(season: nil, weather: .clear), kind.phrases)
        }
    }

    /// 合成池 = 原池整份打底 + 季节句 ×3 + 天气句 ×1（权重即追加次数）。
    func testPoolWeightsBaseLinesAsMajority() {
        let kind = AnimalKind.bear
        let pool = kind.bubblePhrases(season: .winter, weather: .snow)
        let seasonal = kind.seasonalPhrases(season: .winter)
        let weather = kind.weatherPhrases(weather: .snow)
        XCTAssertEqual(pool.count, kind.phrases.count + seasonal.count * 3 + weather.count)
        // 原池整份在前（randomElement 不保证顺序，但「主干的份量」要钉住）
        for line in kind.phrases {
            XCTAssertTrue(pool.contains(line), "原池每一句都必须在合成池里")
        }
        for line in seasonal {
            XCTAssertEqual(pool.filter { $0 == line }.count, 3, "季节句应追加三份")
        }
        for line in weather {
            XCTAssertEqual(pool.filter { $0 == line }.count, 1, "天气句追加一份")
        }
    }

    /// 四季合成池互不相同（同一只动物在四季里说的话不一样）。
    func testSeasonalPoolsDifferAcrossSeasons() {
        for kind in AnimalKind.allCases {
            let pools = ForestSeason.allCases.map { kind.bubblePhrases(season: $0, weather: nil) }
            for i in pools.indices {
                for j in pools.indices where j > i {
                    XCTAssertNotEqual(pools[i], pools[j],
                                      "\(kind.displayName) 在\(ForestSeason.allCases[i].displayName)与\(ForestSeason.allCases[j].displayName)的池子一样")
                }
            }
        }
    }

    // MARK: - 装配哨兵

    /// ⚠️ 被扫的字符串不能出现在源码注释里；反证必须真删。
    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 冒泡入口必须走合成池（把 theme 的季节 / 天气带进每一次抽签）。
    func testTreeCanvasBubbleUsesTheSeasonalPool() throws {
        let canvas = try source("AppUI/Components/TreeCanvas.swift")
        XCTAssertTrue(canvas.contains("bubblePhrases(season: theme.season, weather: theme.weather)"),
                      "requestBubble 必须按当前生效的季节 / 天气合成文案池")
    }
}
