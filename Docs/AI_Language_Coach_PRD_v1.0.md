# AI Language Coach 本地智能语言学习产品

## Product Requirements Document & Technical Specification

**文档版本：V1.0**
**产品类型：本地优先（Local-first）AI 语言学习应用**
**目标平台：macOS 优先，后续可扩展 iOS / Windows**
**核心模式：AI 私教 + 实时语音交互 + 发音纠正 + 个性化学习**
**核心原则：本地模型可插拔、隐私优先、模块化、可持续扩展**

---

# 1. 产品概述

## 1.1 产品定位

本产品是一款以**实时语音交互 + AI 私教 + 个性化学习记忆**为核心的智能语言学习应用。

产品目标不是简单地做一个：

> “ChatGPT + 麦克风 + TTS”

而是构建一个真正具有**教学能力、纠错能力、记忆能力和语言训练能力**的 AI Language Coach。

产品需要能够持续回答以下问题：

* 用户今天应该学什么？
* 用户最近最容易犯什么错误？
* 用户哪些单词发音有问题？
* 用户哪些语法知识薄弱？
* 用户口语是否流畅？
* 用户应该如何练习？
* AI 老师应该使用什么难度和表达方式？
* 用户说错之后，应该如何即时纠正？
* 如何通过重复训练让错误逐渐消失？

因此，产品的核心闭环为：

> **听 → 理解 → 分析 → 纠错 → 教学 → 语音反馈 → 记忆 → 再训练**

---

# 2. 产品核心目标

## 2.1 一级目标

构建一个：

> **完全可以在本地运行、具有长期学习记忆、能够进行实时语音教学的 AI 私教。**

用户可以直接对着电脑说话，而不是通过传统的：

> 打字 → AI 回复 → 再打字

完成学习。

---

## 2.2 核心价值

产品必须重点解决传统语言学习软件的几个问题：

### 问题 1：缺少真实交流

传统背单词、刷题不能很好地训练真实交流能力。

### 问题 2：纠错不够个性化

用户可能长期重复：

> I have went...

却不知道自己为什么总犯这个错误。

### 问题 3：无法长期记忆

普通聊天机器人通常不会系统记录：

* 用户语法错误
* 发音错误
* 高频词汇
* 熟练度
* 学习历史
* 学习目标

### 问题 4：AI 教师不稳定

AI 应该根据用户水平调整：

* 词汇难度
* 语速
* 句子长度
* 语法复杂度
* 纠错频率
* 对话主题

而不是所有用户得到同样的回答。

---

# 3. 产品核心理念

整个产品遵循五个原则。

## 3.1 Local First

核心 AI 能力优先支持本地运行：

* ASR
* LLM
* TTS
* Pronunciation Assessment
* Embedding
* Memory

网络服务不是系统运行的必要条件。

---

## 3.2 Model Agnostic

**绝不把产品和某一个 AI 模型绑定。**

例如：

```text
ASR
 ├── WhisperKit
 ├── whisper.cpp
 ├── SenseVoice
 └── Future Model

LLM
 ├── Qwen
 ├── Llama
 ├── Gemma
 └── Future Model

TTS
 ├── GPT-SoVITS
 ├── Qwen3-TTS
 ├── Chatterbox
 └── Future Model
```

产品只依赖统一接口。

---

# 4. 产品目标用户

## 4.1 第一阶段目标用户

主要面向：

* 英语学习者
* 有一定英语基础的大学生
* 职场人士
* 准备 IELTS / TOEFL 的用户
* 想提高英语口语的人
* 想通过 AI 进行日常交流训练的人

---

## 4.2 后续扩展

可以扩展：

* 日语
* 中文
* 韩语
* 法语
* 西班牙语
* 德语

产品本身不应该在架构层面绑定 English。

---

# 5. 产品核心功能地图

整个产品分为 8 个核心模块：

```text
AI Language Coach
│
├── 1. AI Conversation
│   ├── Free Talk
│   ├── Role Play
│   ├── Scenario Training
│   └── Interview Mode
│
├── 2. Speaking Practice
│   ├── Shadowing
│   ├── Repeat
│   ├── Read Aloud
│   └── Pronunciation Training
│
├── 3. Pronunciation Analysis
│   ├── Phoneme Accuracy
│   ├── Stress
│   ├── Intonation
│   ├── Fluency
│   ├── Speaking Speed
│   └── Pause Analysis
│
├── 4. Grammar Correction
│   ├── Error Detection
│   ├── Correction
│   ├── Explanation
│   └── Error Memory
│
├── 5. Vocabulary
│   ├── New Words
│   ├── Difficult Words
│   ├── Review
│   └── Personalized Vocabulary
│
├── 6. AI Teacher
│   ├── Teaching Strategy
│   ├── Difficulty Control
│   ├── Feedback
│   └── Learning Plan
│
├── 7. Learning Memory
│   ├── User Profile
│   ├── Error History
│   ├── Vocabulary History
│   ├── Pronunciation History
│   └── Progress
│
└── 8. Local AI Model System
    ├── ASR Adapter
    ├── LLM Adapter
    ├── TTS Adapter
    ├── Embedding Adapter
    └── Pronunciation Adapter
```

---

# 6. 核心用户流程

这是整个产品最重要的流程。

## 6.1 实时对话流程

用户：

> “I have went to London last year.”

系统：

```text
Microphone
     ↓
Audio Capture
     ↓
VAD
     ↓
ASR
     ↓
"I have went to London last year."
     ↓
Language Analysis
     ├── Grammar
     ├── Pronunciation
     ├── Vocabulary
     └── Fluency
     ↓
Learning Memory
     ↓
Teacher Agent
     ↓
Response Planner
     ↓
LLM
     ↓
TTS
     ↓
Speaker
```

AI 不只是回答：

> “That's interesting!”

而应该能够根据教学策略判断：

> 用户出现了明显的过去时错误，而且该错误以前已经出现过。

于是 AI 可以回答：

> “Almost! Instead of ‘I have went,’ say ‘I went to London last year.’ We use the simple past because you mentioned a specific past time.”

同时将：

```text
Grammar Error:
present perfect + past time
```

记录到用户学习档案。

---

# 7. 首页 Dashboard

首页应该让用户快速知道：

### 今日学习状态

```text
Good evening!

Your English Progress
────────────────────

Speaking        78
Pronunciation   72
Grammar         81
Vocabulary      75
Fluency         69

Today's Goal
✓ 10 min conversation
✓ 5 pronunciation exercises
○ Review 8 words
```

---

## 7.1 今日推荐

AI 自动生成：

> Today's Focus

例如：

```text
Your recent weakness:
Past tense

Recommended:
Practice past-tense storytelling
```

---

# 8. AI Conversation

这是产品核心功能之一。

## 8.1 Free Talk

用户选择：

> Free Talk

AI 自动根据用户水平开始对话。

例如：

```text
AI:
What did you do last weekend?

User:
I go to Seattle with my friend.
```

系统分析：

```text
Grammar:
"I go" → "I went"

Pronunciation:
Seattle ✓

Fluency:
Good

Vocabulary:
Basic
```

AI 根据配置决定：

### 立即纠正

或者：

### 暂时不打断

这一点必须由 Teacher Agent 决定。

---

# 9. Role Play

用户可以选择现实场景。

例如：

## Airport

AI：

> You are checking in for an international flight.

## Restaurant

AI：

> You are ordering dinner at a restaurant in New York.

## Job Interview

AI：

> I am the interviewer. Please introduce yourself.

## Hotel

AI：

> You just arrived at the hotel and want to check in.

## Doctor

AI：

> Explain your symptoms to the doctor.

---

# 10. Scenario Engine

场景系统不应该简单地只是一个 Prompt。

每个 Scenario 应该拥有结构化配置：

```json
{
  "scenario": "job_interview",
  "difficulty": "B2",
  "role": "interviewer",
  "goal": "evaluate_candidate",
  "target_vocabulary": [],
  "target_grammar": [],
  "max_turns": 20,
  "correction_mode": "moderate"
}
```

这样未来可以大量扩展场景。

---

# 11. Interview Mode

专门用于：

* Job Interview
* IELTS Speaking
* TOEFL Speaking
* Presentation
* Academic Discussion

系统可以在结束之后给出：

```text
Overall Score: 78

Fluency:       82
Grammar:       76
Vocabulary:    80
Pronunciation: 74
Coherence:     81
```

并生成：

### Strengths

### Weaknesses

### Recommended Practice

---

# 12. Pronunciation Assessment

这是产品区别于普通 AI Chat 产品的重要能力。

系统应该分析：

## 12.1 Phoneme Accuracy

例如：

```text
word: world

w     ✓
ɜː    ✓
r     △
l     ✗
d     ✓
```

---

## 12.2 Stress

例如：

```text
PHOtograph
phoTOGraphy
```

判断用户重音位置。

---

## 12.3 Intonation

分析：

* rising tone
* falling tone
* sentence melody
* unnatural pitch contour

---

## 12.4 Fluency

指标：

* Speech Rate
* Pause Duration
* Pause Frequency
* Filled Pauses
* Repetition
* Self-correction

例如：

```text
Speech Rate:
132 WPM

Pause:
Good

Fillers:
"uh" × 6

Fluency:
72/100
```

---

# 13. Shadowing Mode

这是必须保留的核心功能。

流程：

```text
AI speaks
     ↓
User listens
     ↓
User repeats
     ↓
ASR
     ↓
Pronunciation Assessment
     ↓
Compare
     ↓
Score
     ↓
Replay
```

可以显示：

```text
Target:
I would like to make a reservation.

You:
I would like to make a reservation.

Pronunciation: 89
Rhythm:         82
Fluency:        91
```

---

# 14. Grammar Correction Engine

语法系统需要区分：

### Error Detection

检测错误。

### Correction

给出正确表达。

### Explanation

解释为什么。

### Pattern Extraction

提取错误模式。

### Memory

记录到用户长期记忆。

例如：

```text
Original:
I have went there yesterday.

Correction:
I went there yesterday.

Error Type:
Tense

Grammar Pattern:
Present Perfect + Specific Past Time

Severity:
Medium

Frequency:
4
```

---

# 15. Vocabulary System

系统自动从真实对话中提取：

### New Words

### Unknown Words

### Frequently Used Words

### Misused Words

### Recommended Words

---

## 15.1 Vocabulary Card

例如：

```text
reservation

Meaning:
预订

Example:
I'd like to make a reservation.

Your usage:
"I want reservation."

Recommended:
"I'd like to make a reservation."
```

---

# 16. Personalized Learning Memory

这是产品最重要的长期能力之一。

数据库应该至少记录：

```text
User
│
├── Language Level
├── Learning Goals
├── Vocabulary
├── Grammar Errors
├── Pronunciation Errors
├── Conversation History
├── Learning Sessions
├── Weaknesses
├── Strengths
└── Preferences
```

---

# 17. 用户长期画像

例如：

```text
English Level: B1

Strengths:
- Basic vocabulary
- Reading
- Listening

Weaknesses:
- Past tense
- Articles
- /θ/
- Speaking fluency

Learning Goals:
- Job interview
- Daily conversation

Preferred Teacher:
- Friendly
- American English
- Moderate speaking speed
```

---

# 18. AI Teacher Agent

AI Teacher 是整个系统的大脑之一。

它负责：

* 判断当前教学目标
* 决定是否纠错
* 决定纠错程度
* 调整难度
* 选择话题
* 决定是否复习旧知识
* 控制对话节奏
* 调用其他 Agent

---

# 19. Agent Architecture

建议采用：

```text
                  ┌─────────────────┐
                  │   Teacher Agent │
                  └────────┬────────┘
                           │
           ┌───────────────┼───────────────┐
           ↓               ↓               ↓
    Grammar Agent   Pronunciation Agent   Conversation Agent
           │               │               │
           └───────────────┼───────────────┘
                           ↓
                    Learning Memory
```

---

# 20. Grammar Agent

输入：

```text
ASR Text
User Profile
Conversation Context
```

输出：

```json
{
  "errors": [
    {
      "type": "tense",
      "original": "have went",
      "corrected": "went",
      "explanation": "...",
      "severity": "medium"
    }
  ]
}
```

---

# 21. Pronunciation Agent

输入：

```text
Audio
Target Text
ASR Text
```

输出：

```json
{
  "overall_score": 78,
  "phoneme_score": 73,
  "stress_score": 81,
  "intonation_score": 76,
  "fluency_score": 82
}
```

---

# 22. Conversation Agent

负责：

* 当前话题
* 下一轮问题
* 对话难度
* 用户兴趣
* 场景状态
* 目标词汇
* 目标语法

---

# 23. Response Planner

非常重要。

不要：

```text
ASR → LLM → TTS
```

直接连接。

应该：

```text
ASR
 ↓
Analysis
 ↓
Teacher Agent
 ↓
Response Planner
 ↓
LLM
 ↓
TTS
```

Response Planner 决定：

```json
{
  "should_correct": true,
  "correction_style": "gentle",
  "should_explain": true,
  "response_length": "short",
  "difficulty": "B1",
  "tts_style": "friendly_teacher"
}
```

---

# 24. TTS 系统

TTS 必须设计成独立模块。

核心接口：

```text
TTSManager
    │
    ├── GPTSoVITSBackend
    ├── QwenTTSBackend
    ├── ChatterboxBackend
    └── FutureBackend
```

其中，**GPT-SoVITS 可以作为第一候选 TTS Backend**。

它尤其适合：

* AI 教师固定声音
* 参考音色
* 跨语言声音
* 用户自定义教师声音
* Voice Cloning

GPT-SoVITS 官方项目目前支持 zero-shot / few-shot TTS，以及中文、英文、日语、韩语、粤语等多语言能力，因此与这个产品的“AI 老师声音”设计高度匹配。

但产品层面**不能直接依赖 GPT-SoVITS 的 API**。

应该依赖：

```text
ITTSProvider
```

---

# 25. TTS Provider Interface

建议定义：

```python
class TTSProvider:

    def synthesize(
        self,
        text: str,
        voice_id: str,
        language: str,
        style: str | None = None
    ) -> AudioResult:
        pass
```

同时支持：

```python
get_voices()
get_languages()
supports_voice_cloning()
supports_streaming()
supports_style_control()
```

---

# 26. GPT-SoVITS Backend

未来只需要实现：

```text
GPTSoVITSBackend
        ↓
GPT-SoVITS Local Runtime
```

配置：

```yaml
tts:
  provider: gpt_sovits

  endpoint:
    type: local
    host: ""
    port: ""

  model:
    path: ""
    version: ""

  voices:
    teacher_01:
      reference_audio: ""
      reference_text: ""
```

注意：

> **所有 path、model、endpoint、启动方式都留空，由后续合作开发人员填写。**

这样需求文档本身不会把模型部署方式锁死。

---

# 27. Voice System

用户应该可以选择：

```text
Teacher Voice

○ American Female
○ American Male
○ British Female
○ British Male
○ Custom Voice
```

未来支持：

```text
Speed
Pitch
Style
Emotion
Energy
```

但这些控制项必须根据具体 TTS 模型是否支持来决定。

**产品 API 支持这些参数，但 Backend 可以声明某些参数 unsupported。**

---

# 28. 用户 Voice Clone

这是一个很有产品差异化潜力的功能。

用户上传自己的声音：

```text
Your Voice
      ↓
Voice Reference
      ↓
TTS
      ↓
AI speaks English using your voice
```

例如：

> 用户普通话声音 → AI 用用户声音说英语。

这一功能必须增加：

* 用户明确授权
* 声音归属确认
* 禁止未经授权克隆第三方声音
* 本地优先处理

---

# 29. ASR 系统

ASR 同样设计成：

```text
ASRManager
   │
   ├── WhisperKitBackend
   ├── WhisperCppBackend
   ├── SenseVoiceBackend
   └── FutureBackend
```

macOS / Apple Silicon 第一阶段可以优先考虑 WhisperKit 或 whisper.cpp；SenseVoice 可以作为中文及多语言场景的备选。

---

# 30. ASR Interface

```python
class ASRProvider:

    def transcribe(
        self,
        audio: AudioData,
        language: str | None = None
    ) -> Transcript:
        pass
```

输出：

```json
{
  "text": "I went to London yesterday.",
  "language": "en",
  "confidence": 0.96,
  "segments": [],
  "words": []
}
```

后续必须支持 word-level timestamps，因为：

> **发音评测需要时间对齐信息。**

---

# 31. Local LLM

LLM 也不直接写死。

架构：

```text
LLMManager
    │
    ├── MLXBackend
    ├── llama.cpp Backend
    ├── OllamaBackend
    └── FutureBackend
```

接口：

```python
class LLMProvider:

    def generate(
        self,
        messages,
        temperature=0.7,
        max_tokens=512
    ) -> LLMResponse:
        pass

    def stream(...):
        pass
```

---

# 32. Embedding Model

用于：

* 用户学习记忆
* 相似错误检索
* 历史对话检索
* 个性化内容推荐

接口：

```python
class EmbeddingProvider:

    def embed(text: str) -> list[float]:
        pass
```

---

# 33. Memory Architecture

建议：

```text
SQLite
 +
Vector Database
```

第一阶段可以：

```text
SQLite
FAISS
```

---

# 34. Memory 分类

## Short-Term Memory

当前对话：

```text
last 10-20 turns
```

## Session Memory

当前学习 session：

```text
topic
errors
vocabulary
scores
```

## Long-Term Memory

长期：

```text
user profile
learning history
frequent errors
weaknesses
preferences
```

---

# 35. 数据库核心表

建议至少：

```text
users

user_profiles

learning_sessions

conversation_turns

grammar_errors

pronunciation_results

vocabulary

vocabulary_reviews

learning_goals

scenarios

teacher_preferences

model_configs
```

---

# 36. Model Registry

这一点非常重要。

建立统一：

```text
Model Registry
```

例如：

```json
{
  "id": "gpt-sovits-main",
  "type": "tts",
  "provider": "GPTSoVITSBackend",
  "runtime": "local",
  "model_path": "",
  "enabled": true
}
```

ASR：

```json
{
  "id": "whisper-local",
  "type": "asr",
  "provider": "WhisperKitBackend",
  "model_path": "",
  "enabled": true
}
```

这样未来合作开发人员只需要：

1. 安装模型
2. 填写模型路径
3. 实现 Adapter
4. 注册模型

而不需要修改整个产品。

---

# 37. Audio Pipeline

完整音频链路：

```text
Microphone
     ↓
Audio Capture
     ↓
Noise Suppression
     ↓
VAD
     ↓
Speech Segment
     ↓
ASR
     ↓
Analysis
```

TTS：

```text
LLM Response
      ↓
Response Text
      ↓
TTS
      ↓
Audio Buffer
      ↓
Audio Playback
```

---

# 38. VAD

必须加入 VAD。

主要作用：

* 判断用户什么时候开始说话
* 判断什么时候结束
* 避免把静音送入 ASR
* 降低延迟
* 降低计算量

可以预留：

```text
WebRTC VAD
Silero VAD
Apple VAD
Future VAD
```

---

# 39. 实时交互要求

目标不是传统：

```text
用户说完
↓
等待 5 秒
↓
AI 回复
```

而应该：

```text
User Speech
     ↓
Streaming ASR
     ↓
Partial Transcript
     ↓
Early Analysis
     ↓
LLM Streaming
     ↓
TTS Streaming
     ↓
Audio Playback
```

最终目标：

> **用户说完后尽可能快速得到 AI 语音反馈。**

---

# 40. UI 设计

第一版建议采用：

## macOS Native App

推荐：

```text
SwiftUI
+
Local AI Runtime
```

UI：

```text
┌─────────────────────────────────────────┐
│ AI Language Coach                       │
├─────────────────────────────────────────┤
│                                         │
│       🎧  Listening...                  │
│                                         │
│ AI                                      │
│ What did you do last weekend?           │
│                                         │
│ User                                    │
│ I go to Seattle with my friend.        │
│                                         │
│ ─────────────────────────────────────   │
│ Grammar                                  │
│ "go" → "went"                            │
│                                         │
│ Pronunciation     82                     │
│ Fluency           76                     │
│                                         │
│              🎙 Hold to Speak            │
└─────────────────────────────────────────┘
```

---

# 41. Conversation UI

需要显示：

### AI Message

### User Message

### Correction

### Pronunciation Score

### Vocabulary

### Replay

### Slow Playback

---

# 42. Correction UI

例如：

```text
You said:

"I have went to London yesterday."

Better:

"I went to London yesterday."

Why?

Because "yesterday" refers to a specific
past time, so use the simple past.
```

---

# 43. Learning Session

每次学习产生一个 Session。

例如：

```text
Session #128

Duration:
18 min

Conversation:
Restaurant

New Words:
7

Grammar Errors:
4

Pronunciation Issues:
3

Speaking Score:
81
```

---

# 44. Session Summary

结束后自动生成：

```text
Today's Summary

You did well:
✓ Vocabulary
✓ Listening
✓ Sentence structure

Needs practice:
△ Past tense
△ /θ/ pronunciation
△ Speaking fluency

Recommended tomorrow:
"Past-tense storytelling"
```

---

# 45. Learning Plan

系统自动维护：

```text
Weekly Goal

Speaking       ████████░░
Grammar        ██████░░░░
Vocabulary     █████████░
Pronunciation  █████░░░░░
```

并自动决定：

> 明天练什么。

---

# 46. Difficulty System

采用：

```text
A1
A2
B1
B2
C1
C2
```

但实际 AI 控制不应只依赖 CEFR。

还应该考虑：

```text
sentence complexity
vocabulary difficulty
speech rate
grammar complexity
topic difficulty
correction frequency
```

---

# 47. Teacher Personality

用户可以选择：

```text
Friendly
Professional
Strict
Patient
Energetic
Academic
```

同时可以设置：

```text
Correction:
○ Minimal
○ Balanced
○ Intensive
```

---

# 48. Language / Accent

用户可以选择：

```text
Target Language:
English

Accent:
American
British
Australian
```

教师可以使用对应 TTS voice。

---

# 49. Settings

设置页面：

```text
AI Models
Audio
Teacher
Learning
Language
Privacy
Storage
Advanced
```

---

# 50. AI Model Settings

模型配置页面必须支持：

```text
ASR Model
LLM Model
TTS Model
Embedding Model
Pronunciation Model
VAD Model
```

每一个模型都有：

```text
Provider
Model
Path
Runtime
Device
Enabled
```

---

# 51. 本地模型调用接口——核心技术规范

这是本项目必须遵守的架构原则。

所有模型统一遵循：

```text
Application Layer
       ↓
Model Interface
       ↓
Model Adapter
       ↓
Local Runtime
       ↓
Model
```

**禁止 Application Layer 直接调用某个具体模型。**

错误：

```text
ConversationService
     ↓
GPTSoVITS
```

正确：

```text
ConversationService
     ↓
TTSManager
     ↓
ITTSProvider
     ↓
GPTSoVITSBackend
     ↓
GPT-SoVITS
```

---

# 52. Model Adapter 标准

所有模型 Adapter 至少包含：

```text
initialize()
load()
unload()
health_check()
get_capabilities()
```

并根据模型类型实现：

```text
ASR
TTS
LLM
Embedding
Pronunciation
VAD
```

---

# 53. Capability System

例如 GPT-SoVITS：

```json
{
  "streaming": false,
  "voice_cloning": true,
  "multilingual": true,
  "style_control": true,
  "pitch_control": false
}
```

这样 UI 就可以自动决定显示哪些控制项。

---

# 54. Model Benchmark

必须设计模型测试页面。

例如：

```text
Model Benchmark

TTS

GPT-SoVITS
------------------
First Audio: 1.2s
RTF: 0.8
Memory: 5.2 GB

Qwen TTS
------------------
First Audio: 0.9s
RTF: 0.6
Memory: 4.8 GB
```

最终产品可以根据：

* 延迟
* 音质
* 内存
* CPU/GPU
* 稳定性

选择默认模型。

---

# 55. Mac M1 Pro 优先优化

第一目标设备：

> **MacBook Pro M1 Pro / 16GB RAM**

因此必须考虑：

* Apple Silicon
* Metal
* MPS
* MLX
* CPU fallback
* Unified Memory

模型系统必须允许：

```text
GPU / Metal
CPU
```

切换。

---

# 56. 资源管理

由于 16GB RAM 是重要约束，不能同时无脑加载：

```text
ASR
+
LLM
+
TTS
+
Embedding
+
Pronunciation
```

所有模型必须支持：

```text
Load on Demand
Unload
Cache
```

例如：

```text
Conversation
↓
ASR loaded
↓
LLM loaded
↓
TTS loaded

Pronunciation required
↓
Load pronunciation model
↓
Process
↓
Unload
```

---

# 57. Privacy

默认：

> **用户语音不离开设备。**

默认关闭：

```text
Cloud Upload
Telemetry
Remote Logging
```

如果未来增加云模型：

必须明确：

```text
Local
Cloud
Hybrid
```

并让用户主动选择。

---

# 58. 数据隐私

用户数据：

```text
Audio
Transcript
Learning History
Voice
Learning Profile
```

全部默认本地保存。

用户必须能够：

```text
Delete Conversation
Delete Audio
Delete Learning History
Delete Voice Model
Reset Learning Profile
```

---

# 59. Project Architecture

建议最终项目结构：

```text
AI-Language-Coach/
│
├── App/
│
├── UI/
│
├── Core/
│   ├── Conversation/
│   ├── Learning/
│   ├── Memory/
│   └── Audio/
│
├── AI/
│   ├── ASR/
│   ├── LLM/
│   ├── TTS/
│   ├── Pronunciation/
│   ├── Embedding/
│   └── VAD/
│
├── Models/
│   ├── Interfaces/
│   ├── Adapters/
│   └── Registry/
│
├── Database/
│
├── Services/
│
├── Resources/
│
└── Tests/
```

---

# 60. MVP 第一版本

第一版**不要一次做完所有功能**。

MVP 只实现：

### P0

1. 麦克风输入
2. VAD
3. 本地 ASR
4. 本地 LLM
5. 本地 TTS
6. AI 对话
7. Grammar Correction
8. Conversation History
9. 基础 Learning Memory
10. Session Summary

---

# 61. MVP 核心闭环

必须做到：

```text
用户说话
   ↓
ASR
   ↓
识别文本
   ↓
Grammar Analysis
   ↓
LLM
   ↓
Teacher Response
   ↓
TTS
   ↓
AI 说话
```

如果这个闭环跑通：

> 产品已经成立。

---

# 62. V1.1

增加：

* Shadowing
* Pronunciation Score
* Vocabulary
* Learning Dashboard
* Scenario Role Play

---

# 63. V1.2

增加：

* IELTS Mode
* Interview Mode
* Personalized Learning Plan
* Long-term Memory
* Teacher Personality
* Voice Customization

---

# 64. V2

增加：

* Voice Cloning
* 多语言
* 更高级发音分析
* 情绪/语调控制
* AI 自动课程
* 自适应学习系统

---

# 65. 暂时明确不做

为了避免项目失控，V1 暂时不做：

* 社交系统
* 用户社区
* 排行榜
* 在线商城
* 广告
* 复杂账号体系
* 多人实时课堂
* 云端训练平台
* 自研基础模型

---

# 66. 核心性能指标

## ASR

目标：

```text
低延迟
高识别准确率
支持 streaming
```

---

## LLM

目标：

```text
First Token Latency
尽可能低
```

---

## TTS

重点：

```text
First Audio Latency
Real-Time Factor
```

目标：

> 尽量做到接近实时甚至快于实时。

---

# 67. 整体性能目标

理想交互：

```text
User stops speaking
        ↓
< 1 sec
        ↓
AI starts responding
```

最终优化目标：

```text
Speech
 ↓
ASR
 ↓
LLM
 ↓
TTS
 ↓
Audio
```

整个 pipeline 尽可能控制在：

> **1–2 秒级反馈**

实际数值以 M1 Pro 本地模型 Benchmark 为准。

---

# 68. 错误处理

每一个 AI Module 都必须具有：

```text
Model unavailable
Model loading
Model crashed
Out of memory
Unsupported language
Unsupported feature
Audio error
```

例如：

```text
GPT-SoVITS unavailable

Fallback:
Qwen TTS
```

因此：

> **模型失败不能导致整个 App 崩溃。**

---

# 69. Fallback System

例如：

```text
Primary TTS
GPT-SoVITS
      ↓
Failure
      ↓
Qwen TTS
      ↓
Failure
      ↓
System TTS
```

ASR 同理：

```text
WhisperKit
 ↓
whisper.cpp
 ↓
Apple Speech
```

---

# 70. 可扩展性要求

以后加入：

```text
Fish Speech
MOSS-TTS
Chatterbox
Qwen3-TTS
```

不允许修改：

```text
ConversationService
TeacherAgent
LearningService
```

只增加：

```text
NewTTSBackend
```

---

# 71. 开发原则

合作开发必须遵守：

### 原则 1

**模型和业务逻辑分离。**

### 原则 2

**UI 和 AI Runtime 分离。**

### 原则 3

**所有 AI 功能必须有 Interface。**

### 原则 4

**所有模型路径从 Configuration 注入。**

### 原则 5

**不得在代码中硬编码模型路径。**

### 原则 6

**不得让业务层直接 import 某个具体模型。**

### 原则 7

**所有模型支持独立替换。**

---

# 72. 第一阶段模型预留表

| 模块            | 产品接口                     | 第一候选                | 备选                       | 当前是否定型 |
| ------------- | ------------------------ | ------------------- | ------------------------ | ------ |
| ASR           | `IASRProvider`           | WhisperKit          | whisper.cpp / SenseVoice | **否**  |
| VAD           | `IVADProvider`           | Silero/WebRTC       | Apple VAD                | **否**  |
| LLM           | `ILLMProvider`           | 本地 MLX LLM          | llama.cpp                | **否**  |
| TTS           | `ITTSProvider`           | GPT-SoVITS          | Qwen3-TTS / Chatterbox   | **否**  |
| Embedding     | `IEmbeddingProvider`     | 本地 Embedding        | —                        | **否**  |
| Pronunciation | `IPronunciationProvider` | wav2vec2/HuBERT 类方案 | Future                   | **否**  |

这里刻意使用：

> **“第一候选”而不是“最终模型”。**

最终模型必须通过真实 M1 Pro Benchmark 决定。

---

# 73. TTS 模型最终决策原则

GPT-SoVITS 可以作为产品第一阶段重点测试的 TTS。

但是最终不能单纯根据：

> “哪个模型论文/README 看起来最好”

决定。

应该实际测试：

```text
1. 音质
2. 声音自然度
3. Voice Similarity
4. 英语发音
5. 多语言
6. 首字节延迟
7. RTF
8. RAM
9. M1 Pro CPU/GPU 性能
10. 长文本稳定性
```

---

# 74. 产品最重要的技术壁垒

从长期来看，真正值得投入的不是：

> “我用了哪个 TTS。”

而是：

### ① 用户学习记忆

### ② 个性化教学策略

### ③ 错误建模

### ④ 发音评测

### ⑤ AI Teacher Agent

### ⑥ Real-time Audio Pipeline

模型未来都可以换。

但是：

> **用户学习数据和教学系统会形成产品自己的核心资产。**

---

# 75. 最终产品架构

综合前面所有讨论，我建议最终冻结成：

```text
                         AI LANGUAGE COACH
                                │
             ┌──────────────────┴──────────────────┐
             │                                     │
        Presentation Layer                    Learning Layer
             │                                     │
          SwiftUI                         ┌─────────┼─────────┐
             │                            │         │         │
             │                         Grammar  Vocabulary  Progress
             │                            │         │         │
             └──────────────┬─────────────┴─────────┴─────────┘
                            │
                     Teacher Agent
                            │
                    Response Planner
                            │
             ┌──────────────┼──────────────┐
             │              │              │
        Conversation     Grammar     Pronunciation
          Agent           Agent          Agent
             │              │              │
             └──────────────┼──────────────┘
                            │
                       AI Core Layer
                            │
        ┌───────────────────┼────────────────────┐
        │                   │                    │
       ASR                  LLM                 TTS
        │                   │                    │
  ASRProvider        LLMProvider          TTSProvider
        │                   │                    │
  ┌─────┴─────┐       ┌─────┴─────┐       ┌─────┴─────┐
  │WhisperKit │       │   MLX     │       │GPT-SoVITS │
  │whisper.cpp│       │llama.cpp  │       │Qwen TTS   │
  │SenseVoice │       │ Ollama    │       │Chatterbox │
  └───────────┘       └───────────┘       └───────────┘
                            │
                     Local Model Runtime
                            │
                       Apple Silicon
                            │
                    ┌───────┴────────┐
                    │   M1 Pro 16GB  │
                    └────────────────┘
```

---

# 76. 产品的真正核心闭环

最后把整个产品压缩成一句技术定义：

> **AI Language Coach 是一个 Local-first、Model-agnostic 的实时语音语言学习系统，通过 ASR → Language Analysis → Teacher Agent → LLM → TTS 构建实时 AI 对话，通过 Pronunciation / Grammar / Vocabulary Analysis 建立用户长期学习画像，并根据历史错误动态生成个性化学习内容。**
