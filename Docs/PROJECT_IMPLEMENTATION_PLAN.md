# AI Language Coach — Project Implementation Plan

**Version:** 1.0  
**Status:** Engineering Execution Baseline  
**Target Platform:** macOS / Apple Silicon first  
**Primary Development Device:** Apple Silicon, including M1 Pro / 16GB RAM  
**Architecture Principle:** Local-first, model-agnostic, modular, provider/adapter based

---

## 1. Purpose

This document converts the Product Requirements Document and Technical Design into an executable engineering plan.

It is intended to be usable by different AI Coding Agents, including Codex, Claude Code, Cursor, Gemini CLI, Cline, Roo Code, Windsurf, or other agentic development tools.

The implementation plan deliberately separates:

1. Product/business logic
2. AI abstraction interfaces
3. Provider managers
4. Model adapters
5. Local model runtimes
6. Infrastructure
7. UI

Actual local model invocation code is intentionally left replaceable. The project must remain functional with Mock/Stub providers before real local models are integrated.

---

## 2. Engineering Ground Rules

### 2.1 Non-negotiable architecture

The dependency direction is:

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

Never implement:

```text
UI → Whisper
UI → GPT-SoVITS
UI → Qwen
BusinessService → GPT-SoVITS
Agent → WhisperKit
Agent → llama.cpp
```

Use:

```text
Application → ASRManager → IASRProvider → ASRAdapter
Application → LLMManager → ILLMProvider → LLMAdapter
Application → TTSManager → ITTSProvider → TTSAdapter
```

### 2.2 Model-agnostic requirement

The first implementation must not make the product dependent on:

- WhisperKit
- whisper.cpp
- SenseVoice
- GPT-SoVITS
- Qwen3-TTS
- Chatterbox
- llama.cpp
- MLX
- any specific local model

These are implementation candidates, not architectural dependencies.

### 2.3 Configuration requirement

Do not hard-code:

- model paths
- runtime ports
- executable paths
- voice reference paths
- model names
- model versions
- device configuration
- provider selection

Use configuration files and a Model Registry.

### 2.4 AI Agent requirement

An AI Coding Agent must:

1. Inspect existing code before modifying it.
2. Reuse existing abstractions.
3. Avoid unnecessary refactoring.
4. Implement one task at a time.
5. Add or update tests.
6. Verify compilation.
7. Report files changed.
8. Report tests executed.
9. Report unresolved assumptions.
10. Never claim an unverified model/runtime API works.

---

# 3. Target Repository Structure

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

The actual framework/language may evolve, but the logical separation must remain.

---

# 4. Implementation Phases

## Phase 0 — Repository Bootstrap

### Goal

Create a clean, buildable application skeleton.

### Tasks

| ID | Task | Priority |
|---|---|---|
| P0-001 | Initialize repository | P0 |
| P0-002 | Configure build system | P0 |
| P0-003 | Create target directory structure | P0 |
| P0-004 | Add configuration system | P0 |
| P0-005 | Add logging infrastructure | P0 |
| P0-006 | Add dependency injection/container strategy | P1 |
| P0-007 | Add test target | P0 |
| P0-008 | Add developer documentation | P1 |

### Acceptance Criteria

- Project builds successfully.
- Tests execute successfully.
- No model dependency is required to launch the application.
- Configuration can be loaded without hard-coded model paths.
- Logging works in development mode.

---

# 5. Phase 1 — Core Domain Models

## Goal

Establish stable domain objects before implementing AI functionality.

### Tasks

### P1-001 — User Profile

Create:

```text
User
UserProfile
LearningGoal
TeacherPreference
```

Minimum concepts:

```text
nativeLanguage
targetLanguage
targetAccent
currentLevel
learningGoals
preferredTeacherStyle
correctionMode
dailyPracticeTarget
```

### P1-002 — Learning Session

Create:

```text
LearningSession
ConversationTurn
SessionSummary
```

A conversation turn should support:

```text
speaker
timestamp
audioReference
transcript
language
analysis
response
```

### P1-003 — Grammar Error

Create:

```text
GrammarError
```

Minimum fields:

```text
originalText
correctedText
errorType
explanation
severity
timestamp
```

### P1-004 — Vocabulary

Create:

```text
VocabularyItem
VocabularyReview
```

Support:

```text
word
meaning
example
difficulty
mastery
reviewCount
lastReviewedAt
```

### P1-005 — Pronunciation Result

Create:

```text
PronunciationResult
PhonemeResult
ProsodyResult
FluencyResult
```

### Acceptance Criteria

- Domain models do not depend on concrete AI SDKs.
- Models can be serialized/deserialized.
- Unit tests cover core validation and serialization.

---

# 6. Phase 2 — AI Provider Contracts

## Goal

Define stable interfaces before implementing any real model.

## 6.1 ASR

Create:

```text
IASRProvider
```

Required operations:

```text
initialize()
load()
unload()
healthCheck()
transcribe()
streamTranscribe()
getCapabilities()
getMetadata()
```

Capabilities:

```text
supportsStreaming
supportsWordTimestamp
supportsMultilingual
supportsSpeakerRecognition
```

---

## 6.2 LLM

Create:

```text
ILLMProvider
```

Required operations:

```text
initialize()
load()
unload()
healthCheck()
generate()
streamGenerate()
getCapabilities()
getMetadata()
```

Support:

```text
systemPrompt
messages
temperature
maxTokens
structuredOutput
streaming
```

---

## 6.3 TTS

Create:

```text
ITTSProvider
```

Required operations:

```text
initialize()
load()
unload()
healthCheck()
synthesize()
streamSynthesize()
getCapabilities()
getMetadata()
```

Options:

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

Unsupported options must be handled through capability checking rather than silently pretending to work.

---

## 6.4 VAD

Create:

```text
IVADProvider
```

Support:

```text
isSpeech()
streamDetect()
```

---

## 6.5 Embedding

Create:

```text
IEmbeddingProvider
```

Support:

```text
embed()
embedBatch()
getDimensions()
```

---

## 6.6 Pronunciation

Create:

```text
IPronunciationProvider
```

Support:

```text
evaluate()
getCapabilities()
```

### Acceptance Criteria

- All interfaces compile.
- No interface imports a concrete model library.
- Mock implementations can satisfy every interface.
- Capability metadata is queryable.

---

# 7. Phase 3 — Managers and Model Registry

## Goal

Centralize model lifecycle and provider selection.

## 7.1 Managers

Create:

```text
ASRManager
LLMManager
TTSManager
VADManager
EmbeddingManager
PronunciationManager
```

Managers are responsible for:

- selecting provider
- initialization
- loading/unloading
- health checking
- capability checking
- fallback selection
- error translation
- lifecycle management

Managers must not contain model-specific inference logic.

---

## 7.2 Model Registry

Create:

```text
ModelRegistry
ModelConfig
ModelMetadata
ProviderConfig
```

Required operations:

```text
register()
unregister()
enable()
disable()
setDefault()
getDefault()
listAvailable()
healthCheck()
```

Example configuration:

```yaml
asr:
  provider: ""

llm:
  provider: ""

tts:
  provider: ""

models:
  - id: ""
    type: asr
    provider: ""
    runtime:
      type: ""
      host: ""
      port: ""
    model:
      path: ""
      version: ""
```

### Acceptance Criteria

- Provider selection is configuration-driven.
- A provider can be replaced without changing application services.
- Model lifecycle can be tested using mocks.

---

# 8. Phase 4 — Local Audio Pipeline

## Goal

Build microphone-to-audio-stream infrastructure independently from ASR.

Pipeline:

```text
Microphone
 ↓
AudioCapture
 ↓
AudioBuffer
 ↓
VAD
 ↓
SpeechSegment
```

### Tasks

| ID | Task |
|---|---|
| P4-001 | Microphone permission flow |
| P4-002 | Audio capture |
| P4-003 | Audio format normalization |
| P4-004 | Ring buffer |
| P4-005 | VAD integration |
| P4-006 | Speech segment generation |
| P4-007 | Audio persistence |
| P4-008 | Audio error handling |

### Acceptance Criteria

- Microphone can start/stop safely.
- Audio stream is stable.
- VAD can identify speech/non-speech.
- No ASR model is required for audio pipeline tests.

---

# 9. Phase 5 — Mock AI Pipeline

## Goal

Make the complete product flow executable before integrating real models.

Pipeline:

```text
Microphone
 ↓
VAD Mock
 ↓
ASR Mock
 ↓
Teacher Agent
 ↓
Grammar Agent
 ↓
Conversation Agent
 ↓
Response Planner
 ↓
LLM Mock
 ↓
TTS Mock
 ↓
Playback
```

### Mock Provider Requirements

ASR Mock:

```text
returns deterministic transcript
```

LLM Mock:

```text
returns deterministic teacher response
```

TTS Mock:

```text
returns synthetic/test audio
```

### Acceptance Criteria

The user can complete a simulated conversation session without any real AI model installed.

This phase is critical because it proves that the product architecture works independently of model integration.

---

# 10. Phase 6 — Conversation Engine

## Goal

Implement the core AI conversation state machine.

Create:

```text
ConversationSession
ConversationState
ConversationContext
ConversationEngine
```

State example:

```text
idle
listening
processing
responding
completed
error
```

Conversation context should include:

```text
recentTurns
currentTopic
scenario
userProfile
learningGoals
knownErrors
targetVocabulary
teacherPreference
difficulty
```

### Acceptance Criteria

- Conversation state transitions are deterministic.
- Conversation can be paused/resumed.
- Session can terminate safely.
- Context can be serialized.

---

# 11. Phase 7 — Teacher Agent

## Goal

Implement pedagogical control.

Teacher Agent responsibilities:

1. Determine response style.
2. Determine correction intensity.
3. Adjust difficulty.
4. Decide when to correct.
5. Select learning objectives.
6. Maintain teaching strategy.

Input:

```text
userProfile
conversationContext
userTranscript
grammarAnalysis
pronunciationAnalysis
learningMemory
```

Output:

```json
{
  "response_mode": "conversation",
  "correction_level": "balanced",
  "difficulty": 3,
  "learning_focus": [
    "past_tense"
  ],
  "should_correct": true
}
```

### Acceptance Criteria

Teacher decisions are represented as structured data and are not directly coupled to UI.

---

# 12. Phase 8 — Grammar Agent

## Goal

Detect and explain grammar errors.

Pipeline:

```text
Transcript
 ↓
Grammar Agent
 ↓
Error Detection
 ↓
Correction
 ↓
Explanation
 ↓
Memory
```

Output:

```json
{
  "has_error": true,
  "original": "I have went to London.",
  "corrected": "I went to London.",
  "error_type": "verb_tense",
  "explanation": "Use the simple past for a completed event in the past."
}
```

### Requirements

Support:

- error detection
- correction
- explanation
- severity
- error pattern
- repeated-error detection

### Acceptance Criteria

Grammar analysis is testable without a specific LLM provider.

---

# 13. Phase 9 — Conversation Agent

## Goal

Generate pedagogically appropriate conversational direction.

Responsibilities:

- topic selection
- follow-up questions
- scenario state
- difficulty adjustment
- user engagement
- conversation continuity

The agent should avoid producing the final spoken response directly.

Instead:

```text
Conversation Agent
 ↓
Response Plan
 ↓
LLM
```

---

# 14. Phase 10 — Response Planner

## Goal

Separate reasoning from final language generation.

Create:

```text
ResponsePlan
```

Example:

```json
{
  "intent": "correct_and_continue",
  "acknowledgement": true,
  "correction": {
    "show": true,
    "style": "brief"
  },
  "explanation": {
    "show": true,
    "length": "short"
  },
  "next_question": true,
  "target_vocabulary": [
    "experience"
  ]
}
```

This prevents the LLM prompt from becoming the single location of business logic.

---

# 15. Phase 11 — Local LLM Integration

## Goal

Integrate one validated local LLM through the existing abstraction.

### Rules

The first real LLM must be integrated as:

```text
LLMManager
 ↓
ILLMProvider
 ↓
ConcreteAdapter
 ↓
Runtime
 ↓
LocalModel
```

Potential runtime families may include:

```text
MLX
llama.cpp
other validated local runtime
```

The exact model is not architecturally fixed.

### Integration checklist

- Verify runtime availability.
- Verify model loading.
- Verify prompt format.
- Verify structured output.
- Verify streaming.
- Measure TTFT.
- Measure tokens/sec.
- Measure memory.
- Test unload/reload.

### Acceptance Criteria

LLM can be replaced by another provider without modifying Teacher Agent or Conversation Agent.

---

# 16. Phase 12 — Local ASR Integration

## Goal

Replace ASR Mock with a validated local provider.

Candidate implementations may include:

```text
WhisperKit
whisper.cpp
SenseVoice
other validated local ASR
```

### Required tests

- short utterance
- long utterance
- noisy audio
- silence
- multilingual input
- streaming input
- timestamp accuracy
- memory usage

### Acceptance Criteria

ASR output matches the common transcript schema and requires no changes to upper application layers.

---

# 17. Phase 13 — Local TTS Integration

## Goal

Replace TTS Mock with a local provider.

Potential adapters:

```text
GPT-SoVITS
Qwen3-TTS
Chatterbox
other validated local TTS
```

Architecture:

```text
TTSManager
 ├── GPTSoVITSAdapter
 ├── QwenTTSAdapter
 └── ChatterboxAdapter
```

### GPT-SoVITS-specific rule

GPT-SoVITS must remain an adapter implementation.

Do not expose GPT-SoVITS-specific APIs to:

- UI
- Agent
- Application Service
- domain models

Reference voice configuration must be externalized.

Example:

```yaml
voices:
  teacher_default:
    reference_audio: ""
    reference_text: ""
```

### Acceptance Criteria

TTS provider can be switched without modifying the conversation engine.

---

# 18. Phase 14 — Streaming End-to-End Pipeline

## Goal

Reduce perceived response latency.

Target:

```text
User stops speaking
 ↓
ASR result
 ↓
Agent analysis
 ↓
LLM streaming
 ↓
Sentence/phrase chunk
 ↓
TTS streaming
 ↓
Playback
```

### Rules

Do not wait for the entire LLM response if the selected provider supports streaming.

Chunking must occur at safe semantic boundaries.

Avoid:

```text
token → TTS
```

Prefer:

```text
phrase/sentence → TTS
```

### Metrics

Record:

```text
ASR latency
LLM TTFT
LLM generation speed
TTS TTFA
audio playback start latency
end-to-end latency
```

### Target

The system should aim to begin spoken AI response within approximately 1–2 seconds after the user finishes speaking under a validated local configuration.

This is a target, not a guarantee for every model/device.

---

# 19. Phase 15 — Learning Memory

## Goal

Turn conversations into long-term personalized learning data.

## Memory layers

### Short-term

Current conversation.

### Session memory

Current practice session.

### Long-term memory

Persistent learning profile.

Store:

```text
grammar errors
vocabulary
pronunciation weaknesses
learning goals
difficulty history
conversation topics
progress
```

### Retrieval

Create:

```text
MemoryService
MemoryRepository
MemoryRetriever
```

Potential architecture:

```text
SQLite
+
Local Vector Index
```

### Acceptance Criteria

A future session can retrieve relevant historical learning information.

---

# 20. Phase 16 — Database

Recommended initial database:

```text
SQLite
```

Core tables:

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
```

### Rules

- Repository pattern.
- No database access from UI.
- No SQL embedded in Agents.
- Database migrations must be versioned.
- Tests must use isolated test databases.

---

# 21. Phase 17 — Scenario System

## Goal

Make role-play data-driven.

Scenario example:

```json
{
  "id": "airport_checkin",
  "title": "Airport Check-in",
  "difficulty": 3,
  "objective": "Complete an airport check-in conversation",
  "roles": [
    "passenger",
    "checkin_agent"
  ],
  "target_vocabulary": [
    "boarding_pass",
    "luggage",
    "destination"
  ]
}
```

Initial scenarios:

- Restaurant
- Airport
- Hotel
- Shopping
- Job Interview
- Doctor Visit
- Daily Conversation

Scenario logic should not be hard-coded into individual UI screens.

---

# 22. Phase 18 — Shadowing

## Goal

Implement sentence-level listening and repetition.

Pipeline:

```text
Reference Audio
 ↓
Reference Transcript
 ↓
User Recording
 ↓
ASR / Alignment
 ↓
Pronunciation Evaluation
 ↓
Feedback
```

Features:

- play reference
- record user
- replay user
- compare transcript
- compare timing
- pronunciation feedback

---

# 23. Phase 19 — Pronunciation Engine

## Goal

Implement measurable pronunciation evaluation.

Initial dimensions:

```text
phoneme accuracy
word accuracy
stress
intonation
fluency
speaking speed
pause duration
```

Recommended conceptual pipeline:

```text
Audio
 ↓
ASR
 ↓
Forced Alignment
 ↓
Phoneme Analysis
 ↓
Acoustic Features
 ↓
Scoring
 ↓
PronunciationResult
```

Do not make the first version dependent on a single pronunciation model.

---

# 24. Phase 20 — Vocabulary System

Features:

- vocabulary extraction
- difficult word detection
- new word saving
- review scheduling
- mastery tracking
- personalized vocabulary

Review logic should be separated from UI.

---

# 25. Phase 21 — Session Summary

After each session generate:

```text
SessionSummary
```

Suggested content:

```text
duration
speakingTime
newVocabulary
grammarErrors
pronunciationScore
fluencyScore
strengths
weaknesses
recommendedPractice
nextSessionFocus
```

The summary must be persisted locally.

---

# 26. Phase 22 — Dashboard and Progress

Dashboard:

```text
Today
 ↓
Practice time
 ↓
Recent mistakes
 ↓
Vocabulary
 ↓
Pronunciation
 ↓
Learning goals
```

Progress views:

- grammar trend
- vocabulary growth
- pronunciation trend
- speaking time
- practice frequency
- skill distribution

UI reads application-level data only.

---

# 27. Phase 23 — Settings

Settings categories:

### Language

```text
target language
native language
accent
```

### Teacher

```text
personality
correction mode
difficulty
```

### AI Models

```text
ASR provider
LLM provider
TTS provider
Embedding provider
Pronunciation provider
```

### Voice

```text
voice
speed
pitch
style
```

### Privacy

```text
local-only mode
audio retention
conversation retention
```

---

# 28. Phase 24 — Voice Customization and Cloning

This is a later-phase capability.

Requirements:

- explicit user consent
- only user-owned or authorized voices
- local processing by default
- clear indication when a cloned/custom voice is active
- no third-party voice cloning workflow

Potential providers:

```text
GPT-SoVITS
Qwen3-TTS
Chatterbox
```

The application should expose generic capabilities such as:

```text
supportsVoiceCloning
supportsStyle
supportsEmotion
supportsPitchControl
```

and not expose provider-specific APIs.

---

# 29. Phase 25 — Resource Management

## Goal

Keep the application usable on Apple Silicon 16GB devices.

### Requirements

Implement:

```text
ModelLifecycleManager
ResourceMonitor
MemoryBudget
```

Rules:

1. Do not keep all large models loaded simultaneously.
2. Prefer lazy loading.
3. Unload inactive models when necessary.
4. Detect memory pressure.
5. Fail gracefully on OOM.
6. Avoid duplicate model instances.
7. Benchmark real memory consumption.

Example strategy:

```text
Conversation active:
ASR loaded
LLM loaded
TTS loaded

Pronunciation task:
pause/unload nonessential components
load pronunciation engine
```

---

# 30. Phase 26 — Error Handling

Define a unified error taxonomy.

Example:

```text
AIError
├── ProviderUnavailable
├── ModelNotFound
├── ModelLoadFailed
├── OutOfMemory
├── InferenceTimeout
├── InvalidOutput
├── UnsupportedCapability
├── RuntimeCrash
└── ProviderConfigurationError
```

Other errors:

```text
AudioError
DatabaseError
StorageError
ConfigurationError
PermissionError
```

Every error should have:

```text
code
message
recoverable
userMessage
technicalContext
```

Do not swallow exceptions.

---

# 31. Phase 27 — Testing Strategy

## Unit Tests

Test:

- domain models
- repositories
- managers
- agents
- configuration
- memory
- response planner
- state machines

## Integration Tests

Test:

```text
Audio → VAD → ASR
ASR → Grammar Agent
Agent → LLM
LLM → TTS
Conversation → Memory
Session → Database
```

## End-to-End Tests

Minimum flow:

```text
Start app
 ↓
Start conversation
 ↓
Record speech
 ↓
ASR
 ↓
Analyze
 ↓
Generate response
 ↓
TTS
 ↓
Playback
 ↓
Save session
```

Mock providers should be used in CI.

---

# 32. Phase 28 — Benchmarking

Create:

```text
Tests/Benchmark/
```

Benchmark dimensions:

### ASR

```text
WER
latency
RTF
memory
streaming stability
```

### LLM

```text
TTFT
tokens/sec
memory
context handling
structured output reliability
```

### TTS

```text
TTFA
RTF
audio quality
voice consistency
memory
```

### Pronunciation

```text
alignment latency
score consistency
phoneme accuracy
```

### System

```text
end-to-end latency
peak memory
CPU usage
GPU/MPS utilization
crash rate
```

Benchmark results should be stored as versioned artifacts.

---

# 33. Phase 29 — Security and Privacy

Local-first requirements:

- no cloud upload by default
- no telemetry by default
- audio stored locally
- user profile stored locally
- learning memory stored locally
- voice references stored locally

If future cloud functionality is added, it must be explicitly enabled and clearly disclosed.

Sensitive audio data must not be logged.

Never put:

```text
audio bytes
voice reference data
full private conversation
```

into ordinary debug logs.

---

# 34. Phase 30 — Release Preparation

Release checklist:

### Build

- [ ] Clean build succeeds
- [ ] Release build succeeds
- [ ] No debug-only dependency
- [ ] No hard-coded local paths

### AI

- [ ] Provider health checks work
- [ ] Model loading works
- [ ] Model unloading works
- [ ] Fallback works
- [ ] Unsupported capabilities are handled

### Audio

- [ ] Microphone permissions work
- [ ] Recording is stable
- [ ] Playback is stable
- [ ] Streaming does not deadlock

### Data

- [ ] Database migration works
- [ ] Backup/export behavior defined
- [ ] Corrupted data handled

### Performance

- [ ] Memory benchmark completed
- [ ] Latency benchmark completed
- [ ] Long-session test completed

### Privacy

- [ ] No unintended network requests
- [ ] No audio leakage in logs
- [ ] Local storage locations documented

---

# 35. MVP Definition

The MVP is complete when the following flow works:

```text
Open Application
 ↓
Select Target Language
 ↓
Start Conversation
 ↓
Microphone
 ↓
VAD
 ↓
Local ASR
 ↓
Grammar Analysis
 ↓
Teacher Decision
 ↓
Conversation Response
 ↓
Local LLM
 ↓
Local TTS
 ↓
Playback
 ↓
Save Conversation
 ↓
Generate Session Summary
```

MVP required features:

- microphone
- VAD
- local ASR
- local LLM
- local TTS
- AI conversation
- grammar correction
- conversation history
- basic learning memory
- session summary

---

# 36. Post-MVP Roadmap

## V1.1

- shadowing
- pronunciation scoring
- vocabulary system
- dashboard
- scenarios

## V1.2

- IELTS/interview mode
- personalized learning plan
- long-term memory
- teacher personality
- voice customization

## V2

- voice cloning
- multilingual expansion
- advanced pronunciation
- emotion/intonation
- adaptive curriculum
- automatic learning path

---

# 37. Recommended Agent Execution Order

AI Coding Agents should execute tasks in this order:

```text
01 Repository Bootstrap
02 Domain Models
03 Provider Interfaces
04 Managers
05 Model Registry
06 Configuration
07 Audio Pipeline
08 Mock Providers
09 Conversation Engine
10 Teacher Agent
11 Grammar Agent
12 Conversation Agent
13 Response Planner
14 Database
15 Memory
16 Local LLM Adapter
17 Local ASR Adapter
18 Local TTS Adapter
19 Streaming
20 Session Summary
21 Scenario System
22 Shadowing
23 Pronunciation
24 Vocabulary
25 Dashboard
26 Settings
27 Resource Management
28 Benchmarking
29 Security/Privacy
30 Release Validation
```

Do not skip foundational abstraction phases merely to demonstrate a model quickly.

---

# 38. Task Execution Template for AI Coding Agents

Every implementation task should follow this template.

## Task

```text
TASK-ID:
TITLE:
OBJECTIVE:
```

## Before Coding

Agent must inspect:

```text
README
Docs/
current directory structure
related interfaces
related managers
related services
related tests
configuration
```

## Implementation

Agent must specify:

```text
Files to create
Files to modify
Interfaces affected
Dependencies added
Tests added
```

## Validation

Run:

```text
build
unit tests
integration tests where applicable
lint/format where configured
```

## Completion Report

Return:

```text
Implemented:
Files changed:
Tests:
Build:
Known limitations:
Unverified assumptions:
Next recommended task:
```

---

# 39. Example Agent Task

```text
TASK-ID: P2-001

TITLE:
Implement IASRProvider

OBJECTIVE:
Create the model-agnostic ASR provider contract.

FILES:
AI/Interfaces/IASRProvider.swift
AI/Interfaces/ASRModels.swift
Tests/Unit/AI/IASRProviderTests.swift

REQUIREMENTS:
- initialization lifecycle
- transcription
- streaming transcription
- capability query
- metadata query
- no concrete ASR SDK imports

ACCEPTANCE:
- project builds
- tests pass
- MockASRProvider can conform
- WhisperKit is not required
```

---

# 40. Definition of Done

A task is considered complete only when:

- implementation exists
- architecture boundaries are respected
- configuration is externalized
- tests are added/updated
- project builds
- relevant tests pass
- errors are handled
- logging is appropriate
- no unverified API assumptions remain
- documentation is updated when behavior changes

A feature is not complete merely because a demo works.

---

# 41. Architecture Red Lines

AI Coding Agents must not introduce:

```text
UI → AI SDK
UI → Database
Agent → Concrete Model
Business Service → Model Runtime
Hard-coded model path
Hard-coded localhost port
Prompt scattered across UI
Database SQL inside Agent
Provider-specific types in Domain
Global singleton model instances without lifecycle control
Silent exception swallowing
Unvalidated external API assumptions
```

If a task appears to require violating one of these rules, stop and redesign the implementation.

---

# 42. Final Engineering Principle

The implementation should optimize for:

```text
Stable Architecture
>
Replaceable Models
>
Testability
>
Local Performance
>
Feature Speed
```

The project's long-term value is not a particular ASR, LLM, or TTS model.

The core product moat is:

```text
Real-time voice interaction
+
Teacher Agent
+
Learning Memory
+
Personalized Error Modeling
+
Pronunciation Evaluation
+
Adaptive Learning
+
Local Privacy
```

Therefore:

> **Models can change. Providers can change. Runtimes can change. The application architecture should remain stable.**
