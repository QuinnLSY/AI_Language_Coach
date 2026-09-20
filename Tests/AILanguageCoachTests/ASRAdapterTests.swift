import AIDomain
import AIInterfaces
import AIInfrastructure
import AIProviders
import AppCore
import Foundation
import XCTest

/// 第 12 步 本地 ASR（Phase 12）的适配器级测试。
///
/// 计划要求的八类用例里，能在**离线**完整覆盖的都在这里：短句 / 长句 / 噪音 /
/// 静音（空音频）/ 多语言 / 错误映射 / 音频封装 / **时间戳精度**（verbose_json 实测字段）。
/// 「流式」本适配器确实没有（whisper.cpp 无流式端点），用断言钉死而不是假装支持。
///
/// 采用注入式假传输，**不依赖任何本地 runtime / 网络**。
@MainActor
final class ASRAdapterTests: XCTestCase {

    /// 记录请求，用于断言「有没有真的发网络」以及请求体形状。
    private actor CallRecorder {
        private(set) var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
        var count: Int { requests.count }
        var lastBody: Data? { requests.last?.httpBody }
    }

    private func makeAdapter(
        recorder: CallRecorder,
        status: Int = 200,
        body: String
    ) -> WhisperASRAdapter {
        let transport: HTTPClient.Transport = { request, _ in
            await recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
        return WhisperASRAdapter(providerID: "local.asr", client: HTTPClient(transport: transport))
    }

    private func configured(_ adapter: WhisperASRAdapter) async throws {
        try await adapter.initialize(
            config: ProviderConfig(
                id: "local.asr", kind: .asr, enabled: true, runtime: .externalLocalRuntime,
                endpoint: "http://127.0.0.1:18080"
            )
        )
    }

    /// 一段时长 `seconds` 的合成语音（正弦波，可指定振幅）。
    private func samples(seconds: Double, amplitude: Float = 0.4, sampleRate: Double = 16_000) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { amplitude * sinf(Float($0) * 0.05) }
    }

    // MARK: - 短句 / 长句 / 噪音 / 静音

    func testShortUtteranceReturnsTranscript() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"Hello there."}"#)
        try await configured(adapter)

        let result = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.5)))
        XCTAssertEqual(result.text, "Hello there.")
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testLongUtteranceSendsFullAudio() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"A long paragraph."}"#)
        try await configured(adapter)

        let audio = samples(seconds: 30)
        let result = try await adapter.transcribe(ASRRequest(audioSamples: audio))
        XCTAssertEqual(result.text, "A long paragraph.")
        // 30s@16k 的音频（约 960KB PCM）必须**完整**进请求体，不能截断。
        let body = await recorder.lastBody ?? Data()
        XCTAssertGreaterThan(body.count, audio.count * 2, "整段音频（含 WAV 头）应完整发送")
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("RIFF"), "应以 WAV 封装发送")
    }

    func testNoisyAudioStillTranscribed() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"garbled but recognised"}"#)
        try await configured(adapter)

        // 满幅随机噪声：适配器不做音频内容判断（那是 VAD 的活），应照常发出去并回填结果。
        var noisy = samples(seconds: 0.3)
        var generator = SystemRandomNumberGenerator()
        for index in noisy.indices { noisy[index] = Float.random(in: -1...1, using: &generator) }

        let result = try await adapter.transcribe(ASRRequest(audioSamples: noisy))
        XCTAssertEqual(result.text, "garbled but recognised")
    }

    func testEmptyAudioRejectedWithoutNetwork() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"should not be used"}"#)
        try await configured(adapter)

        do {
            _ = try await adapter.transcribe(ASRRequest(audioSamples: []))
            XCTFail("空音频应被拒绝")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .invalidRequest("没有可识别的音频"))
        }
        let count = await recorder.count
        XCTAssertEqual(count, 0, "空音频不得发起网络请求")    }

    func testSilenceReturnsEmptyText() async throws {
        // 静音判决属于 VAD；真发到 ASR 时服务端可能回空串，适配器要能接受。
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"   "}"#)
        try await configured(adapter)

        let result = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 1, amplitude: 0)))
        XCTAssertEqual(result.text, "", "空/纯空白结果应被 trim 成空串而不是报错")
    }

    // MARK: - 多语言

    func testMultilingualSendsLanguageField() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"Bonjour"}"#)
        try await configured(adapter)

        _ = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.4), language: "en-US"))
        let body = String(decoding: await recorder.lastBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="language""#), "指定语言时应带 language 字段")
        XCTAssertTrue(body.contains("en-US"))
        XCTAssertTrue(body.contains(#"name="response_format""#), "应显式要求 json 响应")
    }

    func testLanguageOmittedWhenNotProvided() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"ok"}"#)
        try await configured(adapter)

        _ = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.4)))
        let body = String(decoding: await recorder.lastBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(body.contains(#"name="language""#), "没给语言就不该塞空 language 字段")
    }

    func testPrimaryLanguageTagNormalization() {
        // 云端接口不认区域后缀，统一归一成主标签。
        XCTAssertEqual(RemoteEndpoint.primaryLanguageTag("en-US"), "en")
        XCTAssertEqual(RemoteEndpoint.primaryLanguageTag("zh-Hans-CN"), "zh")
        XCTAssertEqual(RemoteEndpoint.primaryLanguageTag("fr"), "fr")
        XCTAssertNil(RemoteEndpoint.primaryLanguageTag(nil))
        XCTAssertNil(RemoteEndpoint.primaryLanguageTag(""))
    }

    // MARK: - 错误映射

    func testServerErrorIsMapped() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, status: 500, body: "boom")
        try await configured(adapter)

        do {
            _ = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.3)))
            XCTFail("5xx 应报错")
        } catch let error as AIProviderError {
            guard case .serverError(let status, _) = error else {
                return XCTFail("应映射为 serverError，实际 \(error)")
            }
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("非预期错误类型：\(error)")
        }
    }

    func testMalformedResponseIsMapped() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: "not json at all")
        try await configured(adapter)

        do {
            _ = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.3)))
            XCTFail("非 JSON 响应应报错")
        } catch let error as AIProviderError {
            guard case .invalidResponse = error else {
                return XCTFail("应映射为 invalidResponse，实际 \(error)")
            }
        } catch {
            XCTFail("非预期错误类型：\(error)")
        }
    }

    func testTranscribeWithoutInitializeThrows() async {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"x"}"#)
        do {
            _ = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.2)))
            XCTFail("未初始化应报错")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .notInitialized)
        } catch {
            XCTFail("非预期错误类型：\(error)")
        }
    }

    func testInitializeRejectsMissingEndpoint() async {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: "{}")
        do {
            try await adapter.initialize(
                config: ProviderConfig(id: "local.asr", kind: .asr, enabled: true, runtime: .externalLocalRuntime)
            )
            XCTFail("缺少端点应报配置错误")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .invalidConfiguration("缺少 runtime 端点"))
        } catch {
            XCTFail("非预期错误类型：\(error)")
        }
    }

    // MARK: - 能力口径（不假装支持）

    func testStreamingIsNotAdvertisedButWordTimestampsAre() {
        let adapter = WhisperASRAdapter(providerID: "local.asr")
        let capabilities = adapter.capabilities()
        XCTAssertFalse(capabilities.streaming, "whisper.cpp 没有流式端点，不得声称支持")
        XCTAssertTrue(capabilities.wordTimestamp,
                      "verbose_json 实测给得出词级时间戳（计划 Phase 12 的 timestamp accuracy 项）")
        XCTAssertEqual(adapter.metadata().runtime, .externalLocalRuntime)
    }

    // MARK: - 时间戳（verbose_json）

    func testRequestsVerboseJSON() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"Hi"}"#)
        try await configured(adapter)

        _ = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.4)))
        let body = String(decoding: await recorder.lastBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("verbose_json"), "要时间戳就必须显式要 verbose_json")
    }

    func testVerboseResponseYieldsWordTimestamps() async throws {
        let recorder = CallRecorder()
        let payload = """
        {"text":" Good morning.","segments":[{"id":0,"text":" Good morning.",\
        "start":0.0,"end":2.12,"words":[{"word":" Good","start":0.03,"end":0.26,\
        "probability":0.82},{"word":" morning","start":0.26,"end":0.58,"probability":0.83}]}]}
        """
        let adapter = makeAdapter(recorder: recorder, body: payload)
        try await configured(adapter)

        let result = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.4)))
        XCTAssertEqual(result.text, "Good morning.")
        let segments = try XCTUnwrap(result.segments, "有 segments 就该解析出来")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0.0, accuracy: 1e-6)
        XCTAssertEqual(segments[0].end, 2.12, accuracy: 1e-6)
        XCTAssertEqual(result.words?.map(\.word), [" Good", " morning"])
        XCTAssertEqual(result.words?.first?.start ?? -1, 0.03, accuracy: 1e-6)
        XCTAssertEqual(result.words?.first?.confidence ?? 0, 0.82, accuracy: 1e-6)
    }

    func testResponseWithoutSegmentsYieldsNilTimestamps() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"Hello"}"#)
        try await configured(adapter)

        let result = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.4)))
        XCTAssertNil(result.segments, "runtime 没给时间戳就是 nil，不能是空数组")
        XCTAssertNil(result.words)
        XCTAssertEqual(result.text, "Hello", "拿不到时间戳也要拿到文字")
    }

    func testEmptySegmentsBecomeNilNotAmbiguousEmptyArray() async throws {
        let recorder = CallRecorder()
        let adapter = makeAdapter(recorder: recorder, body: #"{"text":"","segments":[]}"#)
        try await configured(adapter)

        let result = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.4)))
        XCTAssertNil(result.segments, "空 segments 要退化成 nil，避免与「无时间戳」混淆")
    }

    func testSegmentWithPartialTimestampsIsDropped() async throws {
        let recorder = CallRecorder()
        // 第二段只有 start 没有 end —— 报一半等于没报，宁可丢。
        let payload = """
        {"text":"a b","segments":[{"text":"a","start":0.0,"end":1.0,"words":[]},\
        {"text":"b","start":1.0}]}
        """
        let adapter = makeAdapter(recorder: recorder, body: payload)
        try await configured(adapter)

        let result = try await adapter.transcribe(ASRRequest(audioSamples: samples(seconds: 0.4)))
        XCTAssertEqual(result.segments?.count, 1, "时间戳不全的那一段必须丢掉，不能拿 0 冒充")
        XCTAssertEqual(result.segments?.first?.text, "a")
    }

    // MARK: - 真机时间戳（runtime 不在时 Skip，不算失败）

    /// 计划 Phase 12 的 `timestamp accuracy` 项：拿**真实语音**打真机，确认时间戳不是纸面支持。
    ///
    /// 上面那几条用的是构造出来的 JSON —— 只能证明「给我这个形状我解析得对」，
    /// 证明不了「这个 runtime 真的会给时间戳，而且时间戳是合理的」。
    /// 本机没装 whisper.cpp / 服务没起 / 没有 `say` 时一律 Skip。
    func testRealRuntimeReturnsWordTimestampsForRealSpeech() async throws {
        let adapter = WhisperASRAdapter(providerID: "local.asr")
        try await adapter.initialize(
            config: ProviderConfig(
                id: "local.asr", kind: .asr, enabled: true, runtime: .externalLocalRuntime,
                endpoint: "http://127.0.0.1:8858", requestTimeout: 60
            )
        )
        guard case .connected = await adapter.healthCheck() else {
            throw XCTSkip("本地 whisper.cpp 未运行（127.0.0.1:8858），跳过真机时间戳用例")
        }

        let samples = try Self.realSpeechSamples()
        let result = try await adapter.transcribe(ASRRequest(audioSamples: samples, language: "en"))
        XCTAssertFalse(result.text.isEmpty, "真实语音应能转出文字")

        let words = try XCTUnwrap(result.words, "真机必须给得出词级时间戳，否则不该声明 wordTimestamp")
        XCTAssertFalse(words.isEmpty)
        let duration = Double(samples.count) / 16_000
        for word in words {
            XCTAssertGreaterThanOrEqual(word.start, -0.001, "时间戳不该是负数")
            XCTAssertLessThanOrEqual(word.start, word.end + 1e-6, "起点不该晚于终点（\(word.word)）")
            XCTAssertLessThanOrEqual(word.end, duration + 0.5, "终点不该明显超出音频长度")
        }
        let starts = words.map(\.start)
        XCTAssertEqual(starts, starts.sorted(), "词级时间戳应随音频推进单调不减")
    }

    /// 用系统 `say` 合成一句真实语音，再用 `afconvert` 转成 16k 单声道 WAV 后解码。
    /// 机器上缺工具就 Skip —— 不为了一条用例把音频素材提交进仓库。
    private static func realSpeechSamples() throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-asr-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let aiff = directory.appendingPathComponent("probe.aiff")
        let wav = directory.appendingPathComponent("probe.wav")
        try run("/usr/bin/say", ["-v", "Samantha", "-o", aiff.path, "Good morning, how are you doing today"])
        try run("/usr/bin/afconvert",
                ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        return try decodePCM16WAV(Data(contentsOf: wav))
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("缺少 \(path)，跳过真机用例")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(path) 退出码非 0，跳过真机用例")
        }
    }

    /// 极简 16bit PCM WAV 解码（按 chunk 找 `data`，不假设头固定 44 字节 ——
    /// `afconvert` 会插别的 chunk）。
    private static func decodePCM16WAV(_ data: Data) throws -> [Float] {
        let bytes = [UInt8](data)
        guard bytes.count > 44,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
            throw AIProviderError.invalidResponse("不是合法的 WAV")
        }
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let size = Int(bytes[offset + 4]) | (Int(bytes[offset + 5]) << 8)
                | (Int(bytes[offset + 6]) << 16) | (Int(bytes[offset + 7]) << 24)
            let body = offset + 8
            if id == "data" {
                let end = min(body + size, bytes.count)
                var samples: [Float] = []
                samples.reserveCapacity((end - body) / 2)
                var index = body
                while index + 1 < end {
                    let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                    samples.append(Float(Int16(bitPattern: raw)) / 32_768)
                    index += 2
                }
                return samples
            }
            offset = body + size + (size % 2)
        }
        throw AIProviderError.invalidResponse("WAV 里没有 data chunk")
    }

    // MARK: - WAV 封装

    func testWAVHeaderIsWellFormed() {
        let data = WhisperASRAdapter.wavData(samples: [0, 0.5, -0.5, 1.0], sampleRate: 16_000)
        let bytes = [UInt8](data)

        XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: bytes[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(bytes: bytes[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(bytes: bytes[36..<40], encoding: .ascii), "data")

        // RIFF 大小 = 文件长度 - 8；data 大小 = 采样数 × 2。
        let riffSize = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        XCTAssertEqual(Int(riffSize), data.count - 8)
        let dataSize = UInt32(bytes[40]) | UInt32(bytes[41]) << 8 | UInt32(bytes[42]) << 16 | UInt32(bytes[43]) << 24
        XCTAssertEqual(Int(dataSize), 4 * 2)

        // 采样率（小端）
        let rate = UInt32(bytes[24]) | UInt32(bytes[25]) << 8 | UInt32(bytes[26]) << 16 | UInt32(bytes[27]) << 24
        XCTAssertEqual(rate, 16_000)
        XCTAssertEqual(bytes[22], 1, "必须单声道")
        XCTAssertEqual(bytes[34], 16, "必须 16bit")
    }

    func testWAVClampsOutOfRangeSamples() {
        // 越界采样必须被削顶，不能回绕成刺耳的爆音。
        let data = WhisperASRAdapter.wavData(samples: [2.0, -3.0], sampleRate: 8_000)
        let bytes = [UInt8](data)
        let first = Int16(bitPattern: UInt16(bytes[44]) | UInt16(bytes[45]) << 8)
        let second = Int16(bitPattern: UInt16(bytes[46]) | UInt16(bytes[47]) << 8)
        XCTAssertEqual(first, 32_767)
        XCTAssertEqual(second, -32_767)
    }

    func testWAVHandlesEmptySamples() {
        let data = WhisperASRAdapter.wavData(samples: [], sampleRate: 16_000)
        XCTAssertEqual(data.count, 44, "无采样时仍应是合法的空 WAV（只有头部）")
    }
}
