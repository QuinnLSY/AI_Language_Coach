import AIDomain

/// 练习模块 → 地面戏码的唯一翻译表（批次四 · A「分模块回应」）。
///
/// 为什么单独一张表而不是散在各发射点：模块会加、戏码会换，
/// 「哪个模块演什么」必须只有一处能改 —— 否则森林对同一个模块的回应
/// 会在两个地方各说一套话。
///
/// 设计口径：模块回应的**动作要有辨识度**，且必须是这只小动物真的会做的事
/// （读完想听故事、写完在地上划两笔、听完竖耳朵），不是「一律跳一下庆祝」。
public enum ForestModuleSkit {

    /// 这个模块演什么动作。
    ///
    /// ⚠️ 刻意避开 `.wiggle`（那是双人舞的专用动作）与 `.spin`（那是点击彩蛋），
    /// 免得模块回应和日常小剧场撞成同一个样子。
    public static func action(for module: PracticeModule) -> LivelyAnimalAction {
        switch module {
        case .reading: .nod      // 安静听着，像在听故事
        case .writing: .dig      // 在地上划两笔：我也写写字
        case .listening: .listen // 竖起耳朵
        case .shadowing: .shake  // 摇头晃脑地跟着念
        case .vocabulary: .stretch // 复习完伸个懒腰
        case .exam: .hop         // 考完啦，跳一下
        case .errorDrill: .tilt  // 又记住一个，歪头想想
        }
    }

    /// 这个模块演出几只（1 = 独角戏，2 = 有伴）。
    ///
    /// 祝贺性质的（考试 / 跟读）多来一只热闹些；安静性质的（阅读 / 听力）只派一只，
    /// 一大群围过来会破坏「安静」这件事本身。
    public static func castSize(for module: PracticeModule) -> Int {
        switch module {
        case .reading, .writing, .listening, .vocabulary, .errorDrill: 1
        case .shadowing, .exam: 2
        }
    }

    /// 这个模块的台词池（随机抽一句）。
    public static func lines(for module: PracticeModule) -> [String] {
        switch module {
        case .reading:
            return [
                "读完了？讲给我听听好不好～",
                "书里那只小熊后来怎么样啦？",
                "我也想听这个故事！",
            ]
        case .writing:
            return [
                "写得好认真，我也在地上划两笔！",
                "你的字像小树枝一样有劲儿～",
                "我也想学写字！",
            ]
        case .listening:
            return [
                "嘘——我竖起耳朵听着呢！",
                "那句话我好像听懂啦！",
                "你的耳朵也越来越灵啦～",
            ]
        case .shadowing:
            return [
                "一二三，跟你一起念～",
                "你的声音真好听！",
                "再来一句，我还没念够！",
            ]
        case .vocabulary:
            return [
                "复习完啦，伸个懒腰～",
                "这些词我都记住啦！",
                "明天再考考我呀！",
            ]
        case .exam:
            return [
                "考完啦！你真棒！",
                "不管几分，你都很努力！",
                "辛苦啦，去吃点心吧～",
            ]
        case .errorDrill:
            return [
                "错题又少一个！",
                "这次我真的记住它了！",
                "错过的词，再见就是老朋友啦～",
            ]
        }
    }

    /// 中途退出时的送别话（不评判、不催，只说「下次见」）。
    ///
    /// ⚠️ 语气纪律：退出不是失败，这里**绝不**出现「可惜」「怎么不练完」这类话。
    public static func farewellLines(for module: PracticeModule) -> [String] {
        switch module {
        case .reading:
            return ["故事先留着，下次接着讲～", "书签我帮你夹好啦！"]
        case .writing:
            return ["草稿我帮你收着，明天接着写～", "写到一半也是写过呀！"]
        case .listening:
            return ["耳朵也要休息，下次再听～", "那句话我替你记着呢！"]
        case .shadowing:
            return ["嗓子要休息啦，明天再念～", "你念的那句我还记得！"]
        case .vocabulary:
            return ["剩下的词明天再来看～", "记住的那几个已经是你啦！"]
        case .exam:
            return ["交卷啦，下次再来闯关！", "走到哪里都算数～"]
        case .errorDrill:
            return ["错题不跑，明天再来找它～", "今天就到这里，休息一下！"]
        }
    }
}
