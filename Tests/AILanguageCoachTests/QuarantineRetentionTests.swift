import AIDomain
@testable import AIInfrastructure
import Foundation
import XCTest

/// 坏库隔离目录的保留策略（#674）。
///
/// 隔离目录过去**只进不出**：库每坏一次多一份（主库 + WAL + SHM），
/// 一份 1 MB 起，攒几年就是几百 MB —— 而存储面板还在报「1 MB」。
/// 这一组钉住两条硬边界：最近那份永远不碰、只清超出保留窗口的老副本。
final class QuarantineRetentionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ name: String, daysAgo: Double) -> QuarantineRetention.Entry {
        .init(name: name, modifiedAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    // MARK: - 纯函数

    func testTheOnlyCopyIsNeverPruned() {
        let plan = QuarantineRetention.prunePlan(entries: [entry("a", daysAgo: 999)], now: now)
        XCTAssertTrue(plan.isEmpty, "只有一份时它就是「最近那份」，绝不回收")
    }

    func testCopiesBeyondTheWindowArePruned() {
        let entries = [
            entry("newest", daysAgo: 1),
            entry("second", daysAgo: 2),
            entry("third", daysAgo: 3),
            entry("fourth", daysAgo: 4),
            entry("fifth", daysAgo: 5),
        ]
        let plan = QuarantineRetention.prunePlan(entries: entries, now: now)
        XCTAssertEqual(Set(plan), ["fourth", "fifth"], "留最近 \(QuarantineRetention.maxKeptCopies) 份，其余回收")
        XCTAssertEqual(plan.count + QuarantineRetention.maxKeptCopies, entries.count)
    }

    func testExpiredCopiesArePrunedEvenInsideTheKeepWindow() {
        let entries = [
            entry("newest", daysAgo: 1),
            entry("old-1", daysAgo: Double(QuarantineRetention.maxAgeDays) + 10),
            entry("old-2", daysAgo: Double(QuarantineRetention.maxAgeDays) + 20),
        ]
        let plan = QuarantineRetention.prunePlan(entries: entries, now: now)
        XCTAssertEqual(Set(plan), ["old-1", "old-2"], "超龄的不再留，哪怕它排在保留窗口之内")
    }

    /// 最近那份无条件保留 —— 它是上一次的抢救现场，清掉等于抹掉最后一次证据。
    func testTheNewestCopySurvivesEvenWhenExpired() {
        let entries = [
            entry("newest", daysAgo: Double(QuarantineRetention.maxAgeDays) + 30),
            entry("older", daysAgo: Double(QuarantineRetention.maxAgeDays) + 40),
        ]
        let plan = QuarantineRetention.prunePlan(entries: entries, now: now)
        XCTAssertEqual(plan, ["older"], "全部超龄时只能清到「只剩最近那份」为止")
    }

    /// ⚠️ 反证：「全留着」与「按策略回收」的结果必须相反 ——
    /// 两者一样（plan 为空）就说明保留策略没接上，而这条断言会一直绿。
    func testKeepingEverythingWouldLetTheDirectoryGrowForever() {
        let entries = (1...6).map { entry("copy-\($0)", daysAgo: Double($0)) }
        let plan = QuarantineRetention.prunePlan(entries: entries, now: now)
        XCTAssertFalse(plan.isEmpty, "六份副本必须触发回收")
        XCTAssertLessThan(plan.count, entries.count, "全留着（\(entries.count) 份）与按策略回收（\(plan.count) 份）结果必须相反")
    }

    // MARK: - 落盘

    /// 真目录：清掉的是该清的那几份，最近那份原地不动。
    func testPruneQuarantineRemovesOnlyTheOldestCopies() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-quarantine-\(UUID().uuidString)", isDirectory: true)
        let directory = DataResilience.quarantineDirectory(base: base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        for day in 1...5 {
            let url = directory.appendingPathComponent("learning.db.corrupted-2026100\(day)-000000")
            try Data(repeating: 0x41, count: 1024).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-Double(day) * 86_400)],
                ofItemAtPath: url.path
            )
        }

        let outcome = DataResilience.pruneQuarantine(base: base, now: now)
        XCTAssertEqual(outcome.removed, 2)
        XCTAssertEqual(outcome.freedBytes, 2048)

        let survivors = (try FileManager.default.contentsOfDirectory(atPath: directory.path)).sorted()
        XCTAssertEqual(survivors.count, 3)
        XCTAssertTrue(survivors.contains("learning.db.corrupted-20261001-000000"), "最近那份必须还在")
    }

    func testPruneQuarantineOnAnEmptyDirectoryDoesNothing() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-quarantine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outcome = DataResilience.pruneQuarantine(base: base, now: now)
        XCTAssertEqual(outcome.removed, 0, "一次都没坏过 = 目录还不存在，没什么可回收")
        XCTAssertEqual(outcome.freedBytes, 0)
    }
}
