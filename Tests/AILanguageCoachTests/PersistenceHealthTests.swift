import AIDomain
import AIServices
@testable import AppUI
import Foundation
import XCTest

/// 落库失败必须**出声**（2026-10-02 止血批）。
///
/// 以前的形状：所有落库点都是 `try? await ...`，学习库打不开时应用照常能聊 ——
/// 「存不住」这件事没有任何天然症状，用户练一整天，退出重进才发现历史是空的。
/// 静默丢数据比崩溃更糟：崩溃有声音，这个没有。
///
/// ⚠️ 全程用**显式** `databasePath`：裸 `CoachServices()` 会落到用户真实的学习库上。
@MainActor
final class PersistenceHealthTests: XCTestCase {

    /// 一个**必定打不开**的路径：父目录在只读位置，谁也创建不出来。
    ///
    /// 不打不开这条用例就测不到东西，所以下面每个用例都先断言「确实打不开」。
    private nonisolated static let unopenablePath = "/dev/null/alc-no-such-dir/learning.db"

    // MARK: - 库不可用时必须记下来

    /// 落一次库失败一次：计数 + 一句给用户看的原因（含动作名）。
    func testPersistMessageRecordsTheFailure() async {
        let services = CoachServices(databasePath: Self.unopenablePath)
        // ⚠️ `await` 不能写进 XCTAssert 的 autoclosure（编译期直接报错），一律先取值再断言。
        let available = await services.isPersistenceAvailable
        XCTAssertFalse(available, "这个路径必须打不开，否则这条用例没在测它想测的东西")

        await services.persistMessage(ChatMessage(role: .user, content: "hello"), sessionID: UUID())

        let count = await services.persistenceFailureCount
        XCTAssertEqual(count, 1)
        // 动作名由调用点写、只写一次（AppErrorTextTests 那条纪律）：这里必须有，且只有一个冒号。
        let reason = await services.lastPersistenceFailure ?? ""
        XCTAssertTrue(reason.contains("保存这条消息"), "给用户看的原因里要有动作名，实际：\(reason)")
        XCTAssertEqual(reason.filter { $0 == "：" }.count, 1, "动作名与原因之间只能有一个冒号：\(reason)")
    }

    /// 每次失败各算一次：攒够次数 UI 才说得出「有 N 次没存住」。
    func testEveryFailedWriteCountsOnce() async {
        let services = CoachServices(databasePath: Self.unopenablePath)
        await services.persistMessage(ChatMessage(role: .user, content: "one"), sessionID: UUID())
        await services.persistMessage(ChatMessage(role: .user, content: "two"), sessionID: UUID())
        await services.finishSession(UUID())
        let count = await services.persistenceFailureCount
        XCTAssertEqual(count, 3)
    }

    // MARK: - 界面上要有横幅

    /// 库打不开时 `refreshPersistenceHealth` 必须挂一条**带动作**的横幅。
    func testRefreshRaisesABannerWhenTheDatabaseWillNotOpen() async {
        let state = AppState(services: CoachServices(databasePath: Self.unopenablePath))
        await state.refreshPersistenceHealth()

        let notice = state.persistenceNotice
        XCTAssertNotNil(notice, "库打不开却不出声 = 用户练一天才发现历史是空的")
        XCTAssertTrue(notice?.text.contains("不会保存") == true, "横幅要把后果说清楚：\(notice?.text ?? "")")
        XCTAssertNotNil(notice?.action, "必须给一个能动手的出口（打开设置里有数据目录与备份）")
    }

    /// 一切正常时不挂横幅 —— 也别把上一次的旧警告一直挂着吓人。
    func testRefreshStaysQuietWhenEverythingSaves() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-persistence-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let services = CoachServices(databasePath: dir.appendingPathComponent("learning.db").path)
        let available = await services.isPersistenceAvailable
        XCTAssertTrue(available, "临时目录里的库应当能打开")

        let state = AppState(services: services)
        await state.refreshPersistenceHealth()
        XCTAssertNil(state.persistenceNotice)
    }

    // MARK: - 接线哨兵（源码级）

    /// 开屏必须查一次：库打不开这件事只有启动时查才来得及说。
    func testStartupChecksPersistenceHealth() throws {
        let raw = try Self.code("Sources/AppUI/AppState.swift")
        XCTAssertTrue(raw.contains("await refreshPersistenceHealth()"),
                      "start() 里没有查落库健康 —— 库打不开就又变回沉默降级")
    }

    /// 中间栏必须真的把横幅画出来（挂在所有页面之上，不只聊天页）。
    func testMainViewHostsTheBanner() throws {
        let raw = try Self.code("Sources/AppUI/Views/MainView.swift")
        // ⚠️ 数**出现次数**，不能只问「出现过」：定义处本身就写着这个名字，
        // 光看 contains 的话，把横幅从布局里摘掉照样是绿的（假绿）。
        let bannerUses = raw.components(separatedBy: "persistenceBanner").count - 1
        XCTAssertGreaterThanOrEqual(bannerUses, 2,
                                    "persistenceBanner 要既定义又被挂进布局，实际出现 \(bannerUses) 次")
        XCTAssertTrue(raw.contains("await state.refreshPersistenceHealth()"),
                      "每轮对话落库后要复查一次，否则「开着开着写不进去了」照样没人知道")
    }

    /// 读源码，剥掉注释行（注释里出现的反例写法不该把哨兵判据自己骗过去）。
    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
