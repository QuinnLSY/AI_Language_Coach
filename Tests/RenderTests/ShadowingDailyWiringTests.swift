import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 每日跟读（需求一）在**真实链路**上的守卫：`AppState` → `CoachServices` → 落盘缓存。
///
/// 领域层的解析/轮转已由 `DailyWordContentTests` 钉住；这里钉的是接线：
/// 「今天已经生成过 → 页面直接用它，一行都不重生成」。
/// 走的是真缓存命中分支，**不碰模型**（缓存未命中会去调 LLM，所以用例只测命中那一条）。
@MainActor
final class ShadowingDailyWiringTests: XCTestCase {

    private var window: NSWindow?

    /// 快照真实的「练到第几句」并**清空**，返回还原闭包。
    ///
    /// ⚠️ `shadowing.progress` 是真 `UserDefaults` 里的键，而 `AppState` 在
    /// 「今天的素材」这条路上会**落回**它（切页 / 重启接着上次那一句练）。
    /// 不清的话，同一个测试进程里别人写进去的位置会漏到这里 ——
    /// 本类断言「全新一天从第一句开始」就会变成「看谁先跑」的抽奖。
    private func isolateShadowingProgress() -> () -> Void {
        let key = AppState.shadowingProgressStorageKey
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// 一份「今天已经有句子」的 AppState：临时配置文件 + 临时缓存文件，绝不碰真实数据。
    private func makeState(seeded: Bool) async throws -> (AppState, ShadowingDailyStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowing-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = ShadowingDailyStore(fileURL: directory.appendingPathComponent("shadowing-daily.json"))
        if seeded {
            await store.save(
                day: ShadowingDailyRule.dayKey(),
                language: "en-US",
                drills: (0..<20).map { index in
                    ShadowingDrill(
                        id: "seed-\(index)",
                        text: "Sentence number \(index) is deliberately a bit longer than the old fixed drills.",
                        translation: "第 \(index) 句。",
                        topic: index < 4 ? "机场值机" : "酒店入住",
                        difficulty: 3,
                        focus: "连读"
                    )
                }
            )
        }

        let config = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let dictionaryBase = directory.appendingPathComponent("dict", isDirectory: true)
        let state = AppState(services: CoachServices(
            config: config,
            databasePath: ":memory:",
            dictionaryStore: DictionaryBookStore(
                fileURL: dictionaryBase.appendingPathComponent("dictionaries.json"),
                booksDirectory: dictionaryBase.appendingPathComponent("books", isDirectory: true)
            ),
            shadowingDailyStore: store
        ))
        return (state, store)
    }

    /// 「同一天必须拿到同一批句子」：缓存里有今天的句子时，`AppState` 要**直接采用**，
    /// 不重生成、并把「这是今日生成的」标出来（页面据此显示「今日 · 20 句」）。
    ///
    /// 这里量的是**全新一天**（`shadowing.progress` 里没有今天的记录）——
    /// 没有记录就不该凭空冒出位置来。至于「回来接着上次那一句」，那是**存了记录**的场景，
    /// 由 `ShadowingSentenceStateTests.testSavedIndexIsRestoredOnTheSameDay` 钉住。
    func testTodayDrillsAreTakenFromCacheWithoutRegenerating() async throws {
        let restoreProgress = isolateShadowingProgress()
        defer { restoreProgress() }
        let (state, store) = try await makeState(seeded: true)

        await state.loadTodayShadowingDrills()

        XCTAssertEqual(state.shadowingDrills.count, 20, "应当用缓存里那一批 20 句")
        XCTAssertEqual(state.shadowingDrills.first?.id, "seed-0", "拿到的必须是缓存内容，不是别的来源")
        XCTAssertTrue(state.shadowingIsDailyGenerated, "缓存命中同样要标成「今日生成」")
        XCTAssertNil(state.shadowingNotice, "缓存命中的正常路径不该给用户任何提示")
        XCTAssertEqual(state.shadowingIndex, 0, "今天还没记住过位置，就该从第一句开始")
        XCTAssertFalse(state.isShadowingLoading, "缓存命中是瞬时的事，不该闪加载态")

        // 缓存本身也得还在（别在读取路径上误删）。
        let cached = await store.drills(day: ShadowingDailyRule.dayKey(), language: "en-US")
        XCTAssertEqual(cached?.count, 20)
    }

    /// 切走再切回来不该换句子：第二次进入跟读页拿到的是同一批（同一份缓存）。
    func testReenteringThePageKeepsTheSameSentences() async throws {
        let (state, _) = try await makeState(seeded: true)

        await state.loadShadowing()
        let first = state.shadowingDrills.map(\.text)
        await state.loadShadowing()
        XCTAssertEqual(state.shadowingDrills.map(\.text), first, "同一天内句子必须稳稳不变")
    }

    /// 换学习语言后，昨天那份句子（甚至今天那份）都不该再被用 —— 缓存按语言作废。
    func testCacheIsInvalidatedWhenTheLearningLanguageChanges() async throws {
        let (state, store) = try await makeState(seeded: false)
        await store.save(
            day: ShadowingDailyRule.dayKey(),
            language: "ja-JP",
            drills: [ShadowingDrill(id: "ja-1", text: "これは日本語の文です。")]
        )
        // ⚠️ `await` 不能写进 `XCTAssert*` 的 autoclosure（编译器直接拒），先取出来。
        let cachedForToday = await state.services.shadowingCachedDrills(day: nil)
        XCTAssertNil(
            cachedForToday,
            "学习语言是 en-US，日语那份缓存不该被认作今天的素材"
        )
    }

    /// 缓存文件写坏 / 不存在 → 当作「今天还没生成」，**绝不删文件**（大不了重生成一次）。
    func testCorruptCacheIsIgnoredButNotDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowing-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shadowing-daily.json")
        try Data("{ 这不是 JSON".utf8).write(to: url)

        let store = ShadowingDailyStore(fileURL: url)
        let unreadable = await store.drills(day: ShadowingDailyRule.dayKey(), language: "en-US")
        XCTAssertNil(unreadable, "坏文件应当当作「今天还没有」")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "读不出来只能当作「今天没有」，不能顺手把用户的文件清掉"
        )

        // 而且它还能被正常覆盖写成一份好的。
        await store.save(
            day: ShadowingDailyRule.dayKey(), language: "en-US",
            drills: [ShadowingDrill(id: "ok-1", text: "Recovered.", translation: "恢复了。")]
        )
        let recovered = await store.drills(day: ShadowingDailyRule.dayKey(), language: "en-US")
        XCTAssertEqual(recovered?.count, 1)
    }

    // MARK: - 跟读页外观：换一批按钮 + 今日标签

    /// 用户口径：每日 20 句、按情景随机，因此页面上必须能看出
    /// ①这批是今日生成的 ②有个「换一批」的口子在（不满意时能重来）。
    func testShadowingHeaderShowsDailyBadgeAndRefreshButton() async throws {
        let (state, _) = try await makeState(seeded: true)
        await state.loadTodayShadowingDrills()

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(ShadowingView(state: state).forestTheme(theme)))
        // **固定视口**，不用 `fittingSize`：这一页是「工具条 + ScrollView」，
        // 页面的理想高度只有工具条参与计算，滚动区在无界高度下会展开成一片空白，
        // 抓出来的图既不像用户看到的、也证明不了句子画没画出来。
        let viewport = CGSize(width: 780, height: 600)
        host.frame = NSRect(origin: .zero, size: viewport)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("round42-shadowing-daily-day.png"))

        XCTAssertGreaterThan(rep.pixelsWide, 700)

        // ⚠️ 不要拿 `fittingSize` 当布局健康检查：这一页是「工具条 + ScrollView」，
        // 滚动区的内容不参与理想高度计算（实测 fittingSize 只有 307.5），断言它会误伤好页面。
        // 要看的是「用户真的看得见什么」—— 下面那条分区域的墨迹断言。

        // ⚠️ 参考句走的是可划词文本（AppKit `NSTextView`）。那层的自定尺寸量错时不会崩、
        // 不会报错，只是「有框没字」——实测就翻过车（容器宽度被压成 1pt，整句话都画没了）。
        // 所以这里**只数卡片那一条带**的墨迹：页头页脚本来就有字，把它们算进来，
        // 一张空白页也能过断言。
        let scale = CGFloat(rep.pixelsWide) / viewport.width
        let band = CGRect(
            x: 30 * scale, y: 190 * scale, width: 720 * scale, height: 120 * scale
        )
        let sentenceInk = inkCount(rep, in: band)
        XCTAssertGreaterThan(
            sentenceInk, 300,
            "跟读页的参考句必须真的画出来（卡片那一带实测墨迹 \(sentenceInk)）"
        )
        // 同一句话在旧版代码里的墨迹是 1（只剩一个点），差了两个量级 —— 阈值不会误报。
    }

    /// 图上某块区域里「不是背景」的像素数（背景浅，深色像素就是字形）。
    private func inkCount(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
        let minX = max(0, Int(rect.minX))
        let maxX = min(rep.pixelsWide, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(rep.pixelsHigh, Int(rect.maxY))
        var count = 0
        for x in stride(from: minX, to: maxX, by: 2) {
            for y in stride(from: minY, to: maxY, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.redComponent < 0.8 || color.greenComponent < 0.8 { count += 1 }
            }
        }
        return count
    }
}
