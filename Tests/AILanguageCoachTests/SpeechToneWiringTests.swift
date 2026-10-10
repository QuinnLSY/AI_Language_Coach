import XCTest

/// ② 朗读调门 / 语气的**接线哨兵**。
///
/// 钉住的都是「真机上不会立刻响、但响起来极难定位」的那几件事：缓存键的成员、
/// 播放侧快路径的条件、适配器用的编码器。它们的共同点是 —— 症状全都表现为
/// 「调了没反应」或「换了还是老声音」，而看着代码又像是写对了。
final class SpeechToneWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    /// 去掉整行注释后的 (行号, 文本) —— 注释里提到旧写法不该让哨兵报红。
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, raw in
                let line = String(raw)
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
                return (index + 1, line)
            }
    }

    /// 从含 `marker` 的那一行起，把语句取全。
    ///
    /// ⚠️ 续行有**三种**写法，少认一种就会把后半截的缺陷全放过：
    /// 括号未闭合（多行参数列表）、行尾 `+`、以及 —— 本仓库实际用的是 —— **行首 `+`**
    /// （`let key = "…"` 换行后 `    + "…"`）。只按「行尾有 +」判，第一行就停了，
    /// 缓存键真正带语气的那半截从没被检查过（这是本条哨兵第一版踩的坑）。
    private func statement(containing marker: String, in text: String) -> (number: Int, body: String)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        func depth(_ line: String) -> Int {
            line.reduce(0) { $0 + ($1 == "(" ? 1 : ($1 == ")" ? -1 : 0)) }
        }
        var body = lines[start]
        var balance = depth(lines[start])
        var index = start
        while index + 1 < lines.count {
            let current = lines[index].trimmingCharacters(in: .whitespaces)
            let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
            let continues = balance > 0
                || current.hasSuffix("+") || current.hasSuffix(",")
                || next.hasPrefix("+") || next.hasPrefix("&")
            guard continues else { break }
            index += 1
            body += "\n" + lines[index]
            balance += depth(lines[index])
        }
        return (start + 1, body)
    }

    // MARK: - 合成缓存键

    /// 缓存键必须**带语气、不带调门** —— 两个方向的错都会以「调了没反应」呈现。
    ///
    /// - 漏带语气：换了风格却还是老声音（缓存命中旧音频）。
    /// - 错带调门：调门在播放侧生效，与缓存的那段 wav 无关；进键只会让同一句话
    ///   因为调门不同而反复重合成（同时也没人会发现这个键其实是错的）。
    func testCacheKeyCarriesToneButNotPitch() throws {
        let path = "Sources/AIServices/VoiceService.swift"
        let text = try source(path)
        guard let key = statement(containing: "let key = ", in: text) else {
            return XCTFail("\(path) 里找不到合成缓存键的 `let key = ` 语句")
        }
        XCTAssertTrue(key.body.contains("tone.style"), "\(path):\(key.number) 缓存键必须带 style")
        XCTAssertTrue(key.body.contains("tone.emotion"), "\(path):\(key.number) 缓存键必须带 emotion")
        XCTAssertFalse(
            key.body.contains("pitch"),
            "\(path):\(key.number) 缓存键不该带调门（它在播放侧生效，进键只会反复重合成）"
        )
    }

    /// 合成的请求体必须真的把语气带上 —— 否则设置页选了也只是记在配置里。
    func testSynthesisRequestCarriesTone() throws {
        let path = "Sources/AIServices/VoiceService.swift"
        let text = try source(path)
        guard let request = statement(containing: "TTSRequest(", in: text) else {
            return XCTFail("\(path) 里找不到 `TTSRequest(` 构造点")
        }
        XCTAssertTrue(
            request.body.contains("tone:"),
            "\(path):\(request.number) 合成请求没带上语气 —— 设置页的取值到此为止"
        )
    }

    // MARK: - 播放侧

    /// 「1× 原声」快路径（`AVAudioPlayer`）**没有变调能力**，所以它只能在
    /// 「原速 + 原声」时才走。
    ///
    /// 反证：只判 `rate`，调门设了会走快路径被吃掉 —— 症状是「调门设了没反应，
    /// 但拨到 1.5× 语速就听得出变了」，看着像调门时灵时不灵。
    func testFastPathRequiresBothDefaultRateAndPitch() throws {
        let path = "Sources/AIInfrastructure/AudioPlayback.swift"
        let text = try source(path)
        for line in codeLines(text) where line.text.contains("abs(rate - 1.0) < 0.01") {
            XCTAssertTrue(
                line.text.contains("pitch == .natural"),
                "\(path):\(line.number) 快路径只判了语速 —— 调门会被吃掉（拨到非 1× 才听得出）"
            )
        }
    }

    /// 回放学员自己的录音**刻意固定原声**：跟读对照的全部意义就是听到自己真实的音高，
    /// 拿老师的调门去变调，对照的就不是自己的声音了。
    func testReplayNeverChangesTheLearnersPitch() throws {
        let path = "Sources/AIServices/VoiceService.swift"
        let text = try source(path)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("func replayLastRecording") }) else {
            return XCTFail("\(path) 里找不到 replayLastRecording")
        }
        let body = lines[start...].prefix(20).joined(separator: "\n")
        XCTAssertTrue(
            body.contains("pitch: .natural"),
            "\(path):\(start + 1) 回放必须固定 pitch: .natural（对照的是学员自己的声音）"
        )
    }

    // MARK: - 透传链路的编码器

    /// 语气键名来自配置（任意字符串），所以编码器**不能做键名转换**。
    ///
    /// 实测：`RemoteCommon.makeEncoder()` 带 `.convertToSnakeCase`，会把
    /// `prosodyStyle` 改写成 `prosody_style` —— 服务端**静默忽略**这个参数
    /// （不报错、不生效），排查方向会完全跑偏到「模型不支持」上去。
    func testRemoteAdapterEncodesToneWithoutKeyConversion() throws {
        let path = "Sources/AIProviders/RemoteTTSAdapter.swift"
        let text = try source(path)
        XCTAssertTrue(
            text.contains("makeVerbatimEncoder()"),
            "\(path) 语气请求必须用不做键名转换的编码器"
        )
        XCTAssertTrue(
            text.contains("toneFields(for: request.tone)"),
            "\(path) 语气字段的唯一算式在 `ProviderConfig.toneFields(for:)`，不许在这里自己判一遍"
        )
    }

    /// 本地 Qwen3 链路同一条规矩：语气字段与编码器都走同一份来源。
    func testQwenAdapterEncodesToneFromConfig() throws {
        let path = "Sources/AIProviders/Qwen3TTSAdapter.swift"
        let text = try source(path)
        XCTAssertTrue(text.contains("makeVerbatimEncoder()"), "\(path) 必须用不做键名转换的编码器")
        XCTAssertTrue(
            text.contains("toneFields(for: request.tone)"),
            "\(path) 语气字段必须来自 `ProviderConfig.toneFields(for:)`"
        )
    }

    // MARK: - 跟读示范

    /// 跟读示范的 `pitch` / `tone` **不给默认值**：示范必须是「同一个老师、同一个音色、
    /// 同一个调门」。留了默认值，某个调用点忘了传就会静默用原声 —— 而跟读正是
    /// 最需要听懂老师真实语调的地方，这里静默降级最难被发现。
    func testShadowingSignaturesHaveNoDefaultPitchOrTone() throws {
        let path = "Sources/AIServices/ShadowingService.swift"
        let text = try source(path)
        for line in codeLines(text) where line.text.contains("tone: SpeechTone") || line.text.contains("pitch: SpeechPitch") {
            XCTAssertFalse(
                line.text.contains("="),
                "\(path):\(line.number) 不给 default —— 漏传会静默退成原声"
            )
        }
    }

    // MARK: - 六个朗读入口

    /// 所有朗读入口必须取**同一份**播放参数（`currentSpeechPlayback()`）。
    ///
    /// 反证：某个入口自己写 `pitch: .natural`，就会出现「对话区生效、跟读示范没生效」
    /// 这类一半生效 —— 用户只在其中一个页面试，怎么都复现不出来。
    func testEveryReadingEntryUsesTheSinglePlaybackSource() throws {
        let paths = [
            "Sources/AppUI/AppState+Voice.swift",
            "Sources/AppUI/AppState+Shadowing.swift",
            "Sources/AppUI/AppState+Listening.swift",
        ]
        for path in paths {
            let text = try source(path)
            XCTAssertTrue(text.contains("currentSpeechPlayback()"), "\(path) 应当从统一入口取播放参数")
            for line in codeLines(text) where line.text.contains("pitch:") {
                // 声明那一行（`-> (pitch: SpeechPitch, tone: SpeechTone)`）不算调用点。
                if line.text.contains("-> (pitch:") { continue }
                XCTAssertTrue(
                    line.text.contains("playback.pitch"),
                    "\(path):\(line.number) 调用点自己给了调门 —— 应改用 currentSpeechPlayback()"
                )
            }
        }
    }
}
