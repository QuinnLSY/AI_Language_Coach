#!/usr/bin/env python3
"""生成内置词典资源（Sources/AIInfrastructure/Resources/Dictionaries/*.json）。

## 两样东西必须来自外部，不能手写

- **词表与中文释义**：手写几百个词还能忍，手写几千个词就是拿错误当数据。
  所以主源用 ECDICT（英汉双解，按考试大纲打了 cet6 / ielts 标签，
  牛津三千核心词有独立的 oxford 位）：https://github.com/skywind3000/ECDICT
- **音标**：手写音标几乎必然出错。ECDICT 自带的是老式 ASCII 音标
  （`ә'bændәn`），与本项目其余部分的现代 IPA 风格不一致，
  所以只取它的**词表 / 释义 / 标签**，音标一律用离线 IPA 词典
  （eng_to_ipa / CMUdict）另生成 —— 同一本词典内部音标风格必须一致。

ECDICT 的 CSV 不进仓库（66MB）。没有 CSV 时退回本文件里的手写词表，
保证无网环境也能重建资源（只是词少）。词组（`give up` 这类）ECDICT 没有
考试标签，一律从手写词表里补进来 —— 每日推荐有「词组」这一档，缺了它那一档就空了。

用法：
  /Users/chenjianxu/.workbuddy/binaries/python/envs/default/bin/python Scripts/build_dictionaries.py
  环境变量 ECDICT_CSV 可指定 CSV 路径（默认 .workbuddy/build/ecdict/ecdict.csv）。
"""
import csv
import json
import os
import pathlib
import re
import sys

try:
    import eng_to_ipa as ipa
except ImportError:  # pragma: no cover - 没装依赖时只影响音标
    ipa = None

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/AIInfrastructure/Resources/Dictionaries"
IELTS_SRC = ROOT / "Sources/AIInfrastructure/Resources/Vocabulary/ielts_words.json"
ECDICT_CSV = pathlib.Path(
    os.environ.get("ECDICT_CSV") or (ROOT / ".workbuddy/build/ecdict/ecdict.csv")
)

csv.field_size_limit(10 ** 9)

# ---------------------------------------------------------------- 离线兜底词表
# 只有在没有 ECDICT CSV 时才整本使用；有 CSV 时只贡献其中的**词组**。
# 之所以留着：无网环境要能重建资源，且短语是 ECDICT 标签体系覆盖不到的部分。
FALLBACK_OXFORD = [
    ("be", "v.", "是；存在", 1), ("have", "v.", "有；拥有", 1),
    ("do", "v.", "做；干", 1), ("say", "v.", "说；讲", 1),
    ("go", "v.", "去；走", 1), ("get", "v.", "得到；变得", 1),
    ("make", "v.", "做；制造；使得", 1), ("know", "v.", "知道；认识", 1),
    ("think", "v.", "想；认为", 1), ("take", "v.", "拿；花费；乘坐", 1),
    ("see", "v.", "看见；理解", 1), ("come", "v.", "来；到达", 1),
    ("want", "v.", "想要；需要", 1), ("use", "v./n.", "使用；用途", 1),
    ("find", "v.", "找到；发现", 1), ("give", "v.", "给；提供", 1),
    ("tell", "v.", "告诉；讲述", 1), ("work", "v./n.", "工作；起作用", 1),
    ("call", "v./n.", "打电话；称呼", 1), ("try", "v./n.", "尝试；努力", 1),
    ("ask", "v.", "问；请求", 1), ("need", "v./n.", "需要；必要", 1),
    ("feel", "v.", "感觉；觉得", 1), ("become", "v.", "变成；成为", 1),
    ("leave", "v.", "离开；留下", 1), ("put", "v.", "放；摆放", 1),
    ("mean", "v./adj.", "意思是；吝啬的", 1), ("keep", "v.", "保持；保存", 1),
    ("let", "v.", "让；允许", 1), ("begin", "v.", "开始", 1),
    ("seem", "v.", "似乎；好像", 1), ("help", "v./n.", "帮助；有助于", 1),
    ("talk", "v./n.", "谈话；交谈", 1), ("turn", "v./n.", "转动；轮到", 1),
    ("start", "v./n.", "开始；启动", 1), ("show", "v./n.", "展示；演出", 1),
    ("hear", "v.", "听见；听说", 1), ("play", "v./n.", "玩；播放；戏剧", 1),
    ("run", "v.", "跑；经营", 1), ("move", "v./n.", "移动；搬家", 1),
    ("live", "v./adj.", "居住；活的", 1), ("believe", "v.", "相信；认为", 1),
    ("bring", "v.", "带来；引起", 1), ("happen", "v.", "发生；碰巧", 1),
    ("write", "v.", "写；写作", 1), ("sit", "v.", "坐；位于", 1),
    ("stand", "v.", "站；忍受", 1), ("lose", "v.", "丢失；输掉", 1),
    ("pay", "v./n.", "付款；工资", 1), ("meet", "v.", "遇见；满足", 1),
    ("include", "v.", "包括；包含", 1), ("continue", "v.", "继续；持续", 1),
    ("change", "v./n.", "改变；零钱", 1), ("learn", "v.", "学习；得知", 1),
    ("lead", "v.", "带领；导致", 1), ("understand", "v.", "理解；明白", 1),
    ("watch", "v./n.", "观看；手表", 1), ("follow", "v.", "跟随；遵循", 1),
    ("stop", "v./n.", "停止；车站", 1), ("create", "v.", "创造；建立", 1),
    ("speak", "v.", "说话；发言", 1), ("read", "v.", "阅读；读懂", 1),
    ("spend", "v.", "花费；度过", 1), ("grow", "v.", "生长；增长", 1),
    ("open", "v./adj.", "打开；开放的", 1), ("walk", "v./n.", "走；散步", 1),
    ("win", "v.", "赢；获胜", 1), ("offer", "v./n.", "提供；提议", 1),
    ("remember", "v.", "记得；想起", 1), ("love", "v./n.", "爱；喜爱", 1),
    ("consider", "v.", "考虑；认为", 2), ("appear", "v.", "出现；显得", 2),
    ("buy", "v.", "购买", 1), ("wait", "v.", "等待", 1),
    ("serve", "v.", "服务；供应", 2), ("send", "v.", "发送；寄送", 1),
    ("expect", "v.", "期待；预计", 2), ("build", "v.", "建造；建立", 1),
    ("stay", "v.", "停留；保持", 1), ("fall", "v./n.", "落下；秋天", 1),
    ("cut", "v.", "切；削减", 1), ("reach", "v.", "到达；伸手", 2),
    ("kill", "v.", "杀死；消磨", 2), ("remain", "v.", "保持；剩下", 2),
    ("time", "n.", "时间；次数", 1), ("year", "n.", "年；年度", 1),
    ("people", "n.", "人们；民族", 1), ("way", "n.", "方法；道路", 1),
    ("day", "n.", "白天；日子", 1), ("man", "n.", "男人；人类", 1),
    ("thing", "n.", "东西；事情", 1), ("life", "n.", "生命；生活", 1),
    ("child", "n.", "孩子；儿童", 1), ("world", "n.", "世界；领域", 1),
    ("school", "n.", "学校；学派", 1), ("state", "n.", "状态；国家", 1),
    ("family", "n.", "家庭；家族", 1), ("student", "n.", "学生", 1),
    ("group", "n.", "组；群体", 1), ("country", "n.", "国家；乡村", 1),
    ("problem", "n.", "问题；难题", 1), ("hand", "n.", "手；帮助", 1),
    ("part", "n.", "部分；角色", 1), ("place", "n.", "地方；位置", 1),
    ("week", "n.", "星期；周", 1), ("company", "n.", "公司；陪伴", 1),
    ("system", "n.", "系统；制度", 1), ("program", "n.", "节目；程序", 1),
    ("question", "n.", "问题；疑问", 1), ("case", "n.", "情况；案件；箱子", 2),
    ("point", "n./v.", "要点；指出", 1), ("government", "n.", "政府；治理", 1),
    ("number", "n.", "数字；号码", 1), ("night", "n.", "夜晚；晚上", 1),
    ("home", "n.", "家；家乡", 1), ("water", "n.", "水；水域", 1),
    ("room", "n.", "房间；空间", 1), ("mother", "n.", "母亲", 1),
    ("area", "n.", "地区；面积；领域", 2), ("money", "n.", "钱；货币", 1),
    ("story", "n.", "故事；报道", 1), ("fact", "n.", "事实；真相", 1),
    ("month", "n.", "月；月份", 1), ("lot", "n.", "大量；一块地", 1),
    ("book", "n./v.", "书；预订", 1), ("eye", "n.", "眼睛；眼光", 1),
    ("job", "n.", "工作；职责", 1), ("word", "n.", "单词；话语", 1),
    ("business", "n.", "生意；事务", 2), ("issue", "n./v.", "问题；发行", 2),
    ("side", "n.", "边；方面", 1), ("kind", "n./adj.", "种类；善良的", 1),
    ("head", "n.", "头；负责人", 1), ("house", "n.", "房子；议院", 1),
    ("friend", "n.", "朋友", 1), ("father", "n.", "父亲", 1),
    ("hour", "n.", "小时；时刻", 1), ("game", "n.", "游戏；比赛", 1),
    ("line", "n.", "线；排队；台词", 1), ("end", "n./v.", "结束；末端", 1),
    ("member", "n.", "成员；会员", 2), ("law", "n.", "法律；定律", 2),
    ("car", "n.", "汽车；车厢", 1), ("city", "n.", "城市", 1),
    ("community", "n.", "社区；群体", 2), ("name", "n./v.", "名字；命名", 1),
    ("team", "n.", "团队；队伍", 1), ("minute", "n.", "分钟；片刻", 1),
    ("idea", "n.", "想法；主意", 1), ("kid", "n.", "小孩；开玩笑", 1),
    ("body", "n.", "身体；主体", 1), ("information", "n.", "信息；资料", 2),
    ("back", "n./adv.", "背部；向后", 1), ("parent", "n.", "父母；根源", 1),
    ("face", "n./v.", "脸；面对", 1), ("level", "n.", "水平；层级", 2),
    ("office", "n.", "办公室；职务", 1), ("door", "n.", "门；门口", 1),
    ("health", "n.", "健康；卫生", 1), ("person", "n.", "人；个人", 1),
    ("art", "n.", "艺术；技巧", 1), ("war", "n.", "战争；斗争", 2),
    ("history", "n.", "历史；来历", 1), ("party", "n.", "聚会；政党", 1),
    ("result", "n./v.", "结果；导致", 2), ("morning", "n.", "早晨；上午", 1),
    ("reason", "n./v.", "原因；推理", 2), ("research", "n./v.", "研究；调查", 2),
    ("girl", "n.", "女孩", 1), ("guy", "n.", "家伙；人", 1),
    ("food", "n.", "食物；养料", 1), ("moment", "n.", "时刻；瞬间", 2),
    ("air", "n.", "空气；神态", 1), ("teacher", "n.", "教师；老师", 1),
    ("force", "n./v.", "力量；迫使", 2), ("education", "n.", "教育；培养", 1),
    ("process", "n./v.", "过程；加工", 2), ("music", "n.", "音乐；乐曲", 1),
    ("culture", "n.", "文化；文明", 1), ("big", "adj.", "大的；重要的", 1),
    ("good", "adj.", "好的；擅长的", 1), ("new", "adj.", "新的；陌生的", 1),
    ("first", "adj.", "第一的；最初的", 1), ("last", "adj.", "最后的；上一个的", 1),
    ("long", "adj.", "长的；长久的", 1), ("great", "adj.", "伟大的；很好的", 1),
    ("little", "adj.", "小的；少的", 1), ("own", "adj.", "自己的", 1),
    ("other", "adj.", "其他的；另一个", 1), ("old", "adj.", "老的；旧的", 1),
    ("right", "adj./n.", "正确的；权利", 1), ("high", "adj.", "高的；高级的", 1),
    ("small", "adj.", "小的；年幼的", 1), ("large", "adj.", "大的；大量的", 1),
    ("next", "adj.", "下一个的；紧邻的", 1), ("early", "adj./adv.", "早的；提前", 1),
    ("young", "adj.", "年轻的；幼小的", 1), ("hard", "adj./adv.", "困难的；努力地", 1),
    ("bad", "adj.", "坏的；严重的", 1), ("same", "adj.", "相同的；同样的", 1),
    ("able", "adj.", "能够的；有能力的", 2), ("free", "adj.", "自由的；免费的", 1),
    ("full", "adj.", "满的；充分的", 1), ("special", "adj.", "特别的；专门的", 1),
    ("easy", "adj.", "容易的；轻松的", 1), ("clear", "adj.", "清楚的；晴朗的", 1),
    ("recent", "adj.", "最近的；近来的", 2), ("certain", "adj.", "确定的；某些的", 2),
    ("personal", "adj.", "个人的；私人的", 2), ("red", "adj.", "红色的", 1),
    ("difficult", "adj.", "困难的；难对付的", 1), ("available", "adj.", "可用的；可获得的", 2),
    ("likely", "adj.", "可能的；有希望的", 2), ("short", "adj.", "短的；缺乏的", 1),
    ("local", "adj.", "当地的；局部的", 2), ("sure", "adj.", "确信的；肯定的", 1),
    ("strong", "adj.", "强壮的；强烈的", 1), ("common", "adj.", "共同的；常见的", 2),
    ("whole", "adj.", "整个的；完整的", 1), ("similar", "adj.", "相似的；类似的", 2),
    ("serious", "adj.", "严肃的；严重的", 2), ("ready", "adj.", "准备好的；乐意的", 1),
    ("simple", "adj.", "简单的；朴素的", 1), ("true", "adj.", "真实的；忠实的", 1),
    ("national", "adj.", "国家的；全国的", 2), ("natural", "adj.", "自然的；天生的", 2),
    ("physical", "adj.", "身体的；物理的", 2), ("financial", "adj.", "财政的；金融的", 3),
    ("in the end", "phrase", "最后；终于", 4), ("at least", "phrase", "至少", 4),
    ("as well as", "phrase", "以及；和……一样好", 4), ("in fact", "phrase", "事实上", 4),
    ("by the way", "phrase", "顺便说一句", 4), ("at first", "phrase", "起初；一开始", 4),
    ("for example", "phrase", "例如", 4), ("of course", "phrase", "当然", 4),
    ("on time", "phrase", "准时", 4), ("take care of", "phrase", "照顾；负责", 4),
    ("look for", "phrase", "寻找", 4), ("look forward to", "phrase", "期待；盼望", 4),
    ("give up", "phrase", "放弃", 4), ("come up with", "phrase", "想出；提出", 4),
    ("deal with", "phrase", "处理；应对", 4), ("depend on", "phrase", "取决于；依赖", 4),
    ("instead of", "phrase", "代替；而不是", 4), ("according to", "phrase", "根据；按照", 4),
    ("in order to", "phrase", "为了", 4), ("as a result", "phrase", "结果；因此", 4),
]

FALLBACK_CET6 = [
    ("abandon", "v.", "放弃；抛弃", 2), ("absolute", "adj.", "绝对的；完全的", 2),
    ("abstract", "adj./n.", "抽象的；摘要", 3), ("academic", "adj.", "学术的；学院的", 2),
    ("accelerate", "v.", "加速；促进", 3), ("accommodate", "v.", "容纳；适应；提供住宿", 3),
    ("accomplish", "v.", "完成；实现", 2), ("accumulate", "v.", "积累；堆积", 3),
    ("accurate", "adj.", "准确的；精确的", 2), ("acknowledge", "v.", "承认；致谢", 3),
    ("adequate", "adj.", "充足的；适当的", 3), ("adjust", "v.", "调整；适应", 2),
    ("administrate", "v.", "管理；实施", 3), ("adopt", "v.", "采用；收养", 2),
    ("advocate", "v./n.", "提倡；拥护者", 3), ("aggressive", "adj.", "好斗的；积极进取的", 3),
    ("alternative", "n./adj.", "替代方案；可供选择的", 3), ("ambiguous", "adj.", "模棱两可的；含糊的", 3),
    ("anticipate", "v.", "预料；期望", 3), ("apparent", "adj.", "明显的；表面上的", 3),
    ("appreciate", "v.", "欣赏；感激；理解", 2), ("appropriate", "adj.", "恰当的；合适的", 2),
    ("approximate", "adj.", "大约的；近似的", 3), ("arbitrary", "adj.", "任意的；专断的", 3),
    ("assemble", "v.", "集合；组装", 3), ("assign", "v.", "分配；指派", 3),
    ("assume", "v.", "假定；承担", 2), ("assure", "v.", "保证；使确信", 3),
    ("attach", "v.", "附上；使依恋", 3), ("attitude", "n.", "态度；看法", 2),
    ("attribute", "v./n.", "归因于；属性", 3), ("authority", "n.", "权威；当局", 3),
    ("benefit", "n./v.", "利益；受益", 2), ("budget", "n.", "预算；经费", 2),
    ("capable", "adj.", "有能力的；能够的", 2), ("capacity", "n.", "容量；能力", 3),
    ("category", "n.", "类别；范畴", 3), ("challenge", "n./v.", "挑战；质疑", 2),
    ("characteristic", "n./adj.", "特征；典型的", 3), ("circumstance", "n.", "情况；环境", 3),
    ("civilization", "n.", "文明；文明社会", 3), ("clarify", "v.", "澄清；阐明", 3),
    ("collapse", "v./n.", "倒塌；崩溃", 3), ("commit", "v.", "承诺；犯（错）", 3),
    ("compensate", "v.", "补偿；弥补", 3), ("competent", "adj.", "有能力的；称职的", 3),
    ("complicated", "adj.", "复杂的；难懂的", 2), ("comprehensive", "adj.", "全面的；综合的", 3),
    ("conclude", "v.", "得出结论；结束", 2), ("concrete", "adj./n.", "具体的；混凝土", 3),
    ("conflict", "n./v.", "冲突；矛盾", 3), ("consequence", "n.", "结果；后果", 3),
    ("considerable", "adj.", "相当大的；可观的", 3), ("consistent", "adj.", "一致的；连贯的", 3),
    ("constant", "adj.", "不变的；持续的", 3), ("constitute", "v.", "构成；组成", 3),
    ("consume", "v.", "消耗；消费", 3), ("contemporary", "adj.", "当代的；同时代的", 3),
    ("contribute", "v.", "贡献；促成", 3), ("controversial", "adj.", "有争议的", 3),
    ("convenient", "adj.", "方便的；便利的", 2), ("convey", "v.", "传达；运送", 3),
    ("convince", "v.", "使确信；说服", 3), ("cooperate", "v.", "合作；配合", 3),
    ("crucial", "adj.", "至关重要的", 3), ("cultivate", "v.", "培养；耕作", 3),
    ("decorate", "v.", "装饰；布置", 2), ("dedicate", "v.", "奉献；献身", 3),
    ("definite", "adj.", "明确的；确定的", 3), ("deliberate", "adj./v.", "故意的；仔细考虑", 3),
    ("demonstrate", "v.", "证明；演示", 3), ("deny", "v.", "否认；拒绝给予", 3),
    ("derive", "v.", "起源于；获得", 3), ("desperate", "adj.", "绝望的；拼命的", 3),
    ("destruction", "n.", "破坏；毁灭", 3), ("determine", "v.", "决定；确定", 2),
    ("devote", "v.", "致力于；献身", 3), ("diminish", "v.", "减少；削弱", 3),
    ("distinct", "adj.", "明显的；截然不同的", 3), ("distinguish", "v.", "区分；辨别", 3),
    ("distribute", "v.", "分配；分布", 3), ("diverse", "adj.", "多样的；不同的", 3),
    ("domestic", "adj.", "国内的；家庭的", 3), ("dominate", "v.", "支配；主导", 3),
    ("dramatic", "adj.", "戏剧性的；显著的", 3), ("eliminate", "v.", "消除；淘汰", 3),
    ("emerge", "v.", "出现；浮现", 3), ("emphasize", "v.", "强调；着重", 2),
    ("enclose", "v.", "围住；随函附上", 3), ("endure", "v.", "忍受；持续", 3),
    ("enhance", "v.", "提高；增强", 3), ("enormous", "adj.", "巨大的；庞大的", 3),
    ("ensure", "v.", "确保；保证", 3), ("entitle", "v.", "使有权利；给……命名", 3),
    ("essential", "adj.", "必要的；本质的", 3), ("establish", "v.", "建立；确立", 2),
    ("estimate", "v./n.", "估计；评价", 2), ("evaluate", "v.", "评估；评价", 3),
    ("eventually", "adv.", "最终；终于", 3), ("evident", "adj.", "明显的；显然的", 3),
    ("exaggerate", "v.", "夸大；夸张", 3), ("exceed", "v.", "超过；超越", 3),
    ("exclude", "v.", "排除；不包括", 3), ("exhibit", "v./n.", "展出；展品", 3),
    ("expand", "v.", "扩大；膨胀", 3), ("explicit", "adj.", "明确的；直言的", 3),
    ("explore", "v.", "探索；勘探", 2), ("expose", "v.", "暴露；揭露", 3),
    ("extend", "v.", "延伸；延长", 3), ("external", "adj.", "外部的；外来的", 3),
    ("facilitate", "v.", "促进；使便利", 3), ("fascinate", "v.", "使着迷；吸引", 3),
    ("flexible", "adj.", "灵活的；可弯曲的", 3), ("fluctuate", "v.", "波动；起伏", 3),
    ("forbid", "v.", "禁止；不准", 3), ("formal", "adj.", "正式的；形式的", 2),
    ("formulate", "v.", "制定；系统阐述", 3), ("frustrate", "v.", "使沮丧；挫败", 3),
    ("fundamental", "adj.", "基本的；根本的", 3), ("furthermore", "adv.", "此外；而且", 3),
    ("generate", "v.", "产生；生成", 3), ("genuine", "adj.", "真正的；真诚的", 3),
    ("gradually", "adv.", "逐渐地；渐渐地", 2), ("guarantee", "v./n.", "保证；担保", 3),
    ("identify", "v.", "识别；确认", 2), ("ignore", "v.", "忽视；不理会", 2),
    ("illustrate", "v.", "说明；举例说明", 3), ("imitate", "v.", "模仿；仿效", 3),
    ("immediate", "adj.", "立即的；直接的", 3), ("implement", "v.", "实施；执行", 3),
    ("imply", "v.", "暗示；意味着", 3), ("impose", "v.", "强加；征税", 3),
    ("impress", "v.", "给……深刻印象", 2), ("improve", "v.", "改善；提高", 1),
    ("incident", "n.", "事件；事变", 3), ("indicate", "v.", "表明；指示", 3),
    ("individual", "n./adj.", "个人；个别的", 2), ("inevitable", "adj.", "不可避免的", 3),
    ("influence", "n./v.", "影响；作用", 2), ("inform", "v.", "通知；告知", 3),
    ("ingredient", "n.", "成分；要素", 3), ("inherent", "adj.", "固有的；内在的", 3),
    ("initial", "adj./n.", "最初的；首字母", 3), ("innovate", "v.", "创新；革新", 3),
    ("insist", "v.", "坚持；坚决要求", 3), ("inspire", "v.", "激励；启发", 3),
    ("install", "v.", "安装；任命", 2), ("instant", "adj./n.", "立即的；瞬间", 3),
    ("institute", "n./v.", "机构；建立", 3), ("integrate", "v.", "整合；融入", 3),
    ("intense", "adj.", "强烈的；紧张的", 3), ("interpret", "v.", "解释；口译", 3),
    ("investigate", "v.", "调查；研究", 3), ("involve", "v.", "涉及；牵涉", 3),
    ("isolate", "v.", "隔离；孤立", 3), ("justify", "v.", "证明……正当；辩护", 3),
    ("launch", "v./n.", "发射；发起；推出", 3), ("legislation", "n.", "立法；法规", 3),
    ("maintain", "v.", "维持；保养", 3), ("majority", "n.", "多数；大多数", 3),
    ("manipulate", "v.", "操纵；控制", 3), ("manufacture", "v./n.", "制造；产品", 3),
    ("mature", "adj./v.", "成熟的；成熟", 3), ("mechanism", "n.", "机制；机械装置", 3),
    ("mention", "v.", "提到；提及", 2), ("minimum", "n./adj.", "最小值；最低的", 3),
    ("modify", "v.", "修改；调整", 3), ("monitor", "v./n.", "监控；显示器", 3),
    ("motivate", "v.", "激励；促使", 3), ("negative", "adj.", "消极的；负的", 3),
    ("neglect", "v.", "忽视；疏忽", 3), ("negotiate", "v.", "谈判；协商", 3),
    ("neutral", "adj.", "中立的；中性的", 3), ("nevertheless", "adv.", "然而；尽管如此", 3),
    ("obtain", "v.", "获得；得到", 3), ("obvious", "adj.", "明显的；显然的", 2),
    ("occupy", "v.", "占据；占用", 3), ("occur", "v.", "发生；出现", 2),
    ("oppose", "v.", "反对；对抗", 3), ("optimistic", "adj.", "乐观的", 3),
    ("organize", "v.", "组织；安排", 2), ("originate", "v.", "起源；发起", 3),
    ("overcome", "v.", "克服；战胜", 3), ("participate", "v.", "参加；参与", 3),
    ("particular", "adj.", "特别的；特定的", 2), ("perceive", "v.", "察觉；理解", 3),
    ("permanent", "adj.", "永久的；长期的", 3), ("persist", "v.", "坚持；持续", 3),
    ("perspective", "n.", "视角；观点", 3), ("persuade", "v.", "说服；劝说", 3),
    ("phenomenon", "n.", "现象；非凡的人", 3), ("philosophy", "n.", "哲学；人生观", 3),
    ("policy", "n.", "政策；保单", 2), ("potential", "adj./n.", "潜在的；潜力", 3),
    ("precise", "adj.", "精确的；准确的", 3), ("predict", "v.", "预测；预言", 3),
    ("prejudice", "n./v.", "偏见；使有偏见", 3), ("preserve", "v.", "保护；保存", 3),
    ("primarily", "adv.", "主要地；首先", 3), ("principle", "n.", "原则；原理", 3),
    ("priority", "n.", "优先；优先事项", 3), ("procedure", "n.", "程序；手续", 3),
    ("progress", "n./v.", "进步；进展", 2), ("prohibit", "v.", "禁止；阻止", 3),
    ("promote", "v.", "促进；提升", 2), ("propose", "v.", "提议；求婚", 3),
    ("prospect", "n.", "前景；可能性", 3), ("pursue", "v.", "追求；从事", 3),
    ("qualify", "v.", "使合格；取得资格", 3), ("quantity", "n.", "数量；量", 2),
    ("recognize", "v.", "认出；承认", 2), ("recommend", "v.", "推荐；建议", 2),
    ("reduce", "v.", "减少；降低", 1), ("reform", "n./v.", "改革；改造", 3),
    ("regardless", "adv.", "不管；无论", 3), ("register", "v./n.", "登记；注册表", 3),
    ("regulate", "v.", "管理；调节", 3), ("reinforce", "v.", "加强；巩固", 3),
    ("reject", "v.", "拒绝；否决", 3), ("relevant", "adj.", "相关的；切题的", 3),
    ("reliable", "adj.", "可靠的；可信赖的", 3), ("reluctant", "adj.", "不情愿的；勉强的", 3),
    ("remarkable", "adj.", "卓越的；非凡的", 3), ("remove", "v.", "移除；去除", 2),
    ("replace", "v.", "取代；更换", 2), ("represent", "v.", "代表；表示", 3),
    ("require", "v.", "需要；要求", 2), ("reserve", "v./n.", "预订；保留；储备", 3),
    ("resist", "v.", "抵抗；抵制", 3), ("resolve", "v.", "解决；决心", 3),
    ("resource", "n.", "资源；办法", 2), ("respond", "v.", "回应；响应", 3),
    ("restrict", "v.", "限制；约束", 3), ("retain", "v.", "保留；记住", 3),
    ("reveal", "v.", "揭示；透露", 3), ("reverse", "v./adj.", "颠倒；相反的", 3),
    ("review", "n./v.", "复习；评论", 2), ("revise", "v.", "修订；复习", 3),
    ("satisfy", "v.", "满足；使满意", 2), ("scarce", "adj.", "稀少的；缺乏的", 3),
    ("schedule", "n./v.", "日程；安排", 2), ("scrutinize", "v.", "仔细检查；细看", 3),
    ("secure", "adj./v.", "安全的；获得", 3), ("sensitive", "adj.", "敏感的；易受影响的", 3),
    ("significant", "adj.", "重要的；显著的", 3), ("simultaneously", "adv.", "同时地", 3),
    ("sophisticated", "adj.", "复杂精密的；老练的", 3), ("specific", "adj.", "具体的；特定的", 2),
    ("stable", "adj.", "稳定的；牢固的", 3), ("stimulate", "v.", "刺激；激励", 3),
    ("strategy", "n.", "策略；战略", 3), ("substitute", "n./v.", "替代品；代替", 3),
    ("subtle", "adj.", "微妙的；细微的", 3), ("sufficient", "adj.", "充足的；足够的", 3),
    ("summarize", "v.", "总结；概述", 3), ("superior", "adj.", "更好的；上级的", 3),
    ("supplement", "n./v.", "补充；增补", 3), ("suppose", "v.", "假设；认为", 3),
    ("sustain", "v.", "维持；承受", 3), ("technique", "n.", "技术；技巧", 3),
    ("temporary", "adj.", "临时的；暂时的", 3), ("tendency", "n.", "趋势；倾向", 3),
    ("thorough", "adj.", "彻底的；全面的", 3), ("transform", "v.", "转变；改造", 3),
    ("transmit", "v.", "传输；传播", 3), ("tremendous", "adj.", "巨大的；极好的", 3),
    ("ultimate", "adj.", "最终的；根本的", 3), ("undergo", "v.", "经历；遭受", 3),
    ("undertake", "v.", "承担；着手做", 3), ("unique", "adj.", "独特的；唯一的", 3),
    ("utilize", "v.", "利用；使用", 3), ("vague", "adj.", "模糊的；含糊的", 3),
    ("valid", "adj.", "有效的；正当的", 3), ("vanish", "v.", "消失；不见", 3),
    ("vary", "v.", "变化；使不同", 3), ("version", "n.", "版本；说法", 3),
    ("violate", "v.", "违反；侵犯", 3), ("virtue", "n.", "美德；优点", 3),
    ("visible", "adj.", "看得见的；明显的", 3), ("voluntary", "adj.", "自愿的；志愿的", 3),
    ("witness", "n./v.", "目击者；目睹", 3), ("yield", "v./n.", "产生；屈服；产量", 3),
    ("in terms of", "phrase", "就……而言；从……方面", 4),
    ("take into account", "phrase", "考虑到；把……考虑在内", 4),
    ("in addition to", "phrase", "除……之外（还）", 4),
    ("make up for", "phrase", "弥补；补偿", 4),
    ("at the expense of", "phrase", "以……为代价", 4),
    ("be aware of", "phrase", "意识到；知道", 4),
    ("in spite of", "phrase", "尽管；不顾", 4),
    ("on behalf of", "phrase", "代表；为了", 4),
    ("play a role in", "phrase", "在……中起作用", 4),
    ("in response to", "phrase", "作为对……的回应", 4),
    ("give rise to", "phrase", "引起；导致", 4),
    ("be subject to", "phrase", "受……影响；取决于", 4),
    ("in the long run", "phrase", "从长远来看", 4),
    ("put up with", "phrase", "忍受；容忍", 4),
    ("run out of", "phrase", "用完；耗尽", 4),
]

# ---------------------------------------------------------------- 清洗规则

# 首行开头的领域标记（`[经] 分析` / `[法] 放弃`）—— 不是释义，丢掉。
DOMAIN_MARKER = re.compile(r"^[\[［]\s*([^\]]{1,8})\s*[\]］]\s*")
# 词性标记（`vt.` / `a.` / `ad.` …），只认行首。
POS_MARKER = re.compile(r"^([A-Za-z]{1,5})\.\s*")
# 一行里可能有多个词性：`n. 放任, 无拘束` 之后再接 `v. 舍弃`。
POS_NAMES = {
    "n": "n.", "v": "v.", "vt": "v.", "vi": "v.", "a": "adj.", "adj": "adj.",
    "ad": "adv.", "adv": "adv.", "prep": "prep.", "conj": "conj.",
    "pron": "pron.", "num": "num.", "art": "art.", "aux": "aux.",
    "int": "int.", "abbr": "abbr.", "pl": "n.",
}
# 释义切分（中英逗号 / 分号都算一项）。
SENSE_SPLIT = re.compile(r"[,;，；]")
# 这些标记开头的词条对学习者是噪音（人名 / 地名 / 网络梗），不收。
JUNK_LEAD = ("[人名]", "[地名]", "[网络]", "[缩写]", "[缩写词]")

# 单字词上限：够长到不可能有；太长的基本是模型幻觉或复合词。
WORD_PATTERN = re.compile(r"^[a-z][a-z'\-]{1,23}$")

# ---------------------------------------------------------------- 虚词停用表
#
# 判据只有一条：**这个词有没有词汇意义（学它有没有用）？**
# - `the` / `of` / `is` / `he` / `and` 没有 —— 学员第一天就认识了，收进词库的唯一后果是
#   「每日推荐」抽出一堆 `the / of / he`，练习价值为零；查这些词也不是词典的用例。
# - `because` / `although` / `while` / `unless` **有** —— 它们是表达逻辑关系的
#   从属连词，中高级学员真要练「怎么用它们把话说清楚」，所以**留**在词库里。
# 所以这里收的只是「纯语法词」：冠词、代词、助动词与情态动词、基本介词、
# **并列**连词、纯语法副词与基本数词。从属连词和有实义的副词一律不收。
STOP_WORDS = frozenset("""
a an the
i me my mine myself we us our ours ourselves you your yours yourself yourselves
he him his himself she her hers herself it its itself they them their theirs themselves
this that these those which who whom whose what whatever whoever whichever
and or but nor so yet if than
either neither both each every all any some such own same other another
as for one
of in on at to from by with without about into onto upon over under above below
between among through during before after against along across behind beyond within
beside besides toward towards via per off out up down near past despite except
is am are was were be been being do does did doing done have has had having
will would shall should can could may might must ought
not no none nothing nobody nowhere never here there where when why how now then
very too also only just even still yes ok okay please thanks thank oh mm
""".split())

# 最多给几项释义 / 词性，以及中文释义的总长上限（搜索行要一行放得下）。
MAX_SENSES = 4
MAX_SENSE_CHARS = 44
MAX_POS = 3

# 英式拼写 → 美式拼写（**只收发音相同的**）：CMUdict 里没有英式拼法，
# 而 `analyse` 这种词没有音标比给个错的好。`aeroplane` 就不在此列 ——
# 它与 `airplane` 的发音并不相同，硬套会给出错误的音标。
BRITISH_ALIASES = {
    "analyse": "analyze", "enrolment": "enrollment", "dishonour": "dishonor",
    "despatch": "dispatch", "carcase": "carcass", "cigaret": "cigarette",
    "dependant": "dependent", "by-product": "byproduct",
    "co-operation": "cooperation", "drop-out": "dropout",
    "co-ordinate": "coordinate", "colour": "color", "favour": "favor",
    "honour": "honor", "labour": "labor", "neighbour": "neighbor",
    "centre": "center", "metre": "meter", "theatre": "theater",
    "organise": "organize", "realise": "realize", "recognise": "recognize",
    "programme": "program", "catalogue": "catalog", "behaviour": "behavior",
    "favourite": "favorite", "humour": "humor", "rumour": "rumor",
    "travelling": "traveling", "modelling": "modeling", "cancelled": "canceled",
}


# ---------------------------------------------------------------- 音标

def phonetic_for(word: str) -> str:
    """离线 IPA 音标；策略见文件头。

    音标一律包在 `/…/` 里 —— 与本项目其余部分同一形状（词组不给音标）。
    """
    if ipa is None:
        return ""
    candidates = [word]
    stripped = word.replace("-", "")
    if stripped != word:
        candidates.append(stripped)
    alias = BRITISH_ALIASES.get(word)
    if alias:
        candidates.append(alias)
    for candidate in candidates:
        converted = ipa.convert(candidate)
        # eng_to_ipa 查不到时会在词尾加 `*`
        if converted and "*" not in converted:
            return f"/{converted}/"
    return ""


# ---------------------------------------------------------------- ECDICT 抽取

def clean_translation(raw: str) -> tuple:
    """把 ECDICT 的释义原文清成 `(词性, 中文)`。

    原文形如 `vt. 放弃, 抛弃, 遗弃\\nn. 放任, 无拘束` —— 换行是行分隔、
    逗号是义项分隔，词性写在行首。返回的词性已归一（`a.` → `adj.`、`vt.` → `v.`），
    中文里不再带词性前缀（词性是独立字段，搜索行靠它排版）。
    """
    lines = (raw or "").split("\\n")
    pos: list = []
    senses: list = []
    for line in lines[:3]:
        text = line.strip()
        while True:
            marker = DOMAIN_MARKER.match(text)
            if not marker:
                break
            text = text[marker.end():]
        while True:
            marker = POS_MARKER.match(text)
            if not marker:
                break
            name = POS_NAMES.get(marker.group(1).lower())
            if not name:
                break
            if name not in pos:
                pos.append(name)
            text = text[marker.end():]
            # `n. [法] 放弃` —— 词性后面还可能跟一个领域标记。
            inner = DOMAIN_MARKER.match(text)
            if inner:
                text = text[inner.end():]
        for piece in SENSE_SPLIT.split(text):
            piece = piece.strip().strip("。.").strip()
            if not piece or piece in senses:
                continue
            senses.append(piece)
    return pos[:MAX_POS], senses[:MAX_SENSES]


def join_senses(senses: list) -> str:
    """义项合成一行，超长从尾部截断（宁可少给一项，也不让它撑破搜索行）。"""
    text = "；".join(senses)
    if len(text) <= MAX_SENSE_CHARS:
        return text
    kept: list = []
    for sense in senses:
        candidate = "；".join(kept + [sense])
        if len(candidate) > MAX_SENSE_CHARS:
            break
        kept.append(sense)
    return "；".join(kept) if kept else text[:MAX_SENSE_CHARS]


def difficulty_of(row: dict) -> int:
    """难度档：1 简单 / 2 中等 / 3 困难（4 留给词组，见 `DictionaryWord` 注释）。

    轴是**词频名次**，不是柯林斯星级 —— 星级衡量的是「这个词对学习者有多核心」，
    在 ECDICT 里对高频虚词明显不靠谱：`the` 五星、`in` 只有两星、`common` 只有一星。
    拿它当难度轴会得出「`the` 最简单、`in` 是困难词」这种自相矛盾的分档。
    词频名次是单调的、可复现的，也符合直觉：越常用越简单。
    """
    rank = frequency_rank(row)
    if rank <= 1000:
        return 1
    if rank <= 3000:
        return 2
    return 3


def frequency_rank(row: dict) -> int:
    """词频名次（BNC / 当代语料库取更靠前的那个）；两个语料库都没有 → 排最后。"""
    ranks = []
    for key in ("bnc", "frq"):
        raw = (row.get(key) or "").strip()
        if raw.isdigit() and int(raw) > 0:
            ranks.append(int(raw))
    return min(ranks) if ranks else 10 ** 9


def read_ecdict(path: pathlib.Path, wants) -> dict:
    """从 ECDICT CSV 里挑出每本书的词条。

    `wants` 是 `(book_id, 判定函数)`：判定函数收 row，返回这本书要不要它。
    只收**原型词**（`exchange` 里带 `0:` 的是变形，如 `abandons` / `abandoned`）——
    词库里塞满变形词会让每日推荐抽到一堆 `-ed` 形式，也会把词条数注水成两倍。
    虚词（见 `STOP_WORDS`）一律不收。
    """
    found = {book_id: {} for book_id, _ in wants}
    with open(path, encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            word = (row.get("word") or "").strip()
            if not WORD_PATTERN.match(word):
                continue
            if word in STOP_WORDS:
                continue
            if "0:" in (row.get("exchange") or ""):
                continue
            translation = row.get("translation") or ""
            stripped = translation.lstrip()
            if not stripped or stripped.startswith(JUNK_LEAD):
                continue
            tags = (row.get("tag") or "").split()
            for book_id, matches in wants:
                if not matches(row, tags):
                    continue
                if word in found[book_id]:
                    continue
                pos, senses = clean_translation(translation)
                if not senses:
                    continue
                found[book_id][word] = {
                    "word": word,
                    "phonetic": phonetic_for(word),
                    "pos": "/".join(pos),
                    "zh": join_senses(senses),
                    "difficulty": difficulty_of(row),
                    "_rank": frequency_rank(row),
                }
    for book_id in found:
        rows = sorted(found[book_id].values(), key=lambda item: (item["_rank"], item["word"]))
        for item in rows:
            item.pop("_rank", None)
        found[book_id] = rows
    return found


# ---------------------------------------------------------------- 手写词表

def curated_rows(rows: list) -> list:
    """手写词表 → 词典条目（音标按同一套规则补）。

    虚词照样挡掉 —— 兜底路径也要与主路径同一口径，否则「有没有网」会给出
    两套不同的词库，而这种差异没人会想到去查。
    """
    seen = set()
    result = []
    for word, pos, zh, difficulty in rows:
        key = word.lower()
        if key in seen or key in STOP_WORDS:
            continue
        seen.add(key)
        result.append({
            "word": word,
            "phonetic": phonetic_for(word),
            "pos": pos,
            "zh": zh,
            "difficulty": difficulty,
        })
    return result


def phrases_of(rows: list) -> list:
    """手写词表里的词组（含空格的）—— ECDICT 的考试标签覆盖不到它们。"""
    return [row for row in rows if " " in row[0]]


def merge(base: list, extra: list) -> list:
    """把补充词条并进主表（同名以主表为准），词组放最后。"""
    seen = {item["word"].lower() for item in base}
    merged = list(base)
    for item in extra:
        if item["word"].lower() in seen:
            continue
        seen.add(item["word"].lower())
        merged.append(item)
    return merged


def ielts_curated() -> list:
    """既有的雅思词库（每日推荐的现役数据源）—— 并进雅思词典，避免换源后丢词。"""
    raw = json.loads(IELTS_SRC.read_text(encoding="utf-8"))
    return [
        {
            "word": rec["word"],
            "phonetic": phonetic_for(rec["word"]),
            "pos": rec.get("pos", ""),
            "zh": rec.get("zh", ""),
            "difficulty": rec.get("difficulty", 2),
        }
        for rec in raw
    ]


# ---------------------------------------------------------------- 主流程

BOOKS = [
    ("builtin.oxford", "oxford", "牛津核心词", lambda row, tags: row.get("oxford") == "1"),
    ("builtin.cet6", "cet6", "六级核心词汇", lambda row, tags: "cet6" in tags),
    ("builtin.ielts", "ielts", "雅思标准词", lambda row, tags: "ielts" in tags),
]


def build_from_ecdict() -> dict:
    wants = [(book_id, matches) for book_id, _, _, matches in BOOKS]
    words = read_ecdict(ECDICT_CSV, wants)
    return {
        "builtin.oxford": merge(words["builtin.oxford"], curated_rows(phrases_of(FALLBACK_OXFORD))),
        "builtin.cet6": merge(words["builtin.cet6"], curated_rows(phrases_of(FALLBACK_CET6))),
        "builtin.ielts": merge(words["builtin.ielts"], ielts_curated()),
    }


def build_from_curated() -> dict:
    return {
        "builtin.oxford": curated_rows(FALLBACK_OXFORD),
        "builtin.cet6": curated_rows(FALLBACK_CET6),
        "builtin.ielts": ielts_curated(),
    }


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    if ECDICT_CSV.exists():
        print(f"词表来源：ECDICT（{ECDICT_CSV}）")
        books = build_from_ecdict()
    else:
        print(f"⚠️ 没找到 ECDICT CSV（{ECDICT_CSV}），退回手写词表 —— 词会少很多。")
        books = build_from_curated()

    for book_id, file, _, _ in BOOKS:
        rows = books[book_id]
        target = OUT / f"{file}.json"
        target.write_text(json.dumps(rows, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        missing = sum(1 for item in rows if not item["phonetic"])
        levels = {level: sum(1 for item in rows if item["difficulty"] == level) for level in (1, 2, 3, 4)}
        no_pos = sum(1 for item in rows if not item["pos"])
        print(
            f"{file}: {len(rows)} 词 · 缺音标 {missing} · 无词性 {no_pos} · "
            f"难度分布 {levels} · {target.stat().st_size // 1024} KB"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
