#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给情景素材补「主线任务」字段（需求 3）。

只在 JSON 里加 `mainQuest` + `questSteps`，其余键原样保留、缩进与 Python json 默认一致。
写入位置固定在 `targetSentences` 之后 —— 读文件的人一眼能看到「这一关要做什么」。

用法：python3 Scripts/add_scenario_quests.py
"""
import json
import os
import sys

SCENARIO_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources", "AIInfrastructure", "Resources", "Scenarios",
)

QUESTS = {
    "daily_small_talk": {
        "mainQuest": "Have a natural small-talk chat: greet, say how you are, share a hobby, and mention your weekend plan.",
        "questSteps": [
            {"id": "daily_small_talk-s1", "text": "Greet the other person and ask how they are doing.",
             "hint": "先说自己的情况，再反问对方",
             "anchors": ["I'm doing well, thanks. How about you?"]},
            {"id": "daily_small_talk-s2", "text": "Tell them about one of your hobbies.",
             "hint": "My hobby is ...",
             "anchors": ["My hobby is playing basketball."]},
            {"id": "daily_small_talk-s3", "text": "Mention your weekend plan or the weather.",
             "hint": "顺着话题再补一句，让对话继续",
             "anchors": ["I'm going to visit my family this weekend.",
                         "By the way, the weather is really nice today."]},
        ],
    },
    "job_interview": {
        "mainQuest": "Complete a job interview: introduce yourself, give your strengths, describe past experience and ask about the salary.",
        "questSteps": [
            {"id": "job_interview-s1", "text": "Introduce yourself and state how much experience you have.",
             "hint": "I have ... years of experience in ...",
             "anchors": ["I have five years of experience in marketing."]},
            {"id": "job_interview-s2", "text": "Name your main strength and back it up.",
             "hint": "My strength is ...",
             "anchors": ["My strength is teamwork."]},
            {"id": "job_interview-s3", "text": "Describe past experience and ask about the salary.",
             "hint": "先讲过去，再主动问一句你想知道的",
             "anchors": ["I used to work for a small startup.",
                         "I'd like to know more about the salary."]},
        ],
    },
    "restaurant": {
        "mainQuest": "Complete a full restaurant visit: get a table, order a starter and a drink, then pay the bill.",
        "questSteps": [
            {"id": "restaurant-s1", "text": "Ask for a table and get the menu.",
             "hint": "先说人数，再要菜单",
             "anchors": ["I'd like a table for two, please.",
                         "Could I have the menu, please?"]},
            {"id": "restaurant-s2", "text": "Order a starter.",
             "hint": "I'd like ... as a starter",
             "anchors": ["I'd like the soup as a starter."]},
            {"id": "restaurant-s3", "text": "Ask for the bill and finish the meal.",
             "hint": "吃完饭要把账结掉",
             "anchors": ["Can I have the bill, please?"]},
        ],
    },
    "shopping": {
        "mainQuest": "Buy clothes in a shop: check the size, try something on, ask the price and pay.",
        "questSteps": [
            {"id": "shopping-s1", "text": "Ask for a smaller size and ask to try it on.",
             "hint": "先问尺码，再问能不能试",
             "anchors": ["Do you have this in a smaller size?", "Can I try it on?"]},
            {"id": "shopping-s2", "text": "Ask how much it costs.",
             "hint": "How much is ...?",
             "anchors": ["How much is this one?"]},
            {"id": "shopping-s3", "text": "Pay and ask for a receipt.",
             "hint": "买单时顺手要张凭证",
             "anchors": ["Could I have a receipt, please?"]},
        ],
    },
    "airport_checkin": {
        "mainQuest": "Finish an airport check-in: pick a seat, check your luggage and find your gate.",
        "questSteps": [
            {"id": "airport_checkin-s1", "text": "Ask for the seat you prefer.",
             "hint": "座位偏好要主动说",
             "anchors": ["I'd like a window seat, please."]},
            {"id": "airport_checkin-s2", "text": "Tell them what luggage you are checking.",
             "hint": "说清带了几件",
             "anchors": ["I have one piece of carry-on luggage."]},
            {"id": "airport_checkin-s3", "text": "Ask for your gate and show your boarding pass.",
             "hint": "问登机口，再出示登机牌",
             "anchors": ["What's my departure gate?", "Here's my boarding pass."]},
        ],
    },
    "opinion_expression": {
        "mainQuest": "State a clear opinion, give one reason for it, and disagree politely.",
        "questSteps": [
            {"id": "opinion_expression-s1", "text": "Say your opinion clearly.",
             "hint": "In my opinion, ... / I prefer ...",
             "anchors": ["In my opinion, working from home is better.",
                         "I prefer to study in the morning."]},
            {"id": "opinion_expression-s2", "text": "Give the main reason behind your view.",
             "hint": "The main reason is that ...",
             "anchors": ["The main reason is that it saves time."]},
            {"id": "opinion_expression-s3", "text": "Soften the disagreement by conceding a point.",
             "hint": "However 开头，先让一步再守住观点",
             "anchors": ["However, I agree there are some problems."]},
        ],
    },
    "debate": {
        "mainQuest": "Defend your position: disagree firmly, bring evidence, and counter the other side.",
        "questSteps": [
            {"id": "debate-s1", "text": "Disagree with the other side directly.",
             "hint": "立场要说得干脆",
             "anchors": ["I disagree with that point completely."]},
            {"id": "debate-s2", "text": "Support your view with evidence.",
             "hint": "There is strong evidence ...",
             "anchors": ["There is strong evidence to support my view."]},
            {"id": "debate-s3", "text": "Counter the argument and show the other side of the story.",
             "hint": "反驳时给出一层新信息",
             "anchors": ["I would argue that this is not the whole story.",
                         "On the contrary, the data shows the opposite."]},
        ],
    },
    "impromptu_presentation": {
        "mainQuest": "Give a short unprepared talk: open with a topic, give an overview and an example, then summarise.",
        "questSteps": [
            {"id": "impromptu_presentation-s1", "text": "Open by naming your topic.",
             "hint": "今天我要讲的是 ...",
             "anchors": ["Today I would like to talk about my hometown."]},
            {"id": "impromptu_presentation-s2", "text": "Give a quick overview and one concrete example.",
             "hint": "先给轮廓，再举一个例子",
             "anchors": ["First, let me give you a quick overview.",
                         "For example, the local food is amazing."]},
            {"id": "impromptu_presentation-s3", "text": "Close with a one-sentence summary.",
             "hint": "To sum up, ...",
             "anchors": ["To sum up, it is a place worth visiting."]},
        ],
    },
    "hotel_checkin": {
        "mainQuest": "Check in at a hotel: confirm your booking, ask about breakfast and wifi, then request towels.",
        "questSteps": [
            {"id": "hotel_checkin-s1", "text": "Confirm your reservation by name.",
             "hint": "报上预订的名字",
             "anchors": ["I have a reservation under Chen."]},
            {"id": "hotel_checkin-s2", "text": "Ask about breakfast time and wifi.",
             "hint": "问早餐时间、问有没有网络",
             "anchors": ["What time does breakfast start?", "Is there wifi in the room?"]},
            {"id": "hotel_checkin-s3", "text": "Ask for something extra for the room.",
             "hint": "Could I have some extra ...?",
             "anchors": ["Could I have some extra towels?"]},
        ],
    },
    "doctor_visit": {
        "mainQuest": "Describe your symptoms to a doctor, mention an allergy, and ask how to take the medicine.",
        "questSteps": [
            {"id": "doctor_visit-s1", "text": "Describe your main symptom and how long you have had it.",
             "hint": "说症状，再说持续了多久",
             "anchors": ["I've had a sore throat for three days.", "It hurts when I swallow."]},
            {"id": "doctor_visit-s2", "text": "Mention what you are allergic to.",
             "hint": "I'm allergic to ...",
             "anchors": ["I'm allergic to penicillin."]},
            {"id": "doctor_visit-s3", "text": "Ask how often to take the medicine.",
             "hint": "How often ...?",
             "anchors": ["How often should I take this medicine?"]},
        ],
    },
}


def reorder(payload: dict) -> dict:
    """把 mainQuest / questSteps 挪到 targetSentences 之后，其余保持原序。"""
    quest = {k: payload[k] for k in ("mainQuest", "questSteps") if k in payload}
    rest = {k: v for k, v in payload.items() if k not in quest}
    if "targetSentences" not in rest:
        result = dict(rest)
        result.update(quest)
        return result
    result = {}
    for key, value in rest.items():
        result[key] = value
        if key == "targetSentences":
            result.update(quest)
    return result


def main() -> int:
    changed = 0
    for name in sorted(os.listdir(SCENARIO_DIR)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(SCENARIO_DIR, name)
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
        scenario_id = payload.get("id")
        quest = QUESTS.get(scenario_id)
        if quest is None:
            print(f"skip   {name}（没有为主线任务准备文本）")
            continue
        before = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        payload["mainQuest"] = quest["mainQuest"]
        payload["questSteps"] = quest["questSteps"]
        payload = reorder(payload)
        after = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        if before == after:
            print(f"same   {name}")
            continue
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        changed += 1
        print(f"update {name}：{len(quest['questSteps'])} 步")
    print(f"done：{changed} 个文件已更新")
    return 0


if __name__ == "__main__":
    sys.exit(main())
