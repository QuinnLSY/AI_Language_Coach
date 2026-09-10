# AGENTS.md — AI Language Coach 开发规范

> 面向所有参与本项目的 AI Coding Agent 与人类开发者。
> 工具无关（Codex / Claude Code / Cursor / WorkBuddy 等），项目级强制。
> 权威来源优先级：`PRD > Technical Design > Agent Development Rules > Implementation Plan > LOCAL_MODEL_INTEGRATION_SPEC_v2.0 > 本文件`。
> 本文件只做「可执行化沉淀」，不覆盖上游文档；冲突时以上游文档为准并显式上报。

---

## 0. 技术栈与我方环境（2026-09-08 复核通过）

| 项 | 结论 |
|---|---|
| 语言 / UI | **Swift 6 + SwiftUI**（PRD §40、技术设计 §7–§10、LOCAL_MODEL_INTEGRATION_SPEC_v2.0 §4 三方一致；PRD 中的 Python 片段仅为示意） |
| Xcode | **已安装 Xcode 26.6**（Build 17F113）于 `/Applications/Xcode.app`，`xcode-select -p` 已指向它，`xcodebuild -version` 正常 |
| Swift | 6.3.3（swiftlang-6.3.3.1.3），target `arm64-apple-macosx26.0` |
| 构建 | **SwiftPM 为唯一真相源**（`swift build` / `swift test`）；Xcode 可用于打开 `Package.swift`、SwiftUI 预览、 entitlements 与 `.app` 打包（`xcodebuild`）。命令行 CI 一律走 SwiftPM，不依赖 Xcode GUI |
| SDK | `MacOSX.sdk`（Xcode 26.6），已确认含 `SwiftUI`、`AVFoundation`、`Combine`、`Metal`、`MetalKit`、`MetalPerformanceShaders`、`CoreML` |
| 并发 | Swift Concurrency：`async/await`、`AsyncThrowingStream`、结构化取消 |
| 网络 | Foundation `URLSession`。**不引入第三方 HTTP 依赖**（无 Alamofire 等），除非出现经证实的必要性 |
| 目标平台 | macOS / Apple Silicon，首要设备 MacBook Pro M1 Pro / 16GB 统一内存 |
| 数据库 | SQLite（V1 不引入重型 ORM，Repository 封装） |
| 测试 | XCTest（Unit / Integration / Benchmark 分目录） |

### 0.1 本机已核实的两个坑（必须规避）

1. **HTTP 代理会劫持 localhost 请求**：环境里 `HTTP_PROXY/HTTPS_PROXY=http://127.0.0.1:59067`，`URLSession` 默认读系统代理配置 → 访问 `http://localhost:11434` 会返回 502（`upstream connect failed`）。
   **规避**：本地 runtime 的 `URLSessionConfiguration` 必须显式 `connectionProxyDictionary = [:]`（或设置 `NO_PROXY` 含 `localhost,127.0.0.1`），并在诊断信息里区分「连接被拒（服务没起）」与「被代理拦截」。
2. **Ollama 服务可能没起**（CLI v0.33.3，`/usr/local/bin/ollama`）。`load()/healthCheck()` 必须把「runtime 未启动」报成 `runtimeUnavailable`，而不是崩溃或空字符串。集成测试要能跳过（Skip/标注）而非失败。

### 0.2 Ollama 实测契约（2026-09-09 对真实 runtime 验证，v0.33.3）

**已验证**：服务在跑（`http://127.0.0.1:11434`，需 `--noproxy '*'` / `connectionProxyDictionary = [:]`）。已装模型：`deepseek-r1:7b`（completion）、`nomic-embed-text:latest`（embedding，768 维，context 2048）。**`qwen3` 尚未安装** —— 健康检查与集成测试必须容忍模型缺失。

| 端点 | 实测 |
|---|---|
| `GET /v1/models` | `{"object":"list","data":[{"id","object":"model","created","owned_by":"library"}]}` |
| `GET /api/tags` | 含 `name/model/modified_at/size/digest/details{format,family,parameter_size,quantization_level,context_length,embedding_length}/capabilities` |
| `POST /v1/chat/completions` | OpenAI 兼容，实测字段见下 |

**非流式响应**（逐字段实测）：

```json
{"id":"chatcmpl-526","object":"chat.completion","created":1788913893,
 "model":"deepseek-r1:7b","system_fingerprint":"fp_ollama",
 "choices":[{"index":0,"message":{"role":"assistant","content":"..."},"finish_reason":"length"}],
 "usage":{"prompt_tokens":5,"prompt_tokens_details":{"cached_tokens":0},
          "completion_tokens":32,"total_tokens":37}}
```

**流式**（SSE，`\n\n` 分隔，以 `data: [DONE]` 收尾）：

```json
data: {"id":"chatcmpl-222","object":"chat.completion.chunk","created":...,"model":"...",
       "system_fingerprint":"fp_ollama",
       "choices":[{"index":0,"delta":{"role":"assistant","content":"\n\n"},"finish_reason":null}]}
...
data: {"...","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
data: [DONE]
```

首 chunk 带 `delta.role`；**末 chunk `delta` 为空对象且 `finish_reason` 非 null**；`usage` 在流式 chunk 中**未出现**（实测未见，按「可能缺失」处理，不可强解）。

**推理模型额外字段（2026-09-09 补测，deepseek-r1:7b）**：

```json
{"choices":[{"message":{"role":"assistant","content":"…","reasoning":"…"}}]}
data: {"choices":[{"delta":{"content":"…","reasoning":"…"}}]}
```

- 推理模型会额外返回 **`reasoning`**（非流式在 `message.reasoning`，流式在 `delta.reasoning`）。
- **token 预算会被推理吃掉**：`max_tokens=256` 时实测 `content` 为空串、全在 `reasoning` 里。**配置默认 `max_tokens` 给到 1024**；产品层只展示 `content`，推理过程不直接呈现（UI 显示「思考中…」）。
- Adapter 必须解析 `reasoning` 并映射到 `LLMResponse.reasoning` / `LLMChunk.reasoningDelta`；**禁止把 reasoning 当正文展示，也禁止静默丢弃导致正文判空**。

**错误**：`404` + `{"error":{"message":"model 'qwen3:8b' not found","type":"not_found_error","param":null,"code":null}}`；未知路径 `404 page not found`（纯文本，非 JSON → 解析必须容错）。

**映射约束**（写 `OllamaLLMAdapter` 时）：只依赖上表实测字段，`prompt_tokens_details`、`system_fingerprint` 等**可选解**；`finish_reason` 取值实测到 `length` / `stop`；任何未实测到的字段**先补测再使用**，禁止凭空编造。

---

## 1. 架构红线（违反即打回）

依赖方向**只能**自上而下，禁止反向与跨层：

```
UI → Application Services → Agents → Managers → Provider Interfaces → Adapters → Local Runtime → Models
```

绝对禁止：

```
UI → 任何 AI SDK / Database / 具体 Backend / 模型生命周期 / Prompt 业务
Business Service → GPT-SoVITS / WhisperKit / Qwen / llama.cpp / MLX / Ollama / HTTP
Agent → 具体模型 SDK / SQL / 具体 Runtime（含 Ollama URL、模型名常量）
Domain Model → 模型 SDK 类型
SwiftUI → Ollama / HTTP 直连
```

其它硬性禁令：

- 硬编码模型路径、runtime 端口/host、可执行文件路径、音色参考路径、个人目录
- 把 Prompt 写在 View / ViewModel / Agent / Service 里（一律进 `Resources/Prompts/`，且版本化）
- `catch {}` / `try?` 静默吞错
- 无生命周期管理的全局模型单例
- 未经验证就声明某个第三方 API / 模型 / 命令可用
- 为跑通 demo 而绕过 Provider/Adapter

---

## 2. 目录结构（采用技术设计 §4 / Bootstrap §13）

```
AI-Language-Coach/
├── App/            # 入口、App 组装、依赖装配
├── UI/             # Dashboard / Conversation / Practice / Session / Progress / Settings
├── Core/           # Conversation / Learning / Memory / Audio / Configuration
├── Agents/         # Teacher / Grammar / Conversation / Pronunciation / ResponsePlanner
├── AI/
│   ├── Interfaces/ # IASRProvider / ILLMProvider / ITTSProvider / IVADProvider / IEmbeddingProvider / IPronunciationProvider
│   ├── Managers/   # 各 Manager（选路、生命周期、健康检查、能力检查、fallback、错误转译）
│   ├── Registry/   # ModelRegistry / ModelConfig / ProviderConfig
│   └── {ASR,LLM,TTS,VAD,Embedding,Pronunciation}/  # 各 Adapter
├── Infrastructure/# Database / Storage / Logging / Process
├── Resources/      # Config / Prompts / Scenarios
├── Tests/          # Unit / Integration / Benchmark
└── Docs/
```

**已知文档冲突**：PRD §59 给出的是 `Models/ + Database/ + Services/` 平铺结构，与技术设计 §4 / Bootstrap §13 的 `AI/ + Infrastructure/` 结构不一致。按优先级（技术设计为 HOW 层，且与 Bootstrap 一致）采用**技术设计 §4**，PRD §59 视为早期草图。已上报，待确认。

---

## 3. Provider / Adapter 规范

六个 Provider 接口：`ASRProvider` `LLMProvider` `TTSProvider` `VADProvider` `EmbeddingProvider` `PronunciationProvider`（命名以 v2.0 §5 为准，均继承自 `AIProvider`）。

每个 Adapter 必须实现（`AIProvider` 基类）：

```swift
func initialize() async throws
func load()      async throws
func unload()    async throws
func healthCheck() async throws -> Bool
func getCapabilities() -> AICapabilities
func getMetadata()     -> AIProviderMetadata
```

- **新增模型 = 新增 Adapter**，禁止在业务代码里 `if provider == "xxx"` 分支。
- **能力驱动**：`supportsStreaming / supportsWordTimestamp / supportsVoiceCloning / supportsPitchControl / supportsEmotion / supportsMultilingual / supportsPhonemeAlignment`。调用前先查能力，不支持就走 fallback 或返回 `UnsupportedCapability`，**不允许假装支持**。
- Adapter 只做「接口 ↔ 具体 runtime」的翻译，不放教学逻辑。
- 未接入的外部模型 → 写 `StubAdapter` / `MockAdapter`，文件头必须标 `// [MOCK] NOT FOR PRODUCTION`。

---

## 3B. 本地模型接入规范（v2.0 · 六能力统一）

来源：`Docs/LOCAL_MODEL_INTEGRATION_SPEC_v2.0.md`（取代 v1 的 LLM/Ollama 单一规范，扩展为 ASR/LLM/TTS/VAD/Embedding/Pronunciation 统一接入架构）。

### 3B.0 两条总原则（本规范的地基）

**① 极简接入面 —— 只接"必要模型调用信息"，其余留给后续版本开放。**

模型本地部署完成后，Adapter **只允许消费它向外暴露的必要调用信息**（provider ID、runtime type、endpoint/baseURL 或 model path、model name、capabilities、health）。
一切非必要信息 —— Python 环境、venv 路径、checkpoint 文件名、量化方式、端口、device、线程数、batch size、temperature、top-p、context length、VAD 阈值、embedding 维度、alignment 模型等 —— **一律作为内部配置由应用自动解析**，默认 `auto`，**不在 V1 暴露，更不得要求用户填写**。后续版本按 §3B.4 的分级逐步开放。

**② 用户选"要什么"，不配"怎么跑"。**

```
用户:  AI 模型=Qwen3 8B · 教师音色=Serena · 学习语言=English
应用:  自动解析 → Provider/Runtime/Endpoint/Port/Path/Device/安装/健康/生命周期
```
技术细节必须：自动安装 → 自动发现 → 自动配置 → 自动校验 → 自动管理。普通用户**永远不需要** Developer Mode。

### 3B.1 链路（唯一）

```
SwiftUI → Application Services → Agents → Managers → Provider Interfaces → Adapters → Local Runtime → Model/Pipeline
```

六条能力同构，例：

```
TeacherAgent → LLMManager → LLMProvider → OllamaLLMAdapter → Ollama → Qwen3
AudioCapture → ASRManager → ASRProvider → WhisperKitASRAdapter → WhisperKit(embedded)
ResponsePlanner → TTSManager → TTSProvider → Qwen3TTSAdapter → 本地 TTS Runtime
AudioCapture → VADManager → VADProvider → SileroVADAdapter → embedded(ONNX)
MemoryService → EmbeddingManager → EmbeddingProvider → OllamaEmbeddingAdapter
Audio → PronunciationManager → PronunciationProvider → PronunciationAdapter → pipeline
```

厂商专属细节（URL、端口、模型名、JSON 结构）**只准出现在对应 Adapter 内部**，不得泄漏到 Domain / Agent / UI。

### 3B.2 统一 Provider 契约

```swift
protocol AIProvider: Sendable {
    func initialize() async throws
    func load() async throws
    func unload() async throws
    func healthCheck() async throws -> Bool
    func getCapabilities() -> AICapabilities
    func getMetadata() -> AIProviderMetadata
}

protocol LLMProvider: AIProvider {
    func generate(request: LLMRequest) async throws -> LLMResponse
    func stream(request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error>
}
protocol ASRProvider: AIProvider { func transcribe(request: ASRRequest) async throws -> ASRResult }
protocol TTSProvider: AIProvider {
    func synthesize(request: TTSRequest) async throws -> TTSResult
    func stream(request: TTSRequest) -> AsyncThrowingStream<TTSChunk, Error>
}
protocol VADProvider: AIProvider { func process(audio: AudioBuffer) async throws -> VADResult }
protocol EmbeddingProvider: AIProvider { func embed(texts: [String]) async throws -> [[Float]] }
protocol PronunciationProvider: AIProvider { func analyze(request: PronunciationRequest) async throws -> PronunciationResult }
```

统一传输模型放 `AI/Interfaces/`，**不放 Adapter**。`AICapabilities` 含 `streaming / multilingual / structuredOutput / wordTimestamp / voiceCloning / pitchControl / emotionControl / phonemeAlignment / embedding`。
**复用优先**：已有等价抽象则沿用现有命名，不新建重复接口。

### 3B.3 Runtime 类别（每个 Adapter 必须声明其一）

| 类型 | 含义 | 端口 | 例子 | 用户 UI |
|---|---|---|---|---|
| `embedded` | 运行时编进 App | 无 | WhisperKit、Silero VAD | 通常隐藏 |
| `ollama` | Ollama 托管模型 | 有 | Qwen3、Embedding | 仅选模型 |
| `python_process` | App 管理本地 Python runtime | 通常 | GPT-SoVITS、Qwen3-TTS | 音色/模型 |
| `external_local_runtime` | 其他本地 runtime 暴露 API | 通常 | llama.cpp、MLX server | 仅高级 |
| `pipeline` | 多模型/算法协同 | 视情况 | 发音评测 | 简化模式 |
| `resource` | 辅助资源，非推理模型 | 无 | 参考音频、词典 | 需要时 |

**禁止假设每个模型都有 `modelPath / endpoint / port / python env`** —— embedded 类没有。

### 3B.4 配置分层与字段分级

**两层**：`Product Configuration`（用户可见：模型/语言/音色/练习模式）→ `Configuration Resolver` → `Model Registry` → `Manager` → `Adapter` → `Runtime`。
用户配置必须与底层 runtime **解耦**；`Runtime Configuration` 不得泄漏进普通产品 UI。

**每个配置字段必须归类**：

| 级别 | 含义 | V1 典型字段 |
|---|---|---|
| `USER_VISIBLE` | 实质影响体验才暴露 | 模型、语言、音色、练习模式 |
| `USER_VISIBLE_ADVANCED` | 可选，V2+ 再开放 | 音色风格、响应风格、质量/速度偏好 |
| `AUTO_MANAGED` | 应用自动解析 | path、port、device、quantization、dimensions |
| `INTERNAL_ONLY` | 永不暴露 | PID、health URL、runtime dir、venv |

**`auto` 是一等配置值**：表示"由 Registry / RuntimeManager / 设备能力 / 已装模型元数据自动解析"，进入 `Ready` 前必须被解析为具体值。
V1 只暴露 **Model / Language / Voice / Practice Mode**；Endpoint/端口/路径/设备/进程/模型版本等仅在 **Developer Mode 显式开启**后出现。

### 3B.5 V1 运行时矩阵（已定）

| 能力 | V1 选型 | 部署 | Adapter | 端口 | 用户需配 |
|---|---|---|---|---|---|
| ASR | WhisperKit + Whisper | embedded | `WhisperKitASRAdapter` | 无 | 通常无 / 语言 |
| LLM | **deepseek-r1:7b via Ollama（V1 首个验证模型，已装）**；`qwen3:8b` 待产品功能验证后作为**可选项**加入 | 本地进程 | `OllamaLLMAdapter` | 自动，典型 11434 | 模型（UI 可选，不硬编码） |
| TTS | **Qwen3-TTS 0.6B（V1 唯一首选）** | 托管本地 runtime | `Qwen3TTSAdapter` | 自动 | 音色/语言 |
| TTS 后续 | GPT-SoVITS（**V1 不实现**，部署复杂；待 Qwen3-TTS 跑通验证后再纳入模型选项） | 托管本地 runtime | `GPTSoVITSAdapter` | 自动 | 音色 |
| VAD | Silero VAD | embedded (ONNX) | `SileroVADAdapter` | 无 | 无需 |
| Embedding | Ollama 本地 embedding | 本地 | `OllamaEmbeddingAdapter` | 自动 | 无需 |
| Pronunciation | 对齐 + 声学分析 | pipeline | `PronunciationAdapter` | 视情况 | 语言/练习模式 |

M1 Pro / 16GB：TTS **先 0.6B**，benchmark 后再考虑 1.7B；优先保证 ASR+LLM+TTS 稳定共存，而非单模型最大化。

### 3B.6 应用自动承担的事（不得推给用户）

- **模型获取**：`NotInstalled → Installing → Installed → Verify → Register → HealthCheck → Ready`，由应用负责下载/校验/注册（许可允许时）。
- **安装状态机**：`NotInstalled / Installing / Installed / Loading / Ready / Unavailable / Corrupted / Incompatible / Disabled`；UI 只显示 `Ready ✓` / `Not installed [Install]` / `Runtime 未安装 [Install Runtime]`。
- **Runtime 自动发现**：Ollama 是否安装 → 服务是否起 → 列出已装模型；Python runtime → 托管目录 → venv → 可执行文件 → 健康检查。
- **端口自动分配**：配置端口 → 检查占用 → 占用则选安全回退端口 → 更新内部 endpoint。用户永不填端口。
- **设备自动选择**：默认 `auto`（Apple Silicon → MPS/CoreML/加速后端；不可用回退 CPU）。不问"CPU 还是 MPS"。
- **进程管理**：外部 runtime 统一走 `ProcessManager`（`start/stop/restart/isRunning/healthCheck/getPID/getLogs`）。**Agent 内禁止直接做进程管理**。
- **生命周期归属**：必须清楚谁拥有模型 —— embedded=应用；Ollama=Ollama 自己；python=ProcessManager。禁止重复加载。`load()` 对 Ollama 只是"可达性 + 模型可用性校验 + 建连"。

### 3B.7 进入 Ready 前的配置校验（10 项）

Provider 已注册 → runtime 类型受支持 → 必需配置存在 → 模型存在或可发现 → 外部 runtime 可达 → 所需能力被支持 → 架构兼容 → 可成功 initialize → 内存可接受 → 模型文件有效。

### 3B.8 错误模型与用户友好映射

```swift
enum AIProviderError: Error {
    case invalidConfiguration, runtimeUnavailable, modelUnavailable,
         modelNotInstalled, modelIncompatible, connectionFailed, timeout,
         cancelled, invalidRequest, invalidResponse, unsupportedCapability,
         insufficientMemory, processLaunchFailed, serverError
}
```

健康状态区分：`Connected / Ready / RuntimeUnavailable / ModelUnavailable / ModelNotInstalled / ConfigurationInvalid / ModelIncompatible / RequestFailed`。

**技术错误必须转成用户动作**：`FileNotFoundError: s2Gv4.pth` → 「教师音色未就绪，缺少语音模型 [安装]」；`Connection refused 127.0.0.1:7860` → 「AI 教师暂时不可用 [重试]」。
禁止静默转空串或伪造成功；错误文案可操作且**不含敏感对话内容**。详细诊断只在 Developer Mode 显示。

### 3B.9 流式 / 取消 / 超时 / 重试 / 结构化输出

- 流式为一等公民：`AsyncThrowingStream` → **句子/短语边界**切分 → TTS；**禁止 token 直送 TTS**；应尽早开始 TTS 而非等完整响应。
- 必须支持取消（用户抢话即停）；禁止同步阻塞 SwiftUI。
- 显式超时配置。**不重试**：非法配置 / 不支持的能力 / 模型缺失 / 畸形请求 / 用户取消。**流式禁止盲目重放**（内容会重复或变化）。
- 结构化输出必须 provider-independent；**绝不假设模型会返回合法 JSON**，畸形输出显式报 `invalidResponse`。

### 3B.10 Prompt 隔离

```
GrammarAgent → PromptBuilder → LLMRequest → LLMManager → OllamaLLMAdapter
```
长 Prompt 只放 `Resources/Prompts/`（版本化）；禁止出现在 SwiftUI View、传输层代码、任何 Adapter 内。

### 3B.11 测试

- 单元测试：配置解析、**配置解析（auto 解析）**、请求构造、响应映射、流式 chunk 映射、能力映射、错误映射、取消、Model Registry。
- Mock 必备六个：`MockLLMProvider / MockASRProvider / MockTTSProvider / MockVADProvider / MockEmbeddingProvider / MockPronunciationProvider`。**所有 Agent 必须能在无任何本地模型的情况下测试**。
- 集成测试（runtime 可用时）分能力覆盖：LLM（健康/模型可用/生成/流式/非法配置/模型缺失/取消）、TTS（进程启动/模型可用/音色加载/合成/流式/关闭）、ASR（加载/音频输入/转写/时间戳/语言）、VAD（语音/静音/turn 边界/误报）、Embedding（生成/维度/归一化/批）、Pronunciation（对齐/音高/时长/重音/评分/解释）。
- **runtime 依赖测试必须与离线单测分离**，runtime 不可用时 Skip 而非 Fail；并遵守 §0.1 的代理绕行。

### 3B.12 密钥

本地优先 V1 尽量避免云 API key。若未来确实需要：**只存 Keychain**（或平台安全凭据机制），禁止出现在源码、配置文件、Git、日志、调试输出中。

### 3B.13 明令禁止（spec §55 摘要）

1. 硬编码 `qwen3:8b` 之类模型名 / `localhost:11434` 之类端点
2. 从 SwiftUI 或 Agent 直连 Ollama / GPT-SoVITS / WhisperKit
3. 绕过 Manager；让厂商 JSON 流入 domain 模型
4. 假设所有模型都支持 streaming / structured output
5. 编造端点、模型名、模型文件布局、runtime 行为（**必须对着实际安装的 runtime 核实**）
6. **强迫用户手填技术路径**；在普通设置里暴露 Python 环境 / checkpoint / 端口 / 量化
7. 重复加载模型；同时加载所有大模型
8. 吞掉错误；把推理失败静默转成空输出
9. 无产品需求就加云上传；为快速 demo 破坏 Provider/Adapter；集成期夹带无关功能

### 3B.14 实现顺序（spec §52，37 步）

```
检视仓库与现有架构 → 复用抽象 → 补全 ModelRegistry → 统一 metadata → 统一 capability
→ 配置解析器 → runtime 状态模型 → 六个 Mock → LLMProvider → OllamaLLMAdapter → LLMManager
→ ASRProvider → WhisperKitASRAdapter → VADProvider → SileroVADAdapter → TTSProvider
→ Qwen3TTSAdapter → (GPTSoVITSAdapter) → EmbeddingProvider → PronunciationProvider
→ ProcessManager → 模型安装/发现 → 健康检查 → 生命周期 → 配置 UI
→ 只暴露普通字段 → 高级/开发者配置单独放 → 单测 → runtime 集成测试
→ 接一个 Agent → 打通本地链路 → 验证内存 → 验证模型可替换 → 文档
```

**禁止一上来就把 runtime 调用塞进 Agent。**

### 3B.15 模型/运行时可替换性验收

以下替换必须**不动任何 Agent**：WhisperKit→其他 ASR；Qwen3→其他 LLM；Qwen3-TTS→GPT-SoVITS；Silero→其他 VAD；Ollama Embedding→MLX Embedding；发音 Pipeline A→B。
运行时也需可替换：Ollama→MLX→llama.cpp 跑同一个 Qwen3，只有 Adapter/Provider 层改动。

---

## 4. Agent 规范

| Agent | 职责 | 输出 |
|---|---|---|
| TeacherAgent | 是否纠错、纠错强度、难度、教学目标、话题节奏 | `TeacherDecision`（结构化） |
| GrammarAgent | 检错 / 纠正 / 解释 / 归类 / 严重度 / 重复错误识别 | `[GrammarError]` |
| ConversationAgent | 话题、追问、场景状态、难度、参与度 | `ConversationDirection`（不产出最终口语文本） |
| PronunciationAgent | 音素/重音/语调/流利度/语速/停顿 → 教学层结论 | `PronunciationAnalysis` |
| ResponsePlanner | 把分析转成结构化 `ResponsePlan`，再交给 LLM 生成措辞 | `ResponsePlan` |

- Agent **只**通过 Manager / MemoryService 拿能力，绝不直接碰模型与 SQL。
- Agent 输出必须是可序列化结构化数据，便于单测（不依赖 LLM）。
- 链路固定：`ASR → Analysis → Teacher → ... → ResponsePlanner → LLM → TTS`，禁止 `ASR → LLM → TTS` 直连。

---

## 5. 配置与资源

- 一切可能随机器/模型变化的东西进 `Resources/Config/`（YAML/JSON/plist/Codable）+ `ModelRegistry`：`model path / runtime host / port / baseURL / version / device / memory limit / voice reference / provider selection / language / temperature / topP / maxTokens / requestTimeout / streaming`。
- 默认值（如 Ollama `http://127.0.0.1:11434`、`qwen3:8b`）只能作为**配置文件里的初始值 + 文档示例**，代码里不允许出现字面量。
- **配置分层（见 §3B.4）**：`Resources/Config/` 存的是 **Runtime Configuration**（内部，`auto` 优先）；用户侧的 Product Configuration 只含模型/语言/音色/练习模式，两者经 `Configuration Resolver` 转换。
- **`auto` 必须被显式解析**：任何值为 `auto` 的字段，在进入 `Ready` 前必须解析为具体值，未解析即视为配置不完整。
- 文档中留空的 `path/port/host` 保持留空，由后续接入时填写；代码里不允许出现具体值。
- Scenario 数据驱动（`Resources/Scenarios/*.json`），禁止写死在 UI。
- **关卡 ↔ 情景绑定同样数据驱动**：`Resources/Levels/level_bindings.json`（`{ "<level id>": "<scenario id>" }`）。绑定在 `loadProgress()` 时注入 `TreeLevel.scenarioID`，**不落库**（改绑定表即生效）。绑定后：点这一关直接进该情景；情景结算的星星记在这一关上（累计、封顶到 `requiredStars`）。
- **学习库**：schema 版本集中在 `LearningDatabase.schemaVersion`（现 **v4**：`sessions.scenario_id`）。每次打开会跑一次幂等 `hygiene()`：删除「无消息且无情景」的空会话 —— 否则「最近会话」永远是新行，上次练习恢复不回来。**启动时不得预建空会话**（首条消息 / 首次进情景才建行）。
- Prompt 版本化：`Resources/Prompts/{teacher,grammar,conversation,pronunciation,response_planner}/v1.x.md`。

---

## 6. 错误处理

统一错误枚举，每个错误含 `code / message / recoverable / userMessage / technicalContext`：

```
AIError: ProviderUnavailable · ModelNotFound · ModelLoadFailed · OutOfMemory
         InferenceTimeout · InvalidOutput · UnsupportedCapability
         RuntimeCrash · ProviderConfigurationError
其他:    AudioError · DatabaseError · StorageError · ConfigurationError · PermissionError
```

Provider 侧另有 typed 错误（见 §3B.8 `AIProviderError`，14 个 case，含 `modelNotInstalled / modelIncompatible / insufficientMemory / processLaunchFailed`）。
禁止把错误静默转成空字符串或 `nil`。**技术错误必须映射为用户可执行的动作**（见 §3B.8）。

失败必须：捕获 → 记录 → 给用户可理解信息 → 尝试 fallback → 不崩 App。禁止吞异常。

---

## 7. 日志

分级 `DEBUG / INFO / WARNING / ERROR`；字段 `timestamp · module · provider · operation · latency · status · error`。

生产/默认模式**禁止**输出：原始音频、音色参考数据、完整私人对话内容、API key。开发模式可开详细 pipeline 日志。

---

## 8. 测试规范

| 改动范围 | 必跑 |
|---|---|
| 小改动 | 相关 Unit Test |
| Provider / Adapter | Unit + Provider 集成测试 |
| Pipeline | `Audio → VAD → ASR → Analysis → LLM → TTS` 集成测试 |
| 架构改动 | 全量测试 + 架构自查 |

- CI/本地必须能用 **Mock Provider** 跑完整流程，**不依赖任何真实大模型**（Ollama 未启动时集成测试 Skip，不算失败）。
- 依赖本地 runtime 的测试（Ollama 等）必须与离线单测**物理分离**（独立 target 或 `XCTSkip` 守卫），并遵守 §0.1 的代理绕行。
- 禁止声称「未运行的测试已通过」；报告里必须写实际执行的命令与结果。
- 测试用隔离的临时数据库，不碰用户数据。

---

## 9. 性能与资源（16GB 统一内存）

- 禁止所有模型同时常驻；`ModelLifecycleManager` 负责 lazy load / unload / warm cache / 内存压力检测 / 避免重复实例。
- 策略：对话态仅 `ASR + LLM + TTS`；发音评测态卸载非必要模型再加载评测引擎。
- 外部 runtime（如 Ollama）已托管模型权重时，**不要在本进程重复加载模型文件**；只做可达性校验与建连。
- 流式：LLM token → 句子/短语边界切分 → TTS，**禁止 token 直送 TTS**。
- 目标（非承诺）：用户说完 1–2s 内出声。Benchmark 必须实测，禁止凭空报数。

---

## 10. UI / 配置暴露规则

- **每个配置项必须先分级再实现**（`USER_VISIBLE / USER_VISIBLE_ADVANCED / AUTO_MANAGED / INTERNAL_ONLY`，见 §3B.4）；没有标签的字段不允许进 UI。
- V1 普通 UI 只允许出现：**模型、语言、音色、练习模式**。端口 / 端点 / 路径 / Python 环境 / checkpoint / 量化 / 设备 / 线程数 / temperature / top-p / 阈值 / 维度 / alignment 模型 **一律不进普通 UI**。
- 高级/开发者配置必须独立分区且默认折叠，**普通用户永远不需要打开它**。
- 状态呈现面向用户而非面向机器：`Ready ✓` / `Not installed [Install]` / `Runtime 未安装 [Install Runtime]`，禁止把原始异常、堆栈、路径抛给用户。
- 产品概念 ≠ 工程概念：用户看到的是「AI 教师 / 教师音色 / 发音练习 / 记忆 / 语音识别」，不是「LLM Runtime / TTS Checkpoint / Forced Alignment / Embedding Model / ASR Runtime」。

### 10A. 产品 UI 主题规范（用户 2026-09-09 明确，强制）

**主题**：森林 + 可爱动物。**核心隐喻**：学习者是一只小动物，沿**参天大树**向上攀登，每一关是树上的一个高度/枝桠。

**日夜双景（一等公民，2026-09-09 补充细化）**：
- **白天**：暖阳、明亮青绿林冠、飘动云朵、小动物**活跃**（跳跃/眨眼/奔跑）。
- **夜晚**：深靛夜空 + 星星 + 月亮、萤火虫、小动物**睡觉**（闭眼 + Zzz）。
- **切换入口**（2026-09-10 更新）：**右上角的太阳 / 月亮组件本身**（`CelestialToggle`，点太阳 → 进夜晚，点月亮 → 回白天）+ 设置页的 `白天 / 夜晚 / 跟随系统`。切换需有过渡动画，不得硬切。
- **日夜作用域 = 全局**：任何新组件（含浮层、弹窗、设置、未来新增页面）都必须响应日夜切换。规则：
  1. 颜色一律从 `ForestTheme` 语义色取（`@Environment(\.forestTheme)`），**禁止 View 内写死颜色字面量**；新增语义色先进 `ForestTheme`（已有 `scrim / panel / selection / hover`）。
  2. 根视图挂 `.preferredColorScheme(theme.isNight ? .dark : .light)`，保证原生控件（TextField/Picker/滚动条）同步换肤。
  3. 浮层（如设置面板）**必须用应用内 overlay 实现，不得用系统 `.sheet`**——前者保证在主题环境内、可关闭、日夜联动已验证。
- 主题是**设计系统**不是零散颜色：`ForestTheme` 统一提供 `sky / foliage / trunk / accent / text / surface / scrim / panel / selection / hover` 等语义色板。

**布局（2026-09-09 定稿）**：三栏结构，**不得随意挪动**：
- **左**：可收拉侧边栏 `AppSidebar`（App logo + 名称"语林"、设置、日夜切换、未来所有全局功能入口、收拉按钮）。之后的全局设置/功能**统一进侧边栏**，不再散落各处。
- **中**：对话区 `ChatView`（头部不放设置按钮，模型名以胶囊徽标展示）。
- **右**：成长之树关卡画布 `TreeCanvas`（宽 340）。

**动物形象（用户 2026-09-09 要求，强制）**：
- 每种动物**按物种独立绘制**，必须有可辨识的解剖特征（如：狐狸=尖耳+白口鼻+白尖尾、熊猫=黑耳黑眼圈、老虎=黑条纹+额纹、猫头鹰=大眼+面盘、兔子=长耳粉内耳、松鼠=蓬松大尾、刺猬=尖刺背、熊=圆耳大吻）。**禁止**"同一副身体换色"式的敷衍形象。
- 新增物种进 `AnimalKind` + 在 `Animals.swift` 里写独立绘制结构体，并同步加入设置页动物矩阵。

**闯关结构**：
- 竖直大树画布，节点 = 关卡（可解锁 / 进行中 / 已通关 / 锁定），树枝左右交错。
- 攀登者动物头像显示当前高度与下一个目标；进度变化要有攀爬动画。
- 关卡数据来自领域模型（`TreeLevel` / `ProgressNode`），**UI 不内置业务数据**。

**实现约束（必须遵守既有红线）**：
- UI 只依赖 `Application Services`（如 `ChatService`），**禁止 SwiftUI 直连 Ollama / Provider / SQL / HTTP**（§1）。
- 模型名、端点等只能经配置系统注入（§5、§3B.4）；**模型字段在设置 UI 可填可选，代码里不得出现模型名字面量**（§3B.13）。
- 模型下拉列表若 runtime 提供发现接口（Ollama `/v1/models`），由 Adapter 转成应用层模型后交给 UI；runtime 不可用时降级为配置项里的候选列表 + 明确状态提示，不得崩溃、不得静默空列表。

---

## 11. 编码与提交

- 提交前缀：`feat: fix: refactor: test: docs: perf: chore:`，一次提交一个问题（不同时重写 UI + 换库 + 换模型）。
- 新增依赖前必须回答：`Why / 解决什么 / 现有依赖能否解决 / 对 Apple Silicon 影响 / 维护风险 / License`。默认少加依赖。
- 不确定处用标记：`[UNVERIFIED] [TODO] [MOCK] [EXPERIMENTAL] [BLOCKED]`，不得把实验代码伪装成 Production Ready。
- 改动前：读文件 → 找调用方 → 找相关协议 → 看现有测试 → 确认无重复抽象。默认**最小必要修改**。
- 同步文档：Provider 接口 / Model Registry / 配置 / 数据库 Schema / 公共服务接口 / 架构 任一变更，必须同步 `Docs/` 与本报告。

---

## 12. 隐私与安全

- 默认：音频 / 转写 / 用户画像 / 学习记忆 / 音色参考 **全部本地**，不上传、不开遥测。
- 未来若需云 API key → 只存 **Keychain**，禁止写入源码 / 配置文件 / Git / 日志（见 §3B.12）。
- 用户可删除会话、音频、学习记录、音色模型、重置学习档案。
- 密钥、个人路径、音频数据禁止入库；`.gitignore` 覆盖 `.env*`、`*.db*`、`*.log`、`build/`、`.build/`、`*.wav` 等。
- Voice Cloning 属后期功能，仅限用户本人或已明确授权的声音，需显式同意，架构层只暴露 `supportsVoiceCloning` 之类的泛化能力。

---

## 13. 任务执行模板

```
TASK-ID / TITLE / OBJECTIVE
CURRENT STATE
FILES TO CREATE / MODIFY
ARCHITECTURE IMPACT
IMPLEMENTATION → TESTS → VALIDATION(build+test) → RISKS
NEXT TASK
```

完成报告固定字段：

```
Implemented / Files Created / Files Modified
Tests（实际命令 + 结果）
Build（实际命令 + 结果）
Architecture Check
Known Limitations / Unverified Assumptions / Next Recommended Task
```

---

## 14. Definition of Done

- [ ] 实现完成且架构边界未被破坏
- [ ] 配置外置，无硬编码（含模型名、`baseURL`、端口、超时）
- [ ] 厂商专属类型/JSON 未泄漏到 Domain / Agent / UI
- [ ] 每个新增配置字段已分级（USER_VISIBLE / ADVANCED / AUTO_MANAGED / INTERNAL_ONLY）
- [ ] `auto` 字段在进入 Ready 前已被解析；普通 UI 未暴露技术细节
- [ ] 模型缺失/损坏/runtime 缺失会给出可操作的用户动作，而非原始异常
- [ ] 测试已新增/更新且**实际跑过**
- [ ] `swift build` 通过
- [ ] 错误路径已处理、日志恰当
- [ ] 无未验证的 API 假设
- [ ] 文档已同步
- [ ] Mock 已标注 `[MOCK]`（如适用）

## 0.3 .app 打包与终端验证（2026-09-09 实测沉淀）

- **打包**：`Scripts/make_app.sh`（`--no-build` 跳过构建）→ `dist/AI_Language_Coach.app`（约 4MB）。
  - release 构建 + `strip -x`；SwiftPM 资源 bundle（`AILanguageCoach_AIInfrastructure.bundle`）**必须放 .app 根目录**（生成的 `Bundle.module` 在 `Bundle.main.bundleURL` 下查找）。
  - 不做 codesign：本机构建无 quarantine，双击可跑；整包签名会报 "unsealed contents present in the bundle root"（资源 bundle 在根目录所致）。
  - **release 增量构建可能漏更新可执行文件**（"Build complete 0.19s" 假象）——验证行为前 `rm -rf .build/arm64-apple-macosx/release` 全量重建；且 release 二进制里 grep 不到 Swift 字符串字面量不代表没编进去，以行为验证为准。
- **终端验证**：应用窗口 owner 名取自 CFBundleDisplayName（现为「语林 AI Language Coach」），`wid.swift / bounds.swift / activate.swift` 均已兼容中文名；**zsh 数组下标从 1 开始**（`$B[0]` 为空）；`open --args` 传参不可靠，验证用启动参数时直接运行二进制（注意：直接运行 bundle 内二进制可能出现 138pt 小窗口，`open` 正常；异常小窗口时 `defaults delete com.ailanguagecoach.app` 清 frame）。截图辅助：`--open-settings` / `--open-records`。
- **启动参数（截图 / 端到端验证专用，全部只影响本次进程）**：
  | 参数 | 作用 |
  |---|---|
  | `--open-settings` / `--open-records` / `--open-scenarios` | 启动即打开设置 / 学习记录 / 情景选择 |
  | `--scenario <id>` | 启动即进入某个情景（id 见 `Sources/AIInfrastructure/Resources/Scenarios/`） |
  | `--send "文本"` | 启动 1s 后自动发一条消息（端到端发消息验证） |
  | `--auto-speak` | 启动即打开自动朗读 |
  | `--auto-end-scenario` | 启动 12s 后自动结束当前情景（验证星星结算 / 奖励提示条） |
  | `--sleep-bubble` | 夜晚持续冒「它们在睡觉」气泡（本来由点右下角表情触发） |
  | `--theme day\|night\|system` | **临时**切换主题（只改内存，**不写配置文件**）——验证夜晚主题靠它，别再改 config.json |
- ⚠️ **不要依赖合成点击做 UI 验证**：CGEvent 合成鼠标事件（`.workbuddy/tmp/click.swift`）在本机无辅助功能权限时会被**静默丢弃**，osascript 点击对 SwiftUI 按钮时灵时不灵。验证一律走「启动参数 + `screencapture -l<windowID>` 截图」+ 单测/集成测试。
- ⚠️ **显示器休眠后 `screencapture` 全黑 / 报 `could not create image from window`**（窗口 ID 仍能拿到）。先 `caffeinate -u -t 3` 唤醒；若仍失败说明屏幕已锁，只能等用户解锁，别误判成「应用起不来」。
- **截图尺寸换算**：`screencapture -l` 的 PNG 是 2× 且含窗口阴影边距（约 34pt/边），不能把截图像素坐标直接当屏幕点击坐标用。
