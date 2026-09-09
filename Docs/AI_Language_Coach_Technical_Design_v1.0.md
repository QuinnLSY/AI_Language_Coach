# AI Language Coach 技术设计说明书 V1.0

> 文档状态：Baseline / Engineering Specification  
> 产品：AI Language Coach  
> 平台：macOS / Apple Silicon 优先  
> 目标设备：MacBook Pro M1 Pro / 16 GB RAM  
> 核心原则：Local-first、Model-agnostic、Provider/Adapter、可替换模型、流式交互、隐私优先

---

## 1. 技术目标

AI Language Coach 是一个本地优先的实时 AI 语言学习系统。系统通过：

`Microphone → Audio Pipeline → ASR → Language Analysis → Teacher/Conversation Agents → LLM → Response Planner → TTS → Audio Playback`

形成完整的语音教学闭环，并通过 Grammar、Pronunciation、Vocabulary、Memory 建立长期个性化学习能力。

### 1.1 V1 技术目标

必须实现：

- 本地麦克风采集
- VAD
- 本地 ASR
- 本地 LLM
- 本地 TTS
- 实时/准实时对话
- Grammar Correction
- Conversation History
- Learning Session
- 基础长期 Memory
- 模型 Provider/Adapter 架构
- 模型配置与运行状态管理
- 基础错误处理与日志
- M1 Pro / 16 GB 稳定运行

### 1.2 非目标

V1 不实现：

- 云端训练
- 社交系统
- 多人课堂
- 用户社区
- 商业支付
- 自研基础模型
- 强依赖某一家模型厂商的 API

---

## 2. 架构原则

### 2.1 Model-Agnostic

业务层不得直接依赖具体模型。

禁止：

```text
ConversationService → GPT-SoVITS
```

必须：

```text
ConversationService
    → TTSManager
        → ITTSProvider
            → GPTSoVITSBackend
```

### 2.2 Dependency Inversion

核心业务依赖接口，具体模型实现接口。

### 2.3 Configuration Driven

模型路径、Runtime、设备、端口、参数不得硬编码。

### 2.4 Capability Driven

模型必须声明能力，例如：

- streaming
- multilingual
- voice_cloning
- style_control
- word_timestamps
- phoneme_alignment

UI 和业务逻辑根据 capability 决定可用功能。

### 2.5 Local-first

默认所有：

- Audio
- Transcript
- User Profile
- Learning Memory
- Voice Data

均本地处理和保存。

### 2.6 Graceful Degradation

任一模型不可用时，不应导致 App 崩溃；允许 fallback。

---

## 3. 系统分层

```text
┌─────────────────────────────────────┐
│ Presentation Layer                  │
│ SwiftUI / macOS UI                 │
├─────────────────────────────────────┤
│ Application Layer                   │
│ Conversation / Learning / Session  │
├─────────────────────────────────────┤
│ Agent Layer                         │
│ Teacher / Grammar / Conversation   │
│ Pronunciation / Response Planner   │
├─────────────────────────────────────┤
│ AI Abstraction Layer                │
│ ASR / LLM / TTS / VAD / Embedding │
│ Pronunciation Provider              │
├─────────────────────────────────────┤
│ Adapter Layer                       │
│ WhisperKit / llama.cpp / GPTSoVITS│
│ Qwen / Future Backends              │
├─────────────────────────────────────┤
│ Runtime Layer                       │
│ MLX / Metal / MPS / CPU / Process │
├─────────────────────────────────────┤
│ Infrastructure                      │
│ SQLite / Files / Logging / Config  │
└─────────────────────────────────────┘
```

---

## 4. 推荐项目目录

```text
AI-Language-Coach/
├── App/
├── UI/
│   ├── Dashboard/
│   ├── Conversation/
│   ├── Practice/
│   ├── Session/
│   ├── Progress/
│   └── Settings/
├── Core/
│   ├── Conversation/
│   ├── Learning/
│   ├── Memory/
│   ├── Audio/
│   └── Configuration/
├── Agents/
│   ├── Teacher/
│   ├── Grammar/
│   ├── Conversation/
│   ├── Pronunciation/
│   └── ResponsePlanner/
├── AI/
│   ├── Interfaces/
│   ├── Managers/
│   ├── Registry/
│   ├── ASR/
│   ├── LLM/
│   ├── TTS/
│   ├── VAD/
│   ├── Embedding/
│   └── Pronunciation/
├── Infrastructure/
│   ├── Database/
│   ├── Storage/
│   ├── Logging/
│   └── Process/
├── Resources/
│   ├── Config/
│   ├── Prompts/
│   └── Scenarios/
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   └── Benchmark/
└── Docs/
```

具体语言/框架可以调整，但模块边界必须保持。

---

## 5. 核心 Domain Model

### 5.1 User

```text
User
- id
- createdAt
- targetLanguages
- activeLanguage
```

### 5.2 UserProfile

```text
UserProfile
- userId
- level
- goals
- preferredAccent
- teacherStyle
- correctionMode
- speakingSpeed
- updatedAt
```

### 5.3 LearningSession

```text
LearningSession
- id
- userId
- scenarioId
- startedAt
- endedAt
- duration
- summary
- scores
```

### 5.4 ConversationTurn

```text
ConversationTurn
- id
- sessionId
- speaker
- audioPath
- transcript
- timestamp
- language
- asrConfidence
```

### 5.5 GrammarError

```text
GrammarError
- id
- sessionId
- turnId
- category
- originalText
- correctedText
- explanation
- severity
- pattern
```

### 5.6 VocabularyItem

```text
VocabularyItem
- id
- userId
- word
- language
- meaning
- proficiency
- frequency
- lastReviewedAt
```

### 5.7 PronunciationResult

```text
PronunciationResult
- id
- turnId
- overall
- phoneme
- stress
- intonation
- fluency
- speechRate
- pauseScore
```

---

## 6. AI Provider Architecture

统一：

```text
Provider Interface
      ↓
Provider Manager
      ↓
Concrete Adapter
      ↓
Local Runtime
      ↓
Model
```

所有 Provider 必须支持：

```text
initialize()
load()
unload()
healthCheck()
getCapabilities()
getMetadata()
```

---

## 7. ASR

接口：

```swift
protocol ASRProvider {
    func initialize(config: ASRConfig) async throws
    func transcribe(audio: AudioBuffer,
                    options: ASROptions) async throws -> Transcript
    func stream(audioStream: AsyncStream<AudioChunk>,
                options: ASROptions)
        -> AsyncThrowingStream<PartialTranscript, Error>
    func unload() async
    func healthCheck() async -> ProviderHealth
    func capabilities() -> ASRCapabilities
}
```

输出必须支持：

```text
text
language
confidence
segments
words
start/end timestamps
```

word-level timestamp 为后续发音评测保留。

第一候选：

- WhisperKit
- whisper.cpp
- SenseVoice

最终模型必须通过 Benchmark 决定。

---

## 8. VAD

接口：

```swift
protocol VADProvider {
    func detect(audio: AudioBuffer) async throws -> VADResult
    func stream(audioStream: AsyncStream<AudioChunk>)
        -> AsyncThrowingStream<VADEvent, Error>
}
```

事件：

```text
speechStarted
speech
speechEnded
silence
```

候选：

- WebRTC VAD
- Silero VAD
- Apple native capability

---

## 9. LLM

接口：

```swift
protocol LLMProvider {
    func generate(
        messages: [ChatMessage],
        options: LLMOptions
    ) async throws -> LLMResponse

    func stream(
        messages: [ChatMessage],
        options: LLMOptions
    ) -> AsyncThrowingStream<LLMToken, Error>

    func unload() async
    func healthCheck() async -> ProviderHealth
    func capabilities() -> LLMCapabilities
}
```

必须支持 streaming。

模型运行方式可以是：

- MLX
- llama.cpp
- Ollama
- 其他本地 Runtime

不得在业务层固定。

---

## 10. TTS

接口：

```swift
protocol TTSProvider {
    func synthesize(
        text: String,
        options: TTSOptions
    ) async throws -> AudioResult

    func stream(
        textStream: AsyncStream<String>,
        options: TTSOptions
    ) -> AsyncThrowingStream<AudioChunk, Error>

    func voices() async throws -> [Voice]
    func unload() async
    func healthCheck() async -> ProviderHealth
    func capabilities() -> TTSCapabilities
}
```

TTSOptions：

```text
language
voiceId
speed
pitch
style
emotion
referenceAudio
referenceText
```

参数是否真正生效由 Backend capability 决定。

第一候选：

- GPT-SoVITS
- Qwen3-TTS
- Chatterbox

GPT-SoVITS 作为第一阶段重点测试 Backend，但不作为核心架构依赖。

---

## 11. GPT-SoVITS Adapter

必须封装在：

```text
AI/TTS/Adapters/GPTSoVITSBackend
```

配置：

```yaml
tts:
  provider: gpt_sovits
  runtime:
    type: local_process
    host: ""
    port: ""
  model:
    path: ""
    version: ""
  voices:
    teacher_default:
      reference_audio: ""
      reference_text: ""
```

所有实际路径、启动命令、端口和模型参数由合作开发阶段填写。

---

## 12. Embedding

```swift
protocol EmbeddingProvider {
    func embed(text: String) async throws -> [Float]
}
```

用于：

- Long-term Memory
- Similar Error Retrieval
- Vocabulary Retrieval
- Conversation Retrieval

V1 可使用 SQLite + 向量索引/FAISS 类本地方案；具体实现不影响业务层。

---

## 13. Pronunciation Provider

```swift
protocol PronunciationProvider {
    func evaluate(
        audio: AudioBuffer,
        target: String,
        transcript: Transcript
    ) async throws -> PronunciationResult

    func capabilities() -> PronunciationCapabilities
}
```

V1 输出：

```text
overall
phoneme
stress
intonation
fluency
speechRate
pause
```

实现可以采用 forced alignment + acoustic model 等组合方案，不在本规格中锁死模型。

---

## 14. Agent Architecture

```text
TeacherAgent
      ↓
ResponsePlanner
      ↓
ConversationAgent
      ↓
GrammarAgent
      ↓
PronunciationAgent
      ↓
LearningMemory
```

Agent 不直接调用具体模型。

所有 Agent 通过：

```text
LLMManager
ASRManager
TTSManager
MemoryService
```

获取能力。

---

## 15. Teacher Agent

输入：

```text
UserProfile
SessionContext
RecentErrors
LearningGoals
ConversationState
CurrentAnalysis
```

输出：

```json
{
  "shouldCorrect": true,
  "correctionStyle": "gentle",
  "shouldExplain": true,
  "responseLength": "short",
  "difficulty": "B1",
  "continueTopic": true,
  "targetVocabulary": [],
  "targetGrammar": []
}
```

---

## 16. Grammar Agent

输入：

```text
transcript
conversationContext
userProfile
recentGrammarErrors
```

输出：

```json
{
  "errors": [
    {
      "type": "tense",
      "original": "have went",
      "corrected": "went",
      "explanation": "Use simple past with a specific past time.",
      "severity": "medium",
      "pattern": "present-perfect-vs-simple-past"
    }
  ]
}
```

---

## 17. Pronunciation Agent

流程：

```text
Audio
 ↓
ASR
 ↓
Word/Phoneme Alignment
 ↓
Acoustic Analysis
 ↓
Pronunciation Provider
 ↓
Pronunciation Agent
```

Agent 输出教学层结论，而不是原始声学特征。

---

## 18. Response Planner

Response Planner 是模型和教学策略之间的桥梁。

输入：

```text
TeacherDecision
GrammarAnalysis
PronunciationAnalysis
ConversationState
```

输出：

```json
{
  "responseText": "...",
  "correctionIncluded": true,
  "explanationIncluded": true,
  "targetDifficulty": "B1",
  "tts": {
    "voiceId": "teacher_default",
    "speed": 0.95,
    "style": "friendly"
  }
}
```

---

## 19. Conversation State Machine

```text
IDLE
 ↓
LISTENING
 ↓
PROCESSING
 ↓
ANALYZING
 ↓
GENERATING
 ↓
SYNTHESIZING
 ↓
SPEAKING
 ↓
WAITING
 ↓
LISTENING
```

异常：

```text
ANY STATE
 ↓
ERROR
 ↓
RECOVERING
 ↓
IDLE
```

---

## 20. Audio Pipeline

### Input

```text
Microphone
 → AudioCapture
 → AudioBuffer
 → NoiseHandling
 → VAD
 → ASR
```

### Output

```text
LLM Stream
 → Text Chunker
 → TTS Stream
 → AudioBuffer
 → Playback
```

TTS 应尽可能采用句子/短语级 streaming，而不是等待完整回答结束。

---

## 21. Streaming 策略

推荐：

```text
LLM token stream
 ↓
Sentence Boundary Detector
 ↓
TTS first complete phrase
 ↓
Playback
```

不要等待整个 LLM response。

目标：

> 用户停止说话后尽快播放第一段 AI 语音。

---

## 22. Memory Architecture

分三层：

### Short-term

当前 10–20 turns。

### Session

本次学习：

- errors
- vocabulary
- scores
- topic

### Long-term

用户长期：

- level
- frequent errors
- weak pronunciation
- vocabulary
- learning goals
- preferences
- history

---

## 23. Memory Retrieval

```text
Current Turn
 ↓
Embedding
 ↓
Retrieve relevant memories
 ↓
Memory Context
 ↓
Teacher Agent / LLM
```

Memory 必须有 relevance、recency 和 importance 概念，避免把所有历史数据塞进 Prompt。

---

## 24. SQLite

V1 推荐 SQLite。

核心表：

```text
users
user_profiles
learning_sessions
conversation_turns
grammar_errors
pronunciation_results
vocabulary_items
vocabulary_reviews
learning_goals
scenarios
teacher_preferences
model_configs
memory_items
```

数据库访问必须封装，不允许 UI 直接操作 SQL。

---

## 25. Model Registry

统一记录：

```json
{
  "id": "tts-gpt-sovits",
  "type": "tts",
  "provider": "GPTSoVITSBackend",
  "runtime": "local",
  "modelPath": "",
  "enabled": true,
  "priority": 1
}
```

Registry 必须支持：

- register
- unregister
- enable
- disable
- set default
- health check
- capability query

---

## 26. Model Configuration

模型配置分离：

```text
Application Config
Model Config
Runtime Config
User Preferences
```

不得将 API key、路径、端口等散落在代码中。

---

## 27. Model Lifecycle

因为目标设备为 16 GB RAM，模型必须支持：

```text
load on demand
unload
warm cache
memory check
```

禁止无控制地同时常驻所有大模型。

---

## 28. Process Isolation

如果某个模型 Runtime 容易崩溃，优先采用独立本地进程：

```text
Main App
 ├── ASR Process
 ├── LLM Process
 └── TTS Process
```

通过 localhost / IPC 通信。

具体是否进程隔离由 Benchmark 和稳定性测试决定。

---

## 29. Error Handling

错误分类：

```text
ModelNotFound
ModelLoadFailed
RuntimeUnavailable
OutOfMemory
UnsupportedLanguage
UnsupportedCapability
AudioDeviceError
InferenceTimeout
InvalidResponse
DatabaseError
```

错误必须：

1. 被捕获
2. 记录
3. 显示用户可理解的信息
4. 尝试 fallback
5. 不导致整个 App 崩溃

---

## 30. Logging

分级：

```text
DEBUG
INFO
WARNING
ERROR
```

默认日志不得包含：

- 完整用户隐私音频
- 不必要的完整学习记录
- 敏感数据

开发模式可以开启详细 AI Pipeline 日志。

---

## 31. Benchmark Framework

每一个模型 Backend 都必须可以独立 Benchmark。

### ASR

- WER
- latency
- memory
- CPU/GPU usage

### LLM

- TTFT
- tokens/sec
- memory
- stability

### TTS

- TTFA
- RTF
- memory
- voice similarity
- naturalness

### Pronunciation

- scoring consistency
- alignment quality
- latency

---

## 32. Benchmark 数据集

V1 建立本地小型测试集：

```text
short sentences
long sentences
fast speech
slow speech
different accents
background noise
numbers
dates
names
technical vocabulary
```

同一测试集比较不同模型。

---

## 33. M1 Pro 优化

必须优先验证：

- Metal
- MPS
- MLX
- CPU fallback
- Unified Memory
- model quantization
- lazy loading

目标不是单纯追求最大模型，而是：

> 在 16 GB RAM 下获得稳定、低延迟的实时体验。

---

## 34. UI 页面

V1：

```text
Dashboard
Conversation
Scenario
Session Summary
Progress
Settings
```

Settings：

```text
Models
Voice
Language
Teacher
Audio
Privacy
Advanced
```

---

## 35. Scenario Schema

```json
{
  "id": "job_interview",
  "name": "Job Interview",
  "language": "en",
  "level": "B1-B2",
  "role": "interviewer",
  "goal": "interview_practice",
  "maxTurns": 20,
  "correctionMode": "balanced"
}
```

Scenario 必须数据驱动，避免将场景写死在代码中。

---

## 36. Security / Privacy

默认：

- 不上传音频
- 不上传 transcript
- 不上传 voice reference
- 不启用 telemetry

用户可以：

- 删除会话
- 删除音频
- 删除学习数据
- 删除 Voice Reference
- 重置学习档案

Voice cloning 必须要求用户拥有或获得声音使用授权。

---

## 37. Testing

### Unit Test

测试：

- Provider
- Registry
- Memory
- State Machine
- Configuration
- Database

### Integration Test

测试：

```text
Audio → ASR → LLM → TTS
```

### Failure Test

测试：

- 模型不存在
- 模型加载失败
- OOM
- Runtime crash
- Audio interruption
- TTS failure

---

## 38. MVP Acceptance Criteria

MVP 必须满足：

### AC-01

用户可以通过麦克风讲话。

### AC-02

系统能够使用本地 ASR 获得文本。

### AC-03

系统能够进行本地 LLM 对话。

### AC-04

系统能够使用本地 TTS 回复。

### AC-05

系统能够识别并展示基础语法错误。

### AC-06

系统能够保存 Conversation Session。

### AC-07

系统能够保存至少一种长期学习记忆。

### AC-08

ASR/LLM/TTS 均可以替换 Provider。

### AC-09

修改模型不需要修改业务层。

### AC-10

单个模型失败不会导致 App 崩溃。

### AC-11

M1 Pro / 16 GB 可以稳定完成基础对话。

---

## 39. 开发顺序

推荐严格按以下顺序：

```text
Phase 1
Project Skeleton
 ↓
Phase 2
Audio Capture + VAD
 ↓
Phase 3
ASR Provider
 ↓
Phase 4
LLM Provider
 ↓
Phase 5
TTS Provider
 ↓
Phase 6
Conversation Pipeline
 ↓
Phase 7
Grammar Agent
 ↓
Phase 8
Session + SQLite
 ↓
Phase 9
Memory
 ↓
Phase 10
UI Polish
 ↓
Phase 11
Benchmark
 ↓
Phase 12
Pronunciation
```

不要在基础 Pipeline 没跑通前同时开发所有 Agent。

---

## 40. Definition of Done

一个模块只有满足以下条件才算完成：

- Interface 已定义
- Concrete Adapter 已实现
- Configuration 已实现
- Health Check 已实现
- Error Handling 已实现
- Unit Test 已实现
- Integration Test 已实现（适用时）
- Benchmark 已实现（AI Model 适用时）
- Documentation 已更新

---

## 41. 最终架构约束

必须保持：

```text
UI
 ↓
Application Services
 ↓
Agents
 ↓
Managers
 ↓
Provider Interfaces
 ↓
Adapters
 ↓
Local Runtime
 ↓
Models
```

任何开发者或 AI Agent 如果发现：

```text
UI → GPTSoVITS
Service → WhisperKit
Agent → llama.cpp
```

等直接依赖，必须重构为 Provider/Adapter。

---

## 42. 版本演进

V1.0：

- Real-time Conversation
- Grammar
- Memory
- Local Models

V1.1：

- Shadowing
- Pronunciation
- Vocabulary

V1.2：

- Role Play
- Interview
- Learning Plan

V2：

- Voice Cloning
- Multi-language
- Advanced Pronunciation
- Adaptive Curriculum

---

## 43. 模型定型原则

本技术文档**不锁死最终模型**。

当前候选：

```text
ASR:
WhisperKit / whisper.cpp / SenseVoice

LLM:
MLX / llama.cpp based local model

TTS:
GPT-SoVITS / Qwen3-TTS / Chatterbox

Pronunciation:
Forced Alignment + Acoustic Model

Embedding:
Local Embedding Model
```

最终选择必须经过：

`Accuracy + Latency + Memory + Stability + User Experience`

综合 Benchmark。

