import XCTest
import AIDomain

/// 每日推荐「按天恒定」。
///
/// 产品口径：**同一天、同一学习语言必须抽到同一批词**。
/// 原先是每次启动真随机 —— 一天里打开几次就换几拨，「今天要学的这 12 个词」立不住，
/// 用户练到第 7 个去泡杯茶，回来发现整批都换了。
///
/// ⚠️ 非空转说明：决定性用例是 `testSameDayPicksTheSameBatch` ——
/// 老实现（系统随机源）两次抽取会不同，这一条会红。
final class DailyWordPickerSeedTests: XCTestCase {

    // MARK: - 造词库

    /// 每个难度档 `countPerLevel` 个词的合成词库（不读真实资源，脱机可跑）。
    private func bank(countPerLevel: Int = 20, prefix: String = "") -> [DailyWord] {
        var words: [DailyWord] = []
        for level in DailyWordPicker.levelOrder {
            for index in 0..<countPerLevel {
                words.append(DailyWord(word: "\(prefix)l\(level)-w\(index)", difficulty: level))
            }
        }
        return words
    }

    private func seed(dayKey: String, language: String = "en-US") -> UInt64 {
        DailySeed.seed(dayKey: dayKey, language: language)
    }

    private func words(_ picked: [DailyWord]) -> [String] { picked.map(\.word) }

    // MARK: - 决定性

    func testSameDayPicksTheSameBatch() {
        let bank = bank()
        let today = seed(dayKey: "2026-09-18")
        let first = words(DailyWordPicker.pick(from: bank, seed: today))
        let second = words(DailyWordPicker.pick(from: bank, seed: today))

        XCTAssertFalse(first.isEmpty, "抽不出来就没有「今天的词」可言")
        XCTAssertEqual(first, second, "同一天同一语言必须是同一批（老实现每次启动真随机，这一条会红）")
    }

    func testAnotherDayPicksAnotherBatch() {
        let bank = bank()
        let today = words(DailyWordPicker.pick(from: bank, seed: seed(dayKey: "2026-09-18")))
        let tomorrow = words(DailyWordPicker.pick(from: bank, seed: seed(dayKey: "2026-09-19")))

        XCTAssertNotEqual(today, tomorrow, "换一天就该换一批，否则「按天轮换」等于没做")
    }

    func testSwitchingLanguagePicksAnotherBatch() {
        let bank = bank()
        let english = words(DailyWordPicker.pick(from: bank, seed: seed(dayKey: "2026-09-18", language: "en-US")))
        let japanese = words(DailyWordPicker.pick(from: bank, seed: seed(dayKey: "2026-09-18", language: "ja-JP")))

        XCTAssertNotEqual(english, japanese, "换学习语言即作废（与每日跟读同一条口径）")
    }

    func testSeededGeneratorIsDeterministic() {
        var a = SeededRandomGenerator(seed: 42)
        var b = SeededRandomGenerator(seed: 42)
        for _ in 0..<8 {
            XCTAssertEqual(a.next(), b.next())
        }
        var other = SeededRandomGenerator(seed: 43)
        var baseline = SeededRandomGenerator(seed: 42)
        XCTAssertNotEqual(baseline.next(), other.next())
    }

    func testSeedDiffersByDayLanguageAndPurpose() {
        XCTAssertNotEqual(
            DailySeed.seed(dayKey: "2026-09-18", language: "en-US"),
            DailySeed.seed(dayKey: "2026-09-19", language: "en-US"),
            "日子不同种子必须不同"
        )
        XCTAssertNotEqual(
            DailySeed.seed(dayKey: "2026-09-18", language: "en-US"),
            DailySeed.seed(dayKey: "2026-09-18", language: "ja-JP"),
            "语言不同种子必须不同"
        )
        XCTAssertNotEqual(
            DailySeed.seed(dayKey: "2026-09-18", purpose: "daily-words"),
            DailySeed.seed(dayKey: "2026-09-18", purpose: "daily-sentences"),
            "用途不同种子必须不同 —— 以后别的按天功能各走各的序列"
        )
        // 同样入参必须稳定（跨进程可比）。
        XCTAssertEqual(
            DailySeed.seed(dayKey: "2026-09-18", language: "en-US"),
            DailySeed.seed(dayKey: "2026-09-18", language: "en-US")
        )
    }

    // MARK: - 按种子抽不能破坏原有规则

    func testSeededPickStillHonoursTheQuota() {
        let picked = DailyWordPicker.pick(from: bank(), seed: seed(dayKey: "2026-09-18"))

        XCTAssertEqual(picked.count, DailyWordPicker.total, "总数仍是 16（这个合成词库含生词档）")
        for level in DailyWordPicker.levelOrder {
            XCTAssertEqual(
                picked.filter { $0.difficulty == level }.count,
                DailyWordPicker.quota[level] ?? 0,
                "难度 \(level) 的配额不能被「按天恒定」改掉"
            )
        }
    }

    func testSeededPickStillSkipsExcludedWords() {
        let bank = bank()
        let today = seed(dayKey: "2026-09-18")
        let first = DailyWordPicker.pick(from: bank, seed: today)
        let excluded = Set(first.prefix(4).map { $0.word.lowercased() })

        let after = DailyWordPicker.pick(from: bank, excluding: excluded, seed: today)
        XCTAssertFalse(after.contains { excluded.contains($0.word.lowercased()) }, "已认熟 / 已毕业的词不该再出现")
    }

    func testMultiSourceSeededPickIsStable() {
        let sources = [bank(countPerLevel: 10, prefix: "a-"), bank(countPerLevel: 10, prefix: "b-")]
        let today = seed(dayKey: "2026-09-18")
        let first = words(DailyWordPicker.pick(fromSources: sources, seed: today))
        let second = words(DailyWordPicker.pick(fromSources: sources, seed: today))

        XCTAssertEqual(first, second, "多本词典那条入口同样要按天恒定")
        XCTAssertFalse(first.isEmpty)
    }
}
