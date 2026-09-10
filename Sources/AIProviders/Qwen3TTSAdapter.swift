import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// 本地 Qwen3-TTS 语音合成 Adapter。
///
/// 契约（对 ~/AI_Models/services/tts_server.py 实测所得）：
/// - `POST {endpoint}/v1/audio/speech` —— `{"text","voice","language","speed"}` → `audio/wav`。
/// - `GET  {endpoint}/healthz` —— `{"status":"ok","model":...,"voices":[...]}`。
/// - `GET  {endpoint}/v1/voices` —— `{"voices":[...]}`。
///
/// 模型由外部 Python runtime 持有，本进程**不加载任何模型文件**（AGENTS.md §3B / v2.0）。
/// 所有 Qwen3-TTS 专属细节（路径、字段名、音频封装格式）只允许出现在本文件内。
public final class Qwen3TTSAdapter: TTSProvider, VoiceCatalogProvider, @unchecked Sendable {

    public let providerID: String
    public let kind: AIProviderKind = .tts

    private let state = ProviderStateBox()
    private let client: HTTPClient

    public init(providerID: String = "local.tts", client: HTTPClient = HTTPClient()) {
        self.providerID = providerID
        self.client = client
    }

    // MARK: - 生命周期

    public func initialize(config: ProviderConfig) async throws {
        guard let endpoint = config.endpoint, !endpoint.isEmpty else {
            throw AIProviderError.invalidConfiguration("缺少 runtime 端点")
        }
        guard URL(string: endpoint) != nil else {
            throw AIProviderError.invalidConfiguration("端点不是合法 URL")
        }
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }

    public func load() async throws {
        let health = await healthCheck()
        switch health {
        case .connected:
            await state.setLifecycle(.ready)
        case .runtimeUnavailable(let reason):
            await state.setLifecycle(.failed)
            throw AIProviderError.runtimeUnavailable(reason)
        default:
            await state.setLifecycle(.failed)
            throw AIProviderError.runtimeUnavailable(health.userFacingDescription)
        }
    }

    public func unload() async { await state.setLifecycle(.unloaded) }

    public func healthCheck() async -> ProviderHealth {
        guard let config = await state.currentConfig else {
            return .configurationInvalid(reason: "尚未初始化")
        }
        guard let endpoint = config.endpoint, let base = Self.normalizedBase(endpoint) else {
            return .configurationInvalid(reason: "端点缺失或非法")
        }
        let request = URLRequest(url: base.appendingPathComponent("healthz"))
        do {
            let (data, response) = try await client.perform(request, timeout: config.requestTimeout ?? 8)
            guard (200..<300).contains(response.statusCode) else {
                return .requestFailed(reason: "HTTP \(response.statusCode)")
            }
            if let payload = try? JSONDecoder().decode(HealthPayload.self, from: data),
               payload.status != "ok" {
                // 模型仍在加载中，runtime 在线但暂不可用
                return .runtimeUnavailable(reason: "模型加载中")
            }
            return .connected(model: config.model)
        } catch let error as AIProviderError {
            switch error {
            case .connectionFailed(let reason), .timeout(let reason):
                return .runtimeUnavailable(reason: reason)
            default:
                return .requestFailed(reason: error.localizedDescription)
            }
        } catch {
            return .requestFailed(reason: error.localizedDescription)
        }
    }

    public func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(streaming: false, structuredOutput: false, multilingual: true)
    }

    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "本地教师语音", runtime: .externalLocalRuntime)
    }

    // MARK: - 合成

    public func synthesize(_ request: TTSRequest) async throws -> TTSResult {
        let config = try await resolvedConfig()
        let base = try Self.base(config)
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIProviderError.invalidRequest("没有可朗读的文本") }

        var urlRequest = URLRequest(url: base.appendingPathComponent("v1/audio/speech"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            SpeechRequest(
                text: text,
                voice: request.voice ?? config.model ?? "Serena",
                language: request.language ?? "English",
                speed: 1.0
            )
        )

        let (data, response) = try await client.perform(urlRequest, timeout: config.requestTimeout ?? 120)
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.serverError(
                status: response.statusCode,
                message: String(data: data, encoding: .utf8)
            )
        }
        let (samples, sampleRate) = Self.decodeWAV(data)
        return TTSResult(audioSamples: samples, sampleRate: sampleRate, audioData: data)
    }

    /// runtime 侧可用音色；不可用时返回空数组（UI 回退到内置预设）。
    public func availableVoices() async -> [String] {
        guard let config = await state.currentConfig, let base = try? Self.base(config) else { return [] }
        let request = URLRequest(url: base.appendingPathComponent("v1/voices"))
        guard let (data, response) = try? await client.perform(request, timeout: 6),
              (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(VoiceListPayload.self, from: data)
        else { return [] }
        return payload.voices
    }

    // MARK: - 内部

    private func resolvedConfig() async throws -> ProviderConfig {
        guard let config = await state.currentConfig else { throw AIProviderError.notInitialized }
        return config
    }

    private static func base(_ config: ProviderConfig) throws -> URL {
        guard let endpoint = config.endpoint, let base = normalizedBase(endpoint) else {
            throw AIProviderError.invalidConfiguration("端点缺失或非法")
        }
        return base
    }

    private static func normalizedBase(_ endpoint: String) -> URL? {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }

    /// 解析 16bit PCM WAV → Float 采样（-1…1）。非 PCM 或损坏时返回空数组。
    public static func decodeWAV(_ data: Data) -> ([Float], Int) {
        guard data.count > 44 else { return ([], 0) }
        let bytes = [UInt8](data)
        guard Self.ascii(bytes, 0) == "RIFF", Self.ascii(bytes, 8) == "WAVE" else { return ([], 0) }
        var offset = 12
        var channels = 1
        var sampleRate = 24_000
        var bits = 16
        var pcm = Data()
        while offset + 8 <= bytes.count {
            let id = Self.ascii(bytes, offset)
            let size = Int(Self.u32(bytes, offset + 4))
            let bodyStart = offset + 8
            guard size >= 0, bodyStart + size <= bytes.count else { break }
            if id == "fmt " {
                channels = Int(Self.u16(bytes, bodyStart + 2))
                sampleRate = Int(Self.u32(bytes, bodyStart + 4))
                bits = Int(Self.u16(bytes, bodyStart + 14))
            } else if id == "data" {
                pcm = data.subdata(in: bodyStart..<(bodyStart + size))
            }
            offset = bodyStart + size + (size % 2)
        }
        guard bits == 16, !pcm.isEmpty else { return ([], sampleRate) }
        let frameCount = pcm.count / 2
        var samples = [Float]()
        samples.reserveCapacity(frameCount / max(1, channels))
        var index = 0
        while index + 1 < pcm.count {
            let raw = Int16(bitPattern: UInt16(pcm[index]) | (UInt16(pcm[index + 1]) << 8))
            samples.append(Float(raw) / 32768.0)
            index += 2 * channels      // 多声道只取第一声道
        }
        return (samples, sampleRate)
    }

    private static func ascii(_ bytes: [UInt8], _ offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    // MARK: - 传输结构（仅本文件可见）

    private struct SpeechRequest: Encodable {
        let text: String
        let voice: String
        let language: String
        let speed: Float
    }

    private struct HealthPayload: Decodable {
        let status: String
        let model: String?
        let device: String?
        let voices: [String]?
    }

    private struct VoiceListPayload: Decodable {
        let voices: [String]
    }
}
