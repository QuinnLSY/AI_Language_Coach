import AIDomain
import AIInfrastructure
import AIServices
@testable import AppUI
import XCTest

/// S4 · UI 状态机与异步回填（12 条）。
///
/// 共同症状是**用户的操作被静默丢弃 / 结果张冠李戴** ——
/// 不报错、不崩溃，只是「点了没用」或「成绩挂到别的句子上」，编译器一点忙都帮不上。
///
/// 本文件两类判据：
/// - **纯函数 / 行为**：能直接驱动 `AppState` 或纯函数的一律走这条（能真撤反证）；
/// - **源码哨兵**：判据落在 View 内部或整条异步链路里、造不出来时才用，
///   且**每种失效方式各配一条断言**（一条包打天下等于没测）。
///
/// ⚠️ 哨兵别钉整串调用实参、别钉恒等式；判据跟着签名走（可见性 / 参数一变就要回来改）。
@MainActor
final class UIStateMachineTests: XCTestCase {

    // MARK: - 工具

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("s4-state-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 取出函数体：从 `needle` 起到下一个成员声明为止。
    private func body(of needle: String, in source: String) -> String {
        guard let range = source.range(of: needle) else { return "" }
        let rest = source[range.lowerBound...]
        let tail = rest.dropFirst(needle.count)
        let terminators = ["\n    public func ", "\n    private func ", "\n    func ",
                           "\n    public var ", "\n    private var ", "\n    var ",
                           "\n    public nonisolated ", "\n    // MARK:"]
        let ends = terminators.compactMap { tail.range(of: $0)?.lowerBound }
        if let end = ends.min() { return String(rest[..<end]) }
        return String(rest)
    }

    private func drill(_ id: String, _ text: String, _ translation: String = "") -> ShadowingDrill {
        ShadowingDrill(id: id, text: text, translation: translation, topic: "测试")
    }

    private func beginRound(_ round: [ShadowingDrill], mode: ListeningMode, on state: AppState) {
        state.listeningRound = round
        state.listeningIndex = 0
        state.isListeningDrill = true
        state.listeningMode = mode
        if mode == .meaning { state.prepareMeaningQuestion() }
    }

    // MARK: - S4-1 流式跟随（纯函数）

    /// 核心口径：**用户上翻就暂停跟随**。
    ///
    /// 反证：把 `shouldAutoScrollOnContentChange` 的返回值改成恒 `true` → 本条红。
    func testDoesNotFollowWhileUserScrolledUp() {
        XCTAssertFalse(
            ChatScrollMetrics.shouldAutoScrollOnContentChange(isScrolledUp: true, userSentMessage: false),
            "用户上翻之后，老师的流式输出不许每来一个 token 就把人拽回底部"
        )
    }

    func testFollowsWhileUserIsAtTheBottom() {
        XCTAssertTrue(
            ChatScrollMetrics.shouldAutoScrollOnContentChange(isScrolledUp: false, userSentMessage: false),
            "没上翻就该跟着最新内容走（原有体验不能丢）"
        )
    }

    /// 自己发的那一条**永远**要看得见。
    ///
    /// 反证：去掉 `userSentMessage ||` → 本条红。
    func testOwnMessageAlwaysScrollsEvenWhenScrolledUp() {
        XCTAssertTrue(
            ChatScrollMetrics.shouldAutoScrollOnContentChange(isScrolledUp: true, userSentMessage: true),
            "刚发出去的话被留在屏幕外，看起来就像「没发出去」"
        )
    }

    /// 三处自动滚动都要过这道闸门（View 内部造不出来，用哨兵）。
    ///
    /// 反证：把任意一处改回 `scrollToBottom(proxy)` 直调 → 计数变 3 → 红。
    func testStreamingAutoScrollGoesThroughTheFollowGate() throws {
        let view = try source("AppUI/Views/ChatView.swift")
        // 计数含定义那一处（`private func autoScrollIfFollowing(_ proxy: …`）：
        // 3 个触发点（消息条数 / 流式正文 / 思考文本）+ 1 处定义。
        let mentions = view.components(separatedBy: "autoScrollIfFollowing(").count - 1
        XCTAssertEqual(mentions, 4, "三处自动滚动都要走 follow 闸门，且只能由这一个定义提供")
        XCTAssertFalse(
            view.contains(".onChange(of: chat.streamingText) { scrollToBottom(proxy) }"),
            "无条件滚动 = 生成期间上翻完全不可用"
        )
    }

    // MARK: - S4-8 覆盖层真源统一

    /// 铺满窗口的遮罩浮层（全局搜索 / 考试报告…）也要让划词气泡收掉。
    ///
    /// 反证：把 `blockingOverlays` 从 `isContentCovered` 里去掉 → 本条红。
    func testContentCoveredSeesFullScreenOverlays() {
        let state = makeState()
        XCTAssertFalse(state.isContentCovered, "干净状态不该判成「被盖住」")

        state.showingGlobalSearch = true
        XCTAssertTrue(state.isContentCovered, "全局搜索铺满窗口 —— 划词气泡压在最外层会命中错乱")
        state.showingGlobalSearch = false

        state.showingHelp = true
        XCTAssertTrue(state.isContentCovered, "帮助中心同样是整块面板")
    }

    /// 切到跟读 / 听力页也算「聊天区看不见了」（原先这两页漏在清单外）。
    ///
    /// 反证：从 `coveringPanels` 里删掉 `showingShadowing` → 本条红。
    func testPageSwitchesAlsoCoverTheChat() {
        let state = makeState()

        state.showingShadowing = true
        XCTAssertTrue(state.isContentCovered, "切到跟读页，聊天区已经不在屏幕上了")
        state.showingShadowing = false

        state.showingListening = true
        XCTAssertTrue(state.isContentCovered, "听力页同理")
    }

    /// 两份判据的**分工**：遮罩浮层两边都拦；「已经在别的页上」只算被盖住、不算拦快捷键。
    ///
    /// 反证：把 `isShortcutBlockingOverlayPresented` 改回手写清单 → 第二条断言红。
    func testShortcutBlockerEqualsTheOverlaySetNotThePageSet() {
        let state = makeState()

        state.showingScenarios = true
        XCTAssertTrue(state.isContentCovered)
        XCTAssertTrue(state.isShortcutBlockingOverlayPresented, "盖着遮罩按 ⌘3 会把底下那页切走")
        state.showingScenarios = false

        state.showingShadowing = true
        XCTAssertTrue(state.isContentCovered)
        XCTAssertFalse(
            state.isShortcutBlockingOverlayPresented,
            "已经在跟读页上不该拦切页键 —— 那正是切页键要干的事"
        )
    }

    // MARK: - S4-3 听力播放

    /// 播放中再点一次必须原地返回：叠放 + 遍数虚高都是从这里来的。
    ///
    /// 反证：删掉 `guard !listeningIsPlaying else { return }` → 本条红
    /// （会一路走到 TTS 守卫并挂上「TTS 已关闭」提示）。
    func testPlayIsIgnoredWhileAudioIsAlreadyPlaying() async {
        let state = makeState()
        beginRound([drill("d0", "Can I have a receipt", "能给我收据吗")], mode: .dictation, on: state)
        state.listeningIsPlaying = true

        await state.playListeningPrompt()

        XCTAssertEqual(state.listeningPlayCount, 0, "正在放的时候再点一次不该叠一遍、更不该多记一遍")
        XCTAssertTrue(state.listeningIsPlaying, "守卫返回时不该把**当前这一次**的播放态放下")
        XCTAssertNil(state.listeningNotice, "守卫返回不许顺手挂一条提示")
    }

    /// 切句 / 换形式 / 关会话都要先停声。
    ///
    /// 反证：删掉任意一处 `Task { await stopListeningAudio() }` → 本条红。
    func testListeningNavigationAllStopAudio() throws {
        let src = try source("AppUI/AppState+Listening.swift")
        for signature in ["public func advanceListening() {",
                          "public func switchListeningMode(_ mode: ListeningMode) {"] {
            let body = self.body(of: signature, in: src)
            XCTAssertFalse(body.isEmpty, "找不到 \(signature)")
            XCTAssertTrue(body.contains("await stopListeningAudio()"),
                          "\(signature) 切之前必须停掉在途的示范音")
        }
    }

    /// 遍数只算在**刚才那一句**头上。
    ///
    /// 反证：删掉 `guard currentListeningDrill?.id == drill.id` → 本条红。
    func testPlayCountIsScopedToTheSentenceThatWasPlayed() throws {
        let body = self.body(of: "public func playListeningPrompt() async {",
                             in: try source("AppUI/AppState+Listening.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 playListeningPrompt")
        XCTAssertTrue(
            body.contains("guard currentListeningDrill?.id == drill.id else { return }"),
            "播放期间切了句，这一遍不许记到新句头上"
        )
    }

    // MARK: - S4-4 / S4-5 / S4-6 防重复点击（行为）

    /// 「开启新练习」忙时第二次点必须原地返回。
    ///
    /// 反证：删掉 `guard !isStartingFreeTalk else { return }` → 本条红
    /// （会把练习模式改成随口练，并复盘两次）。
    func testStartFreeTalkIsRejectedWhileOneIsInFlight() async {
        let state = makeState()
        let modeBefore = state.productPracticeMode
        state.isStartingFreeTalk = true

        await state.startFreeTalk()

        XCTAssertEqual(state.productPracticeMode, modeBefore, "忙时第二次点必须原地返回，不该改练习模式")
        XCTAssertTrue(state.isStartingFreeTalk, "闸门归**外面那一次**持有，第二次调用不许把它提前放下")
    }

    /// 「重测一轮」出卷在途时第二次点必须原地返回。
    ///
    /// 反证：删掉 `guard !isPlacementLoading else { return }` → 本条红（会落两张卷）。
    func testRestartPlacementIsRejectedWhilePaperIsBeingBuilt() async {
        let state = makeState()
        state.isPlacementLoading = true

        await state.startPlacement()

        XCTAssertTrue(state.placementPaper.isEmpty, "出卷在途时第二次点必须原地返回")
    }

    /// 取今日跟读素材的并发闸门。
    ///
    /// 反证：删掉 `guard !isGeneratingShadowingDrills else { return }` → 本条红
    /// （第二次会真的发起一次生成，把手上这批整批换掉）。
    func testShadowingDailyLoadIsRejectedWhileAlreadyInFlight() async {
        let state = makeState()
        let existing = [drill("keep-1", "keep this one"), drill("keep-2", "keep this too")]
        state.shadowingDrills = existing
        state.isGeneratingShadowingDrills = true

        await state.loadTodayShadowingDrills(regenerate: true)

        XCTAssertEqual(state.shadowingDrills.map(\.id), existing.map(\.id),
                       "取数在途时第二次请求必须原地返回，不许把练到一半的句子换掉")
    }

    // MARK: - S4-2 / S4-11 / S4-12 / S4-7 / S4-10 源码哨兵

    /// 跟读：先把「这次录的是谁」钉住，界面回填再校验一次。
    ///
    /// 反证：删掉 `currentShadowingDrill?.id == drill.id` → 本条红。
    func testShadowingBackfillChecksTheSentenceIsStillCurrent() throws {
        let body = self.body(of: "public func finishShadowingRecording()",
                             in: try source("AppUI/AppState+Shadowing.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 finishShadowingRecording")
        XCTAssertTrue(body.contains("let recordedDrill = currentShadowingDrill"),
                      "识别 / 评测前就要钉住对象，否则这一句的录音会被拿去跟下一句比")
        XCTAssertTrue(body.contains("currentShadowingDrill?.id == drill.id"),
                      "界面回填必须校验「还是这一句」—— 否则「第 4 句」会挂着第 3 句的成绩")
        XCTAssertTrue(body.contains("currentShadowingPassage?.id == passage.id"), "段落粒度同理")
        XCTAssertTrue(body.contains("defer { isShadowingBusy = false }"),
                      "忙碌态要罩住整条链路；识别一完就放开，那一瞬间「下一句」正好可点")
    }

    /// 跟读：四处切句 / 切粒度都要先停声。
    ///
    /// 反证：删掉任意一处 `await stopShadowingAudioBeforeSwitch()` → 本条红。
    func testEveryShadowingNavigationStopsInFlightAudio() throws {
        let src = try source("AppUI/AppState+Shadowing.swift")
        for signature in ["public func setShadowingMode(_ mode: ShadowingMode) async {",
                          "public func nextShadowingPassage() async {",
                          "public func nextShadowingDrill() async {",
                          "public func previousShadowingDrill() async {"] {
            let body = self.body(of: signature, in: src)
            XCTAssertFalse(body.isEmpty, "找不到 \(signature)")
            XCTAssertTrue(body.contains("await stopShadowingAudioBeforeSwitch()"),
                          "\(signature) 切之前必须停掉在途的示范音")
        }
    }

    /// 朗读：AppState 侧也要有世代令牌（底层服务管声音，这里管界面回写）。
    ///
    /// 反证：删掉 `guard speakRequestToken == token` → 本条红。
    func testSpeakCarriesAGenerationToken() throws {
        let src = try source("AppUI/AppState+Voice.swift")
        let speak = self.body(of: "public func speak(_ text: String) async {", in: src)
        XCTAssertFalse(speak.isEmpty, "找不到 speak")
        XCTAssertTrue(speak.contains("guard speakRequestToken == token else { return }"),
                      "被后一次朗读作废的那一次不许再回写 phase / error")

        let stop = self.body(of: "public func stopSpeaking() async {", in: src)
        XCTAssertTrue(stop.contains("speakRequestToken = nil"), "停声也要作废在途那次的回写")
    }

    /// 翻译：回填前复查正文没变（编辑重发会保留同一个 id）。
    ///
    /// 反证：删掉那条 `guard ... content == source` → 本条红。
    func testTranslateRechecksTheMessageContent() throws {
        let body = self.body(of: "public func translate(messageID: UUID) async {",
                             in: try source("AIServices/ChatService.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 translate")
        XCTAssertTrue(body.contains("?.content == source"),
                      "翻译途中编辑重发同一条 → 旧译文会挂到新正文底下")
    }

    /// 写作：改写对比比的是**交出去的那一版**，不是活草稿。
    ///
    /// 反证：把 View 改回 `state.writingDraft` → 本条红。
    func testWritingDiffUsesTheSubmittedSnapshot() throws {
        let body = self.body(of: "private func diffText(", in: try source("AppUI/Views/WritingView.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 diffText")
        XCTAssertTrue(body.contains("original: state.writingSubmittedEssay"),
                      "用活草稿比 diff，会把用户刚改的词标成「老师改的」")
        XCTAssertFalse(body.contains("original: state.writingDraft"))
    }

    /// 交卷时留底、收卡时忘掉。
    ///
    /// 反证：删掉 `writingSubmittedEssay = essay` 或收卡里那句清空 → 本条红。
    func testSubmittedEssaySnapshotLifecycle() async {
        let state = makeState()
        XCTAssertTrue(state.writingSubmittedEssay.isEmpty, "没交过卷就是空的")

        state.writingSubmittedEssay = "hello world"
        state.dismissWritingReview()
        XCTAssertTrue(state.writingSubmittedEssay.isEmpty, "收卡就该忘掉那一版正文")

        let submit = self.body(of: "public func submitWriting() async {",
                               in: (try? source("AppUI/AppState+WritingReading.swift")) ?? "")
        XCTAssertTrue(submit.contains("writingSubmittedEssay = essay"), "交卷要留一份底")
    }

    /// 自动朗读只在**条数变多**时触发。
    ///
    /// 反证：改回 `count > 0` → 删一条消息会把上一条旧回复重念一遍。
    func testAutoSpeakOnlyFiresWhenMessagesGrew() throws {
        let view = try source("AppUI/Views/ChatView.swift")
        XCTAssertTrue(view.contains("guard count > previous else { return }"),
                      "删除消息不是「老师刚回了一条」")
        XCTAssertFalse(view.contains("if autoSpeak, count > 0, let last"),
                       "只看 count > 0 就会把旧回复重念一遍")
    }
}
