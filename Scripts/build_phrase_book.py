#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""生成 Resources/Dictionaries/phrases.json —— 「常用搭配」词组书（difficulty 全为 4）。

## 为什么词组要自成一册

三本词书里 difficulty=4 的条目**去重后只有 49 条**，而每日推荐每天要 2 个词组
→ 24 天就见底，之后缺口被别的档顶上，「每天 2 个词组」这条承诺兑现不了。
更重要的是：**查词组时该去词组书里找**，而不是在三本词书里拣出几条同名条目。
所以词组独立成书，推荐与查找都以它为先（接线见 DictionaryCatalog / DictionaryLibrary）。

## 数据从哪来（两路合并，手写那路优先）

1. **手写策展**（`CURATED`）：教学里真正会教的固定搭配 —— 介词框架、短语动词、
   be+adj+prep、日常口语。这些是**为学生写的**，释义短、只留常用义。
2. **ECDICT 多词条目里柯林斯星级 > 0 的**（`collins` 字段）：ECDICT 一共 36.7 万条
   多词条目，但**全部没有词频、没有考试标签** —— 它是一份未整理的原始堆。
   唯一可用的质量信号就是柯林斯星级（「对学习者有多核心」）。
   实测：拿多词条目的**组成部分词频**排序会把 `be in` / `to it` 这类碎片顶到最前
   （词组的常用度 ≠ 组成部分的常用度），拿结构模式（动词+小品词）过滤仍混着
   `along of` / `fine away` / `cover in` 这类冷僻义，**只有柯林斯星级这一层干净**
   ——`fossil fuel` / `social security` / `state of mind` / `elementary school`。
   代价是偏名词词组（词组书与词书互补，正好）。

## 十条过滤规则（每条都对应一种实测过的脏数据）

- `collins` 必须 > 0（见上，唯一的质量信号）
- 词形 `^[a-z][a-z'\-]*( [a-z][a-z'\-]*){1,3}$`（小写；挡掉 `et al.` 这类带点的缩写）
- **拼合后是单词**的排除：ECDICT 把合成词同时收成 `mainland` 与 `main land`、
  `blacksmith` 与 `black smith` —— 拆开那份是重复条目，拼回去能查到就丢掉
- **屈折形式**排除（`went out` 不能当词条）：首词在单字表的 `exchange` 里带 `0:` 即为屈折
- **全部由虚词组成**的排除（`to be` / `of and on`）
- 释义**只剥不丢**：`[医] [计] [经]` 这类领域标记是**附加义项**，
  `blood pressure\n[医] 血压` 的第一行完全可用 —— 只丢掉带标记的行，不是丢掉整条
- 首义以 `[人名] [地名] [网络] [缩写]` 开头 → 丢
- 释义混拉丁字母 → 丢（说明没译）
- 释义带括号 / 省略号模板（`…` 表句式而非词义）→ 丢
- 截断到 22 字、最多两义（一行放不下就没法当推荐语）

## 音标

词组不生成音标（多词短语的音标价值低，`DictionaryWord.phonetic` 允许为空），
所以本书**不进** build_dictionaries.py 的音标流程。

用法：
  /Users/chenjianxu/.workbuddy/binaries/python/envs/default/bin/python Scripts/build_phrase_book.py
  环境变量 ECDICT_CSV 可指定 CSV（默认 .workbuddy/build/ecdict/ecdict.csv）；
  没有 CSV 时只写手写那一路（离线也能重建，只是词少）。
"""
import csv
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/AIInfrastructure/Resources/Dictionaries"
ECDICT_CSV = pathlib.Path(
    os.environ.get("ECDICT_CSV") or (ROOT / ".workbuddy/build/ecdict/ecdict.csv")
)

csv.field_size_limit(10 ** 9)

# ---------------------------------------------------------------- 手写策展（优先）
# (word, pos, zh)
CURATED = [
    # ── 介词 / 连接短语 ──────────────────────────────────────────────
    ("in front of", "prep.", "在…前面"),
    ("in the middle of", "prep.", "在…中间"),
    ("at the end of", "prep.", "在…结束时"),
    ("at the beginning of", "prep.", "在…开始时"),
    ("in the process of", "prep.", "在…过程中"),
    ("on the basis of", "prep.", "在…基础上；基于"),
    ("in case of", "prep.", "万一；如果发生"),
    ("in charge of", "prep.", "负责；掌管"),
    ("in need of", "prep.", "需要"),
    ("in search of", "prep.", "寻找；寻求"),
    ("in view of", "prep.", "鉴于；考虑到"),
    ("with respect to", "prep.", "关于；就…而言"),
    ("due to", "prep.", "由于；因为"),
    ("thanks to", "prep.", "多亏；由于"),
    ("regardless of", "prep.", "不管；不顾"),
    ("apart from", "prep.", "除…之外"),
    ("along with", "prep.", "连同；和…一起"),
    ("for the sake of", "prep.", "为了…起见"),
    ("by means of", "prep.", "通过…方式"),
    ("in line with", "prep.", "与…一致；符合"),
    ("in contrast to", "prep.", "与…形成对照"),
    ("on account of", "prep.", "因为；由于"),
    ("in place of", "prep.", "代替"),
    ("in favour of", "prep.", "赞成；支持"),
    ("in exchange for", "prep.", "交换；以…换取"),
    ("in connection with", "prep.", "与…有关"),
    ("in relation to", "prep.", "关于；涉及"),
    ("in honour of", "prep.", "为纪念；为庆祝"),
    ("with the help of", "prep.", "在…的帮助下"),
    ("on behalf of", "prep.", "代表"),
    ("at the top of", "prep.", "在…顶部"),
    ("at the bottom of", "prep.", "在…底部"),
    ("in the face of", "prep.", "面对；不顾"),
    ("in the hope of", "prep.", "怀着…的希望"),
    ("out of date", "adj.", "过时的；陈旧的"),
    ("out of order", "adj.", "出故障的；混乱的"),
    ("out of control", "adj.", "失去控制的"),
    ("out of breath", "adj.", "上气不接下气的"),
    ("out of reach", "adj.", "够不着的"),
    ("up to date", "adj.", "最新的；跟上时代的"),
    ("up to now", "adv.", "到目前为止"),
    ("in advance", "adv.", "提前；预先"),
    ("in common", "adv.", "共同；共有"),
    ("in general", "adv.", "总的来说；大体上"),
    ("in particular", "adv.", "尤其；特别是"),
    ("in person", "adv.", "亲自；当面"),
    ("in public", "adv.", "当众；公开地"),
    ("in return", "adv.", "作为回报"),
    ("in vain", "adv.", "徒劳；白费"),
    ("in brief", "adv.", "简言之"),
    ("in detail", "adv.", "详细地"),
    ("in silence", "adv.", "沉默地"),
    ("on purpose", "adv.", "故意地"),
    ("on average", "adv.", "平均而言"),
    ("on business", "adv.", "因公；出差"),
    ("on duty", "adv.", "值班；当班"),
    ("on sale", "adv.", "在售；打折"),
    ("at last", "adv.", "终于；最后"),
    ("at most", "adv.", "至多"),
    ("at once", "adv.", "立刻；同时"),
    ("at present", "adv.", "目前；现在"),
    ("at random", "adv.", "随机地"),
    ("by accident", "adv.", "偶然；意外地"),
    ("by chance", "adv.", "碰巧"),
    ("by mistake", "adv.", "错误地；无意中"),
    ("by far", "adv.", "到目前为止；远为"),
    ("by no means", "adv.", "决不"),
    ("in no time", "adv.", "立刻；马上"),
    ("for instance", "adv.", "例如"),
    ("for good", "adv.", "永远；永久地"),
    ("above all", "adv.", "最重要的是"),
    ("after all", "adv.", "毕竟；终究"),
    ("all in all", "adv.", "总的来说"),
    ("first of all", "adv.", "首先"),
    ("so far", "adv.", "到目前为止"),
    ("as usual", "adv.", "像往常一样"),
    ("as follows", "adv.", "如下"),
    ("and so on", "adv.", "等等；诸如此类"),
    ("or so", "adv.", "大约；左右"),
    ("once again", "adv.", "再一次"),
    ("over and over", "adv.", "一再；反复"),
    ("again and again", "adv.", "反复地"),
    ("little by little", "adv.", "一点一点地；逐渐"),
    ("step by step", "adv.", "一步一步地"),
    ("day by day", "adv.", "一天天；逐日"),
    ("one by one", "adv.", "一个接一个地"),
    ("side by side", "adv.", "并排；并肩"),
    ("face to face", "adv.", "面对面"),
    ("hand in hand", "adv.", "手拉手；密切关联"),
    ("from time to time", "adv.", "不时；偶尔"),
    ("now and then", "adv.", "偶尔；有时"),
    ("sooner or later", "adv.", "迟早；早晚"),
    ("more or less", "adv.", "或多或少；大约"),
    ("more and more", "adv.", "越来越"),
    ("all over the world", "adv.", "全世界"),
    ("around the clock", "adv.", "夜以继日；全天候"),
    ("as soon as possible", "adv.", "尽快"),
    ("as a matter of fact", "adv.", "事实上"),
    ("on the whole", "adv.", "总的来说"),
    ("to some extent", "adv.", "在某种程度上"),
    ("to a large extent", "adv.", "在很大程度上"),
    ("in the short term", "adv.", "短期来看"),
    ("in conclusion", "adv.", "总之；最后"),
    ("in summary", "adv.", "总之；概括地说"),
    ("last but not least", "adv.", "最后但同样重要"),
    ("without doubt", "adv.", "毫无疑问"),
    ("no doubt", "adv.", "无疑；确实"),
    ("no longer", "adv.", "不再"),
    ("no matter what", "adv.", "无论如何"),
    ("at all costs", "adv.", "不惜任何代价"),
    ("at any rate", "adv.", "无论如何；至少"),
    ("under no circumstances", "adv.", "决不"),

    # ── 短语动词 ────────────────────────────────────────────────────
    ("give in", "v.", "屈服；让步"),
    ("give out", "v.", "分发；用完"),
    ("give away", "v.", "赠送；泄露"),
    ("put off", "v.", "推迟；拖延"),
    ("put on", "v.", "穿上；上演"),
    ("put out", "v.", "熄灭；出版"),
    ("take part in", "v.", "参加；参与"),
    ("take place", "v.", "发生；举行"),
    ("take over", "v.", "接管；接手"),
    ("take up", "v.", "开始从事；占据"),
    ("take on", "v.", "承担；呈现"),
    ("take off", "v.", "起飞；脱下"),
    ("take action", "v.", "采取行动"),
    ("take measures", "v.", "采取措施"),
    ("take notes", "v.", "记笔记"),
    ("take responsibility", "v.", "承担责任"),
    ("take a walk", "v.", "散步"),
    ("take a shower", "v.", "洗澡"),
    ("take medicine", "v.", "吃药"),
    ("take it easy", "v.", "放轻松；别紧张"),
    ("look after", "v.", "照顾；照料"),
    ("look into", "v.", "调查；研究"),
    ("look up", "v.", "查阅；抬头看"),
    ("look down on", "v.", "看不起；轻视"),
    ("look out", "v.", "当心；留神"),
    ("come across", "v.", "偶然遇到；偶然发现"),
    ("come true", "v.", "实现；成真"),
    ("come up", "v.", "出现；被提出"),
    ("come to an end", "v.", "结束；告终"),
    ("get along with", "v.", "与…相处"),
    ("get rid of", "v.", "摆脱；除去"),
    ("get used to", "v.", "习惯于"),
    ("get over", "v.", "克服；从…恢复"),
    ("get through", "v.", "通过；熬过"),
    ("get in touch with", "v.", "与…取得联系"),
    ("go on", "v.", "继续；发生"),
    ("go over", "v.", "复习；仔细检查"),
    ("go through", "v.", "经历；仔细检查"),
    ("go ahead", "v.", "前进；请便"),
    ("go out", "v.", "外出；熄灭"),
    ("make up", "v.", "组成；编造；化妆"),
    ("make sense", "v.", "讲得通；有道理"),
    ("make sure", "v.", "确保；查明"),
    ("make progress", "v.", "取得进步"),
    ("make friends", "v.", "交朋友"),
    ("make a living", "v.", "谋生"),
    ("make a decision", "v.", "做决定"),
    ("make an effort", "v.", "付出努力"),
    ("make a mistake", "v.", "犯错误"),
    ("make ends meet", "v.", "收支相抵；勉强糊口"),
    ("bring up", "v.", "抚养；提出"),
    ("break down", "v.", "出故障；崩溃"),
    ("break up", "v.", "分手；解散"),
    ("break into", "v.", "闯入；打断"),
    ("carry on", "v.", "继续；坚持"),
    ("turn out", "v.", "结果是；生产"),
    ("turn up", "v.", "出现；调高"),
    ("turn down", "v.", "拒绝；调低"),
    ("turn into", "v.", "变成；转化"),
    ("turn on", "v.", "打开（开关）"),
    ("turn off", "v.", "关掉（开关）"),
    ("set up", "v.", "建立；设立"),
    ("set off", "v.", "出发；引发"),
    ("set out", "v.", "出发；着手"),
    ("run into", "v.", "偶然遇到；撞上"),
    ("run away", "v.", "逃跑；跑开"),
    ("find out", "v.", "查明；弄清"),
    ("figure out", "v.", "弄明白；算出"),
    ("work out", "v.", "解决；锻炼；算出"),
    ("point out", "v.", "指出"),
    ("pick up", "v.", "捡起；学会；接人"),
    ("end up", "v.", "最终成为；结果"),
    ("hand in", "v.", "上交；提交"),
    ("hold on", "v.", "稍等；坚持住"),
    ("keep up with", "v.", "跟上；不落后"),
    ("keep in mind", "v.", "记住"),
    ("keep in touch", "v.", "保持联系"),
    ("keep a promise", "v.", "遵守诺言"),
    ("keep a diary", "v.", "记日记"),
    ("leave out", "v.", "遗漏；省去"),
    ("let down", "v.", "使失望"),
    ("pay attention to", "v.", "注意；关注"),
    ("pay a visit", "v.", "拜访；访问"),
    ("rely on", "v.", "依赖；依靠"),
    ("care about", "v.", "关心；在乎"),
    ("belong to", "v.", "属于"),
    ("consist of", "v.", "由…组成"),
    ("lead to", "v.", "导致；通向"),
    ("result in", "v.", "导致；结果是"),
    ("result from", "v.", "由…引起"),
    ("apply for", "v.", "申请"),
    ("approve of", "v.", "赞成；认可"),
    ("benefit from", "v.", "从…中受益"),
    ("complain about", "v.", "抱怨；投诉"),
    ("concentrate on", "v.", "专注于"),
    ("cope with", "v.", "应付；处理"),
    ("dream of", "v.", "梦想；渴望"),
    ("insist on", "v.", "坚持"),
    ("participate in", "v.", "参与；参加"),
    ("prevent from", "v.", "阻止；防止"),
    ("protect from", "v.", "保护…免受"),
    ("recover from", "v.", "从…中恢复"),
    ("refer to", "v.", "指的是；参考"),
    ("succeed in", "v.", "成功做到"),
    ("suffer from", "v.", "遭受；患…病"),
    ("think of", "v.", "想到；考虑"),
    ("worry about", "v.", "担心；担忧"),
    ("catch up with", "v.", "赶上"),
    ("catch a cold", "v.", "感冒"),
    ("catch fire", "v.", "着火"),
    ("do exercise", "v.", "做运动；锻炼"),
    ("do homework", "v.", "做作业"),
    ("do business", "v.", "做生意"),
    ("have a fever", "v.", "发烧"),
    ("have a look", "v.", "看一看"),
    ("have a rest", "v.", "休息一下"),
    ("have a good time", "v.", "玩得开心"),
    ("have breakfast", "v.", "吃早餐"),
    ("have access to", "v.", "有权使用；可以接触到"),
    ("have an impact on", "v.", "对…有影响"),
    ("have an effect on", "v.", "对…有影响"),
    ("lose weight", "v.", "减肥"),
    ("gain weight", "v.", "增重；发胖"),
    ("earn money", "v.", "赚钱"),
    ("save money", "v.", "省钱；存钱"),
    ("waste time", "v.", "浪费时间"),
    ("tell the truth", "v.", "说实话"),
    ("tell a lie", "v.", "说谎"),
    ("draw a conclusion", "v.", "得出结论"),
    ("carry out a survey", "v.", "进行调查"),
    ("play an important part in", "v.", "在…中起重要作用"),

    # ── be + adj. + prep. ───────────────────────────────────────────
    ("be fond of", "adj.", "喜欢；爱好"),
    ("be proud of", "adj.", "以…为荣"),
    ("be responsible for", "adj.", "对…负责"),
    ("be interested in", "adj.", "对…感兴趣"),
    ("be good at", "adj.", "擅长"),
    ("be bad at", "adj.", "不擅长"),
    ("be made of", "adj.", "由…制成"),
    ("be satisfied with", "adj.", "对…满意"),
    ("be tired of", "adj.", "对…厌倦"),
    ("be afraid of", "adj.", "害怕"),
    ("be different from", "adj.", "与…不同"),
    ("be similar to", "adj.", "与…相似"),
    ("be famous for", "adj.", "因…而闻名"),
    ("be full of", "adj.", "充满"),
    ("be worth doing", "adj.", "值得做"),
    ("be capable of", "adj.", "有能力做；能够"),
    ("be keen on", "adj.", "热衷于；喜爱"),
    ("be short of", "adj.", "缺少；不足"),
    ("be busy with", "adj.", "忙于"),
    ("be involved in", "adj.", "参与；卷入"),

    # ── 数量 / 限定搭配 ──────────────────────────────────────────────
    ("a great deal of", "det.", "大量的"),
    ("a large number of", "det.", "大量的；许多的"),
    ("a variety of", "det.", "各种各样的"),
    ("the majority of", "det.", "大多数"),
    ("a great many", "det.", "许多；大量"),
    ("a number of", "det.", "若干；一些"),
    ("the rest of", "det.", "其余的"),
    ("a couple of", "det.", "几个；一对"),
    ("a great amount of", "det.", "大量的"),
    ("a series of", "det.", "一系列"),

    # ── 日常口语 ────────────────────────────────────────────────────
    ("long time no see", "int.", "好久不见"),
    ("never mind", "int.", "没关系；别介意"),
    ("what's up", "int.", "怎么了；最近如何"),
    ("thank goodness", "int.", "谢天谢地"),
    ("my pleasure", "int.", "我的荣幸；不客气"),
    ("you're welcome", "int.", "不客气"),
    ("see you later", "int.", "回头见；再见"),
    ("no problem", "int.", "没问题"),
    ("it doesn't matter", "int.", "没关系"),
    ("that's all right", "int.", "没关系；不用谢"),
    ("I'm afraid so", "int.", "恐怕是这样"),
    ("make yourself at home", "int.", "别拘束；当自己家"),
    ("how are you doing", "int.", "你好吗；最近怎么样"),
    ("in a hurry", "adv.", "匆忙；赶时间"),
    ("on the way", "adv.", "在路上；在途中"),
    ("in the way", "adv.", "挡道；妨碍"),
    ("on the other hand", "adv.", "另一方面"),
    ("even though", "conj.", "即使；虽然"),
    ("as if", "conj.", "好像；似乎"),
    ("as though", "conj.", "好像；仿佛"),
    ("so that", "conj.", "以便；为了"),
    ("such as", "conj.", "例如；诸如"),
    ("in case", "conj.", "以防；万一"),
    ("in order that", "conj.", "为了；以便"),
]

# ---------------------------------------------------------------- 过滤用的词表 / 正则
WORD_RE = re.compile(r"^[a-z][a-z'\-]*$")
PHRASE_RE = re.compile(r"^[a-z][a-z'\-]*(?: [a-z][a-z'\-]*){1,3}$")
# 领域标记 / 词性标记 / 释义里的括注，三种都要**循环剥**（见 clean_gloss）
DOMAIN_MARKER = re.compile(r"^[\[［]\s*[^\]］]{1,10}\s*[\]］]")
INLINE_MARKER = re.compile(r"[\[［][^\]］]{1,24}[\]］]")
PAREN_NOTE = re.compile(r"[（(][^）)]*[）)]")
ELLIPSIS = re.compile(r"\.{2,}|。{2,}")
# ⚠️ 必须含 `v.`（ECDICT 里有 `v. 全体地` 这种写法，漏了它会出一条以「v.」开头的释义）；
# 也要能吃掉**复合标记**（`vt.& vi. 盼望` 这种一个词条挂两个词性的写法）。
POS_MARKER = re.compile(
    r"^(?:(?:un|na|vt|vi|v|n|a|ad|adv|prep|conj|pron|int|det|abbr|aux|num)\.[\s&]*)+",
    re.I,
)
JUNK_PREFIX = re.compile(r"^[\[［]?\s*(人名|地名|网络|缩写|词根|词组|商标)")

# ECDICT 把合成词拆开又重收了一份的**真·artifact**。
#
# ⚠️ 这里刻意是**显式名单**而不是一条通用规则（「拼合后是单词就丢掉」）。
# 那条通用规则试过：它会剔掉 141 条，其中约 130 条是真词组 ——
# `air force` / `ice cream` / `living room` / `post office` / `time zone` /
# `vice versa` / `best seller` …… 因为 ECDICT 里 `airforce`、`icecream` 同样存在，
# 而它们与拆开那份**都是标准写法**。用一条规则牺牲 130 条换 8 条，代价不对。
# 名单里的这些，拼合形式才是唯一正确写法。
SPLIT_ARTIFACTS = {
    "main land",      # mainland
    "main stream",    # mainstream
    "down stairs",    # downstairs
    "black smith",    # blacksmith
    "man date",       # mandate（ECDICT 把它拆成了两个词）
    "head way",       # headway
    "high lands",     # highlands
    "new found",      # newfound
    "old fashioned",  # 这一条的 ECDICT 释义是「古典鸡尾酒」，也是错义
    "ha ha",          # 拟声词，不是搭配
    "uh huh",         # 同上
}

# 小品词：`break down` / `put out` 的第二个词。用来识别「动词+小品词」这种形状。
PARTICLES = set("up down off on in out away back over through along around about into".split())

# ---------------------------------------------------------------- 常用短语（只给词条，释义取 ECDICT）
#
# 这是一条**中间路线**，分工是全篇最要紧的一点：
#   · **收哪些**由这张表定（这是主观挑选，无法从语料推出来）；
#   · **中文释义**一律取 ECDICT（`translation`），一个都不自己写。
#
# 为什么需要它：手写那 297 条偏向考试里的介词框架与固定搭配，日常**短语动词**严重缺席
# —— 实测拿 170 条最常用短语动词去比，只命中 6 条（`give up` / `take care of` /
# `look forward to` / `put up with` 全都不在册）。而 ECDICT 的柯林斯星标只覆盖
# 777 条多词条目，短语动词一条都没星标，所以光靠星标那一路也补不上。
#
# ⚠️ 每条都必须能在 ECDICT 里查到并洗出干净释义，否则脚本**直接报错退出**：
# 不允许静默少收 —— 那会让「说好收了 give up」变成一句无从核对的空话。
COMMON_PHRASES = """
give up|take care of|look forward to|put up with|get up|wake up|turn to|work on|depend on
agree with|deal with|look for|wait for|listen to|speak to|think about|talk about|ask for
arrive at|arrive in|believe in|break out|bring about|call off|call on|carry out|catch up
check in|check out|clear up|come about|come along|come back|come down|come in|come on|come out
cut down|cut off|die out|dress up|drop by|drop out|eat out|fall asleep|fall behind|fall down
fall in love|fill in|fill out|focus on|get along|get back|get down|get in|get off|get on
get out|get together|give back|go after|go away|go back|go down|go in|go off|go up|grow up
hand out|hang on|hang out|hold back|hold up|hurry up|join in|keep away|keep down|keep on
keep out|knock down|lay off|let in|let out|live on|look around|look back|look down
look over|look through|make out|make up for|move on|pass away|pass by|pass on|pay back|pay off
pick out|point at|pull over|put away|put back|put down|put forward|put together|put up|ring up
run out of|run over|see off|sell out|send for|set aside|set down|settle down|show off|show up
shut down|shut up|sit down|slow down|sort out|speak up|stand by|stand for|stand out|stand up
stay up|stick to|switch off|switch on|take away|take back|take down|take in|take out|take to
talk over|tear down|tell off|throw away|throw up|try on|try out|turn around|turn back|turn over
turn round|use up|warm up|wash up|watch out|wear out|write down|write off|bring back|bring down
bring in|break away|break in|break off
""".strip().replace("\n", "|").split("|")

# 虚词：一个词组**全部**由它们组成就没有练习价值（`to be` / `of and on`）
FUNCTION_WORDS = set("""
the a an and or but nor so yet if than then that this these those
i you he she it we they me him her us them my your his its our their mine yours
am is are was were be been being do does did done have has had having
will would shall should can could may might must
at by for from in into of on onto to with within without over under above below
up down off out away back through along across around about after before between among during
not no very too also only just even still here there now once again ever never
as such all any some each every both either neither much many more most less least few little
one two three first second last next own same other another
""".split())

MAX_GLOSS = 22


def clean_gloss(translation: str) -> str | None:
    """把 ECDICT 的 translation 洗成一行能当推荐语用的中文。

    ⚠️ 两件必须记住的事：

    1. **领域标记（`[医] [计] [经]`）是附加义项而不是脏数据**：
       `血压\\n[医] 血压` 第一行完全可用。所以是**剥掉带标记的行**，不是丢掉整条。
    2. **词性标记与领域标记会交替出现**（`n. [医]最后结果; 成品鉴定`），
       而且领域标记还可能**夹在释义中间**（`n. [美国俚语]名人, 要人, ...`）。
       所以必须**循环剥**，剥不动为止，不能只剥一层 —— 只剥一层就会漏出
       以「[医]」「[美国俚语]」开头的释义。
    """
    if not translation.strip():
        return None
    lines = [line.strip() for line in translation.replace("\\n", "\n").split("\n")]
    lines = [line for line in lines if line]
    if not lines:
        return None
    # 首行就是人名 / 地名 / 网络用语 → 整条不要（这是 Skill 文档里写明的噪声判据）
    if JUNK_PREFIX.match(lines[0]):
        return None

    for line in lines:
        text = line
        while True:
            before = text
            text = POS_MARKER.sub("", text)
            text = DOMAIN_MARKER.sub("", text)
            text = INLINE_MARKER.sub("", text)
            text = text.strip()
            if text == before:
                break
        if not text:
            continue
        if JUNK_PREFIX.match(text):
            continue
        if re.search(r"[A-Za-z]{2,}", text):
            continue                         # 混拉丁文 = 没译
        text = PAREN_NOTE.sub("", text).strip()   # 括注是用法说明，不是词义
        if not text:
            continue
        # `把...拿出来` 里的 `...` 是**宾语占位符**（中文词典的通行写法），不是句式模板 ——
        # 规范成单字符的 `…`，与手写表里的 `在…前面` 保持一致。
        # ⚠️ 曾经把「带省略号」当模板整条丢掉，结果 `give up` / `agree with` /
        # `look over` 这些最常用的短语全部被误杀。
        text = ELLIPSIS.sub("…", text)
        parts = [p.strip() for p in re.split(r"[,，;；]", text) if p.strip()]
        if not parts:
            continue
        gloss = "；".join(parts[:2])
        if len(gloss) > MAX_GLOSS:
            gloss = parts[0][:MAX_GLOSS]
        if gloss:
            return gloss
    return None


def load_ecdict() -> tuple[list[dict], set[str], dict[str, str]]:
    """读 ECDICT：返回（多词条目, 屈折形式集合, 多词词条→原始释义）。"""
    if not ECDICT_CSV.exists():
        print(f"⚠️ 没有 ECDICT CSV（{ECDICT_CSV}），只写手写那一路。")
        return [], set(), {}

    multi: list[dict] = []
    inflected: set[str] = set()
    by_word: dict[str, str] = {}
    with ECDICT_CSV.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            word = (row["word"] or "").strip()
            if " " in word:
                multi.append(row)
                by_word.setdefault(word.lower(), row["translation"] or "")
                continue
            lower = word.lower()
            if not WORD_RE.fullmatch(lower):
                continue
            if "0:" in (row["exchange"] or ""):
                inflected.add(lower)
    return multi, inflected, by_word


def from_common_phrases(by_word: dict[str, str]) -> tuple[list[tuple[str, str]], list[str]]:
    """`COMMON_PHRASES` 那张表：词条我定，**释义全部取 ECDICT**。

    拿不到干净释义的一律进返回的第二项（缺料清单），由调用方**报错退出**。
    """
    picked: list[tuple[str, str]] = []
    missing: list[str] = []
    for item in COMMON_PHRASES:
        word = item.strip().lower()
        if not word:
            continue
        gloss = clean_gloss(by_word.get(word, ""))
        if gloss:
            picked.append((word, gloss))
        else:
            missing.append(word)
    return picked, missing


def from_ecdict(multi: list[dict], inflected: set[str]) -> tuple[list[tuple[str, str]], dict]:
    """从 ECDICT 多词条目里取柯林斯星级 > 0 的。返回（(word, zh) 列表, 统计）。"""
    stats = {"multi": len(multi), "noStar": 0, "badForm": 0, "inflected": 0,
             "splitArtifact": 0, "allFunction": 0, "badGloss": 0, "ok": 0}
    # 一律小写，与另外三本书**保持一致**：它们是用 `^[a-z][a-z'\-]{1,23}$` 从 ECDICT 抽的，
    # 全小写；词组书若留着 `high Command` / `Mickey Mouse` 这种混排大小写，
    # 同一本词典库里会出现两套写法。查询本身是不区分大小写的，小写不损失任何信息。
    picked: dict[str, str] = {}
    for row in multi:
        word = (row["word"] or "").strip()
        star = (row["collins"] or "").strip()
        if not (star.isdigit() and int(star) > 0):
            stats["noStar"] += 1
            continue
        lower = word.lower()
        if not PHRASE_RE.fullmatch(lower):
            stats["badForm"] += 1
            continue
        parts = lower.split()
        # 屈折形式不能当词条，但**只对「动词+小品词」这种形状**较真：
        # `went out` / `worn out` / `bogged down` 该收的是 `go out` / `wear out` / `bog down`。
        # ⚠️ 不能对整条词组做这个检查 —— ECDICT 把 `living`（live 的现在分词）、
        # `best`（good 的最高级）也算屈折形，照整条查会把 `living room` / `best seller`
        # 一起误杀（实测掉 165 条里绝大多数是这类名词词组）。
        if len(parts) == 2 and parts[1] in PARTICLES and parts[0] in inflected:
            stats["inflected"] += 1
            continue
        if lower in SPLIT_ARTIFACTS:
            stats["splitArtifact"] += 1
            continue
        if all(part in FUNCTION_WORDS for part in parts):
            stats["allFunction"] += 1
            continue
        gloss = clean_gloss(row["translation"] or "")
        if not gloss:
            stats["badGloss"] += 1
            continue
        picked.setdefault(lower, gloss)
        stats["ok"] += 1
    return sorted(picked.items()), stats


def main() -> None:
    multi, inflected, by_word = load_ecdict()
    ecdict_entries, stats = from_ecdict(multi, inflected) if multi else ([], {})
    if multi:
        print("ECDICT 多词条目:", stats["multi"])
        print("  无星标:", stats["noStar"], " 词形不合:", stats["badForm"],
              " 屈折形式:", stats["inflected"], " 拆词变体:", stats["splitArtifact"],
              " 全虚词:", stats["allFunction"], " 释义不合格:", stats["badGloss"])
        print("  采用:", len(ecdict_entries))

    common_entries, common_missing = from_common_phrases(by_word) if by_word else ([], [])
    if by_word:
        print("常用短语表:", len(COMMON_PHRASES), "条 → 取到释义", len(common_entries))
    if common_missing:
        # 不静默少收：这张表是「这批短语一定收全」的承诺，缺了就改表或修清洗规则。
        raise SystemExit(
            "❌ 下面这些常用短语拿不到干净释义，请改清洗规则或从表里去掉：\n  "
            + "\n  ".join(common_missing)
        )

    curated_keys = {w.strip().lower() for w, _, _ in CURATED}
    assert len(curated_keys) == len(CURATED), "手写表内部有重复"

    rows = [{"word": w, "pos": p, "zh": z, "difficulty": 4} for w, p, z in CURATED]
    seen = set(curated_keys)
    added_ecdict = 0
    added_common = 0
    # 顺序即优先级：手写策展（释义最短最准）> 常用短语表 > 柯林斯星标。
    for word, gloss in common_entries:
        if word in seen:
            continue
        seen.add(word)
        rows.append({"word": word, "pos": "", "zh": gloss, "difficulty": 4})
        added_common += 1
    for word, gloss in ecdict_entries:
        if word in seen:
            continue
        seen.add(word)
        rows.append({"word": word, "pos": "", "zh": gloss, "difficulty": 4})
        added_ecdict += 1

    # ---- 自检（写盘前就拦下）----
    keys = [r["word"].strip().lower() for r in rows]
    assert len(set(keys)) == len(keys), "产出里有重复词条"
    assert all(r["difficulty"] == 4 for r in rows), "词组书里混进了非词组档"
    assert all(" " in r["word"] for r in rows), "词组书里混进了单字词条"
    assert all(r["zh"].strip() for r in rows), "有条目没释义"
    assert all(len(r["zh"]) <= MAX_GLOSS + 6 for r in rows), "释义超长，会撑破一行"

    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / "phrases.json"
    with out.open("w", encoding="utf-8") as handle:
        json.dump(rows, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print("写出:", out)
    print("条目:", len(rows),
          f"（手写 {len(CURATED)} + 常用短语 {added_common} + 星标 {added_ecdict}）")

    # 与三本词书的重合只作提示：跨书同名由选词器去重，不占两个名额。
    existing: set[str] = set()
    for book in ("cet6", "ielts", "oxford"):
        path = OUT / f"{book}.json"
        if path.exists():
            with path.open(encoding="utf-8") as handle:
                for item in json.load(handle):
                    existing.add(item["word"].strip().lower())
    overlap = sorted(set(keys) & existing)
    print("与三本词书重合:", len(overlap), overlap)

    print("\n--- 抽查释义（前 12 条手写 / 前 12 条 ECDICT）---")
    for row in rows[:12]:
        print(f'  手写   {row["word"]:26s} | {row["pos"]:6s} {row["zh"]}')
    for row in rows[len(CURATED):len(CURATED) + 12]:
        print(f'  ECDICT {row["word"]:26s} |        {row["zh"]}')


if __name__ == "__main__":
    sys.exit(main())
