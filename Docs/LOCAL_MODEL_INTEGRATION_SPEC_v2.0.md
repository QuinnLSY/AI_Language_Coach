# AI Language Coach — Local Model Integration Specification

**Version:** 2.0  
**Status:** Development Baseline / Unified Model Configuration Specification  
**Target:** macOS / Apple Silicon / Swift 6 / SwiftUI  
**Primary Hardware Target:** Apple Silicon, M1 Pro / 16 GB unified memory  
**Initial Runtimes:** Embedded Swift/Core ML, Ollama, Local Python Runtimes  
**Architecture:** Model-Agnostic + Provider/Adapter + Local-First + User-Simple Configuration

---

# 1. Purpose

This document defines the engineering contract for integrating locally deployed AI models into **AI Language Coach**.

Unlike the previous version, this specification is no longer limited to LLM/Ollama integration.

It defines one unified model integration architecture for:

```text
ASR
LLM
TTS
VAD
Embedding
Pronunciation
```

The primary engineering objective is:

> Models and runtimes must be replaceable without requiring changes to Agents, business logic, or SwiftUI.

The first concrete LLM target remains:

```text
Ollama
   ↓
OllamaLLMProvider
   ↓
LLMProvider
   ↓
LLMManager
```

The complete local AI architecture is:

```text
SwiftUI
   ↓
Application Services
   ↓
AI Agents
   ↓
AI Managers
   ↓
Provider Interfaces
   ↓
Provider Adapters
   ↓
Local Runtime
   ↓
Local Model / Model Pipeline
```

The six major AI capabilities are:

```text
ASR
LLM
TTS
VAD
Embedding
Pronunciation
```

All six MUST follow the same architectural principles.

---

# 2. Product Configuration Principle: Simple for Users, Complete for Agents

AI Language Coach is a **consumer-facing language learning application**, not a developer tool.

Therefore:

> The user should choose what they want, not configure how the AI runtime works.

For example, an ordinary user should be able to select:

```text
AI Model
    Qwen3 8B

Teacher Voice
    Serena

Learning Language
    English
```

The user should NOT normally be required to enter:

```text
Python executable path
Virtual environment path
Model checkpoint path
Port number
API endpoint
ONNX model path
PyTorch version
Quantization mode
Device backend
Health-check URL
```

These technical details SHOULD be:

1. automatically installed;
2. automatically discovered;
3. automatically configured;
4. automatically validated;
5. automatically managed by the application.

Advanced configuration may be introduced in future versions, but it MUST NOT be required for normal operation.

---

## 2.1 Two Configuration Layers

The implementation MUST distinguish between **Product Configuration** and **Runtime Configuration**.

### Product Configuration

This is what ordinary users can see.

```text
User
  ↓
Product Model UI
  ↓
Simple User Configuration
```

Examples:

```text
Language
Teacher Voice
AI Model
Practice Mode
Voice Cloning
```

### Runtime Configuration

This is internal application configuration.

```text
Simple User Configuration
  ↓
Configuration Resolver
  ↓
Model Registry
  ↓
Provider Manager
  ↓
Provider Adapter
  ↓
Runtime
  ↓
Model
```

Examples:

```text
Runtime Type
Endpoint
Port
Model Path
Python Environment
Runtime Directory
Device
Quantization
Health Check
Process ID
Model Version
```

Runtime configuration MUST NOT leak into ordinary product UI unless there is a specific advanced-use case.

---

## 2.2 Required UI Design Rule

Every configuration field MUST be classified as one of:

```text
USER_VISIBLE
USER_VISIBLE_ADVANCED
AUTO_MANAGED
INTERNAL_ONLY
```

Default behavior:

```text
USER_VISIBLE
    ↓
Only information that materially affects user experience

USER_VISIBLE_ADVANCED
    ↓
Optional configuration for advanced users

AUTO_MANAGED
    ↓
Application resolves automatically

INTERNAL_ONLY
    ↓
Never expose to normal users
```

The default product UI SHOULD contain as few fields as possible.

---

## 2.3 Do Not Expose Installation Complexity

The following information SHOULD normally remain invisible to users:

```text
Python version
PyTorch version
Transformers version
ONNX Runtime version
Model file path
Runtime executable path
Virtual environment path
Local port
Health-check endpoint
Process ID
Model weight filenames
Quantization
Inference backend
MPS/CPU selection
Thread count
Batch size
Context length
Temperature
Top-P
Max Tokens
VAD threshold
Embedding dimension
Forced alignment model
Phoneme dictionary
Acoustic analysis model
```

These parameters may exist internally.

The AI Coding Agent MUST implement them as internal configuration.

---

## 2.4 Versioning Principle

The product MUST support progressive configuration exposure.

### V1

Expose only:

```text
Model
Language
Voice
Practice Mode
```

### V2+

Potentially expose:

```text
Voice style
Response style
Model quality/speed preference
Advanced voice settings
```

### Developer / Debug Mode

Only when explicitly enabled:

```text
Runtime
Endpoint
Model Path
Port
Device
Process
Model Version
Health Check
```

Normal users MUST NOT need Developer Mode.

---

# 3. Mandatory Architecture

The dependency direction MUST be:

```text
SwiftUI
   ↓
Application Services
   ↓
Agents
   ↓
Managers
   ↓
Provider Interfaces
   ↓
Concrete Provider Adapters
   ↓
Local Runtime
   ↓
Local Model / Pipeline
```

For example:

```text
SwiftUI
   ↓
ConversationService
   ↓
TeacherAgent
   ↓
LLMManager
   ↓
LLMProvider
   ↓
OllamaLLMProvider
   ↓
Ollama
   ↓
Qwen3
```

ASR:

```text
AudioCapture
   ↓
ASRManager
   ↓
ASRProvider
   ↓
WhisperKitASRAdapter
   ↓
WhisperKit
   ↓
Whisper Model
```

TTS:

```text
ResponsePlanner
   ↓
TTSManager
   ↓
TTSProvider
   ↓
Qwen3TTSAdapter
   ↓
Local TTS Runtime
   ↓
Qwen3-TTS
```

VAD:

```text
AudioCapture
   ↓
VADManager
   ↓
VADProvider
   ↓
SileroVADAdapter
   ↓
Embedded Runtime
   ↓
Silero VAD
```

Pronunciation:

```text
Audio
   ↓
PronunciationManager
   ↓
PronunciationProvider
   ↓
PronunciationAdapter
   ↓
Alignment + Acoustic Analysis Pipeline
```

---

## 3.1 Prohibited Architecture

The following are prohibited:

```text
SwiftUI → Ollama

SwiftUI → WhisperKit

SwiftUI → GPT-SoVITS

TeacherAgent → Ollama

GrammarAgent → Ollama

ConversationAgent → WhisperKit

ApplicationService → GPT-SoVITS

Agent → llama.cpp

Agent → Python process
```

Agents MUST depend only on provider-independent abstractions.

---

# 4. Technology Baseline

Use:

```text
Swift 6
SwiftUI
macOS
Apple Silicon
Swift Concurrency
async/await
AsyncThrowingStream
Foundation URLSession
Swift Package Manager
XCTest
```

Do not introduce additional networking dependencies unless there is a demonstrated need.

Local runtime communication SHOULD preferably use:

```text
Foundation URLSession
```

for HTTP-based providers.

---

# 5. Unified Provider Contract

Every AI capability SHOULD provide a provider-independent interface equivalent to:

```swift
protocol AIProvider: Sendable {

    func initialize() async throws

    func load() async throws

    func unload() async throws

    func healthCheck() async throws -> Bool

    func getCapabilities() -> AICapabilities

    func getMetadata() -> AIProviderMetadata
}
```

Capability-specific interfaces may extend this base contract.

For example:

```swift
protocol LLMProvider: AIProvider {

    func generate(
        request: LLMRequest
    ) async throws -> LLMResponse

    func stream(
        request: LLMRequest
    ) -> AsyncThrowingStream<LLMChunk, Error>
}
```

ASR:

```swift
protocol ASRProvider: AIProvider {

    func transcribe(
        request: ASRRequest
    ) async throws -> ASRResult
}
```

TTS:

```swift
protocol TTSProvider: AIProvider {

    func synthesize(
        request: TTSRequest
    ) async throws -> TTSResult

    func stream(
        request: TTSRequest
    ) -> AsyncThrowingStream<TTSChunk, Error>
}
```

VAD:

```swift
protocol VADProvider: AIProvider {

    func process(
        audio: AudioBuffer
    ) async throws -> VADResult
}
```

Embedding:

```swift
protocol EmbeddingProvider: AIProvider {

    func embed(
        texts: [String]
    ) async throws -> [[Float]]
}
```

Pronunciation:

```swift
protocol PronunciationProvider: AIProvider {

    func analyze(
        request: PronunciationRequest
    ) async throws -> PronunciationResult
}
```

The exact existing project abstractions SHOULD be reused if equivalent abstractions already exist.

Do not create duplicate interfaces unnecessarily.

---

# 6. Capability Model

Behavior MUST be capability-driven.

Example:

```swift
struct AICapabilities: Sendable {

    let streaming: Bool

    let multilingual: Bool

    let structuredOutput: Bool

    let wordTimestamp: Bool

    let voiceCloning: Bool

    let pitchControl: Bool

    let emotionControl: Bool

    let phonemeAlignment: Bool

    let embedding: Bool
}
```

Never assume every runtime supports every capability.

For example:

```text
WhisperKit
    streaming       → supported/implementation-dependent
    wordTimestamp   → supported
    voiceCloning    → not applicable

Ollama LLM
    streaming       → supported
    voiceCloning    → not applicable

Qwen3-TTS
    voiceCloning    → model-dependent
    emotion         → model-dependent

Silero VAD
    streaming       → supported
    voiceCloning    → not applicable
```

The application MUST query capabilities instead of hard-coding assumptions.

---

# 7. Provider Metadata

Every provider SHOULD expose:

```swift
struct AIProviderMetadata: Sendable {

    let providerID: String

    let displayName: String

    let capabilityType: AICapabilityType

    let runtimeType: AIRuntimeType

    let runtimeVersion: String?

    let modelName: String?

    let modelVersion: String?
}
```

Example:

```text
providerID:
    ollama

displayName:
    Ollama

capabilityType:
    LLM

runtimeType:
    ollama

modelName:
    qwen3:8b
```

Model names MUST come from configuration.

---

# 8. Runtime Categories

Every local AI integration MUST declare one of the following runtime types.

| Runtime Type | Meaning | Port | Examples | User UI |
|---|---|---:|---|---|
| `embedded` | Runtime integrated into application | No | WhisperKit, Silero VAD | Usually hidden |
| `ollama` | Ollama manages local models | Yes | Qwen3, Embeddings | Model selection |
| `python_process` | App manages local Python runtime | Usually | GPT-SoVITS, Qwen3-TTS | Voice/model |
| `external_local_runtime` | Other local runtime exposes API | Usually | llama.cpp, MLX server | Advanced only |
| `pipeline` | Multiple models/algorithms cooperate | Depends | Pronunciation | Simplified mode |
| `resource` | Supporting asset, not inference model | No | Reference audio, dictionaries | Only when needed |

The Agent MUST NOT assume that every model has:

```text
modelPath
endpoint
port
python environment
```

Some models are embedded directly into the application.

---

# 9. Unified Model Configuration Concept

The universal conceptual model is:

```text
Provider
    ↓
Runtime
    ↓
Endpoint / Path
    ↓
Model
    ↓
Capabilities
    ↓
Parameters
    ↓
Health
```

Every capability MUST fit this abstraction.

---

# 10. Unified Configuration Field Catalog

The following fields form the internal canonical configuration schema.

| Field | Internal | Normal UI | Description | Example |
|---|---|---|---|---|
| Provider Name | Required | Visible | Human-readable provider name | `Ollama` |
| Provider ID | Required | Hidden | Stable internal ID | `ollama` |
| Capability Type | Required | Category | ASR/LLM/TTS/VAD/Embedding/Pronunciation | `LLM` |
| Runtime Type | Required | Hidden | Runtime implementation type | `ollama` |
| Model Name | Required | Visible | Selected model | `qwen3:8b` |
| Model Version | Optional | Hidden | Model version | `v1` |
| Model Path | Conditional | Hidden | Local model path | `/Models/...` |
| Model Repository | Optional | Hidden | Model source | Hugging Face |
| Endpoint | Conditional | Hidden | Local API endpoint | `http://127.0.0.1:11434` |
| Port | Conditional | Hidden | Local runtime port | `11434` |
| Runtime Directory | Conditional | Hidden | Runtime working directory | `/Applications/...` |
| Python Environment | Conditional | Hidden | Managed Python environment | `/.../.venv/bin/python` |
| Executable Path | Conditional | Hidden | Runtime executable | `/usr/local/bin/...` |
| Device | Optional | Auto | CPU/MPS/GPU/etc. | `auto` |
| Language | Conditional | Visible | Target language | `English` |
| Streaming | Optional | Auto | Streaming support | `true` |
| Word Timestamp | Optional | Hidden | ASR word timestamps | `true` |
| Voice ID | Conditional | Visible | Selected voice | `teacher_default` |
| Reference Audio | Conditional | Conditional | Voice-cloning reference | `user_voice.wav` |
| Reference Text | Conditional | Conditional | Reference transcript | `Hello...` |
| Context Length | Optional | Hidden | LLM context capacity | `32768` |
| Temperature | Optional | Hidden | Sampling parameter | `0.7` |
| Top P | Optional | Hidden | Sampling parameter | `0.9` |
| Max Tokens | Optional | Hidden | Generation limit | `1024` |
| Keep Alive | Optional | Hidden | Model residency | `5m` |
| Threshold | Conditional | Hidden | VAD/scoring threshold | `0.5` |
| Dimensions | Conditional | Hidden | Embedding dimension | `768` |
| Batch Size | Optional | Hidden | Batch size | `1` |
| Quantization | Optional | Hidden | Precision/compression | `8bit` |
| Capabilities | Required | Hidden | Supported features | `streaming` |
| Health Check | Required | Status only | Runtime readiness check | `/health` |
| Enabled | Required | Visible | Provider enabled state | `true` |

---

# 11. Normal User UI Rules

The product MUST follow this rule:

> If a field does not affect the user's conceptual choice, do not expose it.

For example:

### Good

```text
AI Model

○ Fast
● Balanced
○ High Quality
```

or:

```text
AI Model

Qwen3 8B
```

### Bad

```text
Model Path:
~/Library/Application Support/AI-Language-Coach/models/qwen3-8b-q4_k_m.gguf

Quantization:
Q4_K_M

Context:
32768

Temperature:
0.7

Top P:
0.9

Threads:
8

MPS:
Enabled
```

The second UI is a developer console and MUST NOT be the default product experience.

---

# 12. ASR Configuration

## 12.1 Recommended V1

Use:

```text
WhisperKit
    +
Whisper
```

Runtime:

```text
embedded
```

Adapter:

```text
WhisperKitASRAdapter
```

No local HTTP server is required.

WhisperKit integrates Whisper with Apple's Core ML stack through Swift and supports local inference on Apple platforms. The official project should be used as the primary integration reference.

## 12.2 Internal Configuration

```yaml
asr:
  provider: whisperkit
  runtime: embedded

  model:
    name: large-v3
    path: auto

  language: auto

  device: auto

  streaming:
    enabled: true

  timestamps:
    word: true
```

## 12.3 User UI

Normal UI:

```text
Speech Recognition

Language:
Auto
```

Optionally:

```text
Language:
English
```

Everything else SHOULD be automatic.

Do NOT expose:

```text
Model Path
CoreML Model Path
Device
Decoder Parameters
Sample Rate
Model File Name
```

---

# 13. LLM Configuration

## 13.1 Recommended V1

Use:

```text
Ollama
    ↓
Qwen3
```

Adapter:

```text
OllamaLLMAdapter
```

Runtime:

```text
ollama
```

Typical local endpoint:

```text
http://127.0.0.1:11434
```

The endpoint MUST remain configuration-driven.

## 13.2 Internal Configuration

```yaml
llm:

  defaultProvider: ollama

  providers:

    ollama:

      enabled: true

      runtime: ollama

      endpoint:
        baseURL: "http://127.0.0.1:11434"

      model:
        name: "qwen3:8b"

      generation:
        temperature: 0.7
        topP: 0.9
        maxTokens: 1024

      streaming:
        enabled: true
```

## 13.3 User UI

Normal UI:

```text
AI Teacher

Model:
Qwen3 8B
```

Potential future simplified options:

```text
Response Quality

○ Fast
● Balanced
○ High Quality
```

The application resolves these product-level choices into runtime parameters.

Do not expose temperature/top-p/max tokens by default.

---

# 14. Ollama API

Prefer the OpenAI-compatible interface when practical:

```text
POST /v1/chat/completions
```

The base URL MUST come from configuration.

Example conceptual request:

```json
{
  "model": "qwen3:8b",
  "messages": [
    {
      "role": "system",
      "content": "You are an English teacher."
    },
    {
      "role": "user",
      "content": "I have went to London."
    }
  ],
  "temperature": 0.7,
  "top_p": 0.9,
  "stream": true
}
```

Exact supported fields MUST be verified against the installed Ollama version.

Do not invent parameters.

All Ollama-specific request/response structures MUST remain inside:

```text
OllamaLLMAdapter
```

---

# 15. LLM Streaming

Streaming is a first-class requirement.

Target flow:

```text
User stops speaking
        ↓
ASR
        ↓
Agent Analysis
        ↓
LLMManager
        ↓
LLMProvider.stream()
        ↓
LLM Chunks
        ↓
Response Planner
        ↓
Sentence / Phrase Chunks
        ↓
TTS
        ↓
Playback
```

The system SHOULD begin TTS before the entire LLM response has completed.

The Response Planner SHOULD convert token streams into meaningful speech chunks.

Example:

```text
LLM:
"I think the main issue is..."

TTS:
"I think the main issue is..."
        ↓
Playback starts

LLM:
"...the verb tense you used."

TTS:
"...the verb tense you used."
```

Use:

```swift
AsyncThrowingStream
```

or the project's equivalent.

Streaming MUST support cancellation.

---

# 16. TTS Configuration

TTS is different from LLM and ASR because it often involves:

```text
Model
+
Voice
+
Reference Audio
+
Language
+
Runtime
```

The user should think in terms of:

```text
Teacher Voice
```

not:

```text
GPT checkpoint
SoVITS checkpoint
Python environment
Vocoder
Port
```

---

# 17. Qwen3-TTS

Recommended initial TTS candidate:

```text
Qwen3-TTS
```

The Qwen3-TTS family provides 0.6B and 1.7B model variants and supports multiple speech/voice modes.

For the M1 Pro / 16 GB target:

```text
V1:
0.6B first

V2:
1.7B after benchmark
```

The application SHOULD prioritize stable coexistence of:

```text
ASR
+
LLM
+
TTS
```

rather than maximizing the size of one model.

## 17.1 Runtime

Possible runtime:

```text
python_process
```

or another supported local runtime.

Adapter:

```text
Qwen3TTSAdapter
```

## 17.2 Internal Configuration

```yaml
tts:

  provider: qwen3_tts

  runtime: python_process

  model:
    name: "Qwen3-TTS-0.6B"
    path: auto

  voice:
    id: teacher_default

  language: auto

  device: auto

  streaming:
    enabled: true
```

## 17.3 Normal User UI

```text
Teacher Voice

Serena
```

Potential future:

```text
Teacher Voice

○ Serena
○ Daniel
○ Emma
○ My Voice
```

The user MUST NOT need to enter model paths.

---

# 18. Voice Cloning

Voice cloning MUST be treated as a product feature, not a model installation procedure.

Normal UI:

```text
Teacher Voice

○ Preset Voice

○ My Voice

[ Add Voice Sample ]
```

If reference text is required by the selected model:

```text
Voice Sample
[ audio.wav ]

What was said?
[ Hello, this is my voice. ]
```

The application SHOULD automatically:

1. validate audio;
2. normalize audio;
3. determine duration;
4. store it locally;
5. associate it with a voice profile;
6. pass it to the TTS adapter.

The user should not see:

```text
referenceAudioPath
speakerEmbedding
xvector
checkpoint
modelPath
```

unless Developer Mode is enabled.

Voice cloning MUST require explicit user consent.

Only authorized/user-provided voice data may be used.

---

# 19. GPT-SoVITS

GPT-SoVITS may be integrated as an alternative local TTS runtime.

Its internal runtime can involve multiple model resources, such as:

```text
GPT weights
+
SoVITS weights
+
text frontend resources
+
optional pronunciation resources
+
reference audio
```

The architecture MUST hide this complexity from ordinary users.

## 19.1 Adapter

```text
GPTSoVITSAdapter
```

## 19.2 Runtime

```text
python_process
```

## 19.3 Internal Configuration

Conceptually:

```yaml
tts:

  provider: gpt_sovits

  runtime: python_process

  runtimeDirectory: auto

  pythonEnvironment: auto

  models:
    gpt: auto
    sovits: auto

  voice:
    referenceAudio: auto
    referenceText: auto

  language: auto

  device: auto

  endpoint:
    baseURL: auto
```

The application MUST NOT expose separate:

```text
GPT .ckpt
SoVITS .pth
```

fields to ordinary users.

Instead:

```text
TTS Provider:
GPT-SoVITS

Voice:
Teacher Default
```

The Agent is responsible for mapping this product-level configuration to the underlying runtime configuration.

---

# 20. VAD Configuration

Recommended V1:

```text
Silero VAD
```

Runtime:

```text
embedded
```

Adapter:

```text
SileroVADAdapter
```

Silero VAD can be used locally and supports ONNX-based execution.

## 20.1 Internal Configuration

```yaml
vad:

  provider: silero

  runtime: embedded

  model:
    path: auto

  sampleRate: 16000

  threshold: 0.5

  minSpeechDuration: 250ms

  minSilenceDuration: 300ms

  device: auto
```

## 20.2 Normal UI

Normally:

```text
No VAD configuration required.
```

The user should simply speak.

The application automatically determines:

```text
Speech Start
Speech End
Turn Boundary
```

Advanced VAD tuning MAY be exposed in Developer Mode only.

---

# 21. Embedding Configuration

Embedding is primarily an internal capability used for:

```text
Long-term Memory
Semantic Search
Learning History
User Profile Retrieval
Scenario Retrieval
Knowledge Retrieval
```

It should therefore NOT normally be exposed as a model-selection screen.

## 21.1 Recommended V1

Possible runtime:

```text
Ollama
```

or an embedded local embedding runtime.

Adapter:

```text
OllamaEmbeddingAdapter
```

or:

```text
MLXEmbeddingAdapter
```

## 21.2 Internal Configuration

```yaml
embedding:

  provider: ollama

  runtime: ollama

  endpoint:
    baseURL: "http://127.0.0.1:11434"

  model:
    name: auto

  dimensions: auto

  normalize: true

  batchSize: 1
```

The application SHOULD automatically determine:

```text
model
dimension
normalization
batch size
device
```

The user normally sees only:

```text
Memory
    Enabled
```

---

# 22. Pronunciation Configuration

Pronunciation MUST NOT be designed as a single-model integration.

The recommended architecture is:

```text
User Audio
   ↓
ASR
   ↓
Forced Alignment
   ↓
Phoneme Timing
   ↓
Acoustic Analysis
   ├── Pitch / F0
   ├── Duration
   ├── Energy
   ├── Stress
   └── Fluency
   ↓
Pronunciation Score
   ↓
LLM Explanation
   ↓
User Feedback
```

Therefore:

```text
Pronunciation
```

is a:

```text
pipeline
```

rather than a single:

```text
model
```

---

## 22.1 Internal Pronunciation Configuration

```yaml
pronunciation:

  provider: default_pipeline

  runtime: pipeline

  language: auto

  alignment:
    model: auto

  acoustic:
    model: auto

  pitch:
    enabled: true

  duration:
    enabled: true

  stress:
    enabled: true

  fluency:
    enabled: true

  scoring:
    threshold: auto
```

The application SHOULD automatically select the appropriate alignment model and language resources.

---

## 22.2 Normal User UI

Normal UI:

```text
Pronunciation Practice

Target Language:
English

Practice Mode:
Pronunciation
```

The user should NOT need to select:

```text
Forced Alignment Model
Phoneme Dictionary
F0 Algorithm
Acoustic Model
Scoring Threshold
```

---

# 23. Model Acquisition

The application SHOULD own model acquisition whenever licensing and distribution terms permit.

Preferred flow:

```text
User selects feature/model
        ↓
Model Registry
        ↓
Check local installation
        ↓
Model exists?
   ├── Yes
   │     ↓
   │   Health Check
   │     ↓
   │   Ready
   │
   └── No
         ↓
      Install / Download
         ↓
      Verify
         ↓
      Register
         ↓
      Health Check
         ↓
      Ready
```

The user should NOT be required to manually locate model files under normal circumstances.

---

# 24. Model Installation States

The application MUST support explicit model states.

```text
NotInstalled
Installing
Installed
Loading
Ready
Unavailable
Corrupted
Incompatible
Disabled
```

User-facing UI should map these to simple states.

Example:

```text
AI Teacher

Qwen3 8B

Status:
Ready ✓
```

If unavailable:

```text
AI Teacher

Qwen3 8B

Status:
Not installed

[ Install ]
```

If the runtime is missing:

```text
AI Teacher

Local AI Runtime is not installed.

[ Install Runtime ]
```

The user should not see raw runtime exceptions.

---

# 25. Model Registry

Provide a central registry equivalent to:

```text
registerProvider()
unregisterProvider()

enableProvider()
disableProvider()

setDefaultProvider()

getProvider()

listProviders()

healthCheck()

getCapabilities()

getMetadata()

installModel()

removeModel()

isModelInstalled()
```

The registry SHOULD also track:

```text
providerID
capabilityType
runtimeType
modelName
modelVersion
installationState
capabilities
healthState
```

---

# 26. Model Registry Example

Conceptual structure:

```text
ModelRegistry

├── ASR
│   └── WhisperKit
│       └── Whisper large-v3
│
├── LLM
│   └── Ollama
│       └── Qwen3 8B
│
├── TTS
│   ├── Qwen3-TTS
│   └── GPT-SoVITS
│
├── VAD
│   └── Silero VAD
│
├── Embedding
│   └── Local Embedding Model
│
└── Pronunciation
    └── Default Pronunciation Pipeline
```

Agents MUST NOT directly access the registry.

They should access the appropriate Manager.

---

# 27. Provider Lifecycle

Expected lifecycle:

```text
Created
   ↓
Initialized
   ↓
Ready
   ↓
Running
   ↓
Idle
   ↓
Unloaded
```

For embedded models:

```text
Application
    ↓
Provider
    ↓
Load local model
```

For Ollama:

```text
Application
    ↓
Ollama Adapter
    ↓
Ollama
    ↓
Ollama manages model lifecycle
```

For Python runtime:

```text
Application
    ↓
ProcessManager
    ↓
Python Runtime
    ↓
Model
```

The application MUST understand which layer owns the model lifecycle.

---

# 28. Process Management

External runtimes SHOULD be managed by a dedicated:

```text
ProcessManager
```

The Agent MUST NOT implement process management directly inside Agents.

Conceptual flow:

```text
TTSManager
    ↓
TTSProvider
    ↓
GPTSoVITSAdapter
    ↓
ProcessManager
    ↓
Python Runtime
    ↓
GPT-SoVITS
```

ProcessManager SHOULD support:

```text
start()
stop()
restart()
isRunning()
healthCheck()
getPID()
getLogs()
```

The user should normally never see the process.

---

# 29. Port Management

Ports MUST NOT normally be entered by ordinary users.

The application SHOULD use:

```text
Automatic Port Assignment
```

or:

```text
Configured Internal Port
```

Recommended behavior:

```text
Find configured port
        ↓
Check availability
        ↓
If occupied:
    choose safe fallback port
        ↓
Start runtime
        ↓
Update internal endpoint
```

For Ollama, the known default local endpoint may be used when available, but the application MUST keep it configuration-driven.

---

# 30. Runtime Auto-Discovery

The application SHOULD detect installed runtimes automatically.

Example:

```text
Ollama installed?
    ↓
Yes
    ↓
Check service
    ↓
List installed models
```

For Python runtimes:

```text
Managed Runtime Directory
    ↓
Virtual Environment
    ↓
Runtime executable
    ↓
Health Check
```

For embedded models:

```text
Application Bundle
    ↓
Model Assets
    ↓
Load
```

The user should not need to know which mechanism is being used.

---

# 31. Automatic Device Selection

Device selection SHOULD default to:

```text
auto
```

The application determines the best available backend.

Examples:

```text
Apple Silicon
    ↓
MPS / Core ML / Accelerated Backend
```

If acceleration is unavailable:

```text
Fallback
    ↓
CPU
```

The user should not be asked:

```text
CPU or MPS?
```

unless the product later introduces an Advanced Settings mode.

---

# 32. Resource Management

Target hardware:

```text
Apple Silicon
M1 Pro
16 GB Unified Memory
```

The application MUST NOT attempt to load all large models simultaneously.

Rules:

1. Prefer lazy loading.
2. Keep only necessary models resident.
3. Unload inactive models when appropriate.
4. Avoid duplicate model loading.
5. Avoid unnecessary audio buffer copies.
6. Respect unified memory pressure.
7. Monitor external runtime memory where possible.
8. Prefer smaller models for simultaneous ASR + LLM + TTS.
9. Gracefully degrade under memory pressure.

Recommended:

```text
Conversation Mode

ASR
   ↓
LLM
   ↓
TTS
```

should reuse resources whenever possible.

---

# 33. Configuration Resolution

The application SHOULD resolve:

```text
User Configuration
```

into:

```text
Runtime Configuration
```

Example:

User:

```text
AI Model:
Qwen3 8B
```

Resolver:

```text
Provider:
Ollama

Runtime:
ollama

Endpoint:
127.0.0.1:11434

Model:
qwen3:8b

Streaming:
true

Device:
auto
```

User:

```text
Teacher Voice:
Serena
```

Resolver:

```text
Provider:
Qwen3-TTS

Runtime:
python_process

Model:
0.6B CustomVoice

Voice:
serena

Language:
English

Device:
auto
```

The user configuration MUST remain independent of the underlying runtime.

---

# 34. Canonical Internal Configuration

The serialization format may be:

```text
YAML
JSON
Swift Codable
plist
database
```

The exact format is implementation-dependent.

The semantic structure SHOULD resemble:

```yaml
models:

  asr:

    provider: whisperkit

    runtime: embedded

    model:
      name: large-v3
      path: auto

    language: auto

    device: auto

    streaming:
      enabled: true

    timestamps:
      word: true


  llm:

    provider: ollama

    runtime: ollama

    endpoint:
      baseURL: http://127.0.0.1:11434

    model:
      name: qwen3:8b

    streaming:
      enabled: true

    generation:
      temperature: 0.7
      topP: 0.9
      maxTokens: 1024


  tts:

    provider: qwen3_tts

    runtime: python_process

    model:
      name: Qwen3-TTS-0.6B
      path: auto

    voice:
      id: teacher_default

    language: auto

    device: auto


  vad:

    provider: silero

    runtime: embedded

    model:
      path: auto

    sampleRate: 16000

    threshold: 0.5


  embedding:

    provider: ollama

    runtime: ollama

    endpoint:
      baseURL: http://127.0.0.1:11434

    model:
      name: auto

    dimensions: auto


  pronunciation:

    provider: default_pipeline

    runtime: pipeline

    language: auto

    alignmentModel: auto

    acousticModel: auto
```

`auto` MUST be treated as a first-class configuration value.

It means:

> Resolve this value automatically from the Model Registry, Runtime Manager, device capabilities, or installed model metadata.

---

# 35. Normal User Configuration Examples

## 35.1 First Launch

The user SHOULD see something similar to:

```text
Welcome to AI Language Coach

Learning Language
[ English ]

AI Teacher
[ Default Teacher ]

Voice
[ Serena ]

AI Model
[ Balanced ]

[ Continue ]
```

No runtime configuration is required.

---

## 35.2 Normal Settings

```text
AI Teacher

Language
English

AI Model
Qwen3 8B

Teacher Voice
Serena

Pronunciation Feedback
On

Long-term Memory
On
```

---

## 35.3 Voice Cloning

```text
Teacher Voice

Preset Voice
    Serena

My Voice
    Not configured

[ Add My Voice ]
```

After selecting:

```text
Voice Recording

[ Select Audio ]

Reference Text
[ Optional ]

[ Create Voice ]
```

---

# 36. Advanced Settings

Advanced settings MAY exist but MUST be separated.

Example:

```text
Advanced

AI Runtime
    Ollama

Endpoint
    http://127.0.0.1:11434

Model
    qwen3:8b

Status
    Connected ✓

[ Test Connection ]
```

The Advanced section MUST NOT be required for normal operation.

---

# 37. Model Source Map

The implementation SHOULD prefer official or primary project sources.

| Capability | Preferred Source |
|---|---|
| WhisperKit / Whisper Core ML | WhisperKit official repository and linked model repository |
| Ollama | Ollama official documentation and model registry |
| Qwen3 | Qwen official repositories/model pages or Ollama registry |
| Qwen3-TTS | Qwen official repository and linked model repositories |
| GPT-SoVITS | GPT-SoVITS official repository, releases, and linked pretrained model sources |
| Silero VAD | Silero VAD official repository |
| Embedding | Official model repository or Ollama registry |
| Pronunciation | Primary repositories for selected alignment/acoustic components |

Reference sources:

- WhisperKit: official GitHub repository
- WhisperKit Core ML models: official linked Hugging Face repository
- Ollama: official website and API documentation
- Qwen: official GitHub organization
- Qwen3-TTS: official Qwen repository
- GPT-SoVITS: official RVC-Boss repository
- Silero VAD: official snakers4 repository

The Agent MUST NOT invent:

```text
download URLs
model names
model file layouts
API endpoints
ports
runtime behavior
```

If the installed runtime differs from the documentation example, the Agent MUST inspect the actual runtime before implementing integration.

---

# 38. Recommended V1 Runtime Matrix

| Capability | V1 Recommendation | Deployment | Swift Adapter | Port | User Normally Configures |
|---|---|---|---|---|---|
| ASR | WhisperKit + Whisper | Embedded | `WhisperKitASRAdapter` | No | Usually nothing / language |
| LLM | Qwen3 via Ollama | Local process | `OllamaLLMAdapter` | Auto, typically 11434 | Model |
| TTS | Qwen3-TTS 0.6B | Managed local runtime | `Qwen3TTSAdapter` | Auto | Voice / language |
| TTS Alternative | GPT-SoVITS | Managed local runtime | `GPTSoVITSAdapter` | Auto | Voice |
| VAD | Silero VAD | Embedded | `SileroVADAdapter` | No | Nothing |
| Embedding | Local embedding via Ollama | Local | `OllamaEmbeddingAdapter` | Auto | Nothing |
| Pronunciation | Alignment + acoustic analysis | Local pipeline | `PronunciationAdapter` | Depends | Language / practice mode |

---

# 39. V1 Product Configuration Summary

The final V1 UI SHOULD require approximately:

| Capability | User Input |
|---|---|
| ASR | Language, if needed |
| LLM | Model selection |
| TTS | Voice |
| Voice Cloning | Reference audio only when enabled |
| VAD | None |
| Embedding | None |
| Pronunciation | Target language / practice mode |

Therefore the normal user does NOT configure:

```text
Endpoint
Port
Model Path
Runtime Directory
Python
Device
Quantization
Checkpoint
VAD Threshold
Embedding Dimension
Alignment Model
Phoneme Dictionary
```

These are application-managed.

---

# 40. Configuration Validation

Validation MUST occur before a provider enters:

```text
Ready
```

At minimum verify:

1. Provider is registered.
2. Runtime type is supported.
3. Required configuration exists.
4. Model exists or can be discovered.
5. External runtime is reachable when applicable.
6. Required capabilities are supported.
7. Runtime/model architecture is compatible.
8. Provider can initialize successfully.
9. Memory requirements are acceptable.
10. Required model files are valid.

---

# 41. User-Friendly Error Handling

Technical errors MUST be converted into user-facing actions.

Bad:

```text
Python subprocess exited with code 1.
FileNotFoundError:
GPT_SoVITS/s2Gv4.pth
```

Good:

```text
Teacher voice is not ready.

A required voice model is missing.

[ Install Model ]
```

Bad:

```text
HTTP 500
Connection refused
127.0.0.1:7860
```

Good:

```text
AI Teacher is temporarily unavailable.

[ Retry ]
```

Developer Mode may display detailed diagnostics.

---

# 42. Error Model

Use typed errors equivalent to:

```swift
enum AIProviderError: Error {

    case invalidConfiguration

    case runtimeUnavailable

    case modelUnavailable

    case modelNotInstalled

    case modelIncompatible

    case connectionFailed

    case timeout

    case cancelled

    case invalidRequest

    case invalidResponse

    case unsupportedCapability

    case insufficientMemory

    case processLaunchFailed

    case serverError
}
```

Never silently convert errors into:

```text
""
```

or fake success.

---

# 43. Timeout and Retry

All external runtime requests MUST use explicit timeout configuration.

Retries MUST be conservative.

Do NOT retry automatically when:

```text
Invalid configuration
Unsupported capability
Model missing
Malformed request
User cancellation
```

Streaming requests MUST NOT be blindly replayed because doing so may duplicate generated content.

---

# 44. Health Check

Every provider MUST support health verification where practical.

The provider should distinguish:

```text
Connected
RuntimeUnavailable
ModelUnavailable
ModelNotInstalled
ConfigurationInvalid
ModelIncompatible
RequestFailed
Ready
```

Example internal status:

```text
Provider:
Ollama

Runtime:
Available

Model:
Qwen3 8B

Model:
Installed

Health:
Ready
```

Normal UI:

```text
AI Teacher
Ready ✓
```

---

# 45. Model Discovery

If a runtime supports installed-model discovery, the Adapter SHOULD expose it through the Manager.

Example:

```text
Ollama
   ↓
list local models
   ↓
OllamaLLMAdapter
   ↓
LLMManager
   ↓
ModelRegistry
   ↓
Product UI
```

Do not hard-code:

```text
qwen3:8b
```

as the only available model.

---

# 46. Structured Output

Agents such as:

```text
GrammarAgent
ResponsePlanner
PronunciationAgent
```

may require structured output.

Example:

```json
{
  "hasError": true,
  "original": "I have went to London.",
  "corrected": "I went to London.",
  "errorType": "verb_tense",
  "explanation": "The verb form is incorrect."
}
```

Structured output MUST be provider-independent.

Never assume that a model returns valid JSON merely because the prompt requests it.

Validate and handle malformed output explicitly.

---

# 47. Prompt Isolation

Prompts belong in:

```text
Resources/
    Prompts/
```

or the project's centralized prompt layer.

Do not place long prompts in:

```text
SwiftUI
Transport Code
Provider Adapter
```

Preferred flow:

```text
GrammarAgent
   ↓
PromptBuilder
   ↓
LLMRequest
   ↓
LLMManager
   ↓
LLMProvider
   ↓
Runtime
```

---

# 48. Example Grammar Agent Flow

Input:

```text
I have went to London.
```

Flow:

```text
User Speech
    ↓
VAD
    ↓
ASR
    ↓
Transcript
    ↓
GrammarAgent
    ↓
PromptBuilder
    ↓
LLMManager
    ↓
LLMProvider
    ↓
Ollama
    ↓
Qwen3
    ↓
LLMResponse
    ↓
GrammarAgent
    ↓
GrammarError
```

GrammarAgent MUST NOT contain:

```text
Ollama URL
Model Name
Port
HTTP Request
```

---

# 49. Full Conversation Runtime Flow

The target conversation pipeline is:

```text
Microphone
    ↓
Audio Capture
    ↓
VAD
    ↓
ASR
    ↓
Transcript
    ↓
Teacher / Grammar / Conversation / Pronunciation Agents
    ↓
Response Planner
    ↓
LLM
    ↓
Streaming Response
    ↓
Sentence / Phrase Segmentation
    ↓
TTS
    ↓
Audio Playback
```

Long-term memory:

```text
Conversation
    ↓
Embedding
    ↓
Memory Store
    ↓
Semantic Retrieval
    ↓
Future Conversation
```

Pronunciation:

```text
User Audio
    ↓
ASR
    ↓
Alignment
    ↓
Acoustic Analysis
    ↓
Pronunciation Score
    ↓
LLM Explanation
```

---

# 50. Testing

## Unit Tests

Test:

```text
Configuration parsing
Request construction
Response mapping
Streaming chunk mapping
Capability mapping
Error mapping
Cancellation
Model registry
Configuration resolution
```

---

## Mock Providers

At minimum:

```text
MockLLMProvider
MockASRProvider
MockTTSProvider
MockVADProvider
MockEmbeddingProvider
MockPronunciationProvider
```

Agents MUST be testable without actual local models.

Example:

```text
GrammarAgent
    ↓
MockLLMProvider
    ↓
Deterministic Response
```

---

## Integration Tests

For Ollama:

```text
Runtime Health
Model Availability
Normal Generation
Streaming
Invalid Configuration
Unavailable Model
Cancellation
```

For TTS:

```text
Runtime Launch
Model Availability
Voice Loading
Synthesis
Streaming
Process Shutdown
```

For ASR:

```text
Model Loading
Audio Input
Transcription
Timestamp Output
Language Handling
```

For VAD:

```text
Speech Detection
Silence Detection
Turn Boundary
False Positive Handling
```

For Embedding:

```text
Embedding Generation
Dimension Validation
Normalization
Batch Processing
```

For Pronunciation:

```text
Alignment
Pitch
Duration
Stress
Score
Explanation
```

Runtime-dependent tests MUST remain separate from offline unit tests.

---

# 51. Definition of Done

The local AI integration is complete only when:

- [ ] Provider abstraction exists or is correctly reused.
- [ ] Provider-specific code is isolated inside adapters.
- [ ] Endpoint is configuration-driven.
- [ ] Model name is configuration-driven.
- [ ] Model paths are not hard-coded.
- [ ] No Agent directly references a runtime.
- [ ] No SwiftUI view directly references a runtime.
- [ ] Managers control provider access.
- [ ] Health checks work.
- [ ] Model availability can be detected.
- [ ] Normal generation/inference works.
- [ ] Streaming works where supported.
- [ ] Cancellation works where supported.
- [ ] Typed provider errors exist.
- [ ] Mock providers exist.
- [ ] Unit tests exist.
- [ ] Integration tests exist.
- [ ] Unsupported capabilities are handled explicitly.
- [ ] Configuration and troubleshooting are documented.
- [ ] ASR follows Provider/Adapter architecture.
- [ ] LLM follows Provider/Adapter architecture.
- [ ] TTS follows Provider/Adapter architecture.
- [ ] VAD follows Provider/Adapter architecture.
- [ ] Embedding follows Provider/Adapter architecture.
- [ ] Pronunciation follows Provider/Adapter architecture.
- [ ] Normal UI exposes only necessary fields.
- [ ] Runtime paths are automatically managed where possible.
- [ ] Ports are automatically managed where possible.
- [ ] Python environments are automatically managed where possible.
- [ ] Model files are automatically managed where possible.
- [ ] Missing models produce actionable installation states.
- [ ] Advanced configuration is isolated from ordinary settings.
- [ ] Model acquisition is separated from model execution.
- [ ] Model Registry tracks installed models and health state.
- [ ] Resource management is compatible with 16 GB Apple Silicon.
- [ ] Local-first privacy is preserved.

---

# 52. AI Agent Implementation Order

The Coding Agent SHOULD execute the following order.

```text
1. Inspect repository and existing architecture.

2. Inspect current AI interfaces and models.

3. Reuse existing abstractions where equivalent.

4. Identify current Managers.

5. Identify current Provider interfaces.

6. Implement or complete ModelRegistry.

7. Implement unified AI provider metadata.

8. Implement unified capability model.

9. Implement configuration resolver.

10. Implement runtime state model.

11. Implement Mock Providers.

12. Implement LLMProvider.

13. Implement OllamaLLMProvider.

14. Implement LLMManager.

15. Implement ASRProvider.

16. Implement WhisperKitASRAdapter.

17. Implement VADProvider.

18. Implement SileroVADAdapter.

19. Implement TTSProvider.

20. Implement Qwen3TTSAdapter.

21. Implement GPTSoVITSAdapter if required.

22. Implement EmbeddingProvider.

23. Implement PronunciationProvider.

24. Implement ProcessManager.

25. Implement model installation/discovery.

26. Implement health checks.

27. Implement model lifecycle management.

28. Implement configuration UI.

29. Expose only normal user fields.

30. Add Advanced/Developer configuration separately.

31. Add unit tests.

32. Add runtime integration tests.

33. Connect one Agent.

34. Verify complete local request path.

35. Verify memory behavior.

36. Verify model replacement.

37. Document troubleshooting.
```

Do NOT start by putting direct runtime calls into Agents.

---

# 53. Security and Privacy

AI Language Coach is local-first.

The intended local LLM data path is:

```text
User Data
    ↓
AI Language Coach
    ↓
localhost
    ↓
Local Runtime
    ↓
Local Model
```

The intended TTS path is:

```text
User Text
    ↓
AI Language Coach
    ↓
Local TTS Runtime
    ↓
Local Voice Model
    ↓
Audio
```

The intended voice-cloning path is:

```text
User Consent
    ↓
Reference Audio
    ↓
Local Voice Profile
    ↓
Local TTS Runtime
```

Do NOT introduce cloud upload or telemetry through the local model integration.

Logs MUST avoid storing sensitive conversation content by default.

Voice reference data MUST remain local by default.

---

# 54. Secrets

If a future provider requires an API key:

```text
API Key
```

MUST NOT be stored in:

```text
Source Code
Configuration Files
Git
Logs
Debug Output
```

Use:

```text
Keychain
```

or the platform's secure credential mechanism.

However, local-first V1 should avoid requiring cloud API keys whenever possible.

---

# 55. Prohibited AI Agent Behavior

The Coding Agent MUST NOT:

1. hard-code a specific model such as `qwen3:8b` into business logic;
2. hard-code `localhost:11434` inside Agents;
3. call Ollama directly from SwiftUI;
4. call GPT-SoVITS directly from Agents;
5. call WhisperKit directly from Agents;
6. bypass Managers;
7. expose provider-specific JSON to domain models;
8. assume every model supports streaming;
9. assume every model supports structured output;
10. invent endpoints;
11. invent model names;
12. invent model file layouts;
13. invent runtime behavior;
14. force users to manually enter technical paths;
15. expose Python environments in normal settings;
16. expose model checkpoints in normal settings;
17. expose ports in normal settings;
18. expose quantization in normal settings;
19. load duplicate copies of models unnecessarily;
20. load all large models simultaneously;
21. swallow errors;
22. silently convert inference failure to empty output;
23. add cloud upload without explicit product requirements;
24. break Provider/Adapter architecture for a quick demo;
25. add unrelated product features during model integration.

---

# 56. Advanced Configuration Policy

Advanced configuration MAY be introduced later.

However, advanced fields MUST remain provider-independent at the domain level.

Good:

```text
TTSProviderConfig

    runtimeOptions
        ├── provider-specific options
        └── runtime-specific options
```

Bad:

```text
TeacherProfile

    gptSovitsGPTCheckpoint

    gptSovitsSoVITSWeight

    ollamaKeepAlive

    sileroThreshold
```

The product domain model MUST NOT become coupled to temporary model choices.

---

# 57. Model Replacement Requirement

The following replacement MUST be possible without changing Agents:

```text
WhisperKit
    ↓
Another ASR Provider
```

```text
Qwen3
    ↓
Another Local LLM
```

```text
Qwen3-TTS
    ↓
GPT-SoVITS
```

```text
Silero VAD
    ↓
Another VAD
```

```text
Ollama Embedding
    ↓
MLX Embedding
```

```text
Pronunciation Pipeline A
    ↓
Pronunciation Pipeline B
```

The expected architecture is:

```text
Same Agent
    ↓
Same Manager
    ↓
Different Provider
    ↓
Different Runtime
```

---

# 58. Runtime Replacement Requirement

The runtime itself must also be replaceable.

Example:

```text
Qwen3

Ollama
   ↓
Qwen3
```

can later become:

```text
MLX
   ↓
Qwen3
```

or:

```text
llama.cpp
   ↓
Qwen3
```

without changing:

```text
TeacherAgent
GrammarAgent
ConversationAgent
ResponsePlanner
```

Only the Adapter/Provider layer should change.

---

# 59. Product-Level Abstraction

The user should think:

```text
AI Teacher
```

rather than:

```text
LLM Runtime
```

The user should think:

```text
Teacher Voice
```

rather than:

```text
TTS Checkpoint
```

The user should think:

```text
Pronunciation Practice
```

rather than:

```text
Forced Alignment Pipeline
```

The user should think:

```text
Memory
```

rather than:

```text
Embedding Model
```

The user should think:

```text
Speech Recognition
```

rather than:

```text
ASR Runtime
```

This separation between **product concepts** and **engineering concepts** is mandatory.

---

# 60. Final Engineering Principle

The goal is NOT:

```text
"Make SwiftUI call Ollama."
```

The goal IS:

```text
"Build a stable, testable, model-agnostic local AI integration layer
with simple consumer-facing configuration."
```

The complete principle is:

```text
WHAT:

AI Language Coach needs local AI capabilities:

ASR
LLM
TTS
VAD
Embedding
Pronunciation


HOW:

Manager
   ↓
Provider Interface
   ↓
Adapter
   ↓
Local Runtime
   ↓
Model / Pipeline


PRODUCT UI:

Expose only the minimum configuration
ordinary users actually need.


INTERNAL:

Automatically resolve:

- model paths
- runtime paths
- ports
- processes
- dependencies
- device
- capabilities
- health checks
- model installation
- model lifecycle


FIRST:

Embedded ASR/VAD
+
Ollama LLM
+
Managed local TTS
+
Local Embedding
+
Pronunciation Pipeline


FUTURE:

Replace a model without changing Agents.

Replace a runtime without changing business logic.

Upgrade the runtime without forcing ordinary users
to understand the underlying technology.
```

A model can be replaced.

A runtime can be replaced.

A provider can be replaced.

A deployment method can be replaced.

The user-facing product model should remain stable.

The architecture should not need to be rewritten.