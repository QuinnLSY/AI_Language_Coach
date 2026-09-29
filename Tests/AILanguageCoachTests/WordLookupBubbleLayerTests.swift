import AIDomain
import AppUI
import CoreGraphics
import XCTest

// MARK: - 浮层摆位（纯函数）

final class WordLookupLayerPlacementTests: XCTestCase {

    /// 句子在浮层里的位置和锚点自己的坐标系不同原点，摆位必须先把两者搬到一起。
    func testPlacementTranslatesAnchorIntoLayerCoordinates() {
        let sentenceFrame = CGRect(x: 120, y: 240, width: 320, height: 22)
        let word = CGRect(x: 30, y: 4, width: 48, height: 15)
        // 句子自己看到的可视边界可能为负（它在窗口右半边，左边还有半屏空间）。
        let space = WordLookupSpace(topLimit: -240, bottomLimit: 560, leftLimit: -120, rightLimit: 700)
        let bubble = CGSize(width: WordLookupBubble.maxWidth, height: WordLookupBubble.fallbackHeight)

        let point = WordLookupLayerPlacement.origin(
            anchor: word, space: space,
            sourceFrameInLayer: sentenceFrame, bubble: bubble
        )

        // ① 与「先平移再算」完全等价 —— 摆位规则本身没有被改写。
        let expected = WordBubblePlacement.origin(
            anchor: word.offsetBy(dx: sentenceFrame.minX, dy: sentenceFrame.minY),
            bubble: bubble,
            space: space.offsetBy(dx: sentenceFrame.minX, dy: sentenceFrame.minY)
        )
        XCTAssertEqual(point.x, expected.x, accuracy: 0.001)
        XCTAssertEqual(point.y, expected.y, accuracy: 0.001)
        // ② 气泡压在词的**下方**并留出间距：下部空间足够时不该翻到上面去。
        XCTAssertEqual(point.y, 240 + word.maxY + WordBubblePlacement.gap, accuracy: 0.001)
        // ③ 水平以词为中心：隔着整句的偏移也不能算错。
        XCTAssertEqual(point.x, 120 + word.midX - bubble.width / 2, accuracy: 0.001)
    }

    /// 句子靠近底部 → 气泡翻到词的上方**（跨坐标系也不能失效）。
    func testPlacementFlipsAboveWhenNoRoomBelow() {
        let sentenceFrame = CGRect(x: 40, y: 700, width: 300, height: 20)
        let word = CGRect(x: 10, y: 2, width: 40, height: 15)
        // 可视区下边界距词只剩 8pt：下方放不下 84pt 的气泡。
        let space = WordLookupSpace(topLimit: -700, bottomLimit: 10, leftLimit: -40, rightLimit: 600)
        let bubble = CGSize(width: WordLookupBubble.maxWidth, height: WordLookupBubble.fallbackHeight)

        let point = WordLookupLayerPlacement.origin(
            anchor: word, space: space,
            sourceFrameInLayer: sentenceFrame, bubble: bubble
        )

        XCTAssertLessThan(
            point.y + bubble.height, 700 + word.minY,
            "下方放不下时气泡要整个翻到词的上方"
        )
    }
}

// MARK: - 浮层状态机

@MainActor
final class WordLookupBubblePresenterTests: XCTestCase {

    /// 内容是异步来的：探测那一刻往往还没有卡，不该先弹出一个空泡。
    func testPresenterWaitsForCardBeforeShowing() {
        let presenter = WordLookupBubblePresenter()
        let sentenceID = UUID()

        presenter.present(sentenceID: sentenceID, word: "snatch", card: nil, actions: .init())
        XCTAssertNil(presenter.request, "内容还没到就不显示")

        presenter.updateCard(WordLookupCard(text: "snatch", translation: "抢夺"))
        XCTAssertEqual(presenter.request?.card.text, "snatch")
        XCTAssertEqual(presenter.request?.sentenceID, sentenceID)
    }

    /// 鼠标扫过一长句会连着触发好几次探测：晚到的旧词不能盖在新词上。
    func testPresenterDropsCardForAnotherWord() {
        let presenter = WordLookupBubblePresenter()
        presenter.present(sentenceID: UUID(), word: "rival", card: nil, actions: .init())
        presenter.updateCard(WordLookupCard(text: "rival", translation: "对手"))
        XCTAssertNotNil(presenter.request)

        presenter.updateCard(WordLookupCard(text: "snatch", translation: "抢夺"))
        XCTAssertNil(presenter.request, "不是当前划的那个词，直接丢弃")
    }

    /// 鼠标从词挪向气泡按钮要过一段夜路：这段路走完之前气泡不能收。
    func testPointerReachingBubbleKeepsItAlive() async throws {
        let presenter = WordLookupBubblePresenter()
        let sentenceID = UUID()
        presenter.present(sentenceID: sentenceID, word: "derive", card: nil, actions: .init())
        presenter.updateCard(WordLookupCard(text: "derive", translation: "得到"))

        presenter.beginGrace(ownedBy: sentenceID)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(presenter.request, "宽限期内气泡还在")

        presenter.setPointerOnBubble(true)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNotNil(presenter.request, "鼠标已经在气泡上，不该收起")

        presenter.setPointerOnBubble(false)
        // ⚠️ 这一条**必须同步断言**：刚离开的这一刻还在新起的宽限期里
        // （`setPointerOnBubble(false)` 只是重新起了一次倒计时），没有时间依赖。
        XCTAssertNotNil(presenter.request, "刚离开气泡还在宽限期里，不能立刻收")
        await waitUntil("鼠标离开气泡后应当收起") { presenter.request == nil }
    }

    /// 从 A 句划到 B 句：A 已经不再拥有气泡，它那次收起不能把 B 的气泡带走。
    func testPreviousSentenceDoesNotDismissNewOne() async throws {
        let presenter = WordLookupBubblePresenter()
        let sentenceA = UUID()
        let sentenceB = UUID()

        presenter.present(sentenceID: sentenceA, word: "apple", card: nil, actions: .init())
        presenter.updateCard(WordLookupCard(text: "apple", translation: "苹果"))
        presenter.beginGrace(ownedBy: sentenceA)

        presenter.present(sentenceID: sentenceB, word: "banana", card: nil, actions: .init())
        presenter.updateCard(WordLookupCard(text: "banana", translation: "香蕉"))

        // ⚠️ 要盯的是「A 那颗定时炸弹**响过之后** B 还活着」。只睡 450ms 看一眼的话，
        // 机器一忙 A 的宽限期还没到点，这条就变成「还没轮到就通过」的假绿 —— 观察窗口给足。
        //
        // 反证实测（三个数据点）：单独撤 `present` 里的 `graceTask?.cancel()` → **仍绿**；
        // 单独撤 `finishGrace` 里的拥有者校验 → **仍绿**；两道闸**一起撤** → 红。
        // 也就是说「换成 B 后 A 的倒计时收不掉 B」由两条独立机制各保一次（取消 + 归属校验），
        // 本用例钉的是**这个不变量**，钉不到其中任何单独一行 —— 这正是它该有的样子。
        await waitHolding("A 那句的旧宽限期不该把 B 的气泡带走") {
            presenter.request?.card.text == "banana"
        }
    }

    // MARK: - 时间相关断言的两种写法
    //
    // ⚠️ 宽限期是 350ms。凡是要断言「等一会儿之后会怎样」，**别**写「睡 350+xx ms 再看一眼」：
    // 余量只有那点 xx，全量 1300+ 用例一起跑时机器一忙，`Task.sleep` 过冲轻易吃掉它，
    // 同一份代码就随机变红（本仓库真为此排查过一轮）。改成下面两种，语义不变、不与调度抖动赛跑。

    /// 反复检查直到条件成立；超时即失败。「等某事最终发生」用它。
    private func waitUntil(
        _ message: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等了 \(timeout)s 仍未满足：\(message)", file: file, line: line)
    }

    /// 在窗口内反复检查条件**一直**成立，破一次立刻失败。「等某事最终不发生」用它。
    ///
    /// 比「睡固定时长再看一眼」强两处：观察窗口给足（宽限期 350ms 时这里给 1.2s，
    /// 机器再忙也早该响过了），且一旦坏了立刻红，不必等窗口走完。
    private func waitHolding(
        _ message: String,
        duration: TimeInterval = 1.2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard condition() else {
                XCTFail(message, file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

// MARK: - 浮层挂载层级的接线哨兵

/// 2026-09-29 用户口径：**任何浮卡都要显示在整个应用界面的最上方**。
///
/// 报障链路：侧栏为救「徽章浮卡被中间栏盖住」抬到 zIndex(1)，而划词气泡的浮层
/// 挂在中间栏（zIndex 0）上 —— 同一个 HStack 里侧栏反过来把气泡压在了底下，
/// 气泡左半截被侧栏底色盖住。修复：浮层挪到 MainView **最外层 ZStack** 上。
final class WordLookupOverlayMountTests: XCTestCase {

    /// 源码的**非注释行**（行号保留）。
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            return (index + 1, line)
        }
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 浮层必须挂在最外层 ZStack 上，且中间栏不再挂第二份（挂两份会画出两张气泡）。
    ///
    /// 结构判据（对「挪回低层」敏感）：挂载点必须**晚于** body 里 ZStack 的最后一个孩子
    /// （`globalToastOverlays` 引用行），又**早于** GeometryReader 的收尾修饰
    /// （`.frame(minWidth: 1080`）——夹在中间 = 它修饰的是最外层 ZStack 本体。
    /// 挪回 chatArea（文件后面的独立计算属性）或任何更低层级都会落到 `.frame` 之后 → 红。
    ///
    /// 反证：把 `.wordLookupBubbleOverlay()` 挪回 chatArea → 红。标记：`// 反证：`
    func testBubbleOverlayMountsAtTheOutermostLayer() throws {
        let main = codeLines(try source("AppUI/Views/MainView.swift"))
        let mounts = main.filter { $0.text.contains(".wordLookupBubbleOverlay()") }
        XCTAssertEqual(mounts.count, 1, "浮层只允许挂一份")

        // ⚠️ 结构判据（2026-09-29 二次报障的教训）：修饰符必须紧跟在 **ZStack 的闭合
        // 括号**之后。写在括号里、跟在某个孩子后面，ViewBuilder 会把它解析成
        // 「挂在那个孩子身上」——上一版就挂到了 `globalToastOverlays`（无 toast 时是
        // EmptyView）上，锚点 preference 全丢，「任何地方都触发不了划词」。
        // 所以判据不是「行序在谁之后」（那次就是这么漏的），而是**前一行必须是
        // 闭合括号**（且不是 `globalToastOverlays` 本身）。
        guard let mount = mounts.first else { return }
        let index = main.firstIndex { $0.number == mount.number }!
        XCTAssertGreaterThan(index, 0, "浮层挂载行不该是文件第一行")
        let previous = main[index - 1].text.trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(previous, "}",
                       "浮层必须紧跟在 ZStack 闭合括号之后（写进括号里会挂到前一个孩子身上，锚点全丢）")

        let geometryClose = main.first { $0.text.contains(".frame(minWidth: 1080") }
        XCTAssertNotNil(geometryClose, "找不到 GeometryReader 的收尾修饰（结构变了就改这条判据）")
        XCTAssertLessThan(mount.number, geometryClose!.number,
                          "浮层必须挂在最外层 ZStack 上（挂在子视图属性里就到不了最上层）")

        let chat = try source("AppUI/Views/ChatView.swift")
        XCTAssertFalse(chat.contains(".wordLookupBubbleOverlay()"), "中间栏不许再挂浮层")
    }
}
