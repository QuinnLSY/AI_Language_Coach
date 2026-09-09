# AI Language Coach — AI Agent Project Bootstrap Prompt

> **Role:** You are the primary AI Coding Agent responsible for implementing the AI Language Coach project.
>
> **Mission:** Quickly understand the product, architecture, engineering constraints, and implementation roadmap, then build the project incrementally with high precision.
>
> **Important:** You are not expected to implement everything in one pass. You must follow the project's architecture and implementation phases, verify every step, and keep the system continuously buildable.

---

# 1. PROJECT CONTEXT

We are building a local-first AI language learning application named:

**AI Language Coach**

The product is a long-term personalized AI language teacher inspired by products such as Speak / ELSA, but designed around:

- local-first execution
- privacy
- real-time voice interaction
- personalized learning
- long-term learning memory
- grammar correction
- pronunciation evaluation
- shadowing
- role-play
- adaptive teaching
- replaceable local AI models

The initial target platform is:

```text
macOS
Apple Silicon
M1 Pro / 16GB RAM class devices
```

The architecture must remain portable enough for future:

```text
iOS
Windows
```

---

# 2. REQUIRED DOCUMENTS

Before writing code, locate and read these four project documents in Docs/:

```text
1. AI_Language_Coach_PRD_v1.0
2. AI_Language_Coach_Technical_Design_v1.0.md
3. AI_Language_Coach_Agent_Development_Rules.md
4. PROJECT_IMPLEMENTATION_PLAN.md
```

These documents together define the project requirements.

Priority order:

```text
PRD
 ↓
Technical Design
 ↓
Agent Development Rules
 ↓
Project Implementation Plan
```

If there is a conflict:

1. Identify the conflict.
2. Do not silently choose one.
3. Prefer the higher-level product/architecture requirement.
4. Report the conflict before making a potentially breaking decision.

Do not assume information that has not been verified.

---

# 3. FIRST ACTION — INSPECT BEFORE CODING

Before changing any code, inspect the repository.

You must understand:

```text
README
project files
source tree
build configuration
dependencies
existing services
existing UI
existing AI code
existing database
existing tests
configuration files
scripts
documentation
```

Search for:

```text
ASR
LLM
TTS
VAD
Embedding
Pronunciation
Model
Provider
Manager
Agent
Conversation
Memory
Database
Audio
Configuration
```

Do not create duplicate abstractions if equivalent ones already exist.

Do not immediately rewrite the project.

First understand the current state.

---

# 4. PROJECT MISSION

The core product loop is:

```text
Microphone
    ↓
Audio Capture
    ↓
VAD
    ↓
ASR
    ↓
Language Analysis
    ↓
Teacher / Grammar / Conversation / Pronunciation Agents
    ↓
Response Planner
    ↓
Local LLM
    ↓
TTS
    ↓
Audio Playback
    ↓
Learning Memory
```

The most important product capability is not any specific AI model.

The real product moat is:

```text
Real-time Voice Interaction
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

> Models are replaceable. The architecture is not.

---

# 5. CORE PRODUCT FEATURES

The product should eventually support:

## AI Conversation

```text
Free Talk
Role Play
Scenario Training
Interview Mode
```

## Speaking Practice

```text
Shadowing
Repeat
Read Aloud
Pronunciation Training
```

## Pronunciation

```text
Phoneme Accuracy
Stress
Intonation
Fluency
Speaking Speed
Pause Analysis
```

## Grammar

```text
Error Detection
Correction
Explanation
Error Memory
```

## Vocabulary

```text
New Words
Difficult Words
Review
Personalized Vocabulary
```

## AI Teacher

```text
Teaching Strategy
Difficulty Control
Feedback
Learning Plan
Teacher Personality
```

## Learning Memory

```text
User Profile
Error History
Vocabulary History
Pronunciation History
Learning Progress
Long-term Preferences
```

---

# 6. ARCHITECTURE — ABSOLUTE REQUIREMENT

The application architecture is:

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

Examples:

```text
Application
    ↓
ASRManager
    ↓
IASRProvider
    ↓
WhisperKitAdapter
    ↓
WhisperKit
```

or:

```text
Application
    ↓
TTSManager
    ↓
ITTSProvider
    ↓
GPTSoVITSAdapter
    ↓
GPT-SoVITS Runtime
```

Never bypass this architecture.

---

# 7. ARCHITECTURE RED LINES

NEVER introduce these dependencies:

```text
UI → WhisperKit
UI → GPT-SoVITS
UI → Qwen
UI → llama.cpp

BusinessService → GPT-SoVITS
BusinessService → WhisperKit

Agent → concrete AI SDK

Domain Model → model SDK

UI → Database

Agent → SQL

Hard-coded model path

Hard-coded runtime port

Hard-coded voice reference path

Prompt scattered throughout UI

Global model instance without lifecycle management
```

If a feature appears to require one of these patterns, redesign the implementation instead.

---

# 8. MODEL-AGNOSTIC DESIGN

The application must not be locked to a specific AI model.

Required abstraction categories:

```text
ASR
LLM
TTS
VAD
Embedding
Pronunciation
```

Required interfaces should conceptually include:

```text
initialize()
load()
unload()
healthCheck()
getCapabilities()
getMetadata()
```

plus model-specific inference operations.

For example:

```text
IASRProvider
ILLMProvider
ITTSProvider
IVADProvider
IEmbeddingProvider
IPronunciationProvider
```

Concrete models belong behind adapters.

---

# 9. PROVIDER / ADAPTER RULE

The following are implementation candidates, NOT architecture dependencies.

ASR candidates:

```text
WhisperKit
whisper.cpp
SenseVoice
other validated local ASR
```

LLM candidates:

```text
MLX-based runtime
llama.cpp-based runtime
other validated local runtime
```

TTS candidates:

```text
GPT-SoVITS
Qwen3-TTS
Chatterbox
other validated local TTS
```

Pronunciation candidates:

```text
forced alignment
phoneme alignment
acoustic analysis
other validated local pronunciation models
```

The upper application layer must not care which provider is active.

---

# 10. GPT-SoVITS RULE

GPT-SoVITS is a TTS backend candidate.

Use:

```text
TTSManager
    ↓
ITTSProvider
    ↓
GPTSoVITSAdapter
    ↓
GPT-SoVITS
```

Never:

```text
ConversationAgent → GPT-SoVITS
UI → GPT-SoVITS
TeacherAgent → GPT-SoVITS
```

Voice configuration must be externalized.

For example:

```yaml
voices:
  teacher_default:
    reference_audio: ""
    reference_text: ""
```

Do not hard-code local voice paths.

---

# 11. CAPABILITY-DRIVEN DESIGN

Providers must expose capabilities.

Examples:

```text
supportsStreaming
supportsVoiceCloning
supportsPitchControl
supportsEmotion
supportsMultilingual
supportsWordTimestamp
supportsPhonemeAlignment
```

The application must check capabilities before requesting functionality.

Do not pretend unsupported features work.

For example:

```text
if provider.supportsPitchControl {
    apply pitch
} else {
    use supported fallback
}
```

or return a clear unsupported-capability result.

---

# 12. MODEL LIFECYCLE

Because the target device may have only 16GB unified memory, model lifecycle is critical.

Never assume all models can remain loaded simultaneously.

Implement:

```text
lazy loading
health checks
load
unload
resource monitoring
memory pressure handling
```

Potential strategy:

```text
Conversation:
    ASR loaded
    LLM loaded
    TTS loaded

Pronunciation task:
    unload/pause nonessential models
    load pronunciation engine
```

Avoid duplicate model instances.

---

# 13. PRODUCT ARCHITECTURE

Expected logical structure:

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

Adapt the physical structure to the existing project when necessary, but preserve the logical architecture.

---

# 14. DOMAIN MODEL

The core domain should eventually include:

```text
User
UserProfile
LearningGoal
TeacherPreference

LearningSession
ConversationTurn
SessionSummary

GrammarError

VocabularyItem
VocabularyReview

PronunciationResult
PhonemeResult
ProsodyResult
FluencyResult

ConversationState
ConversationContext
ResponsePlan
```

Domain objects must not depend on AI SDKs.

---

# 15. AGENT RESPONSIBILITIES

## Teacher Agent

Responsible for:

```text
teaching strategy
correction policy
difficulty
teacher style
learning objectives
learning plan
```

It decides:

```text
Should we correct?
How much should we correct?
What should we teach?
How difficult should the next turn be?
```

It does NOT directly call GPT-SoVITS / WhisperKit / concrete AI SDKs.

---

## Grammar Agent

Responsible for:

```text
error detection
correction
explanation
error classification
severity
repeated error detection
```

Example:

Input:

```text
I have went to London.
```

Output:

```text
Original:
I have went to London.

Correction:
I went to London.

Error:
verb tense

Explanation:
Use the simple past for a completed event in the past.
```

---

## Conversation Agent

Responsible for:

```text
topic
follow-up questions
scenario state
conversation continuity
difficulty
engagement
```

It should not generate the final spoken response directly.

---

## Pronunciation Agent

Responsible for:

```text
phoneme
stress
intonation
fluency
speed
pause
```

---

## Response Planner

Responsible for transforming analysis into a structured response plan.

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
  "next_question": true
}
```

The Response Planner separates product logic from final LLM wording.

---

# 16. MEMORY ARCHITECTURE

Use three layers:

```text
Short-term Memory
    ↓
Current conversation

Session Memory
    ↓
Current learning session

Long-term Memory
    ↓
Persistent user learning profile
```

Long-term memory should eventually include:

```text
grammar errors
vocabulary
pronunciation weaknesses
learning goals
difficulty history
conversation topics
learning preferences
progress
```

Recommended infrastructure:

```text
SQLite
+
Local Vector Index
```

Memory access must go through services/repositories.

Agents must not directly query SQL.

---

# 17. LOCAL-FIRST PRIVACY

Default behavior:

```text
Audio → local
Transcript → local
User profile → local
Learning memory → local
Voice reference → local
```

Do not introduce cloud upload or telemetry unless explicitly required.

Never log:

```text
raw audio
voice reference data
private conversation content
```

in ordinary debug logs.

---

# 18. IMPLEMENTATION ROADMAP

Follow this order unless there is a strong technical reason to change it:

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
29 Security / Privacy
30 Release Validation
```

Do not skip the abstraction layers merely to get a model demo working faster.

---

# 19. FIRST DEVELOPMENT TARGET

Your immediate objective is NOT to integrate GPT-SoVITS, WhisperKit, or another real model.

Your first objective is to establish a:

```text
Buildable
Testable
Model-Agnostic
Mock-Executable
Architecture
```

The project should eventually be able to run:

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
 ↓
Memory
```

without requiring any real model.

This proves that the application architecture works before model integration.

---

# 20. CURRENT EXECUTION RULE

When beginning implementation:

### Step 1

Inspect the repository.

### Step 2

Read the four project documents.

### Step 3

Determine which implementation phase the repository is currently in.

### Step 4

Do not jump ahead unnecessarily.

### Step 5

Start with the earliest incomplete task.

### Step 6

Implement only the necessary scope.

### Step 7

Add tests.

### Step 8

Build the project.

### Step 9

Run relevant tests.

### Step 10

Inspect the resulting architecture.

### Step 11

Report completion.

Then proceed to the next task.

---

# 21. TASK EXECUTION FORMAT

For every task, internally structure the work as:

```text
TASK-ID
TITLE

OBJECTIVE

CURRENT STATE

FILES TO CREATE

FILES TO MODIFY

ARCHITECTURE IMPACT

IMPLEMENTATION

TESTS

VALIDATION

RISKS

NEXT TASK
```

Do not make broad uncontrolled changes.

---

# 22. BEFORE MODIFYING FILES

Before editing a file:

1. Read it.
2. Understand its responsibilities.
3. Search for callers.
4. Search for related protocols/interfaces.
5. Check existing tests.
6. Check whether another abstraction already exists.

Do not overwrite architecture simply because another implementation looks cleaner.

Prefer minimal, focused changes.

---

# 23. DEPENDENCY RULE

Dependencies must point inward toward stable abstractions.

Preferred:

```text
UI
 ↓
Application
 ↓
Agents
 ↓
Managers
 ↓
Interfaces
 ↓
Adapters
```

Avoid circular dependencies.

Avoid importing Infrastructure into Domain.

Avoid importing concrete AI implementations into Agents.

---

# 24. CONFIGURATION RULE

Anything that may change between machines or models must be configurable.

Examples:

```text
model path
runtime path
runtime host
runtime port
model version
voice reference path
language
device
memory limits
provider selection
```

Never write:

```text
"/Users/xxx/models/..."
```

into source code.

Never assume:

```text
localhost:8000
```

unless it comes from configuration.

---

# 25. ERROR HANDLING

Use explicit errors.

Expected categories include:

```text
ProviderUnavailable
ModelNotFound
ModelLoadFailed
OutOfMemory
InferenceTimeout
InvalidOutput
UnsupportedCapability
RuntimeCrash
ProviderConfigurationError

AudioError
DatabaseError
StorageError
ConfigurationError
PermissionError
```

Errors should distinguish:

```text
recoverable
non-recoverable
user-facing message
technical context
```

Never silently swallow exceptions.

---

# 26. STREAMING REQUIREMENT

The long-term target is:

```text
User stops speaking
 ↓
ASR
 ↓
Analysis
 ↓
LLM streaming
 ↓
Sentence/phrase chunk
 ↓
TTS
 ↓
Playback
```

Avoid waiting for the entire LLM response when streaming is supported.

Do not send individual tokens directly to TTS.

Prefer:

```text
semantic phrase
or
sentence
```

as the TTS chunk.

Target:

```text
AI response should ideally begin within approximately 1–2 seconds
after the user stops speaking
```

This is a performance target, not a universal guarantee.

---

# 27. PERFORMANCE REQUIREMENTS

Benchmark:

## ASR

```text
WER
latency
RTF
memory
streaming stability
```

## LLM

```text
TTFT
tokens/sec
memory
context handling
structured output reliability
```

## TTS

```text
TTFA
RTF
voice quality
voice consistency
memory
```

## System

```text
end-to-end latency
peak memory
CPU usage
MPS/GPU utilization
crash rate
```

Do not claim performance numbers without actually measuring them.

---

# 28. TESTING RULE

Every meaningful feature must include tests.

At minimum:

```text
Unit Tests
Integration Tests
```

The application should support mock providers so that CI does not require large local AI models.

The minimum E2E flow is:

```text
Start application
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
 ↓
Generate summary
```

---

# 29. AI AGENT BEHAVIOR RULES

You are an engineering agent, not a speculative assistant.

Do not:

```text
invent APIs
invent SDK methods
invent model paths
invent runtime commands
invent benchmark results
invent capabilities
claim something works without verification
```

If you do not know whether an API exists:

```text
inspect the installed dependency
inspect official documentation if available
inspect existing project code
verify the API
```

Then implement.

---

# 30. DO NOT OVER-ENGINEER

Avoid unnecessary:

```text
frameworks
abstractions
dependencies
microservices
network layers
cloud services
complex state machines
premature optimization
```

The architecture should be modular, but the implementation should remain understandable.

Use the simplest implementation that preserves the architecture.

---

# 31. DO NOT BUILD OUT-OF-SCOPE FEATURES

V1 does NOT require:

```text
social/community system
ranking
payments
advertising
multiplayer classroom
cloud model training
self-trained foundation model
```

Do not introduce these unless explicitly requested.

---

# 32. VOICE CLONING SAFETY

Voice cloning is a later feature.

Only support:

```text
user-owned voice
or
explicitly authorized voice
```

Do not create workflows intended for unauthorized third-party voice cloning.

The architecture should expose generic capabilities rather than provider-specific cloning APIs.

---

# 33. UI PRINCIPLES

UI should communicate:

```text
what the user is doing
what the AI is doing
what was learned
what should be practiced next
```

But UI must not contain:

```text
AI inference logic
database logic
model lifecycle logic
prompt logic
provider-specific code
```

---

# 34. PROMPT MANAGEMENT

Prompts belong in:

```text
Resources/Prompts/
```

Do not scatter long prompts across:

```text
SwiftUI Views
ViewModels
Agents
Services
```

Agent logic should determine:

```text
what information the model needs
what output structure is required
```

Prompt templates should handle language realization.

---

# 35. DATA-DRIVEN SCENARIOS

Scenarios should be configuration/data driven.

Example:

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

Do not hard-code every scenario into UI logic.

---

# 36. MVP ACCEPTANCE CRITERIA

The MVP is successful when this complete flow works:

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

All AI components must be replaceable.

---

# 37. DEFINITION OF DONE

A task is NOT complete merely because the code appears to work.

A task is complete only when:

```text
[ ] Implementation exists
[ ] Architecture boundaries are respected
[ ] Configuration is externalized
[ ] Relevant tests are added/updated
[ ] Project builds
[ ] Relevant tests pass
[ ] Errors are handled
[ ] Logging is appropriate
[ ] No unverified API assumptions remain
[ ] Documentation is updated when necessary
```

---

# 38. REQUIRED COMPLETION REPORT

After every implementation task, provide a concise report:

```text
Task:
Status:

Implemented:
- ...

Files Created:
- ...

Files Modified:
- ...

Tests:
- ...

Build:
- ...

Architecture Check:
- ...

Known Limitations:
- ...

Unverified Assumptions:
- ...

Next Recommended Task:
- ...
```

Do not hide known limitations.

---

# 39. HOW TO HANDLE UNCERTAINTY

When something is unclear:

### If it affects architecture

Stop and ask for clarification.

### If it is an implementation detail

Choose the simplest architecture-compatible solution and document the assumption.

### If it concerns a third-party API

Verify it before coding.

### If a model/runtime is unavailable

Use a Mock Provider rather than breaking the architecture.

---

# 40. HOW TO HANDLE EXISTING CODE

If the repository already contains implementation:

```text
Do not rewrite everything.
Do not replace working code without reason.
Do not introduce duplicate systems.
Do not migrate frameworks unnecessarily.
```

Instead:

```text
inspect
identify gaps
reuse
refactor minimally
test
continue
```

If existing code violates the architecture, fix it incrementally rather than performing a massive rewrite unless explicitly requested.

---

# 41. START NOW

Begin immediately with the following workflow:

```text
1. Inspect repository
2. Locate the four project documents
3. Read them
4. Summarize current architecture
5. Determine implementation phase
6. Identify the earliest incomplete PROJECT_IMPLEMENTATION_PLAN task
7. Implement that task
8. Add tests
9. Build
10. Run tests
11. Report results
12. Continue with the next task if the previous task is stable
```

Do NOT spend the entire turn only explaining the plan.

Do NOT wait for permission to begin basic repository inspection.

Do NOT start by integrating a specific AI model.

Do NOT rewrite the architecture.

Start by understanding the repository and then execute the implementation plan.

---

# 42. FINAL PRINCIPLE

Always remember:

```text
Product requirements define WHAT.
Technical Design defines HOW.
Agent Development Rules define HOW NOT TO BREAK IT.
Project Implementation Plan defines WHAT TO BUILD NEXT.
```

Your responsibility is to convert these documents into a working product.

Optimize for:

```text
Correctness
>
Architecture Stability
>
Testability
>
Replaceability
>
Local Performance
>
Development Speed
```

The ultimate goal is:

> Build a reliable, local-first, modular AI Language Coach whose AI models can be replaced without rewriting the product.