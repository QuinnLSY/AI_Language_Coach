# AI Language Coach 通用 AI Agent 开发规范

> 适用于：Codex、Claude Code、Cursor、Gemini CLI、Cline、Roo Code、Windsurf 以及其他具备代码读写能力的 AI Coding Agent。
>
> 本文件不是某个特定 Agent 的专用配置，而是项目级、工具无关的工程规则。

---

## 1. 最高优先级

你正在开发的是一个：

**Local-first + Model-agnostic + Modular AI Language Coach。**

必须优先遵守：

1. 不破坏既有架构。
2. 不把具体 AI 模型写死到业务层。
3. 不为了快速实现而绕过 Provider/Adapter。
4. 不擅自扩大需求范围。
5. 不在未验证的情况下声称功能完成。
6. 修改前先理解现有代码。
7. 修改后必须进行适当测试。

---

## 2. 开发前检查

开始任何非简单修改前，必须：

1. 阅读项目 README。
2. 阅读技术设计说明书。
3. 阅读本文件。
4. 检查目录结构。
5. 检查现有 Provider / Manager / Service。
6. 检查相关测试。
7. 搜索现有实现，避免重复造轮子。

如果发现现有架构与本文档冲突：

> 优先保留既有稳定接口，并提出最小重构方案；不要静默大规模改架构。

---

## 3. 不得猜测

如果一个模型、SDK、Runtime 或 API 的实际调用方式未知：

**不要伪造 API。**

应该：

1. 检查本地代码。
2. 检查项目文档。
3. 如果允许联网，查官方文档。
4. 如果仍然无法确认，建立清晰的 TODO / Adapter Stub。
5. 明确标记“待接入”。

禁止生成看似真实但未经验证的：

- import
- API endpoint
- class name
- function signature
- model path
- command
- CLI 参数

---

## 4. 模型无关原则

禁止：

```text
Business Service → GPT-SoVITS
Business Service → WhisperKit
Business Service → Qwen
```

必须：

```text
Business Service
 → Manager
 → Provider Interface
 → Adapter
 → Runtime
 → Model
```

具体模型只能存在于 Adapter / Registry / Configuration 层。

---

## 5. Provider 规则

所有 AI 能力必须使用 Provider Interface：

```text
ASRProvider
LLMProvider
TTSProvider
VADProvider
EmbeddingProvider
PronunciationProvider
```

每个 Provider 尽可能具备：

```text
initialize
load
unload
healthCheck
capabilities
metadata
```

---

## 6. Adapter 规则

新增模型时：

**优先新增 Adapter。**

不要修改核心业务逻辑。

例如新增 Fish Speech：

```text
FishSpeechBackend
implements TTSProvider
```

而不是：

```text
if model == "fish":
    ...
```

在几十个业务文件里增加条件判断。

---

## 7. Capability 规则

不要假设所有模型支持相同能力。

例如：

```text
supportsStreaming
supportsVoiceCloning
supportsPitchControl
supportsEmotion
supportsMultilingual
supportsWordTimestamp
```

UI 和业务层必须根据 capability 判断。

---

## 8. Configuration 规则

禁止硬编码：

```text
model path
port
host
runtime command
device
model version
voice reference path
```

统一进入 Configuration / Model Registry。

---

## 9. 依赖规则

依赖方向：

```text
UI
 ↓
Application
 ↓
Domain / Agents
 ↓
AI Managers
 ↓
Interfaces
 ↓
Adapters
 ↓
Runtime
```

禁止反向依赖。

例如：

```text
GPTSoVITSBackend → SwiftUI
```

属于错误设计。

---

## 10. UI 规则

UI 不允许：

- 直接加载模型
- 直接执行推理
- 直接操作数据库
- 直接调用具体 Backend
- 写 Prompt 业务逻辑

UI 只负责：

- State
- View
- User Interaction
- Presentation

---

## 11. Prompt 规则

Prompt 不要散落在业务代码中。

推荐：

```text
Resources/Prompts/
├── teacher/
├── grammar/
├── conversation/
├── pronunciation/
└── response_planner/
```

Prompt 必须版本化。

---

## 12. Agent 规则

Agent 是教学策略层，不是模型 Runtime。

Agent 可以：

- 决定是否纠错
- 决定教学难度
- 决定回复风格
- 决定下一轮话题
- 读取 Memory

Agent 不应该：

- 直接启动 GPT-SoVITS
- 直接加载 Whisper
- 直接管理模型生命周期

---

## 13. Memory 规则

Memory 必须结构化。

不要把所有历史对话直接塞进 Prompt。

使用：

```text
Short-term Memory
Session Memory
Long-term Memory
```

长期 Memory 必须考虑：

- relevance
- recency
- importance

---

## 14. Audio 规则

Audio Pipeline 必须保持：

```text
Capture
 → VAD
 → ASR
 → Analysis
```

以及：

```text
LLM
 → Text Chunking
 → TTS
 → Playback
```

避免把音频处理逻辑散落在 UI 中。

---

## 15. Streaming 规则

如果 Provider 支持 streaming：

优先使用 streaming。

目标：

```text
ASR streaming
LLM streaming
TTS streaming
```

不要无意义地等待完整结果。

---

## 16. Memory / RAM 规则

目标设备：

**Apple Silicon + 16 GB RAM。**

任何新增模型必须考虑：

- model size
- runtime memory
- peak memory
- concurrent models
- loading latency

优先：

```text
lazy loading
unload
quantization
process isolation
```

而不是无限增加模型规模。

---

## 17. 错误处理规则

任何模型调用都必须考虑：

```text
not found
load failure
OOM
timeout
runtime crash
unsupported capability
invalid output
```

不得使用：

```text
try:
    ...
except:
    pass
```

吞掉错误。

---

## 18. Fallback

如果存在可用 fallback：

```text
Primary
 ↓ failure
Fallback
 ↓ failure
System capability / graceful message
```

但不能为了“看起来支持 fallback”而调用未经验证的模型。

---

## 19. Logging

日志应该帮助开发者定位：

```text
timestamp
module
provider
operation
latency
status
error
```

生产模式禁止输出不必要的用户隐私。

---

## 20. Testing

每次修改后：

### 小修改

运行相关 Unit Test。

### Provider 修改

运行：

- Unit Test
- Provider Integration Test

### Pipeline 修改

运行：

```text
Audio → ASR → LLM → TTS
```

集成测试。

### Architecture 修改

运行完整测试。

---

## 21. Benchmark

任何替换 AI 模型的 Pull Request / 重大修改，都应该记录：

```text
accuracy
latency
memory
stability
```

TTS 特别记录：

```text
TTFA
RTF
voice quality
```

LLM：

```text
TTFT
tokens/sec
```

ASR：

```text
WER
latency
```

---

## 22. Definition of Done

不要仅以：

> “代码写完了”

作为完成标准。

必须满足：

- 编译成功
- 相关测试通过
- 错误路径存在
- 配置完整
- 文档同步
- 无明显架构违规
- 没有未说明的伪实现

---

## 23. Stub 规则

如果外部模型尚未接入，可以建立：

```text
MockProvider
StubProvider
```

但必须明确：

```text
NOT FOR PRODUCTION
```

禁止把 Mock 行为伪装成真实 AI 能力。

---

## 24. Git 规则

推荐小步提交：

```text
feat:
fix:
refactor:
test:
docs:
perf:
```

一次提交尽量只解决一个问题。

不要在一个提交中同时：

- 重写 UI
- 更换数据库
- 更换模型
- 重构 Provider

---

## 25. 修改策略

默认采用：

**最小必要修改。**

不要因为一个需求：

- 重命名大量文件
- 重写整个架构
- 更换框架
- 引入大量新依赖

除非有明确技术理由。

---

## 26. 新依赖规则

新增依赖前说明：

```text
Why?
What does it solve?
Can existing dependency solve it?
Impact on macOS / Apple Silicon?
Maintenance risk?
License?
```

优先减少依赖数量。

---

## 27. 安全规则

不得：

- 把密钥写入代码
- 把个人路径写入代码
- 上传用户音频
- 上传 voice reference
- 默认开启遥测
- 保存不必要的敏感信息

---

## 28. Voice Cloning

Voice cloning 功能只能用于：

- 用户自己的声音
- 用户明确获得授权的声音

不得设计成未经授权复制第三方声音的工具。

---

## 29. Documentation 规则

修改以下内容必须同步文档：

- Provider Interface
- Model Registry
- Configuration
- Database Schema
- Public Service Interface
- Architecture

---

## 30. AI Agent 工作循环

每个任务推荐遵循：

```text
1. Understand
2. Inspect
3. Plan
4. Implement
5. Test
6. Review
7. Document
8. Report
```

---

## 31. Plan 要求

复杂任务开始前先形成简短计划：

```text
Goal
Files to modify
Architecture impact
Implementation
Tests
Risks
```

如果只是简单单文件修改，可以直接实施。

---

## 32. 完成报告

每个任务完成后报告：

```text
Implemented:
- ...

Changed:
- ...

Tests:
- ...

Not implemented:
- ...

Known limitations:
- ...

Next recommended step:
- ...
```

禁止声称未实际运行的测试“通过”。

---

## 33. 不确定性标记

对以下情况必须明确：

```text
[UNVERIFIED]
[TODO]
[MOCK]
[EXPERIMENTAL]
[BLOCKED]
```

不要把实验代码伪装成 Production Ready。

---

## 34. 架构红线

以下行为必须避免：

```text
❌ UI 直接调用模型
❌ 业务层直接依赖 GPT-SoVITS
❌ 硬编码模型路径
❌ 硬编码 localhost 端口
❌ 将 Prompt 散落在 View 中
❌ 将数据库操作写入 UI
❌ catch 后吞掉错误
❌ 未验证 API 却声称可用
❌ 为了功能演示破坏 Provider 架构
❌ 未经用户授权实现第三方 Voice Cloning
```

---

## 35. 最终原则

当“快速实现”和“长期可维护架构”发生冲突时：

优先选择：

**可维护、可替换、可测试、可验证。**

这个项目的核心不是某一个 AI 模型。

核心是：

```text
AI Language Coach
=
Audio Pipeline
+
Model Abstraction
+
Teacher Intelligence
+
Learning Memory
+
Personalization
```

模型可以替换。

架构不能被轻易破坏。
