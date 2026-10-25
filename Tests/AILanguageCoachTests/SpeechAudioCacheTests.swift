import XCTest
import AIDomain
import AIInterfaces
@testable import AIServices
import AppCore

// MARK: - 夹具

/// 只数请求次数、可指定身份与音频体积的 TTS 桩（#672）。
private final class StubTTS: TTSProvider, @unchecked Sendable {
    let providerID: String
    let kind: AIProviderKind = .tts
    private let payload: Data
    private let lock = NSLock()
    private var calls = 0

    init(id: String = "stub.tts", payload: Data = Data([0x01, 0x02])) {
        self.providerID = id
        self.payload = payload
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    /// 同步记账：`NSLock.lock()` 在 async 上下文里不可用（`noasync`）。
    private func noteCall() {
        lock.lock(); calls += 1; lock.unlock()
    }

    func initialize(config: ProviderConfig) async throws {}
    func load() async throws {}
    func unload() async {}
    func healthCheck() async -> ProviderHealth { .connected(model: nil) }
    func capabilities() -> ProviderCapabilities { ProviderCapabilities() }
    func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "Stub TTS", runtime: .remoteAPI)
    }
    func synthesize(_ request: TTSRequest) async throws -> TTSResult {
        noteCall()
        return TTSResult(audioSamples: [], sampleRate: 16_000, audioData: payload)
    }
}

/// 朗读音频缓存（#672）：缓存键必须带 runtime 身份，容量必须按字节封顶。
///
/// 两条性质都是「功能上完全正常、只是**悄悄退化**」的那一类：
/// 键少了身份 → 换供应商后读的是上家的声音（连请求都不发，日志一片安静）；
/// 容量只数条数 → 几条云端长短文就能吃掉上百兆（不报错，只在内存紧张时被系统一次性回收）。
final class SpeechAudioCacheTests: XCTestCase {

    // MARK: - 容量口径（纯函数）

    /// 装得下就不淘汰。
    func testSmallItemsNeedNoEviction() {
        let entries: [(key: String, bytes: Int)] = [("a", 1_000), ("b", 2_000)]
        let victims = SpeechAudioCachePolicy.evictionPlan(entries: entries, incoming: 3_000)
        XCTAssertTrue(victims.isEmpty, "远没到上限时不该动已经缓存的东西")
    }

    /// 淘汰按 FIFO，**够了就停**（不是一律清空）。
    func testEvictionStopsAsSoonAsTheTotalFits() {
        let megabyte = 1024 * 1024
        let entries: [(key: String, bytes: Int)] = [
            ("oldest", 10 * megabyte), ("older", 10 * megabyte), ("newer", 10 * megabyte)
        ]
        let incoming = 10 * megabyte

        let victims = SpeechAudioCachePolicy.evictionPlan(entries: entries, incoming: incoming)

        XCTAssertEqual(victims, ["oldest", "older"], "从最旧开始倒，倒到装得下为止")
        let kept = entries.filter { !victims.contains($0.key) }.reduce(0) { $0 + $1.bytes }
        XCTAssertLessThanOrEqual(kept + incoming, SpeechAudioCachePolicy.totalByteLimit,
                                 "淘汰之后必须真的装得下")
    }

    /// 单条就撑破上限时一路清到底（宁可全清，也不让总量破表）。
    func testOversizedIncomingClearsEverything() {
        let entries: [(key: String, bytes: Int)] = [("a", 100), ("b", 100)]
        let victims = SpeechAudioCachePolicy.evictionPlan(
            entries: entries, incoming: SpeechAudioCachePolicy.totalByteLimit + 1
        )
        XCTAssertEqual(victims.count, entries.count, "来了一条装不下的，旧的就该全部让位")
    }

    /// 单条上限：超限的不进缓存（它本来也不太会被复读）。
    func testOversizedItemIsNotCachedAtAll() {
        XCTAssertFalse(SpeechAudioCachePolicy.allowsCaching(bytes: 0), "空音频没有缓存价值")
        XCTAssertTrue(
            SpeechAudioCachePolicy.allowsCaching(bytes: SpeechAudioCachePolicy.singleItemByteLimit),
            "正好等于上限要收（边界不能差一个字节）"
        )
        XCTAssertFalse(
            SpeechAudioCachePolicy.allowsCaching(bytes: SpeechAudioCachePolicy.singleItemByteLimit + 1),
            "超过单条上限就不缓存"
        )
    }

    /// 反证：不淘汰的话总量必然超限 —— 少了这一半，「淘汰算错了但断言照样绿」看不见。
    func testWithoutEvictionTheTotalWouldBlowTheLimit() {
        let megabyte = 1024 * 1024
        let entries: [(key: String, bytes: Int)] = (0..<10).map { ("k\($0)", 10 * megabyte) }
        let incoming = 10 * megabyte

        let before = entries.reduce(0) { $0 + $1.bytes } + incoming
        XCTAssertGreaterThan(before, SpeechAudioCachePolicy.totalByteLimit, "对照组：不淘汰必然超限")

        let victims = SpeechAudioCachePolicy.evictionPlan(entries: entries, incoming: incoming)
        let after = entries.filter { !victims.contains($0.key) }.reduce(0) { $0 + $1.bytes } + incoming
        XCTAssertLessThanOrEqual(after, SpeechAudioCachePolicy.totalByteLimit, "淘汰后必须回到上限内")
    }

    // MARK: - 缓存键要带 runtime 身份

    /// 同一家供应商、同一句 → 命中缓存（一次请求）。
    func testSameProviderReusesTheCachedAudio() async throws {
        let provider = StubTTS(id: "stub.tts")
        let tts = TTSManager()
        await tts.register(provider)
        let voice = VoiceService(tts: tts)
        let selection = SpeechVoiceSelection.builtin("Ava")

        _ = try await voice.synthesizeCached("Hello.", voice: selection, language: "en")
        _ = try await voice.synthesizeCached("Hello.", voice: selection, language: "en")

        XCTAssertEqual(provider.callCount, 1, "同一家供应商的同一句应当命中缓存")
    }

    /// 换了供应商 → **必须重新合成**：缓存里躺着的是上家的声音。
    func testSwitchingProviderRefetchesTheSameLine() async throws {
        let first = StubTTS(id: "stub.tts")
        let second = StubTTS(id: "other.tts")
        let tts = TTSManager()
        await tts.register(first)
        let voice = VoiceService(tts: tts)
        let selection = SpeechVoiceSelection.builtin("Ava")

        _ = try await voice.synthesizeCached("Hello.", voice: selection, language: "en")
        XCTAssertEqual(first.callCount, 1)

        await tts.register(second)
        _ = try await voice.synthesizeCached("Hello.", voice: selection, language: "en")

        XCTAssertEqual(second.callCount, 1,
                       "换了供应商后同一句必须重新合成 —— 否则用户听到的是上一家的声音")
    }

    // MARK: - 字节封顶

    /// 几条大音频就能把最老的挤出去（只数条数的话，这里会是上百兆常驻）。
    func testLargeAudioEvictsTheOldestEvenWhenTheCountIsSmall() async throws {
        // 3 MB 一条：单条进得了缓存，但 24 MB 的总量装不下十条。
        let megabyte = 1024 * 1024
        let provider = StubTTS(payload: Data(count: 3 * megabyte))
        let tts = TTSManager()
        await tts.register(provider)
        let voice = VoiceService(tts: tts)
        let selection = SpeechVoiceSelection.builtin("Ava")

        for index in 0..<10 {
            _ = try await voice.synthesizeCached("line \(index)", voice: selection, language: "en")
        }
        let filled = provider.callCount
        XCTAssertEqual(filled, 10)

        _ = try await voice.synthesizeCached("line 9", voice: selection, language: "en")
        XCTAssertEqual(provider.callCount, filled, "最新那条必须还在（刚写就被挤掉 = 淘汰账目错了）")

        _ = try await voice.synthesizeCached("line 0", voice: selection, language: "en")
        XCTAssertEqual(provider.callCount, filled + 1,
                       "最老那条已被字节上限挤掉，重查要真的再发一次请求")
    }

    // MARK: - 接线

    /// 两处改造都得真的落在代码里（只声明不用的上限等于没有上限）。
    func testBothLimitsAreWiredIntoTheCache() throws {
        let path = "Sources/AIServices/VoiceService.swift"
        let text = try String(contentsOfFile: path, encoding: .utf8)

        XCTAssertTrue(text.contains("await tts.runtimeIdentity"),
                      "\(path) 的缓存键必须带上 runtime 身份")
        XCTAssertTrue(text.contains("SpeechAudioCachePolicy.allowsCaching"),
                      "\(path) 写入缓存前要过单条上限")
        XCTAssertTrue(text.contains("SpeechAudioCachePolicy.evictionPlan"),
                      "\(path) 写入缓存前要按字节算淘汰")

        let manager = try String(contentsOfFile: "Sources/AIServices/TTSManager.swift", encoding: .utf8)
        XCTAssertTrue(manager.contains("public var runtimeIdentity"),
                      "runtime 身份由 TTSManager 从当前 Provider 的 metadata 取，不能让调用方自己猜")
    }
}
