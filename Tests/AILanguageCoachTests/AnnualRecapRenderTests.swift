import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 年度学习记录卡（贡献图）的**离屏渲染**回归。
///
/// 与同目录另两支渲染测试同款理由：本次验证环境熄屏，一律离屏出图；
/// 断言只钉「用户真能看见」这件事，不钉具体色值（见 `meanDeltaFromBaseline` 的注释）。
@MainActor
final class AnnualRecapRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 820

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    // MARK: - 造数据

    /// 一整天都练到同一个深浅 —— 好让「颜色深浅」这件事可归因。
    private func uniformRecap(_ intensity: PracticeIntensity) -> AnnualRecap {
        let slots = AnnualRecapBuilder.daySlots(now: now, calendar: calendar)
        let days = slots.map { day -> DailyActivity in
            switch intensity {
            case .none:
                return DailyActivity(day: day)
            case .light:
                return DailyActivity(day: day, seconds: 60, messages: 1)
            case .solid:
                // 20 分钟 ≥ 15 分钟目标 → 目标达成；任务只做了对话一项 → 达标不到全清。
                return DailyActivity(day: day, seconds: 20 * 60, messages: 10)
            case .full:
                return DailyActivity(
                    day: day, seconds: 20 * 60, messages: 10,
                    shadowingAttempts: 3, vocabularyReviewed: 2
                )
            }
        }
        return AnnualRecapBuilder.build(days: days, goalMinutes: 15, now: now, calendar: calendar)
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    private func render(_ view: AnyView, day: Bool, width: CGFloat? = nil) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let target = width ?? cardWidth
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: target).background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: target, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，避免把内容裁掉。
        let size = CGSize(width: target, height: max(80, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    /// 与基准图的逐像素平均差异（只统计真的变了的像素），以及变化像素的个数。
    ///
    /// ⚠️ 用**差分**而不是绝对色值：卡片的标题、图例、脚注在每一版里都一模一样，
    /// 一相减就只剩格子本身 —— 也就不必去猜位图坐标原点在上还是在下、
    /// 更不会把琥珀色的标题文字算成「格子变深了」。
    private func diff(_ rep: NSBitmapImageRep, _ baseline: NSBitmapImageRep) -> (mean: Double, count: Int) {
        let width = min(rep.pixelsWide, baseline.pixelsWide)
        let height = min(rep.pixelsHigh, baseline.pixelsHigh)
        var sum = 0.0
        var count = 0
        for x in 0..<width {
            for y in 0..<height {
                guard let a = rep.colorAt(x: x, y: y), let b = baseline.colorAt(x: x, y: y) else { continue }
                let delta = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                guard delta > 0.12 else { continue }
                sum += delta
                count += 1
            }
        }
        return (count == 0 ? 0 : sum / Double(count), count)
    }

    private func luma(_ rep: NSBitmapImageRep) throws -> CGFloat {
        let color = try XCTUnwrap(rep.colorAt(x: 2, y: 2))
        return color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AILanguageCoachTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 深浅真的分四档

    /// 练得越满，格子的颜色越深 —— 而且**只有深浅变了，格子的范围没变**。
    ///
    /// 这一条是整张卡的全部意义：四个深浅必须肉眼可分，否则「今天」和「今日任务」
    /// 两张卡片白写了。
    func testDeeperLevelsDrawDeeperShades() throws {
        let light = try render(AnyView(AnnualRecapCard(recap: uniformRecap(.light))), day: true)
        let solid = try render(AnyView(AnnualRecapCard(recap: uniformRecap(.solid))), day: true)
        let full = try render(AnyView(AnnualRecapCard(recap: uniformRecap(.full))), day: true)

        // 三版的文字完全一致（练过的天数一样），差异只可能来自格子。
        let lightToSolid = diff(solid.rep, light.rep)
        let lightToFull = diff(full.rep, light.rep)

        XCTAssertGreaterThan(lightToSolid.mean, 0.2, "「达标」必须比「开过口」明显更深（实测 \(lightToSolid.mean)）")
        XCTAssertGreaterThan(
            lightToFull.mean, lightToSolid.mean + 0.1,
            "「全清」要比「达标」再深一档（实测 \(lightToFull.mean) vs \(lightToSolid.mean)）"
        )
        // 深浅不同、范围相同：变化的像素数应当基本一致（差的是反锯齿边缘）。
        let gap = abs(Double(lightToFull.count - lightToSolid.count)) / Double(max(lightToSolid.count, 1))
        XCTAssertLessThan(
            gap, 0.2,
            "三版染色的格子数应当一样（只是深浅不同），实测变化像素 \(lightToSolid.count) vs \(lightToFull.count)"
        )
    }

    /// 空网格与「开过口」之间必须一眼看得出差别（否则整年看着像一张白纸）。
    func testTintedGridIsClearlyDifferentFromEmptyGrid() throws {
        let empty = try render(AnyView(AnnualRecapCard(recap: AnnualRecap.empty(now: now))), day: true)
        let light = try render(AnyView(AnnualRecapCard(recap: uniformRecap(.light))), day: true)

        let changed = diff(light.rep, empty.rep)
        XCTAssertGreaterThan(
            changed.count, 20_000,
            "一整年的格子都点亮了，变化像素不该这么少（实测 \(changed.count)）"
        )
        XCTAssertGreaterThan(changed.mean, 0.12, "空格子与点亮格子必须不是同一种颜色")
    }

    // MARK: - ② 高度跟着宽度走（说明宽高比真的生效了）

    /// 53 列 × 7 行的格子，宽了就跟着变大 —— 但如果 `.aspectRatio` 没生效，
    /// 画布要么塌成 0、要么撑到天上去。这里用「换宽度看高度」把这件事钉死。
    func testGridHeightTracksWidth() throws {
        let wide = try render(AnyView(AnnualRecapCard(recap: uniformRecap(.full))), day: true, width: 820)
        let narrow = try render(AnyView(AnnualRecapCard(recap: uniformRecap(.full))), day: true, width: 420)

        XCTAssertGreaterThan(wide.size.height, narrow.size.height + 40,
                             "宽 820 的格子应比宽 420 的大一圈（实测 \(wide.size.height) vs \(narrow.size.height)）")
        XCTAssertLessThan(wide.size.height, 320, "高度不该失控：\(wide.size.height)")
        XCTAssertGreaterThan(narrow.size.height, 120, "窄版也不能塌成一条线：\(narrow.size.height)")
        // 窗口拉到最窄时（中栏只剩 400 多 pt）整块必须还塞得下、月份不叠字 —— 落盘留证。
        try dump(narrow.rep, name: "round34-annual-recap-narrow.png")
    }

    // MARK: - ③ 日夜两版都要能看（并落盘供人眼复核）

    func testBothThemesRenderAndDumpPNG() throws {
        let day = try render(AnyView(AnnualRecapCard(recap: uniformRecap(.full))), day: true)
        let night = try render(AnyView(AnnualRecapCard(recap: uniformRecap(.full))), day: false)

        XCTAssertGreaterThan(try luma(day.rep), try luma(night.rep), "两版底色必须真的不同")
        XCTAssertEqual(day.size.height, night.size.height, accuracy: 2, "同一份内容，两版高度应一致")
        try dump(day.rep, name: "round34-annual-recap-day.png")
        try dump(night.rep, name: "round34-annual-recap-night.png")

        let sparse = try render(AnyView(AnnualRecapCard(recap: sparseRecap())), day: true)
        try dump(sparse.rep, name: "round34-annual-recap-sparse-days.png")
    }

    /// 真实使用中的样子：一年里只有零散几十天练过，深浅混杂。
    private func sparseRecap() -> AnnualRecap {
        let slots = AnnualRecapBuilder.daySlots(now: now, calendar: calendar)
        var days: [DailyActivity] = []
        for (index, slot) in slots.enumerated() where index % 9 == 0 {
            let rich = index % 27 == 0
            days.append(
                DailyActivity(
                    day: slot,
                    seconds: Double(rich ? 25 : 6) * 60,
                    messages: rich ? 12 : 3,
                    shadowingAttempts: rich ? 4 : 0,
                    vocabularyReviewed: rich ? 5 : 0
                )
            )
        }
        return AnnualRecapBuilder.build(days: days, goalMinutes: 15, now: now, calendar: calendar)
    }

    // MARK: - ④ 端到端：真实数据库里的记录真的排到了格子上

    /// 走真实链路：写进 `LearningDatabase` 的消息与复习流水 → `ProgressService`
    /// → `AnnualRecapCard`。构造数据好看不代表取数通了 —— 这条才是取数。
    func testAnnualRecapReadsRealDatabaseRows() async throws {
        let db = try LearningDatabase.inMemory()
        let session = ChatSession(startedAt: now.addingTimeInterval(-30 * 86_400))
        try await db.createSessionIfAbsent(session)

        // 三天前聊满 20 分钟 10 轮（→ 达标），五天前只说了两句（→ 开过口）。
        for (daysAgo, count) in [(3, 10), (5, 2)] {
            let start = calendar.date(
                byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)
            )!.addingTimeInterval(10 * 3600)
            for index in 0..<count {
                let stamp = start.addingTimeInterval(Double(index) * (daysAgo == 3 ? 120 : 30))
                try await db.appendMessage(
                    ChatMessage(role: index % 2 == 0 ? .user : .assistant, content: "m\(index)", createdAt: stamp),
                    sessionID: session.id
                )
            }
        }

        let service = ProgressService(learning: db)
        let recap = await service.annualRecap(now: now, calendar: calendar, goalMinutes: 15)

        XCTAssertEqual(recap.practicedDays, 2, "库里有两天有消息，图上就该有两天是亮的")
        XCTAssertEqual(recap.levelCounts[.solid], 1, "20 分钟 10 轮那天应当是「达标」")
        XCTAssertEqual(recap.levelCounts[.light], 1, "只说两句那天应当是「开过口」")
        XCTAssertEqual(recap.totalMessages, 12)
        XCTAssertGreaterThanOrEqual(recap.dayCount, 365)

        let card = try render(AnyView(AnnualRecapCard(recap: recap)), day: true)
        let empty = try render(AnyView(AnnualRecapCard(recap: AnnualRecap.empty(now: now))), day: true)
        XCTAssertGreaterThan(
            diff(card.rep, empty.rep).count, 500,
            "库里那两天的格子必须真的被点亮（变化像素太少）"
        )
        try dump(card.rep, name: "round34-annual-recap-from-database.png")
    }

    /// 复习流水也要进格子：`vocabulary_reviews` 一行一次判分，同一天同一个词判两次
    /// 只算复习了一个词（与「今日任务」卡片口径一致）。
    func testAnnualRecapCountsVocabularyReviewsFromTheLog() async throws {
        // 这一条要用**真实时钟**：`recordVocabularyReview` 的流水时间戳取的是 `Date()`，
        // 拿一个假的 `now` 去汇总，那些流水就落在「未来」而不在网格里。
        let realNow = Date()
        let db = try LearningDatabase.inMemory()
        var entry = VocabularyEntry(word: "serendipity", meaning: "意外之喜")
        _ = try await db.upsertVocabulary(entry)
        try await db.recordVocabularyReview(entry, remembered: true)
        entry.mastery += 1
        entry.reviewCount += 1
        try await db.recordVocabularyReview(entry, remembered: true)

        let stamps = try await db.vocabularyReviewStamps(since: realNow.addingTimeInterval(-365 * 86_400))
        XCTAssertEqual(stamps.count, 2, "判了两次就该有两条流水")
        XCTAssertEqual(Set(stamps.map(\.itemID)).count, 1)

        let recap = await ProgressService(learning: db)
            .annualRecap(now: realNow, calendar: calendar, goalMinutes: 15)
        let today = recap.weeks.flatMap { $0 }.compactMap { $0 }.first { $0.isToday }
        XCTAssertEqual(today?.activity.vocabularyReviewed, 1, "同一个词判两次只算复习了一个词")
        XCTAssertEqual(today?.tasksDone, 1, "只复习了词 → 三项里做到一项")
        XCTAssertEqual(today?.intensity, .light)
    }

    // MARK: - ⑤ 端到端：学习进度页真的把它画出来了

    func testProgressPageShowsAnnualRecapEndToEnd() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("annual-probe-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        await state.loadScenarios()
        await state.openProgress()

        XCTAssertEqual(state.annualRecap.weeks.count, AnnualRecapBuilder.weeksPerYear,
                       "进度页汇总时年度记录必须一起加载")
        XCTAssertGreaterThanOrEqual(state.annualRecap.dayCount, 365)

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            LearningProgressView(state: state).forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 2200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        XCTAssertGreaterThan(host.fittingSize.height, 400, "整页应能布局")
        try dump(rep, name: "round34-progress-page-with-annual-recap.png")
    }

    // MARK: - ⑥ 「前往学习记录巩固」按钮真的把意图带过去了

    func testMistakesJumpCarriesTheFocusIntent() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("records-focus-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        XCTAssertNil(state.recordsFocus)

        await state.openRecords(focus: .mistakes)
        XCTAssertTrue(state.showingRecords)
        XCTAssertEqual(
            state.recordsFocus, .mistakes,
            "跳转意图必须落到 AppState 上 —— 学习记录页是 `if/else` 新建出来的，接不住别的方式"
        )

        // 页面读一次就该把它消费掉：下次从侧边栏进来不该还自动跳。
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            RecordsView(state: state).forestTheme(theme).frame(width: 700, height: 900)
        ))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window?.contentView = host
        host.layoutSubtreeIfNeeded()
        window?.layoutIfNeeded()
        // 跳转里有一段等待布局的 sleep，给它跑完。
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNil(state.recordsFocus, "学习记录页消费掉跳转意图后必须清空")
        XCTAssertEqual(RecordsFocus.mistakes.anchorID, "records-mistakes")
    }
}
