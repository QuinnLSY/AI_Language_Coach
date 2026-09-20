# 代码审查报告 · v1.0 冻结前

- 范围：`Sources/`（329 个 .swift，约 9.2 万行）+ `Tests/`（122 个文件，2.86 万行）+ `Package.swift` / `Scripts/`
- 时间：2026-09-20
- 性质：**只读审计**，未改动任何代码
- 方法：全量符号计数脚本（声明处 vs 全仓引用）+ 花括号匹配的参数使用分析 + 定向 grep/精读；硬信号（`try!`/`as!`/`fatalError`/强制解包/`TODO`/残留 `print`）已扫，**均为 0**
- 结论：**总体质量高**——分层清晰、注释记录了大量踩坑、无强制解包、无 TODO 债。问题集中在「建好但没接通」的半成品接口、少量重复真源，以及一处发布级路径风险。

---

## 表 1 · 未使用 / 死代码（已逐条核实「全仓仅声明处出现一次」或「零读取」）

| # | 文件:行 | 严重度 | 现象 | 证据 / 影响 | 建议 |
|---|---|---|---|---|---|
| 1-1 | `Sources/AIInterfaces/AIProviderError.swift:40` | 高 | `isRetryable` 定义了完整重试语义（连「非法请求/不支持能力/配置错误一律不重试」都写了），**全仓无消费方** | 无任何重试循环读它 → 网络类错误无自动重试策略；设计意图落空 | 要么在请求层接上（按 `isRetryable` 决定是否重试），要么删掉该属性 |
| 1-2 | `Sources/AIServices/CoachServices.swift:747,752,765` | 高 | `modelConfigs(kind:)` / `defaultModelConfig(for:)` / `registryInconsistencies(for:)` 三个面向 UI 的读接口**零调用** | 连同表 1-3 的 `ModelMetadata` → `ModelRegistry` 的「统一 metadata / capability」目标只落了 enable 一侧 | 接通设置页展示，或降级为 internal/删除 |
| 1-3 | `Sources/AIDomain/ModelRegistry.swift:65` | 中 | `ModelMetadata` 类型零引用 | 与 `ProviderMetadata` 语义重叠，疑为旧设计残留 | 删除或明确其与 `ProviderMetadata` 的分工 |
| 1-4 | `Sources/AIDomain/WordForm.swift:220` | 中 | `looksInflected(_:)` 零引用 | 词典「是否为变形词」的公开判断无人用（实际链路走 `candidates`） | 删除 |
| 1-5 | `Sources/AIServices/PronunciationService.swift:47` | 中 | `hasAcousticChannel` 零引用 | 发音「有无声学通道」标志没被 UI 用 | 删除或接入发音卡 |
| 1-6 | `Sources/AIInfrastructure/ConfigStore.swift:83` | 中 | `reload()` 零引用 | 外部手改 `config.json` 后**无重载入口**，只能重启应用 | 提供重载入口（设置页「重新载入配置」）或删除 |
| 1-7 | `Sources/AppCore/Logging.swift:54,73` | 中 | `LogBus.setMinimumLevel(_:)` 与 `clear()` 零引用 | 日志级别**从未被配置**（一直 debug 全量入内存 500 条 + 全量 os_log）；设置页只看不能清 | 接上级别选择与「清空日志」，或删除 |
| 1-8 | `Sources/AIServices/CoachServices.swift:386,401` | 中 | `attachmentURL(for:)` / `attachmentDirectory` 零引用 | **注释写「设置页『在 Finder 中打开』用」，实际没有这个 UI** → 注释与事实不符 | 补上入口或删掉注释+方法 |
| 1-9 | `Sources/AIServices/CoachServices.swift:1292,1480,2104` | 低 | `llmLabel` / `embeddingHealth` / `materialKit` 零引用 | 零散诊断/取数辅助，已无消费方 | 删除 |
| 1-10 | `Sources/AppUI/AppState.swift:1160` | 低 | `llmHealthDescription` 零引用 | 健康文案算好了没人展示 | 删除或接入 |
| 1-11 | `Sources/AIInfrastructure/ConfigStore.swift:81`、`VoiceProfileStore.swift:34` | 低 | `storageLocation` 两个都只有声明，无读取 | 声明的「存储位置」对外不可达 | 删除 |
| 1-12 | `Sources/AIDomain/ChatAttachment.swift:67,81` | 低 | `isVideo` / `fileExtension` 零引用 | — | 删除 |
| 1-13 | `Sources/AIDomain/ConversationContext.swift:240`、`ExamRunner.swift:69`、`ExamScoring.swift:23` | 低 | `difficultyIsMaxed` / `elapsedSeconds` / `isWholeBand` 零引用 | 会话/考试若干辅助判断死掉 | 删除 |
| 1-14 | `Sources/AIDomain/ReleaseChecklist.swift:230,259` | 低 | `automatedItems` / `statusLabel` 零引用 | 发布清单的筛选/文案无人用 | 删除 |
| 1-15 | `Sources/AIServices/VoiceService.swift:211`、`Sources/AIInfrastructure/MicrophoneRecorder.swift:152` | 低 | `recordingLevel` / `capturedSampleCount` 零引用 | 录音电平表相关状态没接 UI | 删除或接电平表 |
| 1-16 | `Sources/AIInterfaces/LLMInterfaces.swift:172` | **高** | `LLMProvider.llmCapabilities()` 协议要求，3 个 LLM 适配器都实现，**全仓零调用** | 与 `ProviderCapabilities` 并行的第二套能力面（见表 2-1），纯空转 | 二选一：删掉 `llmCapabilities` 并入 `ProviderCapabilities` |
| 1-17 | `Sources/AIInterfaces/AIProvider.swift:49` | 中 | `ProviderCapabilities.wordTimestamp` 无读取方 | 注释说「调用方据此决定要不要读 `ASRResult.words`」，但**没人读这个标志** → 该决策实际不存在 | 接上（Whisper 报 true 时启用词级对齐）或删字段 |
| 1-18 | `Sources/AppCore/Configuration.swift:651` | 低 | `enabledProvider(for:)` 生产代码零用（仅 2 个测试用） | 与 `resolvedProvider(for:)` 语义重叠 | 测试专用可加 `@testable` 说明，或删除改用 `resolvedProvider` |

### 表 1b · AppState 公开动作方法零调用（9 个，全部只出现在声明行）

| # | 文件:行 | 现象 | 影响 |
|---|---|---|---|
| 1b-1 | `AppState.swift:2682 addVocabularyWord()` | 手动添加生词动作无调用 | 见下条 → 整条功能未接通 |
| 1b-2 | `AppState.swift:1268 cancelVoiceInput()` | 取消语音输入动作无调用 | 「取消」可能只有 UI 局部逻辑 |
| 1b-3 | `AppState.swift:1465 clearPendingAttachments()` | 清空待发附件无调用 | 附件栏可能无法整体清空 |
| 1b-4 | `AppState.swift:1471 clearAttachmentSaveNotice()` | 清除保存提示无调用 | `attachmentSaveNotice` 一旦亮起**无法清除**（需确认 UI 是否另走他路） |
| 1b-5 | `AppState.swift:2984 dismissVocabularySuggestions()` | 关闭联想无调用 | 配合 1b-1：联想整条链无 UI |
| 1b-6 | `AppState.swift:3425 cancelRemoveDictionary()` | 取消删词库无调用 | • |
| 1b-7 | `AppState.swift:4011 stopShadowingAudio()` | 停止跟读音频无调用 | • |
| 1b-8 | `AppState.swift:4996 dismissBackupImportNotice()` | 关闭备份导入提示无调用 | • |
| 1b-9 | `AppState.swift:1160 llmHealthDescription` | 死计算属性 | • |

> ℹ️ 这批「动作没按钮」的另一种可能：按钮被移除后动作残留。建议逐条确认是「补 UI」还是「删动作」。

---

## 表 2 · 接口不一致 / 重复真源

| # | 文件:行 | 严重度 | 现象 | 证据 / 影响 | 建议 |
|---|---|---|---|---|---|
| 2-1 | `AIInterfaces/AIProvider.swift:39` vs `AIInterfaces/LLMInterfaces.swift:145` | **高** | 两套并行能力面 `ProviderCapabilities` 与 `LLMCapabilities`，**字段几乎相同**；`RemoteLLMAdapter.swift:123-139` 两个方法内容逐字等价 | 同一份能力在两处声明，改一处忘一处即漂移；且 `llmCapabilities` 无人调（表 1-16） | 合并为单一能力结构 |
| 2-2 | `AIProvider.swift:82-96` vs `AppCore/Configuration.swift:217,294` | 中 | 能力双声明：配置 `capabilities`（供应商自报）与 Adapter `capabilities()`（代码自报），`ttsSupportsVoiceCloning()` 取「或」 | 配置声明可能**高于**实现 → UI 显示「当前供应商支持克隆」但合成失败（false capability） | 能力判定统一为单一权威源，或对「配置 vs 实现」不一致显式告警 |
| 2-3 | `AppCore/Configuration.swift:223` vs `AIProvider.swift:43` | 中 | `vision` 同时存在于配置（`ProviderConfig.vision`）与能力面（`ProviderCapabilities.vision`） | 两处真源，读的人可能取错 | 收敛到配置（当前实现实际用配置） |
| 2-4 | `AppState.swift:128/234` | **高** | `remoteModels` 与 `externalModels` **双写同一份数据**（1836-1837 同帧写两处），而 `remoteModels` **零读取** | 两套真源 + 一套纯空转；后续维护者极易改错那一份 | 删除 `remoteModels`，统一用 `externalModels` |
| 2-5 | `AIInterfaces/OtherProviderInterfaces.swift:116,156` | 低 | `SpeechVoiceSelection.isCloned` 与 `TTSRequest.usesClonedVoice` 逻辑完全重复 | 同一判断两份实现 | 抽成一个工具/复用 |
| 2-6 | `AIProviders/RemoteLLMAdapter.swift:299` | 低 | `chatRequest(base:apiKey:request:config:stream:)` 的 `request/config/stream` 三个入参**完全未用** | 签名误导（看着像会按 stream/config 组请求体，实际只拼 URL+Header） | 收窄签名为 `chatRequest(base:apiKey:)` |
| 2-7 | `AIProviders/RemoteLLMAdapter.swift:299` / 同类 | 低 | 参数忽略见「表 4」未使用参数清单 | — | 同上 |

---

## 表 3 · 功能不完善 / 逻辑冲突

| # | 文件:行 | 严重度 | 现象 | 证据 / 影响 | 建议 |
|---|---|---|---|---|---|
| 3-1 | `AppState.swift:521,551,2682,2979` + `Views/VocabularyView.swift` | **高** | **「手动添加生词 + 输入联想」整条功能未接通**：`vocabularyDraft` / `vocabularySuggestions` / `vocabularyMatches` / `addVocabularyWord()` / `vocabularyDraftChanged()` / `pickVocabularySuggestion` 全套已建，但**没有任何 View 绑定**（仅 MainView:223 一个 launch-arg 探针引用） | 状态与联想引擎纯空转；用户无法手动加词 | 补 UI（词表页输入框 + 联想下拉 + 提交），否则删除整条链 |
| 3-2 | `AIProviderError.swift:40` | 高 | 重试策略未接线（同 1-1） | 断线/超时类错误无重试 | 见 1-1 |
| 3-3 | `Sources/AIInfrastructure/Resources/Config/default-config.json` | 中 | `local.tts`（Qwen3 :8855）enabled，`remote.kina-tts`（Edge 代理 :8856）**disabled** | 默认只走 8855；若本机未跑该服务，TTS 全链不可用且**无回退** | 确认默认启用项与用户实机一致；考虑健康失败时回退到另一 TTS |
| 3-4 | `MEMORY.md` 记录 vs `CoachServices.swift:298-449` | 中 | 记忆写「#24 音色克隆为设计预留、未实现」，实测**已端到端接通**（store/service/UI/`Qwen3TTSAdapter` 传 `referenceAudio`） | 记录过期会误导后续决策 | 更新记忆；并确认 clone 在真实 runtime 上的表现 |
| 3-5 | `AIInfrastructure/ModelRegistry.swift` + `CoachServices.swift:747-766` | 中 | `ModelRegistry` 只接通了 `enable`，读侧（listAvailable/getDefault/inconsistencies）全死 | 「统一 metadata/capability」设计目标未落地 | 见 1-2 |
| 3-6 | `Sources/AppUI/Components/TreeCanvas.swift:776,785` | 中 | `shuffleOnPerch` / `flyBackToGrass` 声明 5~6 个几何入参**全不使用**，4 个调用点仍逐次计算并传入 | 无谓计算 + 签名误导（注释自认「早先算过一次 home 但没用上」） | 收窄签名；`flyBackToGrass` 的 doc「落到离家最近的空位」与实现（直接 `.zero`）也不一致，需统一 |
| 3-7 | 参数清单见「表 4b」 | 低 | 34 处确证未使用参数（已排除长函数假阳性） | 主要影响可读性与「以为在用」 | 逐条清理或 `_` 标注 |

---

## 表 4 · 功能代码边界不安全

| # | 文件:行 | 严重度 | 现象 | 证据 / 影响 | 建议 |
|---|---|---|---|---|---|
| 4-1 | `Sources/AIInfrastructure/ConfigStore.swift:44-53` | **高（发布级）** | `AppPaths.projectRoot` 用**编译期 `#filePath`** 上溯找 `Sources`，且**不校验存在性** | 分发出去的 .app 里该路径是**构建机**的源码路径（用户机上不存在）→ `userDataDirectory()` 的 `createDirectory` 被 `try?` 静默吞掉 → **配置 / learning.db / 音色档案全部写不进去**。当前仅在本机开发环境成立 | 发布版必须改走 `Application Support`（用 `Bundle.main.bundlePath` / `Bundle.main.bundleIdentifier` 判定是否在 `.app` 内），并给写目录失败**可读报错**而非静默 |
| 4-2 | `ConfigStore.swift:69-70,84-85` | 中 | 默认配置加载失败 → 静默回退 `AppConfiguration()`（**空 providers**） | 应用会「一个 provider 都没有」却不给任何提示，难以排查 | 失败时至少 `AppLog.error` + 首屏提示 |
| 4-3 | 全仓 | 中 | **305 处 `try?`**，其中 `ProgressService`(19) / `TreeCanvas`(16) / `PromptBuilder`(15) / `LearningDatabase`(10) / `MainView`(9) 等**零 catch、零日志** | 关键写失败（进度落库、配置、记忆）无声丢失，事后无痕 | 对「写路径 + 关键读路径」的 `try?` 逐条审查，至少留一条 `AppLog.error` |
| 4-4 | `AIInfrastructure/SQLiteDatabase.swift:44,64-67` | 中 | `@unchecked Sendable` + `handle` 是可变的，`close()` 与查询并发时存在 use-after-free 窗口 | 当前调用方（启动/退出单点 close）应无并发，但**契约没有禁止** | 给 close 加「只允许在无并发查询时」的断言，或改用 `sqlite3_close_v2` + 引用计数 |
| 4-5 | `SQLiteDatabase.swift:104` | 低 | `runInTransaction` 不可重入（`BEGIN IMMEDIATE` 嵌套会失败） | 未来若在事务里再调事务会抛错 | 加嵌套保护（计数器/SAVEPOINT） |
| 4-6 | `AppCore/Logging.swift:62-65` | 低 | 日志全部以 `privacy: .public` 写 os_log | 现在靠纪律不放敏感内容；**无代码级护栏** | 提供 `private`/脱敏入口，或加编译期/运行期检查 |
| 4-7 | `AppUI/AppState.swift:762` 附近 | 低 | 手写 `init`（项目已知坑：新增无默认值的 `private var` 漏赋值不报错），属性已达 ~150 个 | 回归风险随属性数增长 | 尽量给新属性默认值；关键字段加测试断言 |

### 表 4b · 确证未使用参数（34 处，花括号匹配，已排除假阳性）

| 文件:行 | 函数 | 未用参数 |
|---|---|---|
| `AIDomain/AnnualRecap.swift:323` | `makeCell` | `calendar` |
| `AIDomain/GrammarAnalysis.swift:301` | `insertionCategory` | `original`, `corrected` |
| `AIDomain/PhonemeAssessment.swift:200` | `lengthened` | `consonant` |
| `AIDomain/Progress.swift:729` | `streak` | `calendar` |
| `AIProviders/RemoteLLMAdapter.swift:299` | `chatRequest` | `request`, `config`, `stream` |
| `AIProviders/MockProviders.swift:54 / 205` | `stream` / `evaluate` | `request` / `audioSamples` |
| `AppUI/Components/TreeCanvas.swift:776` | `shuffleOnPerch` | `count`, `span`, `inset`, `groundLine`, `quantizedWidth` |
| `AppUI/Components/TreeCanvas.swift:785` | `flyBackToGrass` | 同上 5 个 |
| `AppUI/Components/TreeCanvas.swift:961` | `facingAt` | `fallback` |
| `AppUI/Components/VocabularyReviewCard.swift:526` | `speakButton` | `text` |
| `AppUI/Components/WordLookupText.swift:366` | `tokenRange` | `container` |
| `AppUI/Views/LearningProgressView.swift:314` | `openStage` | `level` |
| `AppUI/Views/ScenarioPickerView.swift:454 / 565 / 610` | `questSection` / `levelSection` / `bullet` | `scenario` / `scenario` / `dotted` |
| `AIInfrastructure/AudioPlayback.swift:66,70`、`AIServices/PracticeReminderService.swift:143,161` | 协议回调 | 属 delegate 必需签名，**可忽略** |

---

## 表 5 · 组件功能实现逻辑不流畅

| # | 文件:行 | 严重度 | 现象 | 建议 |
|---|---|---|---|---|
| 5-1 | `AppState.swift`（5045 行，150+ 属性） | 中 | 单文件承担全部 UI 状态，`remoteModels` 这类残留即其产物；新增字段易漏改、易长生第二真源 | 按功能域拆分为多个 `@Observable` 子模型（对话/语音/阅读写作/词汇/进度），AppState 只做聚合 |
| 5-2 | `AIInterfaces/AIProvider.swift:98` | 低 | `public struct ProviderMetadata: Sendable, Equatable {    public var id: String` —— **同一行挤了两个声明**，格式破损（疑编辑事故） | 折行 |
| 5-3 | `AppUI/Views/ScenarioPickerView.swift:565` | 低 | `levelSection(_ scenario:...)` 的 `scenario` 未用 → 疑似「原按 scenario 分区」重构残留 | 收窄签名，确认分区口径 |
| 5-4 | `AIInfrastructure/ConfigStore.swift` 等 | 低 | `ProductConfig` / `ResourcePolicyConfig` / `AppConfiguration` 均手写 `Codable`（老配置兜底正确），但**新增字段要同时改 decode/encode/init 三处** | 用一个「缺省值表」驱动解码，降低三处漂移 |
| 5-5 | `Tests/`（122 文件 / 2.86 万行 / 1380+ 用例） | 低 | 全为 XCTest（0 个 Swift Testing）；单测目标未分片 | 见「构建建议」 |

---

## 表 6 · 构建 / 工程化完善与优化建议

| # | 项 | 优先级 | 现状 | 建议 |
|---|---|---|---|---|
| 6-1 | **发布版数据目录** | P0 | 数据落 `.workbuddy/app-config/`（靠 `#filePath`，见 4-1） | 发布版切 `Application Support`；`.app` 内判定用 `Bundle.main`，不要依赖源码路径 |
| 6-2 | 版本号 | P0 | `make_app.sh` 硬编码 `CFBundleVersion = 0.4.0`，与「v1.0」不符 | 版本号抽到单一来源（如 `Scripts/version.env` + `Package.swift`），脚本读取 |
| 6-3 | CI | P1 | **无 `.github/workflows`** | 加最小 CI：`swift build --build-tests` + `swift test` + `codesign --verify`；PR 必过 |
| 6-4 | Lint / Format | P1 | 无 `.swiftformat` / `.swiftlint.yml` | 引入 swift-format（Apple 官方）统一风格；先只对新增文件强制，避免全仓大 diff |
| 6-5 | 死代码防回归 | P1 | 死代码靠人工审查发现（本次 30+ 处） | CI 接 `periphery`（Swift 死代码扫描），把 `is-exported`/未用声明纳入门禁 |
| 6-6 | 构建时间/体积 | P2 | release 仅宿主机架构；无 LTO | 分发考虑 `--arch arm64 --arch x86_64` 通用二进制；发布版可开 `-Xswiftc -Osize` + LTO 压体积 |
| 6-7 | 资源包 | P2 | AIInfrastructure(2.0M) 与 AppUI(100K) 两个 `Bundle.module`，打包脚本分别硬编码 bundle 名 | 统一到一个资源 target（或脚本用通配匹配 `*.bundle`），减少打包脚本与 target 名耦合 |
| 6-8 | 测试分层 | P2 | 122 文件单目标，全量跑耗时 | 拆 `UnitTests` / `RenderTests`（离屏渲染慢）两个 target；日常只跑前者 |
| 6-9 | 提交节奏 | P2 | 工作区**未提交改动 252 项 + 未跟踪 147 项**（HEAD `c702312`），单次 diff 过大、审查与回滚都难 | 按功能原子提交（#232/#233、警告清零、输入框改造各一笔）；便于定位回归 |
| 6-10 | `dist/` 清洁 | P3 | 混入 2 张 ~5.5MB showcase PNG；`.DS_Store` 出现在仓库目录 | `dist/` 已在 `.gitignore`；建议清掉临时大图，只保留 `.app` |
| 6-11 | 资源引用 | P3 | `Scripts/icon.iconset/*.png` 全部显示 modified（二进制抖动） | 确认是否真的更新了图标；否则 `git checkout` 还原 |

---

## 建议的处理顺序（供排期参考）

1. **P0（发布前必做）**：4-1 数据目录、6-2 版本号
2. **P1（接通或删除，二选一）**：1-1 重试、1-2/3-5 ModelRegistry 读侧、1-16 能力面合并、3-1 手动加词 UI、2-4 `remoteModels` 删除
3. **P2（清理）**：表 1 其余死代码、表 4b 未使用参数、6-3~6-9 工程化
4. **P3（记录更正）**：3-4 更新 `MEMORY.md` 中 #24 的过期描述

> 表 1 / 1b / 4b 的每一条都可用「全仓引用计数」复现；表 4-1 与 3-1 建议人工复核后再决定补 UI 还是删代码。

---

## 处理结果（2026-09-20 晚 · 第一轮）

### 已处理

| 条目 | 处理方式 |
|---|---|
| 1-1 / 3-2 | 重试策略接上：`isRetryable` 在请求层有消费方 |
| 1-2 / 3-5 | `ModelRegistry` 读侧接通设置页「配置体检」（`AppState` 读 `modelConfigs` / `defaultModelConfig` / `registryInconsistencies` 三条投影） |
| 1-5 | `hasAcousticChannel` 接入发音卡 |
| 1-6 | 设置页「重新载入配置」（`AppState.reloadConfigurationFromDisk` → `configStore.reload()`） |
| 1-7 | 设置页日志级别选择 + 清空日志（`LogBus.setMinimumLevel` / `clear`） |
| 1-8 | 「在 Finder 中打开」落地（`NSWorkspace.activateFileViewerSelecting`）；附件 / 音色目录改从 `PrivacyDataLocator` 取，不再由 `AppState` 各存一份路径 |
| 1-9 | `llmLabel` / `materialKit(id:)` 删除 |
| 1-10 | `llmHealthDescription` 接通（体检行的「实际情况」文案） |
| 1-11 | `storageLocation` 接通（配置路径展示） |
| 1-16 | 能力面合并：`llmCapabilities()` 降为协议默认实现（`capabilities().llmView`），三个适配器的重复实现删除 |
| 1-17 | `wordTimestamp` 接通（Whisper 报 true 时启用词级对齐，体检行也说明该能力位） |
| 1b-1 / 1b-5 | 「手动添加生词 + 输入联想」整条链**删除**（`AppState` 的动作与候选池、`VocabularySuggestion`/`VocabularySuggester`、`WordBankEntry` 速查链、launch-arg 探针、对应单测）。理由见下 |
| 1b-2~1b-4 / 1b-6~1b-8 | 各补 UI 落点（取消语音输入 / 清空待发附件 / 关闭保存提示 / 取消删词库 / 停止跟读音频 / 关闭备份提示） |
| 1b-9 | 同 1-10 |
| 3-4 | 已在 `FEATURES.md`「克隆音色（#24）状态更正」更正（端到端实测接通） |
| 2-4 | `remoteModels` 第二真源删除（含写入点与旧 `fetchRemoteModels` 链路） |
| 4-1 / 6-1 | 数据目录改走 Application Support（不再依赖编译期 `#filePath`） |
| 5-2 | `ProviderMetadata` 挤在一行的两处声明折行 |
| 6-2 | 版本号单一来源 `Scripts/version.env`（打包脚本 + 应用内「关于」都读它） |
| 6-3 | 新增 `.github/workflows/ci.yml`：全量编译（含测试目标）→ 警告零容忍 → 全量测试 → 打包 + `codesign --verify` |
| 6-4 | 新增 `.swift-format`（按项目风格收紧，CI 里作**建议项**不阻断） |
| 3-1 | 按「保持词典页唯一入口」处理：查词 →「添加复习」是唯一加词路径，词汇本页只留一句指引（09-16 的既定决策，本轮确认后删代码） |

### 未处理（下一轮候选）

| 条目 | 现状 |
|---|---|
| 2-1~2-3 / 2-5 / 2-7 | 其余接口不一致（已核，剩的是「同名不同源」的语义重叠，改动牵涉行为，需单独评估） |
| 3-3 | 默认启用的 TTS 供应商（`local.tts` :8855 vs `remote.kina-tts` :8856）与实机是否一致待确认 |
| 5-1 / 5-3~5-5 | AppState 拆分、配置解码「三处漂移」（`ProductConfig` / `ResourcePolicyConfig` / `AppConfiguration` 手写 Codable）、测试分层 |
| 6-5~6-11 | periphery 接 CI、通用二进制、资源包统一、测试分片、原子提交、`dist/` 清洁、图标二进制抖动 |

---

## 处理结果（2026-09-20 晚 · 第二轮）

### 表 1 剩余死声明 → 全部删除（11 处）

| 位置 | 删除内容 |
|---|---|
| `AIDomain/ModelRegistry.swift` | `ModelMetadata`（与 `ProviderMetadata` 语义重叠的旧设计残留） |
| `AIDomain/WordForm.swift` | `looksInflected(_:)`（实际链路走 `candidates`） |
| `AIDomain/ChatAttachment.swift` | `isVideo`、`fileExtension`（存储文件名不走它） |
| `AIDomain/ConversationContext.swift` | `difficultyIsMaxed` |
| `AIDomain/ExamRunner.swift` | `elapsedSeconds(now:)` |
| `AIDomain/ExamScoring.swift` | `isWholeBand` |
| `AIDomain/ReleaseChecklist.swift` | `automatedItems`、`statusLabel` |
| `AIServices/VoiceService.swift` | `recordingLevel` |
| `AIInfrastructure/MicrophoneRecorder.swift` | `capturedSampleCount`，**级联** `level`（`recordingLevel` 删掉后它也没有消费方了） |

### 表 4b 未使用参数 → 收敛（34 处中的 32 处）

| 文件 | 处理 |
|---|---|
| `AIDomain/AnnualRecap.swift` | `makeCell` 去掉 `calendar` |
| `AIDomain/GrammarAnalysis.swift` | `insertionCategory` 去掉 `original` / `corrected` |
| `AIDomain/PhonemeAssessment.swift` | `lengthened` 去掉 `after consonant`（长音由元音符号本身决定） |
| `AIDomain/Progress.swift` | `streak` 去掉 `calendar`（只按数组顺序数连续段，不做日期对齐）＋测试调用点同步 |
| `AIProviders/RemoteLLMAdapter.swift` | `chatRequest` 收窄为 `(base:apiKey:)`（原签名误导成「会按 stream/config 组请求体」） |
| `AIProviders/MockProviders.swift` | `stream(_:)` / `evaluate(audioSamples:_:)` 用 `_:` 标注（协议必需签名，实现确实不看） |
| `AppUI/Components/TreeCanvas.swift` | `shuffleOnPerch` / `flyBackToGrass` 各去掉 5~6 个几何入参（只留 `index`），4 个调用点同步；`facingAt(index:fallback:)` → `facingAt(index:)` |
| `AppUI/Components/VocabularyReviewCard.swift` | `speakButton(_:)` → `speakButton()` |
| `AppUI/Components/WordLookupText.swift` | `tokenRange(atGlyph:in:layout:…)` 去掉 `container` |
| `AppUI/Views/LearningProgressView.swift` | `openStage(_:)` 用 `_:` 标注（回调类型要求收 `CEFRLevel`，但确实不用） |
| `AppUI/Views/ScenarioPickerView.swift` | `questSection(_:)` / `levelSection(_:)` 用 `_:` 标注 `Scenario`；`bullet(_:dotted:)` → `bullet(_:)` |
| `AIInfrastructure/AudioPlayback.swift`、`AIServices/PracticeReminderService.swift` | **保留**：属 delegate 必需签名，不是缺陷 |

### 另外两项

- 1-18：`enabledProvider(for:)` 补文档说明「仅供测试」（生产一律走 `resolvedProvider`）。
- 3-6 附带的注释不一致：`flyBackToGrass` 的 doc 与实现已对齐为「直接回家」。

> 本轮验证：全量重编（`touch` 全部源文件）**0 error / 0 warning**；全量测试 **1348 通过 / 0 失败**（1 skip）；`dist/AI_Language_Coach.app` 重打包 v1.0.0 (build 1)、`codesign --verify --deep --strict` 通过。

---

## 提交记录（2026-09-20 夜）

积压的工作区（274 项）已按模块落成 6 笔提交，HEAD 由 `c702312` 前进到 `2a46bb5`。**未推送**（仓库当前无远端配置）。

| 提交 | 内容 |
|---|---|
| `c7fd67f` | chore(工程化)：CI 门禁 + `.swift-format` + 版本号单一来源 + 图标母版与开发者脚本 |
| `68f397d` | feat(词典)：多词库查询 + 词形还原 + 划词卡片与词族（含三册词典 JSON） |
| `4ba6991` | feat(专项练习)：雅思考试模式 + 阅读理解 + 写作批改 + 学习材料库 |
| `fbaef56` | docs：代码审查报告 + 英文轨交互设计稿 |
| `981c61b` | feat(教学体验)：老师人设与语言守则 + 今日作业黑板 + 成长之树滚动 + 主题资源包 |
| `2a46bb5` | refactor(核心)：引擎/服务/配置收敛 + 审计清理（死代码与未使用参数） |

⚠️ **中间提交单独不保证可编译**：`AppState` / `ChatService` / `CoachServices` 横跨上面全部功能域，按功能做 hunk 级切分既高风险又拿不到收益（谁也不能单独跑）。可编译、已验证的边界是 **HEAD** —— 本报告的全部验证数据取自它。

---

## 剩余条目排期（行为级）

### 一、已核清 / 无需动手

| 条目 | 结论 |
|---|---|
| 6-9 提交节奏 | ✅ 本轮完成（见上表） |
| 6-11 图标二进制抖动 | ✅ 已核：**不是抖动**。`Scripts/icon.iconset/*.png` 与改动前哈希不同，且新增母版 `Scripts/brand/yulin-app-icon.png` —— 确实重新出过图，**不要** `git checkout` 还原 |
| 2-1 两套能力面 | ✅ 已成单一真源：`LLMCapabilities` 改为 `ProviderCapabilities.llmView` 投影，不再各自实现一遍 |
| 2-5 克隆判定重复 | ✅ 已抽 `ClonedVoiceRule.isCloned(referenceAudioPath:)`，两处共用同一口径 |
| 2-6 / 3-7 / 4b 未使用参数 | ✅ 第二轮已收敛 |
| 5-3 `levelSection` 未用参数 | ✅ 第二轮已处理 |

### 二、P1 · 会改功能或 UI —— 需确认后动手

| 条目 | 现状与风险 | 备选方案 |
|---|---|---|
| **3-3 默认 TTS 供应商** | `local.tts`(:8855 Qwen3 + `voiceCloning`) **enabled**、`remote.kina-tts`(:8856 免密钥 Edge 代理) **disabled**。实机若只跑 8856，则开箱 TTS 全链不可用且**无回退** | ① 默认切 8856（开箱即有声）② 保持 8855 ③ 默认不动 + 健康失败自动回退 |
| **2-2 克隆音色能力判定** | `CoachServices.ttsSupportsVoiceCloning()` 当前是「**配置声明为真就直接 true**」（`CoachServices.swift:317-321`）→ 配置写了 `voiceCloning` 而适配器实际不支持时，UI 显示可用、点下去合成失败（false capability） | ① 改为「实现为权威，配置只作闸门」② 保留「或」但对不一致显式告警 |
| **5-1 AppState 拆分** | 5136 行 / 150+ 属性承载全部 UI 状态，`remoteModels` 这类残留即其产物 | ① 单独排期（推荐）② 只搬「纯函数 / 常量 / 几何」到独立文件（不动类型与调用点）③ 本轮完整按域拆分 |

### 三、P2 · 不动 app 行为，但动工程边界

| 条目 | 内容 | 风险 |
|---|---|---|
| 5-4 | 配置解码改「缺省值表」驱动（`AppConfiguration` / `ProductConfig` / `ResourcePolicyConfig` 手写 `Codable`，新增字段要同时改 decode/encode/init） | 中：触及老配置兼容 |
| 5-5 + 6-8 | 测试拆 `UnitTests` / `RenderTests` 两个 target（59 个渲染用例落位），日常只跑前者 | 中：动 `Package.swift` 与测试目录 |
| 6-5 | CI 接 `periphery` 死代码门禁（本机未装；CI 里先只告警不阻断） | 中 |
| 6-7 | 资源包统一（现为 `AIInfrastructure` / `AppUI` 两个 `Bundle.module`，打包脚本硬编码 bundle 名） | 中高：动 Bundle 访问路径，历史上踩过「静默取不到 → 走兜底」 |
| 6-6 | 通用二进制（arm64 + x86_64）+ `-Osize` / LTO | 中：产物变大，属发布配置 |

### 四、P3 · 本地清理

| 条目 | 内容 |
|---|---|
| 6-10 | `dist/` 内两张 showcase 大图（`yulin-showcase-studio.png` 2.3M、`yusen-showcase-studio.png` 3.1M）与 `.DS_Store`。`dist/` 已在 `.gitignore`，属**本地**清理 —— 动手前会先列清单等确认 |

---

## 执行结果（2026-09-20 深夜 · 第三轮 · P1/P2 落地）

### 本轮拍板

| 条目 | 用户选择 |
|---|---|
| 3-3 默认 TTS | 切到 8856（免密钥 Edge 代理） |
| 2-2 克隆能力 | 实现为权威，配置只作闸门 |
| 5-1 AppState 拆分 | 单独排期 |
| P2 工程选做 | 四项全做 |
| 隐私判定语义（本轮新发现） | **回环即本机** |

### 落地

| 提交 | 条目 | 内容 |
|---|---|---|
| `701df5f` | 3-3 + 2-2 | 默认 TTS 切 `remote.kina-tts`（8856）；克隆能力判定改「实现为权威」 |
| `0f0c8a7` | 5-4 | `ProductConfig` 解码兜底改取默认 init，往返断言兜底 |
| `1b38da9` | 6-7 + 6-6 | 资源包通配拷贝 + release 目录自适应 + `--universal`/`--optimize-size` 开关 |
| `91c4dcd` | （新） | **隐私：回环端点不算外发** —— 默认 TTS 换成回环 8856 后，`privacy.noUnintendedNetwork` 与 6 个隐私用例全红；判外发的尺子改为「数据出不出机器」而非 runtime 标签 |
| `b60ee5f` | 5-5 + 6-8 | 32 个渲染用例拆到 `Tests/RenderTests/` 独立 target |
| `122bfa8` | 6-5 | periphery 接入（`.periphery.yml` + CI 建议项 job，**刻意不做门禁**） |
| `074d5a3` | 6-6 | **`--universal` 真正可用**：`main.swift`→`AppMain.swift` 避开 xcodebuild 的 top-level/`@main` 冲突；改「两架构各编一次再 lipo」 |

**验证**：全量 `swift test` **1357 通过 / 1 skip / 0 失败**；`dist/AI_Language_Coach.app` 重打包 14M · arm64 · v1.0.0 (build 1)，`codesign --verify --deep --strict` 通过。未推送（仓库无远端）。

### 6-6 体积 / 架构实测（strip -x 后）

| 变体 | 主二进制 | .app 总体积 | 说明 |
|---|---|---|---|
| release `-O`（arm64，现状） | 9.6M | 14M | 当前默认 |
| release `-Osize`（arm64） | **8.3M** | — | **-13%**，`make_app.sh --optimize-size` 一键切换 |
| release 通用（arm64 + x86_64） | 19.8M | 24M | `make_app.sh --universal` |

结论：**单架构 + `-Osize` 是性价比最高的一档**（-13% 体积，代价是峰值性能略降）；通用二进制只在要分发给 Intel 机器时才值得（+108%）。两者都只是打包开关，默认行为未变。

### periphery 清理轮（85 → 0，`c0eb54a`）

| 类别 | 处理 |
|---|---|
| 60 条未用 import（53 文件） | 纯机械删除，全为第一方模块的历次重构遗留 |
| 5 处未用参数 | 删（`monthMarkers -calendar`、`fundamentalFrequency -hop`、`perchStubs -height`、`ensureResidents -count`）；`LearningDatabase.decodeJSON` 的 `as type:` **改实现真用它**（API 形状，删了调用方推不出类型） |
| 5 处未用函数 | 删（`littleEndian`、`CursorGuard.uninstall`、`registryCheckRow`、两个测试助手） |
| 9 处未用属性 | 删（4 个组件的 `@Environment theme`、`chalkLine`、`titleRowContentWidth`、`stageHeight` 等） |
| 6 处赋值即弃 | 删（`TreeCanvas`/`TreeScrollView` 的 `bubblesAllowed` 死传递链——真消费方是 `ForestGroundBand`，MainView 直连；测试结构体里只塞不读的 `size`/`expanded`/`darkByColumn`） |
| `ProviderStateBox.lifecycle` | **保留** + `periphery:ignore` + 说明：规范 v2.0 §27 要求维护这条状态机，目前只写不读 |

**验证**：全量 touch 重编 0 警告；`swift test` 1357 / 1 skip / 0 失败；复扫 85 → 0。

### 清理轮发现的两个真接线缺口（不是死代码，待拍板）

| 缺口 | 现状 |
|---|---|
| ① 录音无法取消 | `ChatView.cancelVoiceButton`（`.help`/无障碍齐全，闭包已接 `state.cancelVoiceInput()`）**从未被放进任何 body** |
| ② 配置体检 UI 没挂上 | `SettingsView.runtimeCard` 整张「运行环境」卡（版本 / 配置位置 / 配置体检 / 重载）从未被渲染；`AppState.registryCheckRows` 有数据无消费 —— #258 补的 UI 实际没接上 |

### 第四轮（22:40–23:25）：剩余项清零

| 条目 | 处理 |
|---|---|
| AppState 拆分（5-1 / #267） | **已做** `41dc696`：5136 → 主文件 1436 行 + 14 个 `AppState+<域>.swift`（126–631 行） |
| `dist/` 本地清理（6-10 / #272） | **已做**：两张 showcase 孤本图（5.2M，无母版、git 未跟踪）与 `.DS_Store` 移入废纸篓，可恢复；dist/ 只剩现役 `.app` |
| 缺口① 录音无法取消（#274） | **已接通** `2c358f5`：录音态输入行、麦克风左侧插入 `cancelVoiceButton`（用户拍板位置） |
| 缺口② 运行环境卡（#275） | **已接通** `2c358f5`：挂在设置页「存储与缓存」之后；`.task` 补 `refreshRegistryCheck()` |

#### #267 拆分细则

- 主文件留：三个公共支撑类型 + 全部存储状态 + 启动 + API Key 草稿 + 主题/进度/学习设置/森林伙伴/页面切换
- 14 个域：黑板 · 模型启停 · 语音+克隆音色 · 附件+气泡翻译 · 模型管理中心+审计 · 进度+提醒 · 写作+阅读 · 词汇本 · 词典 · 划词 · 跟读 · 情景+练习生命周期 · 考试模式 · 缓存+运行环境+备份
- **两条必要代价**：81 处行首 `private`/`private(set)` → internal（跨文件扩展要读写状态）；154 处 `public private(set)` → `public internal(set)`（被移出的方法要写这些状态，外部模块仍只读）
- **两个特例**：MARK 段不等于「纯方法段」——划词段混着 `lookupBubble`/`wordLookupCard` 等 5 个存储属性，扩展放不下，留驻类体；`periphery:ignore` 行内接中文破折号会解析失败，必须 ASCII `-`

#### #274 / #275 的验证边界（诚实记账）

自动断言在此**测不了**：离屏 `NSHostingView` 里 SwiftUI Button 不桥接 AX（探针实测树上 0 个 `NSButton`、`accessibilityLabel` 不落地；`accessibilityChildren` 递归走会 `fatalError`），合成点击也不可行。按「离屏渲染 + 人眼复核」纪律出三张证据图核过：录音态右簇 `× → 波形 → 发送`（取消键在场）、非录音态只有 `麦克风 + 发送`（反证成立）、设置页整页中「运行环境」卡落在「存储与缓存」与「高级」之间。

**验证**：全量 touch 重编 0 警告；`swift test` 1357 / 1 skip / 0 失败；periphery 复扫 0 发现。审计表 1–6 至此**全部清零**。


