import XCTest

/// 语音输入与输入区交互安全（2026-09-27）的**接线哨兵**。
///
/// 这一组盯的不是文案或数值，而是**代码顺序与分支归属** —— 报障的根因全都是这类：
/// 「状态置得太晚」「识别中落进了开始录音那一格」「取消之后结果还能回填」。
/// 它们断了不报错、不崩溃，只是让界面表现回退到用户抱怨的那个样子，所以只能扫源码。
///
/// ⚠️ 被扫的**字符串不能出现在源码注释里**（注释里的同款字符串会让哨兵假绿）；
/// ⚠️ 反证必须**真删**，注释掉同样会被扫到（09-25 教训）。
/// 因此下面的扫描一律**跳过注释行**。
final class VoiceInputWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 源码的**非注释行**（`//` / `///` 开头的整行去掉），行号保留（第 1 行 = index 0）。
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            return (index + 1, line)
        }
    }

    private func firstLine(_ needle: String, in lines: [(number: Int, text: String)]) -> Int? {
        lines.first { $0.text.contains(needle) }?.number
    }

    /// 取出某个 `public func` 的函数体（到下一个同级 `public func` / 文件结束）。
    private func body(of function: String, in source: String) -> String {
        guard let start = source.range(of: function) else { return "" }
        let rest = source[start.lowerBound...]
        let tail = rest.dropFirst(function.count)
        if let next = tail.range(of: "\n    public func ") {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    // MARK: - ① 单一真相：两个布尔不再是可写状态

    /// `isRecording` / `isTranscribing` 必须是 `voicePhase` 的**派生态**，
    /// 不能再被单独赋值 —— 各自维护正是「识别中永远没点亮」的来源。
    func testChatVoiceStateIsDerivedFromPhaseNotAssigned() throws {
        for path in ["AppUI/AppState.swift", "AppUI/AppState+Voice.swift"] {
            let lines = codeLines(try source(path))
            for line in lines {
                let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                XCTAssertFalse(trimmed.hasPrefix("isRecording ="),
                               "\(path):\(line.number) 直接给 isRecording 赋值了；它应由 voicePhase 派生")
                XCTAssertFalse(trimmed.hasPrefix("isTranscribing ="),
                               "\(path):\(line.number) 直接给 isTranscribing 赋值了；它应由 voicePhase 派生")
            }
        }
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(appState.contains("public var isRecording: Bool { voicePhase == .recording }"),
                      "isRecording 应是 voicePhase 的派生计算属性")
        XCTAssertTrue(appState.contains("public var isTranscribing: Bool { voicePhase == .transcribing }"),
                      "isTranscribing 应是 voicePhase 的派生计算属性")
    }

    // MARK: - ② 识别状态必须先落，再等识别

    /// **报障的直接根因**：`finishVoiceInput` 里「进入识别态」的赋值必须**先于**
    /// 那次耗时的 `stopRecordingAndTranscribe`。以前是等它返回后才读服务层的
    /// `isTranscribing`（而服务层内部 `defer` 已经复原，恒读到 false），
    /// 于是整个识别期间界面毫无变化 —— 用户以为没点上，再点一次就落进了「重新录音」。
    func testTranscribingPhaseIsSetBeforeAwaitingRecognition() throws {
        let voice = try source("AppUI/AppState+Voice.swift")
        let body = self.body(of: "public func finishVoiceInput()", in: voice)
        XCTAssertFalse(body.isEmpty, "找不到 finishVoiceInput")

        let lines = codeLines(body)
        guard let phaseLine = firstLine("voicePhase = .transcribing", in: lines),
              let awaitLine = firstLine("await services.voice.stopRecordingAndTranscribe", in: lines) else {
            return XCTFail("识别态赋值或识别调用缺失")
        }
        XCTAssertLessThan(phaseLine, awaitLine,
                          "voicePhase 必须先置 .transcribing 再去 await 识别（第 \(phaseLine) 行 vs \(awaitLine) 行）")
    }

    /// 识别中不能再开一段：上一段的结果还在路上时重开麦克风，
    /// 新一段的中间结果会在串行的语音服务上排队，用户看到「说了话一个字都不出」。
    func testStartingVoiceInputRequiresIdlePhase() throws {
        let voice = try source("AppUI/AppState+Voice.swift")
        let body = self.body(of: "public func startVoiceInput()", in: voice)
        XCTAssertTrue(body.contains("guard voicePhase == .idle else { return }"),
                      "startVoiceInput 必须先确认处在空闲态")
    }

    // MARK: - ②-bis 学员开口即收声（#597）

    /// 点麦克风时老师还在读：停声必须是 `startVoiceInput` 的**第一件事**，
    /// 且必须排在 ASR 运行守卫**之前**（模型没启动也要先收声，见行序断言）。
    ///
    /// 两个失效方式各红一处：删掉停声调用 → 「找不到停声调用」红；
    /// 把它挪到守卫之后 → 行序断言红（用户被 ASR 提示挡住，耳边朗读继续念完）。
    ///
    /// ⚠️ 走 `codeLines`（跳过注释行）：判据字符串不许被注释里的同款文字假绿。
    func testStartingVoiceInputStopsSpeakingBeforeTheASRGuard() throws {
        let voice = try source("AppUI/AppState+Voice.swift")
        let lines = codeLines(voice)
        guard let start = firstLine("public func startVoiceInput()", in: lines) else {
            return XCTFail("找不到 startVoiceInput")
        }
        let body = lines.filter { $0.number > start }
        guard let stopLine = firstLine("await stopSpeaking()", in: body),
              let guardLine = firstLine("guard await services.isModelRunning(.asr)", in: body) else {
            return XCTFail("startVoiceInput 里找不到停声调用或 ASR 运行守卫")
        }
        XCTAssertLessThan(stopLine, guardLine,
                          "停声要先于 ASR 守卫（第 \(stopLine) 行 vs 第 \(guardLine) 行）：模型没启动也要先收声")
    }

    // MARK: - ③ 取消要真的取消（结果不许回填）

    /// 取消后，在途识别的结果回来时必须**作废**：换令牌 + 两处令牌校验。
    /// 少了校验，用户按了取消仍会看到输入框被识别结果覆盖 —— 就是报障里的「取消不了」。
    func testCancellingInvalidatesInFlightRecognition() throws {
        let voice = try source("AppUI/AppState+Voice.swift")

        let cancelBody = self.body(of: "public func cancelVoiceInput()", in: voice)
        XCTAssertTrue(cancelBody.contains("voiceInputToken = UUID()"),
                      "取消必须换令牌，让在途识别自己作废")
        XCTAssertTrue(cancelBody.contains("voicePhase = .idle"),
                      "取消要立刻回到空闲态（界面必须马上有反馈）")

        let finishBody = self.body(of: "public func finishVoiceInput()", in: voice)
        let checks = finishBody.components(separatedBy: "guard token == voiceInputToken else").count - 1
        XCTAssertGreaterThanOrEqual(checks, 2,
                                    "识别后与拼写纠正后各要校验一次令牌（实测 \(checks) 次）")
    }

    /// 服务层的第二道防线：重入的 `stopRecordingAndTranscribe` 会拿空音频
    /// 写出假的「没有录到声音」，把真实失败原因顶掉。
    func testVoiceServiceGuardsAgainstReentrantTranscribe() throws {
        let service = try source("AIServices/VoiceService.swift")
        let lines = codeLines(service)
        guard let head = firstLine("public func stopRecordingAndTranscribe", in: lines),
              let guardLine = lines.first(where: { $0.number >= head && $0.text.contains("guard !isTranscribing else") })?.number
        else {
            return XCTFail("stopRecordingAndTranscribe 缺少重入保护")
        }
        // 重入 guard 必须出现在函数最前面（在停录音之前）。
        guard let stopLine = lines.first(where: { $0.number >= head && $0.text.contains("let samples = recorder.stop()") })?.number else {
            return XCTFail("找不到 recorder.stop()")
        }
        XCTAssertLessThan(guardLine, stopLine, "重入保护要在取音频之前")
    }

    // MARK: - ④ 视图的按钮语义来自阶段

    /// 主按钮的语义必须**按阶段分派**：识别中那一格若退回「开始录音」，
    /// 用户想停就变成了重新录。
    func testMicButtonDispatchesOnPhase() throws {
        let chat = try source("AppUI/Views/ChatView.swift")
        XCTAssertTrue(chat.contains("switch voicePhase.primaryAction"),
                      "主按钮要按 voicePhase.primaryAction 分派")
        XCTAssertTrue(chat.contains("case .cancelTranscribe:"),
                      "识别中的点击语义（放弃这次识别）必须有实现")
        // 旧写法：只有「录音中 / 否则」两个分支。
        let lines = codeLines(chat)
        XCTAssertNil(firstLine("if isRecording {", in: lines),
                     "主按钮不该再有 if isRecording 这种两分支写法")
    }

    /// 识别中主按钮必须给**进度指示**。
    ///
    /// 单看「识别帧与录音帧不同」抓不住这条：把进度环去掉之后，图标会退成 `mic.fill`，
    /// 与录音中的 `waveform` 仍然「不同」，离屏判据照样绿（反证时亲眼撞上）。
    /// 所以「有没有进度指示」只能扫源码钉住。
    func testMicButtonShowsProgressWhileTranscribing() throws {
        let chat = try source("AppUI/Views/ChatView.swift")
        XCTAssertTrue(chat.contains("if voicePhase.isBusy {"),
                      "主按钮要按 voicePhase.isBusy 切换成进度指示")
        XCTAssertTrue(chat.contains("ProgressView().controlSize(.small)"),
                      "识别中的进度指示是那颗小进度环")
    }

    /// 「取消」在**识别中也要在**：识别往往要等好几秒，只给录音中开口子，
    /// 用户就被锁在「必须等它识别完再删字」的流程里。
    func testCancelButtonAppearsWhileTranscribingToo() throws {
        let chat = try source("AppUI/Views/ChatView.swift")
        XCTAssertTrue(chat.contains("if voicePhase != .idle { cancelVoiceButton }"),
                      "取消按钮的显示条件应是「不在空闲态」")
        XCTAssertFalse(chat.contains("if isRecording { cancelVoiceButton }"),
                       "旧的「只在录音中出现」写法必须消失")
    }

    /// 流式写入与定稿写入必须**共用同一个入口**，否则两者对同一段话会给出两种写法。
    ///
    /// ⚠️ 两处**分别**断言：只写一句 `chat.contains("applyVoiceText(text)")` 是假绿 ——
    /// 流式那一处还在，删掉定稿那一处照样能通过（同名调用有两处）。
    func testStreamingAndFinalTextShareOneMergeEntry() throws {
        let chat = try source("AppUI/Views/ChatView.swift")
        XCTAssertTrue(chat.contains("VoiceTranscriptMerge.apply("),
                      "合并规则只能来自 AIDomain 的纯函数")
        XCTAssertFalse(chat.contains("Self.mergedInput("),
                       "旧的 ChatView.mergedInput 已迁到 AIDomain.VoiceTranscriptMerge")

        let lines = codeLines(chat)
        // ① 定稿：主按钮拿到识别文本后在 micButton 里写入。
        guard let micLine = firstLine("private var micButton: some View {", in: lines) else {
            return XCTFail("找不到 micButton")
        }
        let micBody = lines.filter { $0.number > micLine }.prefix(45).map(\.text).joined(separator: "\n")
        XCTAssertTrue(micBody.contains("applyVoiceText("),
                      "定稿文本要在主按钮里走 applyVoiceText（否则用户改过的字会被整段覆盖）")

        // ② 流式：voiceTranscript 变化时写入。
        guard let changeLine = firstLine("onChange(of: voiceTranscript)", in: lines) else {
            return XCTFail("找不到 voiceTranscript 的监听")
        }
        let changeBody = lines.filter { $0.number > changeLine }.prefix(6).map(\.text).joined(separator: "\n")
        XCTAssertTrue(changeBody.contains("applyVoiceText("),
                      "流式结果也要走同一个 applyVoiceText")
        XCTAssertTrue(changeBody.contains("voicePhase.isCapturing"),
                      "流式写入只该发生在采集阶段（识别期不再往输入框写字）")
    }

    // MARK: - ⑤ 同源缺陷：跟读 / 词汇复习的录音入口

    /// 跟读页与词汇复习是**同一个缺陷的另外两处副本**（2026-09-27 一并修）：
    /// 识别那几秒里按钮又变回可点，点下去就是重新开麦，而上一段的识别还在跑 ——
    /// 结果回来时评的已经不是用户正在读的那一句。
    func testShadowingAndVocabularyRecordingGuardAgainstReentry() throws {
        let shadowing = try source("AppUI/AppState+Shadowing.swift")
        XCTAssertTrue(shadowing.contains("guard !isShadowingBusy else { return }"),
                      "识别 / 评分期间不许重开跟读麦克风")
        XCTAssertTrue(shadowing.contains("guard isShadowingRecording else { return }"),
                      "只有真在录音时才收尾（重入会拿空音频换回假的「没有听清」）")

        let vocabulary = try source("AppUI/AppState+Vocabulary.swift")
        XCTAssertTrue(vocabulary.contains("guard !isVocabularyReviewBusy else { return }"),
                      "识别 / 评分期间不许重开复习麦克风")
        XCTAssertTrue(vocabulary.contains("guard isVocabularyReviewRecording else { return }"),
                      "同上，只有真在录音时才收尾")
    }

    /// 跟读页的三颗动作按钮：忙时必须**真的按不动**。
    /// 只把图标换成进度环而不管点击，等于把守卫交给渲染时序去保证（差一帧就重入）。
    func testShadowingActionButtonsAreDisabledWhileBusy() throws {
        let view = try source("AppUI/Views/ShadowingView.swift")
        XCTAssertTrue(view.contains(".disabled(isBusy)"), "忙碌按钮必须 disabled")
        XCTAssertFalse(view.contains("isBusy: false"),
                       "录音按钮的忙态不许恒 false（那正是这次修掉的那一格）")
        XCTAssertTrue(view.contains("isBusy: state.isShadowingBusy"),
                      "录音按钮的忙态要接 isShadowingBusy")
    }

    // MARK: - ⑥ 离开页面必须收掉麦克风

    /// 切页只销毁视图，`AppState` 里的录音状态还在 —— 不主动收尾，麦克风会**跟着用户
    /// 去下一个页面**：他切去词典查个词，回来时录音还在继续，中间那几分钟全被采进去了。
    /// （2026-09-27 补：三页原先都没有 `onDisappear`，这是隐私与资源两头的问题。）
    func testLeavingAPageStopsCapture() throws {
        let chat = try source("AppUI/Views/ChatView.swift")
        XCTAssertTrue(chat.contains("if voicePhase != .idle { onCancelVoiceInput?() }"),
                      "对话页消失时要取消语音输入")

        let pages: [(path: String, call: String)] = [
            ("AppUI/Views/ShadowingView.swift", "state.cancelShadowingRecording()"),
            ("AppUI/Views/VocabularyView.swift", "state.cancelVocabularyReviewRecording()"),
        ]
        for page in pages {
            let view = try source(page.path)
            XCTAssertTrue(view.contains(".onDisappear {"), "\(page.path) 要有 onDisappear 收尾")
            XCTAssertTrue(view.contains(page.call), "\(page.path) 消失时要取消录音")
        }
    }

    /// 收尾动作必须**幂等**：不在录音时什么都不做。
    /// 少了 guard，每次离开页面都会去 stop 一次 recorder（空录音 → 假错误）。
    func testPageExitCancellationIsIdempotent() throws {
        let cases: [(path: String, function: String, guardLine: String)] = [
            ("AppUI/AppState+Shadowing.swift", "public func cancelShadowingRecording()",
             "guard isShadowingRecording else { return }"),
            ("AppUI/AppState+Vocabulary.swift", "public func cancelVocabularyReviewRecording()",
             "guard isVocabularyReviewRecording else { return }"),
        ]
        for item in cases {
            let body = self.body(of: item.function, in: try source(item.path))
            XCTAssertFalse(body.isEmpty, "找不到 \(item.function)")
            XCTAssertTrue(body.contains(item.guardLine),
                          "\(item.function) 要先确认真的在录音（幂等），否则离开页面会误报")
        }
    }

    // MARK: - ⑦ 发送入口的守卫

    /// 生成中按回车**不能**把输入框清空：那时 `ChatService.send` 会把自己挡下，
    /// 而输入框已经清空 —— 用户打的那句就这么没了，还以为是发失败。
    /// 而「老师正在打招呼时抢话」是明确支持的用法（也是 isGenerating），必须放行。
    func testReturnKeyDoesNotClearComposerWhileGenerating() throws {
        let chat = try source("AppUI/Views/ChatView.swift")
        let lines = codeLines(chat)
        guard let sendLine = firstLine("private func send() {", in: lines) else {
            return XCTFail("找不到 send()")
        }
        let head = lines.filter { $0.number > sendLine }.prefix(8).map(\.text).joined(separator: "\n")
        XCTAssertTrue(head.contains("guard !chat.isGenerating || chat.isGreeting else { return }"),
                      "生成中回车要拦住（否则输入被清空、消息却被丢），打招呼抢话那一格要放行")
    }

    /// 服务层是「内容不丢」的最后一道：生成中再发一条要被直接丢弃。
    ///
    /// ⚠️ 必须限定在 `send` 的函数体内：`guard !isGenerating else { return }` 在
    /// `ChatService` 里另有 4 处（重新生成 / 翻译等），整文件 contains 的话，
    /// 删掉 `send` 里那处照样绿（反证时亲眼撞上）。
    func testChatServiceDropsSendWhileGenerating() throws {
        let service = try source("AIServices/ChatService.swift")
        let body = self.body(of: "public func send(", in: service)
        XCTAssertFalse(body.isEmpty, "找不到 ChatService.send")
        XCTAssertTrue(body.contains("guard !isGenerating else { return }"),
                      "生成中不许再发一条（等待中的回复还没落地）")
    }

    /// 发送时如果麦克风还开着，必须先把这段语音收掉 ——
    /// 否则麦克风继续采，用户接着说的话会被录进一条已经发出去的消息里。
    func testSendingWhileRecordingStopsCapture() throws {
        let chat = try source("AppUI/Views/ChatView.swift")
        let lines = codeLines(chat)
        guard let sendLine = firstLine("private func send() {", in: lines) else {
            return XCTFail("找不到 send()")
        }
        let after = lines.filter { $0.number > sendLine }.prefix(30).map(\.text).joined(separator: "\n")
        XCTAssertTrue(after.contains("if voicePhase != .idle {"),
                      "发送前要判断是否还在语音流程里")
        XCTAssertTrue(after.contains("onCancelVoiceInput?()"),
                      "发送前要把语音收掉（停麦克风）")
    }
}
