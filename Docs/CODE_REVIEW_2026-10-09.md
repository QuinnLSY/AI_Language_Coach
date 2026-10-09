# 代码审查报告 · 鲁棒性与边界安全（第二轮）

日期：2026-10-09　｜　范围：`Sources/` 293 个 Swift 文件 / 84,590 行（排除 Tests / Scripts / .build）
前置：`Docs/CODE_REVIEW_2026-09-20.md`（死代码 / 接口一致性）与其后续三批修复
（止血 ①②③④：`ed22a78` → `870b32b` → `f29d01f` → `4343980`）已入库，本报告只列**存量遗漏与新发现**。

> 方法论：五路并行只读取证（错误处理 / 并发内存 / 输入边界 / 凭据安全 / UI 状态机），
> 对最高危的 6 条做了**实测与源码定点核实**，核实结论见每条的「已核实」标记。

---

## 核实结论先行（避免把推测当结论）

| 核实项 | 做法 | 结论 |
|---|---|---|
| `("attachments/.." as NSString).lastPathComponent` | 编译实跑 | **= `".."`**，拼到目录上即数据目录本身。但当前 `storedPath` 只由本进程 `importFile` 生成 → 尚无外部输入路径，判为**加固项 P1**，不是现网漏洞 |
| 浮层是否互斥 | 读 `AppState+Scenario.swift:47-50` | **不互斥**：`openMaterialUpload()` 不关 `showingScenarios`。上一批 `View+EscapeToClose.swift` 注释写的「同屏最多一个 ESC 挂载点」**前提错误**，是我上一批的诊断错误 |
| 回环判定 vs 系统代理 | 读 `HTTPClient.swift:62-90` + 五个 Adapter init | `HTTPClient` 默认绕代理，但五个 RemoteAdapter **默认 `useSystemProxy: true`**；默认 TTS（端点 `127.0.0.1:8856`）被判为「不外发」→ 口径与真实链路相反 |
| `try!` / `as!` / `fatalError` / `precondition` / `unowned` / IUO | 全仓扫描 | **均为 0 处**，这方面历史纪律很好 |
| Timer / Notification / LocalMonitor / URLSession / Semaphore 泄漏 | 全仓扫描 | **均无问题**：4 处 `addLocalMonitor` 全配 `removeMonitor` + 幂等守卫；URLSession 全 `invalidateAndCancel()`；零 `DispatchSemaphore` |

全仓 `try?` 共 **376 处**（AIInfrastructure 144 / AIServices 107 / AppUI 103 / AIProviders 13 / AIDomain 7 / AppCore 2），
其中落在**写 / 删 / 落盘**路径上约 **60 处**。显式空 `catch {}` 仅 2 处。
**最刺眼的一条**：仓库已建好「落库失败计数 + 用户可见横幅」兜底（`CoachServices.recordPersistenceFailure`，15 处调用），
但下面的 S1-2 一批 `try?` 直接绕开它——这些写入失败时计数器不增、横幅不亮，是全仓最难被察觉的一类静默失败。

---

## 批次 S1 · 静默失败（推荐优先）

> 共同症状：**用户以为成了，实际没成**，且没有任何出口能发现。

| # | 位置 | 问题 | 为什么有害 |
|---|---|---|---|
| S1-1 | `ConfigStore.swift:135`（`reload()` 同款 `:158`） | 用户层 `config.json` 读失败被 `try?` 吞掉，配置退成纯内置默认；此后任何 `mutate*` / `updateProduct` 都会 `try persist()` 把这份默认**整份写回** | 用户的 API Key 与自定义供应商被**永久抹掉**，且无任何提示。这是全仓后果最严重的一条。**已核实** |
| S1-2 | `CoachServices.swift:1682`（星星/关卡进度）、`:2074`（写作交卷）、`:2100`（阅读答题）、`SessionReviewService.swift:266`（会话复盘）、`VocabularyService.swift:373`（SRS 复习调度）、`:430`（花了真钱的 LLM 释义）、`ShadowingService.swift:153/189`（跟读成绩）、`CoachServices.swift:1969/1975`（情景进度与重练清理） | 写入失败全部 `try?` 吞掉 | 绕过 `recordPersistenceFailure` → 「学习记录有 N 次没保存成功」横幅**永远不亮**。最好的给用户备案都已落地，却绕开了 |
| S1-3 | `AppState+Maintenance.swift:410` | `try? await services.updateProduct(product)` —— 全仓配置落盘唯一入口（约 35 个调用点）失败无留痕 | 自动备份开关、学习目标、音色、模型选择等「改了重启还原」 |
| S1-4 | `ConfigStore.swift:243 persist()` | 写盘失败只 throw、连一条日志都没有 | 与 S1-1 叠加时构成「读失败 → 写всии回覆盖」的闭环 |
| S1-5 | `CoachServices.swift:1193`、`:1217` | 空 `catch` 吞掉本地服务启停失败 | 用户点了「关闭」以为进程停了，实际还占着显存；开屏自动拉起 TTS 失败全无声 |
| S1-6 | `DataBackup.swift:295`、`:362` | 恢复暂存目录清理失败无声 + 旧库 `-wal/-shm` 删除失败后仍真删主库 | 上一次残留的旧库 WAL 混进新库 → 打不开或内容错乱，而 UI 报「已从备份恢复」 |
| S1-7 | `DataResilience.swift:47` + `CoachServices.swift:174` | 坏库隔离失败（返回值丢弃）时仍告诉用户「文件保留在 corrupted 目录里，没有被删除」 | 用户以为有备份可捞，实际已被覆盖。提示方向相反，比无声更坏 |
| S1-8 | `DictionaryCatalog.swift:293`、`RemoteCallAudit.swift:176` | 导入词典词表 / 调用留痕写失败无声 | 前者「导入成功」重启变空壳；后者让账单对账数据凭空少一段 |

---

## 批次 S2 · 备份、凭据与执行边界（含我上一批的诊断错误）

| # | 位置 | 问题 | 说明 |
|---|---|---|---|
| S2-1 🔴 | `View+EscapeToClose.swift:11` + `MainView.swift:92/97/102` | **注释前提错误**：浮层**不互斥**，同屏可有两个以上 Esc 挂载点 | **我上一批写的代码**。情景面板里点「上传材料」→ 两者并存 → Esc 命中不定 → 关错层，材料浮层孤悬。修正方向：栈式管理（只有栈顶响应 Esc）或打开上层时主动关下层 |
| S2-2 | `DataBackup.swift:35` | 备份 zip 明文打包含全部云端 API Key 的 `config.json`，无加密、无提示 | 自动备份周期性产出含密钥的包；用户把包发给他人求助 = 交出全部密钥 |
| S2-3 | `DataBackup.swift:395-424` | 解包不校验 zip 成员路径（Zip Slip 面）、不设条目数 / 解压体积上限，`locateFile` 递归任意深度 | 依赖 `ditto` 内部行为；与删除备份那条路径的严格校验形成反差 |
| S2-4 | `DataBackup.swift:357-384` | 恢复时用 `removeItem` 永久删除现有 `learning.db` / `config.json`，不进废纸篓、非原子 | 中途 `copyItem` 失败 = 旧库已删、新库半拷；唯一的「恢复前」包会被 `prune` 清掉 |
| S2-5 | `ConfigStore.swift:256` | API Key 明文落盘、`0644`、无 `.completeFileProtection` | 同机其它进程 / Time Machine / 同步盘直接可读；每次改主题、改语速都会再写一遍（密钥副本随操作线性增长） |
| S2-6 | `LocalServiceRunner.swift:33-48` + `CoachServices.swift:1209/1239` | 配置文件里的 `service_start/stop_command` 直接 `/bin/sh -lc` 执行，无白名单无确认；且**开屏自动拉起** | 配合 S2-3（恶意备份覆盖 config.json）是完整的「导入备份 → 重启 → 任意命令执行」链 |
| S2-7 | `MainView.swift:207-234` | 生产 target 残留命令行钩子（`--import-backup` 等），写固定 `/tmp/alc-hook-debug*.txt`；导出路径直接取命令行 | 固定 `/tmp` 路径可被预置符号链接；建议收进 `ALCBench` / `ALCReleaseCheck` 或 `#if DEBUG` |
| S2-8 | `PrivacyPolicy.swift:117` + 五个 RemoteAdapter | 外发披露只看 `runtime == .remoteAPI`；回环被判「不外发」但 `useSystemProxy: true` | **已核实**。默认 TTS 端点 `127.0.0.1:8856` 走系统代理，而 UI 说「全部数据仅在本机处理」。两处各说各话，应共用同一个判据 |
| S2-9 | `PrivacyPolicy.swift:54-56` | 披露只覆盖 llm/asr/tts，漏 embedding 与 pronunciation | 「学习记忆永不出本机」的注释断言已不成立（错句原文会发往嵌入服务） |
| S2-10 | `CredentialText.swift:41` + `RemoteAuthDiagnostics` | 401 文案回显密钥末 4 位 + 位数 + 地址 + 服务端原文，直达 UI | 社工与撞库旁信息；服务端原文最长 200 字符未脱敏 |
| S2-11 | `DataBackup.swift:107-133` + `:152` | 备份保留策略被「文件名无时间戳」绕过 → 外部包永远排最前，`prune` 先清掉本应用产的旧包 | 备份目录长期只增不减 |
| S2-12 | `RemoteCallAudit.swift:39-44` | 留痕路径可被环境变量 `ALC_REMOTE_CALL_LOG` 任意重定向，无白名单 | 与 `:167-180` 的 `.atomic` 覆写回退组合，可用于抹除对账证据 |
| S2-13 | `AttachmentStore.swift:82-92`、六个资源 store | 删除用户资产（附件 / 词典 / 材料 / 场景 / 音色）一律 `removeItem`，不进废纸篓 | 项目里 `trashItem` 的正确做法只用在备份包上——恰恰是最不该优先保护的那一项 |

---

## 批次 S3 · 并发、资源与生命周期

| # | 位置 | 问题 | 症状 |
|---|---|---|---|
| S3-1 🔴 | `AudioPlayback.swift:43-57` | `withCheckedContinuation` 无取消处理 + **丢弃 `player.play()` 的 Bool 返回值** | 音频设备被 Zoom/会议独占时 `play()` 返回 false → delegate 永不回调 → 朗读态永久转圈；`park` 与 `play()` 之间无锁，`stop()` 可插入导致刚开头就静音 |
| S3-2 🔴 | `LocalServiceRunner.swift:53-82` | async 外壳下同步阻塞；管道不排空（子进程输出超 64KB 即死锁）+ 不检查 `Task.isCancelled` | 服务脚本忽略 SIGTERM 时 `readDataToEndOfFile()` 永不返回 → 协作线程池被逐条占死 → 界面还能点但什么都不发生，只能强杀 |
| S3-3 🔴 | `DataBackup.swift:199-216` / `:404-424` | actor 方法内 `waitUntilExit()` + `readDataToEndOfFile()` 同步阻塞 | 压几百 MB 库期间 `snapshots/prune/deleteBackup` 全堵住；自动备份后才 `prune`，两者互相排队 |
| S3-4 | `LocalServiceRunner.swift:33-48 launch()` | `Process` 出作用域无人持有、无人 reap | 每次手点「启动」留一个僵尸进程，一天十几次，`ps` 里一堆 `<defunct>` |
| S3-5 | `RemoteCallAudit.swift:160-180` | `remote-calls.jsonl` 只增不减、无轮转；回退分支用 `.atomic` **整体覆写**而非追加 | 一次瞬态失败把历史留痕截断成一条；文件长期长到几百 MB，且不在 `CacheManager` 清理范围（用户看到占了 800MB 却清不掉） |
| S3-6 | `DictionaryService.swift:32` / `Dictionary.swift:1202` / `AppState.swift:2031` | 三处以用户词为键、**无任何淘汰路径**的字典 | 对照正确做法 `MarkdownText.parseCache`（cap 64）；Service 层与 UI 层还各存一份重复数据 |
| S3-7 | `VoiceService.swift:425-443` | 命中判断与写入之间夹一次 `await` → FIFO 淘汰失效、键重复入队 | 同一句重复合成（多烧一次真金白银的请求），且缓存的是整段 WAV |
| S3-8 | `ChatService.swift:497-522` / `:304-310` | 插入与删除各自 fire-and-forget，跨 Task 无顺序保证 | 「删掉的消息下次打开又回来了」：删除 Task 先于插入 Task 落到库上 |
| S3-9 | `AppState.swift:1458` / `ModelLifecycleManager.swift:30` | `[weak self]` 是假保护：Task 被 `self` 自己的属性持有 → `guard let self` 恒真；`stop()` 在 Sources 内零调用 | 注释「析构后自然退出」与代码事实相反，是一条永不熄灭的心跳 |
| S3-10 | `MicrophoneRecorder.swift:57-114` | TOCTOU：check 与 set 之间一整段无锁代码；并发进入会覆盖 engine 引用 | 目前靠唯一调用方是 actor 兜住；任何新的 `@MainActor` 侧录音入口双击麦克风就会漏一个常开引擎 + tap |
| S3-11 | `TreeCanvas.swift:1571-1603` | 一次起 24+ 个未持有、不可取消的 Task | 切板块后仍继续把已站好的队伍拽走一只（`:1531` 注释已承认该现象） |
| S3-12 | `AudioPlayback.swift:158-198` | 变速播放的三条抛错路径不清理临时文件 | 每次点朗读在 `/tmp` 留一个孤儿 WAV |

---

## 批次 S4 · UI 状态机与异步回填

> 共同症状：**用户的操作被静默丢弃 / 结果张冠李戴**。

| # | 位置 | 问题 | 复现序列 |
|---|---|---|---|
| S4-1 🔴 | `ChatView.swift:800-805` | 流式期间三处 `scrollToBottom` 全部无条件执行，**不读已算好的 `isScrolledUp`**（`:178`） | 生成回复时往上翻看历史 → 每来一个 token 被拽回底部，上翻阅在生成期间完全不可用 |
| S4-2 🔴 | `AppState+Shadowing.swift:363-390` | `isShadowingBusy` 在评测开始前就置 false；回填不校验「还是这一句吗」 | 评分结束瞬间点「下一句」→ 旧句的评测结果覆盖新句卡片，屏幕上「第 4 句」挂着第 3 句的成绩（落库是对的，错的是界面） |
| S4-3 🔴 | `AppState+Listening.swift:115-142` | 播放按钮无 `.disabled(isPlaying)`；三次 await 后回填不校验 | 重复点 → 音频叠着放、「已听 2 遍」虚高；播放中点下一句 → 旧句的遍数与报错记到新句头上 |
| S4-4 | `ChatView.swift:545-562` + `AppState+Scenario.swift:301` | 「开启新练习」整段 await 期间无 busy 标志 | 双击 = 复盘两次 + 会话 id 连跳两级 + 开场白出两条或被静默吞掉 |
| S4-5 | `PlacementSheet.swift:308` | 「重测一轮」漏 `.disabled(isPlacementLoading)`（同卡「开始摸底」有） | 出卷期双击 → 两张同卷覆盖，或两张不同卷交错落 |
| S4-6 | `AppState+Shadowing.swift:165-196` | `isShadowingLoading` 在两个 await 之后才点亮 | 双击「换一批」= 两次真实 20 句模型请求，付两份 token，练一半的句子整批变一次 |
| S4-7 | `ChatService.swift:1239-1281` | 翻译在途结果回填不复查（对比 `performGlobalSearch` 有世代校验） | 翻译途中编辑重发该条（保留同一 id）→ 新正文下挂着旧正文的译文 |
| S4-8 | `AppState.swift:216` vs `AppState+Shortcuts.swift:144` | 「有没有浮层盖着」两份互不一致的真源，各自漏项 | 定级浮层 / 考试报告 / 全局搜索组合下，划词气泡压在最外层导致命中错乱 |
| S4-9 | `ChatView.swift:380-385` | 自动朗读只看 `count > 0`，不看是变多还是变少 | 删除一条消息后自动朗读**上一条早已存在的**回复 |
| S4-10 | `WritingView.swift:350` | diff 实时拿「此刻草稿」对比「上次提交的改写」 | 不收起批改卡直接改稿 → 用户自己刚改的词被标成「老师改的」 |
| S4-11 | `AppState+Shadowing.swift:269-308` | 切句 / 切粒度不停在途音频 | 段落听示范中切段 → 上一段声音继续念完，按钮状态归属到新段 |
| S4-12 | `AppState+Voice.swift:148` | 朗读无世代令牌 | 连点两条「听老师读」→ 前一条的合成仍在队列，用户以为停了声音继续出 |

---

## 批次 S5 · 输入边界与潜藏崩溃

| # | 位置 | 问题 | 触发条件 |
|---|---|---|---|
| S5-1 | `ExamMode.swift:47` + `:59-74` | `ExamStage` 声明 `Codable`，合成的 `Decodable` **不调用钳制 init**，逐属性直赋 | 素材 JSON 写 `"timeLimitSeconds": 0` → 每题起表即超时 → 全被跳过却照样出成绩单（假成功） |
| S5-2 | `ExamMode.swift:243-251` | `prompt(forQuestion:)` 对 `number ≤ 0` 直接取 `prompts[-1]` | `questionCount == 0` 时 `questionNumber` 算出 0 → **越界崩溃**；目前靠调用方恰好不传 0 躲过 |
| S5-3 | `Vocabulary.swift:8` vs `:67` / `:126` | 同款式：`Codable` 绕钳制 → `mastery` 可为负 → `intervalDays[-3]` | 潜伏项：一旦加单词本导入 / 云同步即成真崩溃 |
| S5-4 | `HTTPClient.swift:195-217` | SSE 行缓冲只有遇 `\n` 才清空，无长度上限（错误路径反而有 512 上限） | 连到被劫持/自建端点持续吐字节永不换行 → 内存单调增长 |
| S5-5 | `RemoteCommon.swift:428-453`、`WhisperASRAdapter.swift:191` | multipart 字段名值未转义，且 `boundary` 是**编译期常量**（不需猜）；`model` 来自手填或 `GET /v1/models` 返回 | 恶意端点返回带 `\r\n--boundary` 的 model id → 请求体结构被改写 |
| S5-6 | `RemotePronunciationAdapter.swift:189` | `language` 手填后直接拼进 query，未编码（对比 `RemoteTTSAdapter` 用了 `URLQueryItem`） | 填 `en-US&format=simple&x=1` 改写 query；填 `en US` → URL 为 nil 且看不到真实原因 |
| S5-7 | `LearningDatabase.swift:500-513` | 删除消息的 `IN` 子句不分页 | 长会话点「重新生成」→ 上千占位符越过 `SQLITE_MAX_VARIABLE_NUMBER` → 整批回滚，**界面消息已消失、库里一条没删**，下次启动整批复活 |
| S5-8 | `AppState+Scenario.swift:63`、`CoachServices.swift:477` | 材料导入只查扩展名不查体积；音色参考音频连扩展名以外什么都不查 | 选个 800MB txt 整份读进内存；4GB 音频直接写满数据目录，把学习库和配置一起写挂 |
| S5-9 | `DataBackup.swift:452` | 校验阶段整读 `config.json`（同函数里 SQLite 只读 16 字节头） | 塞几百 MB JSON 的包在**用户还没确认导入**时就撑爆内存 |
| S5-10 | `ExamMode.swift:172-232` | 「某一环节 prompts 为空」的卷不被过滤 | 进入该环节后静默停摆，只能靠超时逐题爬过去，无任何错误提示 |
| S5-11 | `SQLiteDatabase.swift:139` | `PRAGMA user_version=\(version)` 字符串插值 | 参数是 `Int` 无注入面，但它是全库**唯一**一处插值 SQL，容易被人照抄成真注入 |
| S5-12 | `LearningDatabase.swift:470`、`1413` | 会话消息不分页；四张表各一次无约束全表计数 | 长会话（上万条）启动时一次性全表物化 |

---

## 建议处理顺序

| 批次 | 主题 | 条目 | 特点 |
|---|---|---|---|
| **S1** | 静默失败 | 8 | **推荐先做**。改的是「发现了怎么告诉用户」，行为变化最小、收益最高；已有 `recordPersistenceFailure` 兜底可接 |
| **S2** | 备份 / 凭据 / 执行边界 | 13 | 含 S2-1（我上一批的诊断错误，必修）。部分条目涉及产品口径（是否剥离密钥出备份）需你拍板 |
| **S4** | UI 状态机 | 12 | 用户每天都在撞（尤其是流式打断上翻、跟读张冠李戴），但需要你确认期望行为 |
| **S5** | 输入边界 | 12 | 多数是潜伏崩溃，改起来是加 guard / clamp，风险低但收益要等将来 |
| **S3** | 并发与资源 | 12 | 技术债最重（要改 Process/continuation 结构），但症状一旦发生就是「应用假死」 |

最后一列里「需你拍板」的，我会在动手前单独问一次。
