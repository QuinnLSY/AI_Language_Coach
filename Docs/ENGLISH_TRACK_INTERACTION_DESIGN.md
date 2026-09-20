# 英语板块功能交互设计梳理

> 对应任务 #203。**本文只做设计，不改任何行为。**
> 目的有两个：① 把「学员在各板块之间怎么走」写清楚；② 把当前**隐含的英语假设**逐条列出来，
> 收拢成单一取数点，让将来加第二种语言时不用满仓库找字面量。
>
> 已定的范围边界（用户明确过，不要推翻）：当前版本**只做英语**；不多语言、不首启引导、
> 不多档案、不做发布。所以本文的「接缝」不是要现在就动，而是**先把口子留在对的地方**。

---

## 一、板块地图（入口与状态流转）

侧栏 7 项的顺序、文案、图标、快捷键编号全部来自 `AIDomain/AppSection.swift`（唯一定义）。
设置是**浮层**、不是页面（见 `AppState.activeSection` 注释：打开设置不关底下那一页）。

```
                         ┌──────────── 侧栏 AppSection（⌘1…⌘7）────────────┐
                         │
   ①练习(⌘1) ──┬─► 情景对话浮层 ──► 选情景 ──► 起情景 ──► 闯关判定 ──► 自动复盘
               │        ▲                                              │
               └─► 随口练（freeTalk，无情景）                            │
                                                                       ▼
   ②跟读(⌘2) ──► 今日 20 句（按情景生成）──► 听示范 ──► 录音 ──► 逐词对齐 ──► 发音报告
                                                                       │
   ③词典(⌘3) ──► 词典库（3 本）──► 查单词 ──► 词族树                        │
                                                                       │
   ④词汇本(⌘4) ─┬─► 添加/移除/朗读                                      │
               └─► 开始复习 ──► 复习会话（认识/忘了）──────────────────────┤
                                                                       ▼
   ⑤学习进度(⌘5) ◄── ProgressAggregator ◄──────────────────── 全部落库 learning.db
   ⑥学习记录(⌘6) ◄── AnnualRecap（年历 + 最近错题）
   ⑦设置(⌘,)：浮层，覆盖在任意页之上
```

### 1. 练习（默认页）
- **入口**：启动默认落在这一页；侧栏 ⌘1；`openPractice()`。
- **两条支路**：
  - **情景对话**：`openScenarios()` 开浮层 → 卡片展开选情景 → `startScenario()`。
    落库 `sessions.mode = .conversation`，绑定 `scenario_id`。
  - **随口练**：`startFreeTalk()`。`sessions.mode = .freeTalk`，**不绑定情景**。
- ⚠️ **模式唯一真源是 `ChatService.sessionMode`**（`isFreeTalkSession ? .freeTalk : .conversation`）。
  `ChatSession.mode` 有默认值，`persist()` 不显式传就等于「所有会话都是情景对话」——踩过的坑。
- **一场练习的完整生命周期**：
  1. `startScenario()` 记 `scenarioStartIndex`（**必须在开场白之前**）；
  2. 老师开场白（真实模型调用，冷加载 30–60s，等待态见 `TeacherPreparingCard`）；
  3. 轮次累积，`scenarioLearnerUtterances` 只取开场白之后的 `.user`（**必须在 `endScenario()` 前取值**）；
  4. 过关 = **主线任务完成 且 教学重点达标**（`questOK` / `focusOK` 分开判）；
  5. `concludeCurrentPractice()` 顺序**不可颠倒**：复盘 → `importVocabularyFromReviews` → `canPurgeSource` → 才 `purgePracticeMessages`；
  6. `sessions` 行与 `session_reviews` **永不删**（「上次在练什么」靠它答）。
- **续做**：`PracticeResumeRule.action(questComplete:)` —— **启动续做绝不重开已完成关卡**，
  主线跑完即当空闲。`beginScenario` 的「已通关就重置」只服务于**主动**重练。
- **前情提要**：`ScenarioBriefing.swift`，把上次同一情景的收尾结论讲给学员。

### 2. 跟读
- **入口**：⌘2 / `openShadowing()`。
- **素材**：**每天按情景现生成 20 句**（`ShadowingDailyStore` + `Prompts/shadowing_daily.txt`）。
  ⚠️ 铁律：**同一天必须同一批**；换语言即作废；坏文件当「今天没生成」**不删**；模型没起时内置素材顶着。
- **链路**：听示范（TTS）→ 录音 → ASR（**原始结果，不纠正拼写**）→ DP 对齐 → 发音报告。
- ⚠️ **跟读不用拼写纠正**：纠正会把「他实际说了什么」改成「他本来想说什么」，正好抹掉要评估的东西。

### 3. 词典
- **入口**：⌘3 / `openDictionary()`。
- **三本内置书**来自 `DictionaryCatalog.specs`（雅思 / 六级 / 牛津），词条**只从 JSON 读**，代码零字面量。
- **两种查法**：词典库页主动查；**划词气泡**（`WordLookupContext` 挂在消息气泡 overlay 上，须 0.35s 宽限期）。
- ⚠️ 查词联想是**竞态**：`isDictionaryMatchListArmed` 才管浮层显隐（别只看 `dictionaryMatches` 非空）；
  查到词=关；打字/点回输入框 `rearmDictionaryMatches()`=开。

### 4. 词汇本
- **入口**：⌘4 / `openVocabulary()`。
- **三个来源**：手动添加、每日推荐（`VocabularyWordBank` 雅思词库）、**复盘导入**（`importVocabularyFromReviews`）。
- **复习会话**：`VocabularyReviewSession`（纯值类型）只收**真到期**的词，
  排序「最不熟 → 最久没碰 → 字母序」。⚠️「忘了」≠「今天还到期」；文案 N 取 `stillDue`；**朗读分不参与等级**。

### 5. 学习进度 / 6. 学习记录
- 进度：`ProgressAggregator` 纯函数聚合；**`practiceSeconds` 是唯一时长尺**。
- 记录：`AnnualRecap` 纯函数；任务分母固定 3；未来日期是 `nil` 空洞。
- ⚠️ `DailyActivity.hasPractice` 含 `vocabularyReviewed`（不只看对话）。

### 7. 设置（浮层）
- **入口**：⌘, / 侧栏齿轮。
- 11 张卡。与本文相关的是「学习」卡（练习模式 / 学习语言 / 母语）与「教师语音」板块。

---

## 二、英语假设分层清单（这是本文的重点）

按「改动代价」从低到高排。**层级越靠下，加语言时动的地方越多。**

### L0 · Prompt 层 —— 🟡 大体就绪，但有 2 处残留

提示词模板由 `AIInfrastructure/PromptBuilder.swift` 统一做占位符替换：

| 占位符 | 来源 |
|---|---|
| `{learning_language}` | `chat.profile.learningLanguage` |
| `{native_language}` | `chat.profile.nativeLanguage` |
| `{proficiency}` | 课程档位 |
| `{practice_mode}` | `product.practiceMode.displayName` |
| `{target_language}` | 翻译调用方传入（`translationPrompt`） |

**覆盖率实测：18 个模板里 13 个含 `{learning_language}` / `{native_language}`。**
其余 5 个不是遗漏，分三类：

| 模板 | 为什么没有占位符 |
|---|---|
| `free_talk.txt`、`task_briefing.txt` | 是**附加在 `teacher_system.txt` 之后的策略片段**，语言由那条已参数化的 system prompt 提供 |
| `translate.txt` | 用专门的 `{target_language}`（目标语言 ≠ 学习语言） |
| `attachment_note.txt` | 真·语言无关（只说「有附件，别装作看过」） |

👉 **加语言时这一层基本不用动**，但有 2 处残留要修：

1. ⚠️ **`spelling_fix.txt` 第 1 条规则硬编码了英语**：
   > `Fix ONLY spelling mistakes, including words that are clearly mis-heard English words.`
   这是 L0 层里唯一的语言假设。应是 `{learning_language}` 而非 `English`。
2. ⚠️ **`AppState.swift:614-615` 把配置里的 `en-US` 原样灌给** `chat.profile.learningLanguage`，
   于是模型收到的是 `practise en-US` 而不是 `practise English`。模型能猜到，
   但这正是下面 L2 那个「标识不通约」问题的同一个根。

### L1 · 素材层 —— 数据驱动，但**目录结构隐含单一语言**

所有内容都外置成 JSON，代码零字面量（这是好的）。问题是它们**平铺在语言无关的根目录下**：

| 路径 | 内容 | 语言维度 |
|---|---|---|
| `Resources/Scenarios/*.json`（10 个） | 情景（含 `level: "A2-B1"`、`targetVocabulary`、`mainQuest`） | 英语，**无 language 字段** |
| `Resources/Levels/level_bindings.json` | 8 个关卡 → 情景 id 绑定 | 英语 |
| `Resources/Shadowing/drills.json` | 跟读内置兜底素材 | 英语 |
| `Resources/Dictionaries/{ielts,cet6,oxford}.json` | 词典词条 `{word, phonetic, pos, zh, difficulty}` | 英语 |
| `Resources/Pronunciation/lexicon.json` | 音素词库（CMUdict 派生） | **英语音素集** |
| `Resources/Vocabulary/ielts_words.json` | 每日推荐词库 | 英语 |
| `Resources/Config/default-config.json` | 默认配置 | 含 `learning_language: "en-US"` |

👉 加语言时的动作：**新增语言目录 + 在 Catalog 层按语言过滤**。因为目前加载器都是
「找不到就用默认路径」的兜底写法（如 `LevelBindingCatalog` 里 `"Levels/x"` 和 `"x"` 两次尝试），
**乱改目录会静默走到兜底分支**——这是资源层最危险的一类改动。

### L2 · 语言标识层 —— ⚠️ **当前最大的接缝：同一个概念有三套写法，互相不通约**

| 场景 | 用的形式 | 例子 | 真源 |
|---|---|---|---|
| 配置 / UI 下拉 | BCP-47 | `en-US` | `product.learningLanguage` |
| 本地服务调用（ASR/TTS/跟读） | **语言名** | `English` | ❌ **AppState 里 5 处硬编码字面量** |
| 云端 OpenAI 兼容接口 | 主语言标签 | `en` | `RemoteProviderRules.primaryLanguageTag` |

**硬编码清单（改一处漏一处的地方）：**

| 位置 | 内容 |
|---|---|
| `AppState.swift:815` | `setPartialLanguage("English")` —— 语音输入实时识别 |
| `AppState.swift:827` | `stopRecordingAndTranscribe(language: "English")` —— 语音输入收尾 |
| `AppState.swift:864` | `speak(..., language: "English")` —— 老师朗读 |
| `AppState.swift:895` | `speak("Nice to meet you!", ..., language: "English")` —— 音色试听 |
| `AppState.swift:2983` | `playReference(..., language: "English")` —— 跟读示范 |
| `VoiceService.swift:222` | `language: String = "English"` —— **默认参数值也是英语** |

**换算函数散落各处：**
- `AIDomain/RemoteProviderRules.swift:86` `primaryLanguageTag()`：`en-US` → `en`
- `AIDomain/RemoteVoiceRules.swift:78-141`：语言名 ↔ 标签，还带一张
  `"english": "en", "chinese": "zh", …` 的手写映射表

👉 **同一个「学员在学什么语言」被表达了三次**，而且三处的更新时机完全独立。
加一种语言要同时改 6 处字面量 + 2 张映射表——这正是要收拢的对象。

### L3 · 音素评测层 —— 英语专用，机制级

| 位置 | 内容 |
|---|---|
| `AIDomain/PhonemeAssessment.swift:63` | `enum EnglishG2P` —— 规则 G2P 兜底（含 `irregulars` 不规则词表） |
| `AIDomain/PhonemeAssessment.swift:473` | `EnglishG2P.phonemes(for:)` 硬调用 |
| `AIDomain/PhonemeAssessment.swift:23` | `PhonemeLexicon` —— 音素词库，`Resources/Pronunciation/lexicon.json` |
| `AIDomain/RemotePronunciationAdapter.swift:141` | `let locale = config.model ?? "en-US"` —— **评测语言借 `model` 字段承载** |
| `AIDomain/Pronunciation.swift:597` | 语速基准「每分钟词数」按英语朗读节奏定的 |

👉 这一层是**真正的机制**：英语音素集（ARPAbet）、英语 G2P 规则、英语语速基准。
换成日语/法语要重做一套，不是加个参数就行。**建议现在不动**，只在设计上把它标成
「语言相关机制」的边界，让上面的接缝先通。

### L4 · UI 文案层 —— 不影响功能，可最后处理

`Animals.swift`、`SettingsView.swift:190` 等处的「学英语」「I love learning English」等
小动物台词与标语。这些是**气氛文案**，加语言时改不改都不影响链路。

---

## 三、建议的接缝设计（只描述，不在本任务实现）

### 接缝 A：把「学习语言」升级成一个值类型（对应 L2，**优先做**）

现状是三套写法，建议收成一个：

```
LearningLanguage
├─ bcp47        "en-US"    ← 配置里存这个（UI 下拉的 tag）
├─ serviceName  "English"  ← 给本地 ASR/TTS/Qwen3/跟读示范
├─ primaryTag   "en"       ← 给云端 OpenAI 兼容接口
└─ contentKey   "en"       ← 给素材加载器选目录 / 选词典书（对应 L1）
```

落点：
1. `AIDomain/LanguageOptions.swift` 里给每个 `Option` 补上这几个派生字段（纯函数）。
2. `AppState` 那 **5 处 `"English"` 字面量**改成 `LearningLanguage(product.learningLanguage).serviceName`。
3. `VoiceService.swift:222` 的默认参数值去掉，改为**必填**——默认值正是「漏传也不报错」的温床。
4. `PromptBuilder` 收 `serviceName` 而不是 `bcp47`（顺手修掉 `practise en-US` 那个瑕疵）。
5. `RemoteProviderRules.primaryLanguageTag` 与 `RemoteVoiceRules` 的映射表**内联进这个类型**，
   让「英语有几种写法」只有一个地方知道答案。

**收益**：加一种语言时，改的是**一个文件里的一行候选**，而不是 6 处字面量 + 2 张表。

### 接缝 B：素材加载器收语言参数（对应 L1）

现在各 Catalog 都是「硬编码文件名 + 找不到就兜底」。建议在每个加载器入口加语言参数，
**保留兜底行为不变**（这是刻意设计，不是缺陷），但把「按语言选文件」这件事集中到一处。

⚠️ 这一步**破坏性较强**（要动资源目录布局 + 每个加载器），建议**真正加第二种语言时再做**。
现在只需要在本文档里记下「哪些加载器到时候要动」。

### 接缝 C：音素机制抽象（对应 L3）—— **明确不做**

理由：只有英语实现时抽象就是空壳；等第二种语言的音素表真的来了再抽，
那时才知道该抽什么。**现在只标注边界。**

### 不改的事情（避免误解）

- 不新增语言、不改现有英语行为、不改资源配置目录。
- 不改 CEFR 档位与关卡绑定（`level_bindings.json` 是**内容**，不是机制）。
- 不动麦克风链路（已人工验收）。

---

## 四、和后续任务的关系

| 任务 | 与本文的关系 |
|---|---|
| #204 老师人格档位 | 档位要注入 Prompt。**先在本文的 L0 层落**（提示词模板是现成的），不要另起一套字符串拼接 |
| #205/#206 雅思 / 面试模式 | 新的「考试型」流程。**评分必须与 Curriculum/Quest 现有体系分开**，避免两套评价互相污染 |
| #208 上传材料自动出题 | 会往素材层写「用户自定义情景 / 跟读句 / 生词表」。建议届时**直接按接缝 B 的语言目录落盘**，别再造第三套路径 |

---

## 五、一句话结论

**Prompt 层基本为多语言准备好了（18 个模板 13 个已参数化，其余 5 个各有正当理由），
真正卡住的是「语言标识有三套写法」和「素材目录隐含单一语言」这两件事。**
前者代价小、收益大，值得现在就收拢（接缝 A，顺带修掉 `practise en-US` 与
`spelling_fix.txt` 里 "English words" 两处残留）；后者等真加语言时再做（接缝 B）；
音素机制（L3）明确划成「换语言要重做」的边界，不做提前抽象。
