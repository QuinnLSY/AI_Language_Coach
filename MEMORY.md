# MEMORY.md — AI Language Coach 贯穿性要求

> 全项目生命周期内长期有效。**每次会话开工前读 `MEMORY.md` + `AGENTS.md` + `Docs/`（含 `LOCAL_MODEL_INTEGRATION_SPEC_v2.0.md`）。**
> 开发规范细节见 `AGENTS.md`；本文只保留不可动摇的目标、原则、决策与当前进度。

---

## 1. 产品是什么

**AI Language Coach** —— 本地优先（Local-first）的 AI 语言私教。对标 Speak / ELSA，但内核是：

```
实时语音交互 + Teacher Agent + 学习记忆 + 个性化错误建模 + 发音评测 + 自适应教学 + 本地隐私
```

核心闭环：

```
麦克风 → 音频采集 → VAD → ASR → 语言分析 → (Teacher/Grammar/Conversation/Pronunciation) → ResponsePlanner → LLM → TTS → 播放 → 学习记忆
```

判断标准：不是「ChatGPT + 麦克风 + TTS」，而是能回答「这个用户今天该练什么、老犯什么错、怎么纠正」。

---

## 2. 一句话铁律

> **模型可替换，架构不可破坏。**

优先级排序（冲突时从高到低）：

```
正确性 > 架构稳定性 > 可测试性 > 可替换性 > 本地性能 > 开发速度
```

任何「为了快点跑通 demo 而绕过 Provider/Adapter」的方案，一律否决。

---

## 3. 分层依赖（唯一方向）

```
UI → Application Services → Agents → Managers → Provider Interfaces → Adapters → Local Runtime → Models
```

六个必须抽象的 AI 能力：**ASR / LLM / TTS / VAD / Embedding / Pronunciation**。
模型候选（WhisperKit、whisper.cpp、SenseVoice、MLX、llama.cpp、Ollama、LM Studio、GPT-SoVITS、Qwen3-TTS、Chatterbox…）**都只是实现候选，不是架构依赖**。

**本地模型接入的终极目标**：不是"让 SwiftUI 调 Ollama"，而是"建成稳定、可测试、模型无关的本地 AI 集成层，且面向消费者的配置极简"。

两条地基原则（`LOCAL_MODEL_INTEGRATION_SPEC_v2.0`）：

1. **极简接入面** —— 模型本地部署后，Adapter **只消费它向外暴露的必要调用信息**（provider ID、runtime type、endpoint/model path、model name、capabilities、health）。其余一切（Python 环境、venv、checkpoint 文件名、量化、端口、device、线程、batch、temperature、top-p、context、VAD 阈值、embedding 维度、alignment 模型…）**一律内部自动解析，默认 `auto`，V1 不暴露，留待后续版本分级开放**。
2. **用户选"要什么"，不配"怎么跑"** —— 用户只看「AI 模型 / 语言 / 音色 / 练习模式」；路径、端口、进程、依赖、设备、安装、健康、生命周期全部自动管理。普通用户永远不需要 Developer Mode。

厂商专属细节（URL、端口、模型名、JSON）**只准出现在对应 Adapter 内部**，不得泄漏到 Domain / Agent / UI。

---

## 4. 范围边界

**V1 / MVP 必须**：麦克风、VAD、本地 ASR/LLM/TTS、AI 对话、语法纠错、会话历史、基础学习记忆、Session Summary、Provider 可替换。

**V1 明确不做**：云端训练、社交/社区、多人课堂、支付广告、自研基础模型、绑定某厂商 API。
**后期才有**：Shadowing（V1.1）、发音评分（V1.1）、场景与 Dashboard（V1.1）、面试模式/学习计划（V1.2）、Voice Cloning（V2，需用户授权）。

---

## 5. 已确认决策

| 项 | 决策 | 依据 / 状态 |
|---|---|---|
| 语言 / UI | Swift 6 + SwiftUI + Swift Concurrency | PRD §40、技术设计 §7–§10、LOCAL_MODEL_INTEGRATION_SPEC §3 三方一致 |
| Xcode | **已确认安装 Xcode 26.6（17F113）**，`xcode-select` 已指向，`xcodebuild` 可用 | 2026-09-08 复核 |
| 构建方式 | **SwiftPM 为唯一真相源**（`swift build` / `swift test`）；Xcode 用于预览、entitlements、`.app` 打包 | 命令行 CI 不依赖 GUI |
| 目录结构 | 技术设计 §4（= Bootstrap §13）的 `AI/ + Infrastructure/` | 与 PRD §59 平铺结构冲突，按优先级采用技术设计，已上报 |
| 网络层 | Foundation `URLSession`，**不引入第三方 HTTP 依赖** | LOCAL_MODEL_INTEGRATION_SPEC §3 |
| 数据库 | SQLite + Repository 封装；长期记忆再加本地向量索引 | 技术设计 §24 / Implementation Plan §20 |
| 首阶段目标 | **Mock 可跑通全链路**，不接真实模型 | Bootstrap §19、Plan Phase 5 |
| 首个真实 runtime | LLM = **Ollama + Qwen3**（`OllamaLLMAdapter`），走 OpenAI 兼容接口 `/v1/chat/completions` | v2.0 §13–§14 |
| 六能力统一接入 | 全部继承 `AIProvider` 基类契约（`initialize/load/unload/healthCheck/getCapabilities/getMetadata`） | v2.0 §5 |
| 配置模型 | **两层**：Product Config（用户可见：模型/语言/音色/练习模式）→ Configuration Resolver → Runtime Config（`auto` 优先）。字段四级分类：`USER_VISIBLE / USER_VISIBLE_ADVANCED / AUTO_MANAGED / INTERNAL_ONLY` | v2.0 §2、§10、§33 |
| 自动化职责 | 安装/发现/端口/设备/进程/生命周期 全部由应用承担（ProcessManager 统一管外部 runtime），不推给用户 | v2.0 §23–§31 |
| **TTS 首选（已拍板）** | **Qwen3-TTS 0.6B 为 V1 唯一首选**；GPT-SoVITS 部署复杂，**V1 不实现**，待 Qwen3-TTS 跑通验证产品功能后再作为模型选项纳入 | 用户 2026-09-09 确认 |
| **规范基准** | 本地模型接入一律以 **v2.0** 为准（v1 作废）；v2.0 与旧文档冲突处取 v2.0 | 用户 2026-09-09 确认 |
| **LLM V1 首个模型（已拍板）** | **deepseek-r1:7b**（本机已装，立即可验证）；`qwen3:8b` 待产品功能验证后作为**可选项**加入模型列表 | 用户 2026-09-09 确认 |
| **模型字段来源** | 模型名在 **设置 UI 中可填可选**，经配置系统注入；**代码里禁止出现模型名字面量**。后续模型验证由我自行下载部署并填入，不写死 | 用户 2026-09-09 明确 |
| **产品 UI 主题** | 森林 + 可爱动物；向参天大树攀升的闯关式语言教学；**日夜双景**（白天：太阳+活跃动物 / 夜晚：星星+睡觉动物），主界面与设置均可切换 | 用户 2026-09-09 明确 |
| **文件操作范围** | 所有文件操作**仅限项目空间内**，不碰项目目录之外的路径 | 用户 2026-09-09 明确 |
| 隐私 | 默认全本地（含 localhost → Ollama），不上传、不遥测 | PRD §57–§58、spec §24 |

### 环境事实（2026-09-09 复核，务必记住）

- Swift 6.3.3 / arm64-apple-macosx26.0；SwiftPM 6.3.3；`swiftc` 正常。Xcode 26.6（17F113）。
- SDK 含 `SwiftUI / AVFoundation / Combine / Metal / MetalKit / MPS / CoreML`。
- **Ollama v0.33.3 服务已在运行**（`http://127.0.0.1:11434`）。已装模型：`deepseek-r1:7b`（completion）、`nomic-embed-text:latest`（embedding / 768 维 / ctx 2048）。**`qwen3` 未安装** → 健康检查与集成测试必须容忍模型缺失。
- **`/v1/chat/completions` 实际字段已实测并写入 `AGENTS.md §0.2`**（非流式 / 流式 SSE / 错误 404 三份真实样本）。写 Adapter 前以该节为准，未实测字段先补测，禁止编造。
- ⚠️ **系统代理劫持 localhost**：`HTTP_PROXY/HTTPS_PROXY=http://127.0.0.1:59067`，导致 `URLSession` 访问 `localhost:11434` 返回 502。**本地 runtime 的 `URLSessionConfiguration` 必须显式 `connectionProxyDictionary = [:]`**；命令行探测用 `curl --noproxy '*'`。
- 无 `brew`。git 仓库已 init（首次提交 be12b4b）。

### 已知文档冲突（待确认）

1. **目录结构**：PRD §59（`Models/ + Database/ + Services/`）vs 技术设计 §4（`AI/ + Infrastructure/`）→ 采用技术设计。
2. **接口示例语言**：PRD 用 Python 示意，技术设计用 Swift protocol → 以 Swift 为准，Python 仅视为概念示意。
3. **TTS 节奏**：PRD §26 称 GPT-SoVITS 为「第一阶段重点测试 Backend」，Bootstrap §19 要求首阶段完全不接真实模型 → 按 Bootstrap：先 Mock 跑通架构，再逐个替换真实 Adapter。
4. **首个 runtime 的先后**：Bootstrap/Plan 把 LLM 排在 16 步（ASR 17、TTS 18），v2.0 指定 Ollama 为 first runtime → **不冲突但需注意**：v2.0 的 37 步顺序（LLM → ASR → VAD → TTS）插入到路线图第 16 步整体执行，ASR/TTS 仍在其后。
5. ✅ **TTS 首选冲突（已拍板 2026-09-09）**：PRD §24/§26 的 GPT-SoVITS vs v2.0 §17 的 Qwen3-TTS 0.6B → **取 Qwen3-TTS 0.6B 为 V1 唯一首选**。理由：GPT-SoVITS 部署更复杂。GPT-SoVITS **V1 不实现**，待 Qwen3-TTS 跑通验证产品模型功能后，再作为模型选项纳入（届时只是新增一个 `GPTSoVITSAdapter`，不动 Agent）。
6. **Adapter 命名不一致**：Bootstrap/技术设计用 `WhisperKitBackend / GPTSoVITSBackend`，v2.0 §38 用 `WhisperKitASRAdapter / OllamaLLMAdapter / Qwen3TTSAdapter`。→ 统一采用 **`<模型><能力>Adapter`**（如 `WhisperKitASRAdapter`），与 v2.0 一致。

### V1 运行时矩阵（v2.0 §38，已定）

| 能力 | V1 选型 | 部署 | Adapter | 端口 | 用户需配 |
|---|---|---|---|---|---|
| ASR | WhisperKit + Whisper | embedded | `WhisperKitASRAdapter` | 无 | 通常无 / 语言 |
| LLM | **deepseek-r1:7b** via Ollama（V1 首个验证模型，已装）；`qwen3:8b` 验证后作为可选项加入 | 本地进程 | `OllamaLLMAdapter` | 自动(11434) | 模型（UI 可选，不硬编码） |
| TTS | **Qwen3-TTS 0.6B（V1 唯一首选）** | 托管本地 runtime | `Qwen3TTSAdapter` | 自动 | 音色/语言 |
| TTS 后续 | GPT-SoVITS（**V1 不实现**，验证后再纳入） | 托管本地 runtime | `GPTSoVITSAdapter` | 自动 | 音色 |
| VAD | Silero VAD | embedded (ONNX) | `SileroVADAdapter` | 无 | 无需 |
| Embedding | Ollama embedding | 本地 | `OllamaEmbeddingAdapter` | 自动 | 无需 |
| Pronunciation | 对齐 + 声学分析 | pipeline | `PronunciationAdapter` | 视情况 | 语言/练习模式 |

M1 Pro / 16GB：TTS 先 0.6B，benchmark 后再考虑 1.7B；优先保证 ASR+LLM+TTS 稳定共存。**V1 用户只需输入：模型、语言、音色、练习模式** —— 端点、端口、路径、Python 环境、device、量化、temperature、阈值、维度等一律不进普通 UI。

---

## 6. 执行节奏（30 步路线图，见 Implementation Plan §37）

```
01 仓库骨架 → 02 领域模型 → 03 Provider 接口 → 04 Managers → 05 Model Registry
→ 06 配置 → 07 音频管线 → 08 Mock Providers → 09 会话引擎
→ 10 Teacher → 11 Grammar → 12 Conversation → 13 ResponsePlanner
→ 14 数据库 → 15 记忆 → 16 LLM(Ollama) → 17 ASR → 18 TTS → 19 流式
→ 20 Session 总结 → 21 场景 → 22 Shadowing → 23 发音 → 24 词汇
→ 25 Dashboard → 26 设置 → 27 资源管理 → 28 基准 → 29 安全隐私 → 30 发布校验
```

**不跳步**：基础抽象与 Mock 全链路没跑通前，不并行推进多个 Agent，也不提前接真实模型。

### 第 16 步（本地模型接入）内部执行顺序

按 `LOCAL_MODEL_INTEGRATION_SPEC_v2.0 §52`，共 37 步：

```
检视仓库/复用抽象 → ModelRegistry → 统一 metadata → 统一 capability
→ 配置解析器 → runtime 状态模型 → 六个 Mock Provider
→ LLMProvider → OllamaLLMAdapter → LLMManager
→ ASRProvider → WhisperKitASRAdapter → VADProvider → SileroVADAdapter
→ TTSProvider → Qwen3TTSAdapter → (GPTSoVITSAdapter)
→ EmbeddingProvider → PronunciationProvider → ProcessManager
→ 模型安装/发现 → 健康检查 → 生命周期 → 配置 UI
→ 只暴露普通字段 → 高级/开发者配置单独放 → 单测 → runtime 集成测试
→ 接一个 Agent → 打通本地链路 → 验证内存 → 验证模型可替换 → 文档
```

**禁止一上来就把 runtime 调用塞进 Agent。**
**验收硬指标**：WhisperKit→其他 ASR、Qwen3→其他 LLM、Qwen3-TTS→GPT-SoVITS、Silero→其他 VAD、Ollama Embedding→MLX、发音 Pipeline A→B —— 全部替换**不动任何 Agent**；甚至 runtime 从 Ollama 换成 MLX/llama.cpp 跑同一个 Qwen3，也只改 Adapter/Provider 层。

### 当前进度（2026-09-10 下午）

**Phase 0 + UI 大改版 + 第 14 步（SQLite）+ 第 17/18 步（ASR/TTS 本地）+ 第 20 步（Session 总结）已完成**；学习数据库 schema 升到 **v3**（新增 `session_reviews`）。

```
AIServices/    新增 SessionReviewService（练习复盘：LLM 生成 JSON 总结 + heuristic 规则兜底 + 落库）
AIInfra/       AudioPlayback 支持 0.5–3× 变速（AVAudioEngine + AVAudioUnitTimePitch，保持音高）
AIInfra/       Prompts/session_review.txt（复盘 Prompt，版本化）
AppUI/         RecordsView 新增「练习复盘」卡（生成按钮/新词/优点/待改进/建议）
AppUI/         ChatView「听老师读」右侧语速胶囊（与设置页语音卡同一份配置，双向同步）；按钮点击边缘高亮
AppUI/         ForestGroundBand：小动物气泡改为每只独立持有（bubbleTexts/stamps），最新气泡 zIndex 最大
AppCore/       ProductConfig 新增 speechRate（SpeechRate 枚举 6 档，非法取值自动落最近档）
Tests/         69 个测试（新增 SessionReviewTests 9 个 + 真实模型复盘集成测试），全部通过
```

### 截图验证工作流（重要，已踩坑）

1. App 进程会随 shell 命令结束被杀 → **启动 + sleep + 截屏必须在同一条 Bash 命令内**（非沙箱运行）。
2. `open` 二进制会触发 Gatekeeper 沙箱弹窗（"不允许在终端中打开文档"），且弹窗杀不掉会常驻 → **不要用 `open`**，直接 `.build/debug/AILanguageCoach &`。
3. 系统弹窗会污染全屏截图 → 用 `screencapture -l<windowID>` 按窗口 ID 截干净画面（窗口 ID 用 swift + CGWindowListCopyWindowInfo 获取，脚本已验证）。
4. 主题切换验证走配置文件：`.workbuddy/app-config/config.json` 的 `product.theme_mode`（snake_case！不是 themeMode）→ 改后重启进程即可，无需点 UI。
5. `--open-settings` 启动参数可直接打开设置面板，用于动物/模型设置的截图验证。

### 下一步（按路线图）

1. 第 15 步学习记忆继续深化：关卡进度与练习结算联动（completeLevel 已实现，待接复盘结论）。
2. 第 21 步场景系统（Scenario System）→ 情景对话模式真正落地。
3. 词汇本（侧边栏"词汇本"入口已留）：把复盘 new_words 沉淀为可复习的词汇表。

---

## 7. 完成判定（DoD）

```
[ ] 实现存在且架构边界未被破坏
[ ] 配置外置，无硬编码路径/端口
[ ] 测试已新增/更新，且实际执行过（禁止口头宣称通过）
[ ] swift build 通过
[ ] 错误已处理、日志恰当
[ ] 无未验证的第三方 API 假设
[ ] 文档已同步
```

不确定项必须显式标记 `[UNVERIFIED] / [TODO] / [MOCK] / [EXPERIMENTAL] / [BLOCKED]`。
