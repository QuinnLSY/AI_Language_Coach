import Combine
import Foundation
import SwiftUI

// MARK: - 物种

/// 每种动物都有**独立的解剖特征**（耳朵、口鼻、尾巴、纹样），而不是同一副身体换色。
public enum AnimalKind: String, CaseIterable, Sendable, Identifiable {
    case fox
    case panda
    case tiger
    case owl
    case rabbit
    case bear
    case squirrel
    case hedgehog

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fox: "小狐狸"
        case .panda: "小熊猫"
        case .tiger: "小老虎"
        case .owl: "猫头鹰"
        case .rabbit: "小兔子"
        case .bear: "小熊"
        case .squirrel: "小松鼠"
        case .hedgehog: "小刺猬"
        }
    }

    /// **解锁顺序**（⑦-C③）：固定打乱过的全序列，林子里第 k 位伙伴就是这一个。
    ///
    /// 为什么非要单独拎出来：地面带原本在视图里自己打乱取前 N 只，
    /// 那么「再练 25 分钟来一位新伙伴」就**指不出是谁要来** —— 预告点不出名字，
    /// 而且两处各打乱一次迟早对不上（写着「小刺猬要来」，来的却是小狐狸）。
    /// 现在顺序只此一处，地面带取前 N 个、预告取第 N 个，两边必然一致。
    ///
    /// ⚠️ 打乱是**确定性**的（同一套 sin 伪随机，不是 `Hasher`、也不是每启动重摇）：
    /// 换了顺序等于把老用户林子里的居民换了一批。
    public static var unlockOrder: [AnimalKind] {
        let all = allCases
        var order = all
        for i in stride(from: all.count - 1, through: 1, by: -1) {
            let j = Int(unlockSeed(i, 11) * CGFloat(i + 1))
            order.swapAt(i, min(j, i))
        }
        return order
    }

    private static func unlockSeed(_ index: Int, _ salt: Int) -> CGFloat {
        let x = sin(Double(index * 137 + salt * 61)) * 43758.5453
        return CGFloat(x - floor(x))
    }

    /// 每只动物 8~10 条符合自身特性的小语句（产品文案；树上的伙伴被点击时冒泡）。
    public var phrases: [String] {
        switch self {
        case .fox:
            return [
                "跟我读：The early bird catches the worm！",
                "嘘——我听见树叶在用英文聊天啦！",
                "小 trick 要不要？单词要大声说出来才有魔力！",
                "Practice makes perfect，我可是偷偷练过的！",
                "G-O-O-D，拼对了就奖励你一颗糖！",
                "树上有果子、地上有单词，快捡起来！",
                "你今天读的句子，风都帮你记着呢！",
                "跟着我念，舌头要翘一点点哦！",
                "别怕说错，说错了才有小惊喜！",
                "森林里最亮的，是你开口的声音！",
            ]
        case .panda:
            return [
                "Good job！今天的你比竹子还棒！",
                "别急，慢慢来，learning is a journey。",
                "这句话读得很好，给你一朵小红花。",
                "来，跟我读：I love learning English！",
                "累了就歇会儿，竹子分你一半～",
                "记住啦：little by little, day by day。",
                "你今天又长高了一点点，真替你高兴。",
                "发音很棒哦，比上次进步多啦！",
                "不懂就问，我最喜欢爱问问题的小朋友。",
                "坚持到这里的你，已经是森林小英雄啦！",
            ]
        case .tiger:
            return [
                "吼——跟我大声念：I can do it！",
                "声音再大一点，森林都听到你的勇气啦！",
                "单词怕什么，跟本大王一起拿下它！",
                "Roar！犯错也是超酷的尝试！",
                "今天的目标：吃掉十个新单词！",
                "大声朗读，把胆怯都吓跑！",
                "你是最棒的小勇士，再来一关！",
                "A for effort，努力本身就满分！",
                "快，趁太阳还在，多练一句！",
                "我会保护你，尽管开口说吧！",
            ]
        case .owl:
            return [
                "呜呼——悄悄告诉你，单词睡一觉记得更牢。",
                "关于发音，我书架上有三百本书可以借你。",
                "夜里安静，最适合跟读和回想。",
                "坚持复习，才是聪明的秘诀哦。",
                "这个语法点，让我翻翻我的智慧手册…",
                "A wise learner listens first, then speaks。",
                "你问的这个词，古树年轮里都刻着呢。",
                "晚上的你，也要像白天一样闪亮。",
                "复述一遍，就是知识发芽的声音。",
                "慢慢想，聪明的答案都爱迟到一会儿。",
            ]
        case .rabbit:
            return [
                "你…你说得好棒呀！（小声）",
                "跟…跟着我一起念，轻轻地说～",
                "这个单词好可爱，像胡萝卜一样讨人喜欢。",
                "慢慢来，我在旁边给你加油。",
                "嗯嗯，你说对了，奖励你一个抱抱。",
                "今天也要元气满满地跳跳学英语哦！",
                "bunny 就是我，carrot 是我最爱～",
                "别害羞，你的声音很好听呢。",
                "读错也没关系，胡萝卜不会笑话你。",
                "等你学会了，我们一起数星星学英语！",
            ]
        case .bear:
            return [
                "我…我也在学呢，我们一起加油！",
                "这句好难…但我会认真记住的！",
                "英语的蜂蜜，舔一口就甜甜的！",
                "老师夸我了！你也一定会被夸的！",
                "今天学到的新词，我要带回家给妈妈听。",
                "嘿嘿，我会背小星星，也会背 A B C。",
                "摔倒了就爬起来，我再念一遍！",
                "你读得真好听，像蜂蜜一样甜。",
                "我们的树，会随着单词越爬越高！",
                "别走太快，等等我这只小笨熊嘛～",
            ]
        case .squirrel:
            return [
                "这个单词我收进我的树洞宝库啦！",
                "蹦蹦跳跳学得快，跟我一起动起来！",
                "一天捡一个词，冬天就有好多好多！",
                "嗖——我把发音记住啦！",
                "来玩个游戏：我说 apple，你说苹果！",
                "藏起来的单词，都要记得复习哦。",
                "你的进步，我都悄悄攒进树洞里了。",
                "单词像松果，捡多了就是大丰收！",
                "尾巴一甩，难句跑光光！",
                "快夸我，我刚背下一个长句子！",
            ]
        case .hedgehog:
            return [
                "我…我慢慢说，你别着急嘛。",
                "每个单词，都值得被温柔对待。",
                "刺是我的保护壳，勇敢是我的超能力。",
                "你读对了！我开心得刺都软了。",
                "慢慢滚，也能滚到山顶哦。",
                "别碰我的刺…碰我的单词本可以。",
                "今天又比昨天多说了一句话，真好。",
                "小声音也没关系，清楚最重要。",
                "我背单词的样子，像不像在数星星？",
                "谢谢你听我说完，你是温柔的朋友。",
            ]
        }
    }

    /// 季节专属气泡文案（#606）：每季两句，中英混合、带当季意象，性格与 `phrases` 一致。
    ///
    /// 与通用池的关系见 `bubblePhrases(season:weather:)`：**增量**，不是替换 ——
    /// 老用户听惯的鼓励一句不少，只是当季多听到两句应景的。
    public func seasonalPhrases(season: ForestSeason) -> [String] {
        switch self {
        case .fox:
            switch season {
            case .spring: return ["春天的单词像花儿一样一朵朵开！", "春风一吹，新句子就发芽啦。"]
            case .summer: return ["大太阳也晒不化我的学习劲头！", "夏天就要大声朗读，像蝉鸣一样响！"]
            case .autumn: return ["秋天的果实里，全是攒下来的单词！", "落叶堆里藏着一整个夏天的努力哦。"]
            case .winter: return ["冬天也要练口语，嘴里冒着热气呢！", "雪再大，也盖不住你读书的声音。"]
            }
        case .panda:
            switch season {
            case .spring: return ["春天来了，竹子绿了，你也长大了一点。", "春日午后，最适合慢慢读一句英语。"]
            case .summer: return ["天热没关系，心静自然凉，慢慢读。", "夏天的你，比竹叶上的露珠还精神。"]
            case .autumn: return ["秋天把收获存进肚子，像存单词一样。", "天凉了，多喝热水，也多读几句。"]
            case .winter: return ["冬天抱成团，也不忘背单词哦。", "冷冷的天气，读书最暖和了。"]
            }
        case .tiger:
            switch season {
            case .spring: return ["春回大地，本大王也要吼一嗓子英语！", "春天是新开始，跟我一起冲！"]
            case .summer: return ["烈日当头，勇气也要当头！", "夏天的嗓门最大，大声念出来！"]
            case .autumn: return ["秋天的果实，是给努力者的奖赏！", "收获季到了，把单词都收进口袋！"]
            case .winter: return ["寒冬算什么，我的声音能发热！", "再冷的天气，也冻不住开口的勇气。"]
            }
        case .owl:
            switch season {
            case .spring: return ["春天的夜晚，书页声和虫鸣一样好听。", "春夜读书，脑子记得特别牢。"]
            case .summer: return ["夏夜漫长，正好多想几个单词。", "夏天的萤火虫，像我脑海里的灵感。"]
            case .autumn: return ["秋夜清爽，复习的效率最高哦。", "秋天的书本，翻起来沙沙响。"]
            case .winter: return ["冬夜最适合窝着想一想语法。", "安静的雪夜，单词排队跳进脑子里。"]
            }
        case .rabbit:
            switch season {
            case .spring: return ["春天的小花…和你一样可爱呀。", "春风轻轻地，说话也轻轻地。"]
            case .summer: return ["夏天要…吃西瓜，也要读英语哦。", "热热的夏天，声音可以小一点点的。"]
            case .autumn: return ["秋天的落叶，软软的像我的胆子…", "丰收的季节，兔子也攒了很多词呢。"]
            case .winter: return ["冬天…可以把话先说暖和再出口。", "雪再冷，你的声音还是暖的呀。"]
            }
        case .bear:
            switch season {
            case .spring: return ["春天到了，蜂蜜和新单词一起来！", "春日里打滚，滚着滚着就学会一句。"]
            case .summer: return ["夏天再热，学习也不能放假！", "大太阳天，适合到树荫下读书。"]
            case .autumn: return ["秋天的蜂蜜甜，秋天的单词也甜！", "丰收啦！把好句子都搬回树洞。"]
            case .winter: return ["冬天冬眠前…也要先背几个单词！", "冷冷的冬天，读书的小熊最暖和。"]
            }
        case .squirrel:
            switch season {
            case .spring: return ["春天开始囤单词，一年不荒废！", "春日里蹦蹦跳跳，顺便记住三个词！"]
            case .summer: return ["夏天也要勤劳，汗都是努力的！", "太阳越大，我捡词捡得越欢！"]
            case .autumn: return ["秋天是大囤货季！单词装满树洞！", "丰收的秋天，每个松果里都有知识。"]
            case .winter: return ["冬天翻出囤的单词，个个管饱！", "雪再大，树洞里的存货也够吃一冬。"]
            }
        case .hedgehog:
            switch season {
            case .spring: return ["春天慢慢长，单词慢慢记。", "春日里的每一片新叶，都值得慢慢看。"]
            case .summer: return ["夏天热了，说话可以更慢更轻哦。", "炎热的午后，适合轻轻念一个词。"]
            case .autumn: return ["秋天的果实，是一天一天攒出来的。", "天凉好个秋，适合温习学过的句子。"]
            case .winter: return ["冬天缩成球，也不舍得忘掉单词。", "冷天里想起一个学过的词，心里会暖。"]
            }
        }
    }

    /// 天气专属气泡文案（#606）：下雨 / 下雪各一句。
    ///
    /// ⚠️ 晴（`.clear`）**没有专属句** —— 「晴」不配台词：天好着没什么可说的，
    /// 判据同 `AnimalWeatherBehavior.forWeather`（晴连道具都不配）。
    public func weatherPhrases(weather: ForestWeather) -> [String] {
        switch self {
        case .fox:
            switch weather {
            case .rain: return ["下雨天最适合背单词，雨点替我数拍子！"]
            case .snow: return ["下雪啦！张嘴说话，嘴里会冒出白色的哈气～"]
            case .clear: return []
            }
        case .panda:
            switch weather {
            case .rain: return ["下雨了，撑把伞慢慢走，英语慢慢读。"]
            case .snow: return ["下雪天说一句话，嘴里会开出一朵白雾花。"]
            case .clear: return []
            }
        case .tiger:
            switch weather {
            case .rain: return ["下雨天照练！雨点砸不垮我的声音！"]
            case .snow: return ["雪地里吼一声，回声都带着英文字母！"]
            case .clear: return []
            }
        case .owl:
            switch weather {
            case .rain: return ["雨夜读书，别有一番滋味。"]
            case .snow: return ["雪夜安静得，能听见单词落地的声音。"]
            case .clear: return []
            }
        case .rabbit:
            switch weather {
            case .rain: return ["淅沥沥的雨天…适合小声练习，说错也没人听见哦。"]
            case .snow: return ["下雪啦！呵出的白气…像不像一个单词？"]
            case .clear: return []
            }
        case .bear:
            switch weather {
            case .rain: return ["下雨啦！雨点敲树叶，像在敲黑板。"]
            case .snow: return ["下雪天说话，会有一朵小白云跟在嘴边～"]
            case .clear: return []
            }
        case .squirrel:
            switch weather {
            case .rain: return ["下雨就收工？不，我在树洞里背单词！"]
            case .snow: return ["雪地里也能寻宝！脚印旁边就是新单词。"]
            case .clear: return []
            }
        case .hedgehog:
            switch weather {
            case .rain: return ["雨声陪着，读错了也不着急。"]
            case .snow: return ["下雪了，一片一片数雪花，像在数单词。"]
            case .clear: return []
            }
        }
    }

    /// 气泡合成池（#606）：**既有池为主，季节天气句为增量**。
    ///
    /// 权重是追加次数决定的：主干 10 条原样打底，季节两句 ×3、天气一句 ×1 ——
    /// 同一次抽签里季节句约占三成、天气句约占一成。既让林子「说当季的话」，
    /// 又不把老用户听惯的鼓励挤掉（用户 2026-10 拍板「给动物增加季节和天气
    /// 专属的气泡语言」，没说要换掉原来的）。
    ///
    /// 无季节无天气时**逐字等于** `phrases`（老行为，单测钉住）。
    public func bubblePhrases(season: ForestSeason?, weather: ForestWeather?) -> [String] {
        var pool = phrases
        if let season {
            let lines = seasonalPhrases(season: season)
            pool += lines + lines + lines
        }
        if let weather {
            pool += weatherPhrases(weather: weather)
        }
        return pool
    }
}

// MARK: - 配色（仅本文件使用；View 层禁止写字面量颜色）

private enum Fur {
    static let dark = Color(hex: 0x2A2018)
    static let nose = Color(hex: 0x4A3327)
    static let pink = Color(hex: 0xFFA8B6)
    static let cream = Color(hex: 0xFFF4E6)

    static let fox = Color(hex: 0xEF8438)
    static let foxLight = Color(hex: 0xFFF0DF)

    static let pandaBlack = Color(hex: 0x2E2C33)
    static let pandaWhite = Color(hex: 0xFDFBF6)

    static let tiger = Color(hex: 0xF5A13E)
    static let tigerStripe = Color(hex: 0x342A20)
    static let tigerCream = Color(hex: 0xFFF3E2)

    static let owl = Color(hex: 0x8B78AC)
    static let owlDeep = Color(hex: 0x6E5C90)
    static let owlFace = Color(hex: 0xF0E7F7)
    static let owlBeak = Color(hex: 0xF0A93B)

    static let rabbit = Color(hex: 0xF7E9E1)
    static let rabbitShade = Color(hex: 0xE4D2C8)

    static let bear = Color(hex: 0xB07F55)
    static let bearLight = Color(hex: 0xEACBA9)

    static let squirrel = Color(hex: 0xD0763B)
    static let squirrelLight = Color(hex: 0xF8DDC2)

    static let hedgehogSpike = Color(hex: 0x7E6045)
    static let hedgehogFace = Color(hex: 0xE8CBA6)

    // MARK: 季节装扮（#605）

    static let flowerPetal = Color(hex: 0xFF9EB8)
    static let flowerHeart = Color(hex: 0xF2C14E)
    static let lens = Color(hex: 0x2E3A4A)
    static let scarfRed = Color(hex: 0xD2553F)
    static let scarfDeep = Color(hex: 0xA63E2C)
    static let woolHat = Color(hex: 0xE86A92)
    static let woolHatDeep = Color(hex: 0xC24E77)
    static let umbrellaTop = Color(hex: 0xE8703A)
    static let umbrellaDeep = Color(hex: 0xC85A28)
}

// MARK: - 角色配件

/// 身份配件：老师持教棍；小学员沿闯关进度换装（红领巾 → 小背包 → 望远镜 → 毕业帽，
/// 档位见 `StudentProgression`）。配件随动物缩放并参与日夜/跳动。
public enum AnimalAccessory: Equatable, Sendable {
    case none
    case teacher
    /// 红领巾（入门档，0 星起）。
    case student
    /// 小背包（出发档，攒够星就背上去远足）。
    case studentBackpack
    /// 望远镜（探索档，看得更远的学期）。
    case studentTelescope
    /// 毕业帽（学成档，森林里的最高荣誉）。
    case studentGraduation
}

/// 季节装扮（#605）：四季各一件小配饰，与身份配件（`AnimalAccessory`）**叠加** ——
/// 学员夏天戴墨镜的同时照样背小背包，两条线互不替代。
///
/// 判据是纯函数（`forSeason`）：单测与渲染共用同一份映射，换映射要测试先红。
public enum AnimalSeasonOutfit: Equatable, Sendable {
    /// 春：胸前一朵小花。
    case flower
    /// 夏：一副小墨镜。
    case sunglasses
    /// 秋：一条小围巾。
    case scarf
    /// 冬：一顶绒帽。
    case woolHat

    public static func forSeason(_ season: ForestSeason) -> AnimalSeasonOutfit {
        switch season {
        case .spring: return .flower
        case .summer: return .sunglasses
        case .autumn: return .scarf
        case .winter: return .woolHat
        }
    }
}

/// 降水行为（#605）：**下雨打伞、下雪哆嗦** —— 动物不消失，只是换个姿势在场
/// （用户 2026-10 拍板）。
///
/// 判据同为纯函数（`forWeather`）：`clear`（晴）与 nil（不跟随天气）都返回 nil ——
/// 「晴」不配道具，天好着打把伞才是怪的。
public enum AnimalWeatherBehavior: Equatable, Sendable {
    case umbrella
    case shiver

    public static func forWeather(_ weather: ForestWeather?) -> AnimalWeatherBehavior? {
        switch weather {
        case .rain: return .umbrella
        case .snow: return .shiver
        case .clear, nil: return nil
        }
    }
}

// MARK: - 主体

/// 纯矢量绘制的可爱小动物。夜晚进入「睡觉」状态（闭眼 + Zzz），白天蹦跳眨眼。
public struct CuteAnimalView: View {

    public let kind: AnimalKind
    public let isSleeping: Bool
    public let size: CGFloat
    /// 角色配件（老师持教棍 / 小学员戴红领巾）。
    public var accessory: AnimalAccessory = .none
    /// 是否持续蹦跳；地面个体可关闭以获得「有的动、有的安静」的差异。
    public var bobbing: Bool = true
    /// 教棍敲击计数（+1 = 敲两下）。**默认 0**：森林里其它持教棍的老师不受影响。
    ///
    /// 只有「老师黑板」这一处会传 —— 那是唯一需要「敲黑板引起注意」的地方。
    public var knockTick: Int = 0
    /// 庆祝跳一下的计数（+1 = 跳一次）。**默认 0**。
    ///
    /// 与 `bobbing`（常驻浮动）是两回事：老师**平时不跳**（只眨眼 + 挥教棍），
    /// 今日任务全完成那天由 `TeacherCorner` 传一次庆祝 tick 才跳。
    /// 森林里的动物不传这个参数，行为一个字节都不变。
    public var hopTick: Int = 0
    /// 眨眼初相种子：同一屏上的多只动物**必须各传不同的值**，否则它们会整排一起眨
    /// （和「整冠一起摇」是同一类毛病，肉眼一秒就出戏）。
    ///
    /// 默认 `0` = 不偏移 —— 单只动物的既有调用点（老师角 / 气泡 / 各页角落）
    /// 行为一个字节都不变。只有「一屏多只」的编排层（林间地面带）需要传。
    public var blinkPhaseSeed: Int = 0
    /// 当前季节（nil = 不随季节换装扮）。**只由林间地面带传** —— 页面角落的
    /// 功能性头像（老师角 / 气泡 / 各页学员像）不随森林场景换季，行为一个字节不变。
    public var season: ForestSeason? = nil
    /// 当前天气（nil = 无降水行为）。下雨打伞、下雪哆嗦；同样只由地面带传。
    /// 晴（`.clear`）不配道具，判据见 `AnimalWeatherBehavior.forWeather`。
    public var weather: ForestWeather? = nil

    /// **离屏渲染夹具专用总闸**：置 `false` 时动物不启动任何定时动画（眨眼 / 跳动）。
    ///
    /// 为什么非有它不可：`.repeatForever` 的跳动（1.5s 缓动、`bobbing` 默认开）一旦
    /// 生效画面就**永不静止**，眨眼又每 3.2s 关 0.14s。于是「同一份输入连出两次必须
    /// 逐像素相同」这类**确定性守卫在带动物的页面上永远无法成立** —— 帧落在哪一相，
    /// 全看当时机器有多忙（实测：单跑 5/5 绿，全量 3/3 红；差异就是两块 10×8 的方块
    /// —— 那两只眼睛）。靠「多等一会儿直到稳定」是治不好的：它根本不打算停。
    ///
    /// 产品行为**一个字节都不改**（默认 `true`），只有渲染夹具会在 setUp 里关掉它。
    /// 与 `forcedHoveredMessageID` / `DictionaryBookCard.isHovered` 是同一类接缝。
    public static var animationsEnabled = true

    @State private var isBlinking = false
    @State private var isHopping = false
    /// 庆祝跳一下的抬起量（一次性）。与 `isHopping` 的常驻浮动各走各的 offset，互不打断。
    @State private var hopLift: CGFloat = 0
    /// 下雪哆嗦的高频小抖（`AnimalWeatherBehavior.shiver`）。左右 ±2% 尺寸、0.11s 一程。
    @State private var shivering = false

    @Environment(\.appMotion) private var motion

    private let blinkTimer = Timer.publish(every: Self.blinkPeriod, on: .main, in: .common).autoconnect()

    public init(kind: AnimalKind, isSleeping: Bool = false, size: CGFloat = 64,
                accessory: AnimalAccessory = .none, bobbing: Bool = true,
                knockTick: Int = 0, hopTick: Int = 0, blinkPhaseSeed: Int = 0,
                season: ForestSeason? = nil, weather: ForestWeather? = nil) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.size = size
        self.accessory = accessory
        self.bobbing = bobbing
        self.knockTick = knockTick
        self.hopTick = hopTick
        self.blinkPhaseSeed = blinkPhaseSeed
        self.season = season
        self.weather = weather
    }

    // MARK: - 眨眼错峰

    /// 眨眼周期（秒）。**周期统一、初相各异** —— 只错开初相就够，改周期反而会让
    /// 快的那只越来越快地追上慢的（相位不固定 = 时而同步时而不）。
    public nonisolated static let blinkPeriod: Double = 3.2
    /// 闭眼时长（秒）。
    public nonisolated static let blinkDuration: Double = 0.14

    /// 第 `seed` 号个体的眨眼初相（秒，`[0, blinkPeriod)`）。
    ///
    /// 为什么用黄金比例小数部 `frac(seed × φ)` 而不是哈希随机：哈希随机在个体
    /// 少的时候会撞（两只差 0.05s 看起来还是一起眨），而黄金比例是**低差异
    /// 序列**——任意连续 N 个整数的小数部都尽可能均匀地铺满 `[0,1)`，数学上
    /// 保证「前 N 只两两都不挤在一起」。实测 8 只（地面带满员）最小间隔
    /// 0.288s，远大于闭眼的 0.14s，绝不会连成一片。
    ///
    /// 另：它是纯函数且不依赖任何运行时状态 → 离屏渲染与真机拿到同一个值。
    public nonisolated static func blinkLead(seed: Int) -> Double {
        let phi = 0.618_033_988_749_895
        let scaled = Double(seed) * phi
        // 手动取小数部（不用 `truncatingRemainder`，它会跟着被除数带负号）。
        let frac = scaled - scaled.rounded(.down)
        return blinkPeriod * frac
    }

    /// 眨一下（闭眼 → 睁眼）。延迟派发后**再判一次**闸门：延迟期间可能已经
    /// 切到夜晚（睡着了）或被渲染夹具关掉了动画。
    private func blink() {
        guard !isSleeping, Self.animationsEnabled else { return }
        isBlinking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.blinkDuration) { isBlinking = false }
    }

    public var body: some View {
        // 降水行为判据（纯函数）：睡着的动物不冷不躲——Zzz 会脱离打伞的身体，
        // 哆嗦更是只属于醒着的反应。晴 / 无天气 = 没行为。
        let behavior: AnimalWeatherBehavior? =
            isSleeping ? nil : AnimalWeatherBehavior.forWeather(weather)

        ZStack {
            animal
                .frame(width: size, height: size)

            if isSleeping {
                ZzzView(size: size * 0.28)
                    .offset(x: size * 0.38, y: -size * 0.38)
            }

            switch accessory {
            case .none: EmptyView()
            case .teacher: TeacherPointer(size: size, knockTick: knockTick)
            case .student: RedScarf(size: size)
            case .studentBackpack: LittleBackpack(size: size)
            case .studentTelescope: LittleTelescope(size: size)
            case .studentGraduation: GraduationCap(size: size)
            }

            // 季节装扮（#605）：与身份配件叠加——夏天戴墨镜的小熊照样背小背包。
            if let season {
                SeasonOutfit(season: season, size: size, isSleeping: isSleeping)
            }

            // 下雨打伞（#605）：伞撑在身侧偏上，不遮动物的脸。
            if behavior == .umbrella {
                LittleUmbrella(size: size)
            }
        }
        .frame(width: size, height: size)
        .offset(y: isSleeping ? size * 0.02 : (isHopping ? -size * 0.045 : 0))
        .loopAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isHopping)
        // 庆祝跳一下（一次性）：与上面的常驻浮动分开两条 offset，谁都不打断谁。
        .offset(y: hopLift)
        // 下雪哆嗦（#605）：高频小抖一条独立 offset。reduceMotion 下 loopAnimation
        // 不插值（静态缩着），离屏夹具（animationsEnabled=false）同样停 ——
        // 「同一份输入连出两次必须逐像素相同」的确定性守卫不能被它破。
        // ⚠️ 判据不在哆嗦档时位移恒 0（否则「没有天气」也会凭空左移一点）。
        .offset(x: shiverOffset)
        .loopAnimation(
            .linear(duration: 0.11).repeatForever(autoreverses: true),
            value: shivering
        )
        .onChange(of: hopTick) { _, tick in
            // 睡着了不跳（Zzz 会脱离身体）；渲染夹具关着动画也不跳。
            guard tick > 0, !isSleeping, Self.animationsEnabled else { return }
            // emphasis 档：全项目唯一允许过冲的一条曲线，「成功 / 里程碑」专用 ——
            // 今日任务全完成正是这样的时刻。reduceMotion 下它自动退化成 0.12s 线性。
            withAnimation(motion.animation(.emphasis)) { hopLift = -size * 0.22 }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.34))
                withAnimation(motion.animation(.emphasis)) { hopLift = 0 }
            }
        }
        .onAppear {
            if bobbing, !isSleeping, Self.animationsEnabled {
                isHopping = true
            } else {
                isHopping = false
            }
            updateShivering(behavior: behavior)
        }
        .onChange(of: isSleeping) { _, sleeping in
            isHopping = (bobbing && !sleeping && Self.animationsEnabled) ? true : false
            updateShivering(behavior: sleeping ? nil : AnimalWeatherBehavior.forWeather(weather))
        }
        .onChange(of: weather) { _, newValue in
            updateShivering(behavior: isSleeping ? nil : AnimalWeatherBehavior.forWeather(newValue))
        }
        .onReceive(blinkTimer) { _ in
            guard !isSleeping, Self.animationsEnabled else { return }
            let lead = Self.blinkLead(seed: blinkPhaseSeed)
            if lead < 0.001 {
                blink()
            } else {
                // 每拍都延后同一个 lead —— 等价于把整条眨眼序列整体平移，
                // 相位永久错开（不会因为跑久了又飘回同步）。
                DispatchQueue.main.asyncAfter(deadline: .now() + lead) { blink() }
            }
        }
    }

    /// 哆嗦状态跟随天气 / 睡意 / 夹具闸门（放在一处，免得三处 onChange 各写一遍判据）。
    private func updateShivering(behavior: AnimalWeatherBehavior?) {
        shivering = behavior == .shiver && Self.animationsEnabled
    }

    /// 哆嗦位移（#605）：**判据不在哆嗦档时恒 0** —— 没有天气的动物一点不挪，
    /// 否则「关掉天气」与「下雪天」的基准画面会差出一个身位，判据全漂。
    private var shiverOffset: CGFloat {
        guard !isSleeping, AnimalWeatherBehavior.forWeather(weather) == .shiver else { return 0 }
        return shivering ? size * 0.02 : -size * 0.02
    }

    @ViewBuilder
    private var animal: some View {
        switch kind {
        case .fox: FoxAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .panda: PandaAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .tiger: TigerAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .owl: OwlAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .rabbit: RabbitAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .bear: BearAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .squirrel: SquirrelAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .hedgehog: HedgehogAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        }
    }
}

// MARK: - 眼睛

private struct AnimalEye: View {
    let diameter: CGFloat
    let isClosed: Bool
    var sclera: Color? = nil
    var pupil: Color = Fur.dark

    var body: some View {
        ZStack {
            if isClosed {
                Capsule()
                    .fill(pupil)
                    .frame(width: diameter * 0.82, height: max(1.4, diameter * 0.14))
            } else {
                if let sclera {
                    Circle().fill(sclera)
                    Circle().fill(pupil).frame(width: diameter * 0.62, height: diameter * 0.62)
                } else {
                    Circle().fill(pupil)
                }
                Circle()
                    .fill(.white)
                    .frame(width: diameter * 0.30, height: diameter * 0.30)
                    .offset(x: -diameter * 0.17, y: -diameter * 0.18)
                Circle()
                    .fill(.white.opacity(0.55))
                    .frame(width: diameter * 0.13, height: diameter * 0.13)
                    .offset(x: diameter * 0.17, y: diameter * 0.20)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - 小零件

private struct Whiskers: View {
    let size: CGFloat
    let side: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Capsule()
                    .fill(Color(hex: 0x6B5545).opacity(0.5))
                    .frame(width: size * 0.17, height: max(1, size * 0.011))
                    .rotationEffect(.degrees(side > 0 ? -14 + Double(index) * 22 : 14 - Double(index) * 22))
                    .offset(x: side * size * 0.17, y: size * (0.01 + Double(index) * 0.035))
            }
        }
    }
}

private struct Blush: View {
    let size: CGFloat
    let width: CGFloat
    let y: CGFloat

    var body: some View {
        ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
            Ellipse()
                .fill(Fur.pink.opacity(0.45))
                .frame(width: size * width, height: size * width * 0.62)
                .offset(x: side * size * 0.20, y: size * y)
        }
    }
}

// MARK: - 狐狸：尖耳 + 白胸 + 白色口鼻 + 白尖大尾巴

private struct FoxAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Capsule().fill(Fur.fox)
                .frame(width: size * 0.38, height: size * 0.19)
                .rotationEffect(.degrees(-42))
                .offset(x: size * 0.27, y: size * 0.24)
            Circle().fill(Fur.foxLight)
                .frame(width: size * 0.17, height: size * 0.17)
                .offset(x: size * 0.40, y: size * 0.08)

            Ellipse().fill(Fur.fox).frame(width: size * 0.50, height: size * 0.38).offset(y: size * 0.24)
            Ellipse().fill(Fur.foxLight).frame(width: size * 0.24, height: size * 0.20).offset(y: size * 0.29)
            Ellipse().fill(Fur.nose.opacity(0.9)).frame(width: size * 0.12, height: size * 0.08).offset(x: -size * 0.11, y: size * 0.41)
            Ellipse().fill(Fur.nose.opacity(0.9)).frame(width: size * 0.12, height: size * 0.08).offset(x: size * 0.11, y: size * 0.41)

            Circle().fill(Fur.fox).frame(width: size * 0.52, height: size * 0.52).offset(y: -size * 0.13)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Triangle().fill(Fur.fox).frame(width: size * 0.21, height: size * 0.25)
                    .rotationEffect(.degrees(Double(side) * 15))
                    .offset(x: side * size * 0.18, y: -size * 0.34)
                Triangle().fill(Fur.nose).frame(width: size * 0.11, height: size * 0.14)
                    .rotationEffect(.degrees(Double(side) * 15))
                    .offset(x: side * size * 0.18, y: -size * 0.31)
            }
            // 白色口鼻 + 脸颊
            FoxSnout().fill(Fur.foxLight).frame(width: size * 0.34, height: size * 0.24).offset(y: -size * 0.02)
            Ellipse().fill(Fur.foxLight).frame(width: size * 0.46, height: size * 0.15).offset(y: -size * 0.07)
            Ellipse().fill(Fur.nose).frame(width: size * 0.075, height: size * 0.055).offset(y: -size * 0.075)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.105, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.115, y: -size * 0.175)
            }
            Whiskers(size: size, side: -1).offset(x: -size * 0.02, y: -size * 0.06)
            Whiskers(size: size, side: 1).offset(x: size * 0.02, y: -size * 0.06)
        }
    }
}

private struct FoxSnout: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.18))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.18),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.20))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY),
                       control: CGPoint(x: r.maxX, y: r.minY + r.height * 0.90))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.18),
                       control: CGPoint(x: r.minX, y: r.minY + r.height * 0.90))
        return p
    }
}

// MARK: - 熊猫：黑白配色 + 黑眼圈 + 圆耳

private struct PandaAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.16, height: size * 0.27)
                .rotationEffect(.degrees(-16)).offset(x: -size * 0.245, y: size * 0.22)
            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.16, height: size * 0.27)
                .rotationEffect(.degrees(16)).offset(x: size * 0.245, y: size * 0.22)
            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.21, height: size * 0.15).offset(x: -size * 0.13, y: size * 0.41)
            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.21, height: size * 0.15).offset(x: size * 0.13, y: size * 0.41)

            Ellipse().fill(Fur.pandaWhite).frame(width: size * 0.54, height: size * 0.44).offset(y: size * 0.22)

            Circle().fill(Fur.pandaWhite).frame(width: size * 0.56, height: size * 0.56).offset(y: -size * 0.14)
            Circle().fill(Fur.pandaBlack).frame(width: size * 0.20, height: size * 0.20).offset(x: -size * 0.21, y: -size * 0.36)
            Circle().fill(Fur.pandaBlack).frame(width: size * 0.20, height: size * 0.20).offset(x: size * 0.21, y: -size * 0.36)

            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.18, height: size * 0.22)
                .rotationEffect(.degrees(-22)).offset(x: -size * 0.115, y: -size * 0.165)
            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.18, height: size * 0.22)
                .rotationEffect(.degrees(22)).offset(x: size * 0.115, y: -size * 0.165)

            if isSleeping || isBlinking {
                Capsule().fill(Fur.dark).frame(width: size * 0.11, height: max(1.2, size * 0.016)).offset(x: -size * 0.115, y: -size * 0.165)
                Capsule().fill(Fur.dark).frame(width: size * 0.11, height: max(1.2, size * 0.016)).offset(x: size * 0.115, y: -size * 0.165)
            } else {
                ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                    Circle().fill(.white).frame(width: size * 0.088, height: size * 0.088).offset(x: side * size * 0.115, y: -size * 0.168)
                    Circle().fill(Fur.dark).frame(width: size * 0.058, height: size * 0.058).offset(x: side * size * 0.118, y: -size * 0.163)
                }
            }

            RoundedTriangle().fill(Fur.dark).frame(width: size * 0.12, height: size * 0.085).offset(y: -size * 0.055)
            Capsule().fill(Fur.dark.opacity(0.75)).frame(width: size * 0.09, height: max(1, size * 0.012)).offset(y: size * 0.005)
            Blush(size: size, width: 0.10, y: -0.03)
        }
    }
}

private struct RoundedTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let radius = min(r.width, r.height) * 0.28
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY + radius * 0.2))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius * 0.2, y: r.minY),
                       control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + radius * 0.2, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY + radius * 0.2),
                       control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 老虎：橙色 + 黑条纹 + 王字额纹 + 白口鼻

private struct TigerAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Capsule().fill(Fur.tiger).frame(width: size * 0.36, height: size * 0.13)
                .rotationEffect(.degrees(-38)).offset(x: size * 0.28, y: size * 0.25)
            ForEach(0..<2, id: \.self) { index in
                Capsule().fill(Fur.tigerStripe.opacity(0.85))
                    .frame(width: size * 0.055, height: size * 0.14)
                    .rotationEffect(.degrees(-38))
                    .offset(x: size * (0.24 + Double(index) * 0.09), y: size * (0.32 - Double(index) * 0.10))
            }

            Ellipse().fill(Fur.tiger).frame(width: size * 0.54, height: size * 0.44)
                .overlay(
                    ZStack {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule().fill(Fur.tigerStripe.opacity(0.8))
                                .frame(width: size * 0.34, height: size * 0.045)
                                .rotationEffect(.degrees(-22))
                                .offset(x: -size * 0.11, y: size * (-0.10 + Double(index) * 0.10))
                        }
                        ForEach(0..<3, id: \.self) { index in
                            Capsule().fill(Fur.tigerStripe.opacity(0.8))
                                .frame(width: size * 0.34, height: size * 0.045)
                                .rotationEffect(.degrees(22))
                                .offset(x: size * 0.11, y: size * (-0.10 + Double(index) * 0.10))
                        }
                    }
                    .clipShape(Ellipse())
                )
                .offset(y: size * 0.22)
            Ellipse().fill(Fur.tigerCream).frame(width: size * 0.30, height: size * 0.24).offset(y: size * 0.27)

            Circle().fill(Fur.tiger).frame(width: size * 0.56, height: size * 0.56).offset(y: -size * 0.13)
            Circle().fill(Fur.tiger).frame(width: size * 0.21, height: size * 0.21).offset(x: -size * 0.21, y: -size * 0.35)
            Circle().fill(Fur.tiger).frame(width: size * 0.21, height: size * 0.21).offset(x: size * 0.21, y: -size * 0.35)
            Circle().fill(Fur.pink.opacity(0.75)).frame(width: size * 0.12, height: size * 0.12).offset(x: -size * 0.21, y: -size * 0.35)
            Circle().fill(Fur.pink.opacity(0.75)).frame(width: size * 0.12, height: size * 0.12).offset(x: size * 0.21, y: -size * 0.35)

            // 额头「王」字纹
            Capsule().fill(Fur.tigerStripe).frame(width: size * 0.035, height: size * 0.14).offset(y: -size * 0.31)
            Capsule().fill(Fur.tigerStripe).frame(width: size * 0.16, height: size * 0.032).offset(y: -size * 0.34)
            Capsule().fill(Fur.tigerStripe).frame(width: size * 0.16, height: size * 0.032).offset(y: -size * 0.29)

            // 白色口鼻（两瓣）
            Ellipse().fill(Fur.tigerCream).frame(width: size * 0.40, height: size * 0.20).offset(y: -size * 0.03)
            Ellipse().fill(Fur.tigerCream).frame(width: size * 0.15, height: size * 0.13).offset(x: -size * 0.065, y: -size * 0.045)
            Ellipse().fill(Fur.tigerCream).frame(width: size * 0.15, height: size * 0.13).offset(x: size * 0.065, y: -size * 0.045)
            RoundedTriangle().fill(Fur.pink).frame(width: size * 0.11, height: size * 0.075).offset(y: -size * 0.085)
            Capsule().fill(Fur.dark.opacity(0.7)).frame(width: size * 0.08, height: max(1, size * 0.011)).offset(y: -size * 0.02)

            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.105, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.115, y: -size * 0.17)
            }
            Whiskers(size: size, side: -1).offset(x: -size * 0.02, y: -size * 0.07)
            Whiskers(size: size, side: 1).offset(x: size * 0.02, y: -size * 0.07)
        }
    }
}

// MARK: - 猫头鹰：大眼睛 + 面盘 + 耳簇 + 翅膀

private struct OwlAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Ellipse().fill(Fur.owlDeep).frame(width: size * 0.15, height: size * 0.34)
                .rotationEffect(.degrees(-10)).offset(x: -size * 0.235, y: size * 0.16)
            Ellipse().fill(Fur.owlDeep).frame(width: size * 0.15, height: size * 0.34)
                .rotationEffect(.degrees(10)).offset(x: size * 0.235, y: size * 0.16)

            Ellipse().fill(Fur.owl).frame(width: size * 0.52, height: size * 0.50).offset(y: size * 0.14)
            Ellipse().fill(Fur.owlFace).frame(width: size * 0.32, height: size * 0.30).offset(y: size * 0.20)

            // 脚
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Capsule().fill(Fur.owlBeak).frame(width: size * 0.06, height: size * 0.03)
                    .rotationEffect(.degrees(side > 0 ? 20 : -20))
                    .offset(x: side * size * 0.09, y: size * 0.38)
            }

            Circle().fill(Fur.owl).frame(width: size * 0.58, height: size * 0.58).offset(y: -size * 0.16)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Triangle().fill(Fur.owl).frame(width: size * 0.17, height: size * 0.19)
                    .rotationEffect(.degrees(Double(side) * 14))
                    .offset(x: side * size * 0.17, y: -size * 0.42)
            }

            // 面盘
            Circle().fill(Fur.owlFace).frame(width: size * 0.28, height: size * 0.28).offset(x: -size * 0.085, y: -size * 0.18)
            Circle().fill(Fur.owlFace).frame(width: size * 0.28, height: size * 0.28).offset(x: size * 0.085, y: -size * 0.18)

            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.20, isClosed: isSleeping || isBlinking,
                          sclera: Color(hex: 0xFFD98A), pupil: Fur.dark)
                    .offset(x: side * size * 0.085, y: -size * 0.18)
            }

            Triangle().fill(Fur.owlBeak).frame(width: size * 0.11, height: size * 0.12).offset(y: -size * 0.06)
        }
    }
}

// MARK: - 兔子：长耳 + 粉内耳 + 门牙 + 圆尾巴

private struct RabbitAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: size * 0.18, height: size * 0.18).offset(x: -size * 0.28, y: size * 0.27)
            Ellipse().fill(Fur.rabbit).frame(width: size * 0.48, height: size * 0.40).offset(y: size * 0.23)
            Ellipse().fill(Fur.rabbitShade).frame(width: size * 0.18, height: size * 0.11).offset(x: -size * 0.12, y: size * 0.41)
            Ellipse().fill(Fur.rabbitShade).frame(width: size * 0.18, height: size * 0.11).offset(x: size * 0.12, y: size * 0.41)

            Circle().fill(Fur.rabbit).frame(width: size * 0.50, height: size * 0.50).offset(y: -size * 0.11)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Capsule().fill(Fur.rabbit).frame(width: size * 0.135, height: size * 0.38)
                    .rotationEffect(.degrees(Double(side) * 9))
                    .offset(x: side * size * 0.145, y: -size * 0.45)
                Capsule().fill(Fur.pink.opacity(0.85)).frame(width: size * 0.07, height: size * 0.28)
                    .rotationEffect(.degrees(Double(side) * 9))
                    .offset(x: side * size * 0.145, y: -size * 0.45)
            }

            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.10, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.11, y: -size * 0.15)
            }
            RoundedTriangle().fill(Fur.pink).frame(width: size * 0.08, height: size * 0.055).offset(y: -size * 0.055)
            Capsule().fill(Fur.dark.opacity(0.55)).frame(width: size * 0.06, height: max(1, size * 0.010)).offset(y: -size * 0.005)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                RoundedRectangle(cornerRadius: size * 0.012, style: .continuous)
                    .fill(.white)
                    .frame(width: size * 0.032, height: size * 0.055)
                    .offset(x: side * size * 0.026, y: size * 0.025)
            }
            Blush(size: size, width: 0.09, y: -0.05)
            Whiskers(size: size, side: -1).offset(x: -size * 0.01, y: -size * 0.08)
            Whiskers(size: size, side: 1).offset(x: size * 0.01, y: -size * 0.08)
        }
    }
}

// MARK: - 小熊：圆耳 + 大吻部 + 小眼睛

private struct BearAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Ellipse().fill(Fur.bear).frame(width: size * 0.56, height: size * 0.46).offset(y: size * 0.22)
            Ellipse().fill(Fur.bearLight).frame(width: size * 0.32, height: size * 0.25).offset(y: size * 0.28)
            Circle().fill(Fur.bear).frame(width: size * 0.16, height: size * 0.16).offset(x: -size * 0.25, y: size * 0.32)
            Circle().fill(Fur.bear).frame(width: size * 0.16, height: size * 0.16).offset(x: size * 0.25, y: size * 0.32)

            Circle().fill(Fur.bear).frame(width: size * 0.54, height: size * 0.54).offset(y: -size * 0.15)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Circle().fill(Fur.bear).frame(width: size * 0.21, height: size * 0.21).offset(x: side * size * 0.21, y: -size * 0.37)
                Circle().fill(Fur.bearLight).frame(width: size * 0.12, height: size * 0.12).offset(x: side * size * 0.21, y: -size * 0.37)
            }

            Ellipse().fill(Fur.bearLight).frame(width: size * 0.28, height: size * 0.20).offset(y: -size * 0.05)
            Ellipse().fill(Fur.nose).frame(width: size * 0.11, height: size * 0.075).offset(y: -size * 0.105)
            Capsule().fill(Fur.dark.opacity(0.6)).frame(width: size * 0.08, height: max(1, size * 0.011)).offset(y: -size * 0.02)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.085, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.115, y: -size * 0.195)
            }
            Blush(size: size, width: 0.09, y: -0.06)
        }
    }
}

// MARK: - 松鼠：蓬松大尾巴 + 门牙 + 尖耳

private struct SquirrelAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            BushyTail().stroke(Fur.squirrel, style: StrokeStyle(lineWidth: size * 0.21, lineCap: .round))
                .frame(width: size * 0.46, height: size * 0.62)
                .offset(x: size * 0.28, y: size * 0.06)
            BushyTail().stroke(Fur.squirrelLight, style: StrokeStyle(lineWidth: size * 0.10, lineCap: .round))
                .frame(width: size * 0.38, height: size * 0.52)
                .offset(x: size * 0.28, y: size * 0.06)

            Ellipse().fill(Fur.squirrel).frame(width: size * 0.46, height: size * 0.42).offset(y: size * 0.25)
            Ellipse().fill(Fur.squirrelLight).frame(width: size * 0.26, height: size * 0.24).offset(y: size * 0.29)
            Ellipse().fill(Fur.squirrelLight).frame(width: size * 0.15, height: size * 0.10).offset(x: -size * 0.10, y: size * 0.42)
            Ellipse().fill(Fur.squirrelLight).frame(width: size * 0.15, height: size * 0.10).offset(x: size * 0.10, y: size * 0.42)

            Circle().fill(Fur.squirrel).frame(width: size * 0.50, height: size * 0.50).offset(y: -size * 0.12)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Triangle().fill(Fur.squirrel).frame(width: size * 0.17, height: size * 0.19)
                    .rotationEffect(.degrees(Double(side) * 12))
                    .offset(x: side * size * 0.165, y: -size * 0.34)
                Triangle().fill(Fur.pink.opacity(0.8)).frame(width: size * 0.09, height: size * 0.11)
                    .rotationEffect(.degrees(Double(side) * 12))
                    .offset(x: side * size * 0.165, y: -size * 0.32)
            }

            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.115, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.11, y: -size * 0.16)
            }
            Ellipse().fill(Fur.cream).frame(width: size * 0.20, height: size * 0.14).offset(y: -size * 0.045)
            Ellipse().fill(Fur.nose).frame(width: size * 0.07, height: size * 0.05).offset(y: -size * 0.075)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                RoundedRectangle(cornerRadius: size * 0.010, style: .continuous)
                    .fill(.white)
                    .frame(width: size * 0.030, height: size * 0.05)
                    .offset(x: side * size * 0.024, y: size * 0.005)
            }
            Blush(size: size, width: 0.085, y: -0.05)
        }
    }
}

private struct BushyTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.20, y: r.maxY))
        p.addCurve(
            to: CGPoint(x: r.maxX - r.width * 0.05, y: r.minY + r.height * 0.12),
            control1: CGPoint(x: r.minX - r.width * 0.62, y: r.maxY - r.height * 0.28),
            control2: CGPoint(x: r.maxX + r.width * 0.18, y: r.minY + r.height * 0.78)
        )
        return p
    }
}

// MARK: - 刺猬：尖刺背 + 尖嘴

private struct HedgehogAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            SpikyDome().fill(Fur.hedgehogSpike)
                .frame(width: size * 0.76, height: size * 0.52)
                .offset(y: size * 0.10)
            SpikyDome().fill(Fur.hedgehogSpike.opacity(0.55))
                .frame(width: size * 0.52, height: size * 0.34)
                .offset(x: -size * 0.06, y: size * 0.02)

            Ellipse().fill(Fur.hedgehogFace).frame(width: size * 0.44, height: size * 0.40).offset(y: size * 0.20)
            Ellipse().fill(Fur.hedgehogFace).frame(width: size * 0.16, height: size * 0.13).offset(y: size * 0.35)
            Circle().fill(Fur.dark).frame(width: size * 0.07, height: size * 0.06).offset(y: size * 0.345)

            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Circle().fill(Fur.nose).frame(width: size * 0.10, height: size * 0.10).offset(x: side * size * 0.155, y: size * 0.06)
                AnimalEye(diameter: size * 0.075, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.075, y: size * 0.135)
            }
            Ellipse().fill(Fur.hedgehogSpike.opacity(0.9)).frame(width: size * 0.16, height: size * 0.09).offset(x: -size * 0.16, y: size * 0.38)
            Ellipse().fill(Fur.hedgehogSpike.opacity(0.9)).frame(width: size * 0.16, height: size * 0.09).offset(x: size * 0.16, y: size * 0.38)
            Blush(size: size, width: 0.075, y: 0.21)
        }
    }
}

private struct SpikyDome: Shape {
    func path(in r: CGRect) -> Path {
        let spikes = 12
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        for index in 0..<spikes {
            let t0 = Double(index) / Double(spikes)
            let t1 = Double(index + 1) / Double(spikes)
            let x0 = r.minX + r.width * t0
            let x1 = r.minX + r.width * t1
            let xm = (x0 + x1) / 2
            let h0 = domeHeight(t0)
            let h1 = domeHeight(t1)
            p.addLine(to: CGPoint(x: xm, y: r.maxY - r.height * h0))
            p.addLine(to: CGPoint(x: x1, y: r.maxY - r.height * (h0 + h1) / 2 + r.height * 0.16))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }

    private func domeHeight(_ t: Double) -> Double {
        let centered = (t - 0.5) * 2
        return 0.42 + 0.58 * sqrt(max(0, 1 - centered * centered))
    }
}

// MARK: - 共用形状

public struct Triangle: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

public struct ZzzView: View {
    let size: CGFloat
    @State private var offset: CGFloat = 0
    @State private var opacity: Double = 0.25

    @Environment(\.appMotion) private var motion

    public init(size: CGFloat) { self.size = size }

    public var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Text("z")
                    .appFont(size * (0.5 + Double(index) * 0.22), weight: .bold, design: .rounded)
                    .foregroundStyle(.white.opacity(0.85))
                    .offset(x: CGFloat(index) * size * 0.42, y: -CGFloat(index) * size * 0.40)
            }
        }
        .offset(y: offset)
        .opacity(opacity)
        .onAppear {
            // 开了「减弱动态效果」就让 zzz 静静留在原地：这一路 floating 纯粹是装饰
            // （睡觉气氛），动起来既干扰又白白占一次渲染。三个 z 会有一丁点 opacity，
            // 静止时看得出这是「睡了」，不会变成看不见。
            guard !motion.reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) {
                offset = -size * 0.9
                opacity = 0
            }
        }
    }
}

// MARK: - 配件：老师教棍 / 小学员红领巾
//
// 配件按「所有动物共用的身体比例」定位（头在画面上半部、身体居中），
// 因此对任意物种都贴合在脖子/身侧，不依赖某一物种的局部坐标。

private enum AccessoryPalette {
    static let wood = Color(hex: 0x9C6B3F)
    static let woodDark = Color(hex: 0x7A4E2B)
    static let scarf = Color(hex: 0xE8454B)
    static let scarfDark = Color(hex: 0xC22F38)
    static let tip = Color(hex: 0xFFD34D)
    // 成长线配饰：背包（草绿系）/ 望远镜（黄铜系）/ 毕业帽（墨黑 + 金穗）
    static let pack = Color(hex: 0x5FA05C)
    static let packDark = Color(hex: 0x477F48)
    static let strap = Color(hex: 0xE8DCC2)
    static let brass = Color(hex: 0xD9A441)
    static let brassDark = Color(hex: 0xA8792C)
    static let cap = Color(hex: 0x2E2C33)
    static let capDark = Color(hex: 0x1F1E23)
    static let tassel = Color(hex: 0xFFD34D)
}

/// 教棍的姿态（纯函数，方便钉住「往哪边敲」这件事）。
///
/// ⚠️ **符号约定**：`degrees` 是相对竖直的旋转角，SwiftUI 的 y 轴朝下，
/// 所以**正角 = 顺时针 = 棍梢往右**。用户看到「敲黑板时棍梢往左扫」后点名要改成往右，
/// 敲击角因此是正的 —— 改符号等于改方向，别当普通数值随手调。
struct PointerPose: Equatable {
    /// 棍身相对竖直的旋转角（度）。
    var degrees: Double
    /// 整根棍相对老师画框中心的位移（`size` 的倍数）。
    var xRatio: CGFloat
    var yRatio: CGFloat

    static let stickLengthRatio: CGFloat = 0.40

    /// 棍梢相对棍底的横向位移（`size` 的倍数）。正 = 往右。
    var tipOffsetXRatio: CGFloat {
        Self.stickLengthRatio * CGFloat(sin(degrees * .pi / 180))
    }

    /// 三种姿态：敲击 / 随手挥 / 立着。
    static func make(knocking: Bool, waving: Bool) -> PointerPose {
        // 敲黑板：往**右**上方抬起来敲两下（棍梢扫到画框右缘之外，看着才像真敲在板上）。
        if knocking { return PointerPose(degrees: 46, xRatio: 0.22, yRatio: -0.02) }
        // 随手挥：小幅、往左一点点（讲课的节奏感）。
        if waving { return PointerPose(degrees: -18, xRatio: 0.26, yRatio: 0.06) }
        return PointerPose(degrees: 6, xRatio: 0.26, yRatio: 0.06)
    }
}

/// 教棍：握在老师手边的木质小棍 + 金色圆头；比身体短一号，
/// 每隔几秒以棍身底端为轴小幅上下挥动一次（讲课的节奏感）。
private struct TeacherPointer: View {
    let size: CGFloat
    /// +1 → 敲两下（黑板展开时用：教棍点两下引起注意）。0 = 只保留原本的随手挥动。
    let knockTick: Int

    @State private var isWaving = false
    @State private var isKnocking = false
    private let waveTimer = Timer.publish(every: 4.2, on: .main, in: .common).autoconnect()

    private var pose: PointerPose { PointerPose.make(knocking: isKnocking, waving: isWaving) }

    var body: some View {
        ZStack {
            // 棍组（以底端为轴挥动）
            ZStack {
                // 棍身
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [AccessoryPalette.wood, AccessoryPalette.woodDark],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: max(2.2, size * 0.042), height: size * PointerPose.stickLengthRatio)
                // 高光
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: max(1, size * 0.012), height: size * 0.20)
                    .offset(x: -size * 0.012, y: -size * 0.04)
                // 金色圆头（棍梢）
                Circle()
                    .fill(AccessoryPalette.tip)
                    .frame(width: size * 0.085, height: size * 0.085)
                    .overlay(Circle().stroke(AccessoryPalette.woodDark.opacity(0.55), lineWidth: max(1, size * 0.01)))
                    .offset(y: -size * 0.20)
            }
            .rotationEffect(.degrees(pose.degrees), anchor: .bottom)
            .animation(isKnocking
                       ? .easeOut(duration: 0.11)
                       : .easeInOut(duration: 0.45), value: pose)
            .offset(x: size * pose.xRatio, y: size * pose.yRatio)
        }
        .frame(width: size, height: size)
        .onReceive(waveTimer) { _ in
            // 敲黑板的时候不随手挥：两个动作叠在一起会像抽筋
            guard !isKnocking else { return }
            // 挥一下再收回：小幅、不频繁
            isWaving = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isWaving = false }
        }
        .onChange(of: knockTick) { _, _ in
            guard knockTick > 0 else { return }
            Task { @MainActor in
                // 敲两下，中间留一个能看清的间隔（0.11s 出去 / 0.13s 回来 / 停 0.17s）
                for _ in 0..<2 {
                    withAnimation(.easeOut(duration: 0.11)) { isKnocking = true }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    withAnimation(.easeIn(duration: 0.13)) { isKnocking = false }
                    try? await Task.sleep(nanoseconds: 170_000_000)
                }
            }
        }
    }
}

/// 红领巾：脖子处一圈红色三角巾 + 结 + 飘带，贴合所有物种的颈线。
private struct RedScarf: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // 颈圈（略弯，绕过脖子后侧）
            Capsule()
                .fill(AccessoryPalette.scarf)
                .frame(width: size * 0.46, height: size * 0.15)
                .offset(y: size * 0.10)
            Capsule()
                .fill(AccessoryPalette.scarfDark.opacity(0.55))
                .frame(width: size * 0.44, height: size * 0.05)
                .offset(y: size * 0.155)
            // 领结结
            Circle()
                .fill(AccessoryPalette.scarf)
                .frame(width: size * 0.13, height: size * 0.12)
                .offset(y: size * 0.16)
            // 两条飘带
            RoundedTriangle()
                .fill(AccessoryPalette.scarf)
                .frame(width: size * 0.11, height: size * 0.16)
                .rotationEffect(.degrees(-12))
                .offset(x: -size * 0.06, y: size * 0.23)
            RoundedTriangle()
                .fill(AccessoryPalette.scarf)
                .frame(width: size * 0.11, height: size * 0.16)
                .rotationEffect(.degrees(12))
                .offset(x: size * 0.06, y: size * 0.23)
        }
        .frame(width: size, height: size)
    }
}

/// 小背包：背上背的小圆角书包 + 两侧水壶袋 + 扣带，背上它就是「要出发远足」的学员。
private struct LittleBackpack: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // 包身（圆角矩形，背在背后偏一侧，不挡脸）
            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                .fill(AccessoryPalette.pack)
                .frame(width: size * 0.34, height: size * 0.40)
                .offset(x: size * 0.26, y: size * 0.08)
            // 包盖
            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                .fill(AccessoryPalette.packDark)
                .frame(width: size * 0.34, height: size * 0.14)
                .offset(x: size * 0.26, y: size * -0.06)
            // 扣带
            Capsule()
                .fill(AccessoryPalette.strap)
                .frame(width: size * 0.035, height: size * 0.10)
                .offset(x: size * 0.26, y: size * 0.02)
            // 水壶袋
            Capsule()
                .fill(AccessoryPalette.packDark)
                .frame(width: size * 0.10, height: size * 0.20)
                .offset(x: size * 0.14, y: size * 0.12)
        }
        .frame(width: size, height: size)
    }
}

/// 小望远镜：举在眼前的小单筒望远镜（斜向上 25°，望向远处），探索档的象征。
private struct LittleTelescope: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // 镜筒
            Capsule()
                .fill(AccessoryPalette.brass)
                .frame(width: size * 0.42, height: size * 0.13)
                .rotationEffect(.degrees(-25))
                .offset(x: size * 0.20, y: size * -0.16)
            // 物镜（粗端）
            Capsule()
                .fill(AccessoryPalette.brassDark)
                .frame(width: size * 0.12, height: size * 0.17)
                .rotationEffect(.degrees(-25))
                .offset(x: size * 0.36, y: size * -0.22)
            // 目镜（细端）
            Capsule()
                .fill(AccessoryPalette.brassDark)
                .frame(width: size * 0.08, height: size * 0.15)
                .rotationEffect(.degrees(-25))
                .offset(x: size * 0.04, y: size * -0.10)
            // 镜身高光
            Capsule()
                .fill(.white.opacity(0.30))
                .frame(width: size * 0.22, height: size * 0.03)
                .rotationEffect(.degrees(-25))
                .offset(x: size * 0.20, y: size * -0.19)
        }
        .frame(width: size, height: size)
    }
}

/// 毕业帽：方帽 + 帽穗，学成档的最高荣誉，稳稳戴在头顶。
private struct GraduationCap: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // 帽顶（菱形板）
            RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                .fill(AccessoryPalette.cap)
                .frame(width: size * 0.52, height: size * 0.52)
                .rotationEffect(.degrees(45))
                .scaleEffect(x: 1, y: 0.55)
                .offset(y: size * -0.30)
            // 帽座（梯形感的小圆台）
            Capsule()
                .fill(AccessoryPalette.capDark)
                .frame(width: size * 0.36, height: size * 0.10)
                .offset(y: size * -0.22)
            // 帽穗：从帽顶垂到一侧
            Capsule()
                .fill(AccessoryPalette.tassel)
                .frame(width: size * 0.03, height: size * 0.22)
                .rotationEffect(.degrees(18), anchor: .top)
                .offset(x: size * 0.14, y: size * -0.12)
            // 穗子坠
            Circle()
                .fill(AccessoryPalette.tassel)
                .frame(width: size * 0.07, height: size * 0.07)
                .offset(x: size * 0.19, y: size * 0.00)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 季节装扮（#605）

/// 四季小装扮：春小花 / 夏墨镜 / 秋围巾 / 冬绒帽。与身份配件（`AnimalAccessory`）叠加 ——
/// 学员戴墨镜的同时照样背小背包（用户 2026-10 拍板「四季小装扮」）。
///
/// 每件都画在**不遮脸的位置**（胸前 / 眼睛那一条线 / 脖圈 / 头顶），
/// 睡觉时除墨镜外全部收起（睡着了还戴花围巾就违和了）。
private struct SeasonOutfit: View {
    let season: ForestSeason
    let size: CGFloat
    var isSleeping: Bool = false

    var body: some View {
        ZStack {
            switch AnimalSeasonOutfit.forSeason(season) {
            case .flower:
                // 春：胸前一朵五瓣小花（一侧耳饰位，不挡五官）
                ZStack {
                    ForEach(0..<5, id: \.self) { index in
                        Circle()
                            .fill(Fur.flowerPetal)
                            .frame(width: size * 0.055, height: size * 0.055)
                            .offset(x: size * 0.055 * cos(Double(index) * 2 * .pi / 5),
                                    y: size * 0.055 * sin(Double(index) * 2 * .pi / 5))
                    }
                    Circle()
                        .fill(Fur.flowerHeart)
                        .frame(width: size * 0.04, height: size * 0.04)
                }
                .offset(x: size * 0.24, y: size * 0.10)

            case .sunglasses:
                // 夏：一副小墨镜横在眼睛那一条线（眨眼也不摘——墨镜在眼睛外面）。
                // 睡觉时摘掉：闭眼线就在这一条高度，不摘会像「戴墨镜打盹」。
                if !isSleeping {
                    ZStack {
                        Capsule()
                            .fill(Fur.lens)
                            .frame(width: size * 0.20, height: max(1.6, size * 0.026))
                            .offset(x: size * 0.10, y: -size * 0.165)
                        ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                            Circle()
                                .fill(Fur.lens)
                                .frame(width: size * 0.11, height: size * 0.11)
                                .offset(x: side * size * 0.115, y: -size * 0.165)
                            // 镜片高光：一点白，读出「这是玻璃不是黑洞」
                            Circle()
                                .fill(.white.opacity(0.45))
                                .frame(width: size * 0.030, height: size * 0.030)
                                .offset(x: side * size * 0.115 - size * 0.02, y: -size * 0.185)
                        }
                    }
                }

            case .scarf:
                // 秋：绕脖一圈 + 垂下一角（睡觉时收起来）
                if !isSleeping {
                    ZStack {
                        Capsule()
                            .fill(Fur.scarfRed)
                            .frame(width: size * 0.34, height: size * 0.09)
                            .offset(y: size * 0.10)
                        Capsule()
                            .fill(Fur.scarfDeep)
                            .frame(width: size * 0.08, height: size * 0.16)
                            .rotationEffect(.degrees(8))
                            .offset(x: size * 0.10, y: size * 0.20)
                    }
                }

            case .woolHat:
                // 冬：一顶莓红绒帽（帽檐 + 帽顶 + 绒球），睡觉也戴着——冷了更要暖
                ZStack {
                    Circle()
                        .fill(Fur.woolHat)
                        .frame(width: size * 0.30, height: size * 0.30)
                        .offset(y: size * -0.40)
                    Capsule()
                        .fill(Fur.woolHatDeep)
                        .frame(width: size * 0.36, height: size * 0.075)
                        .offset(y: size * -0.28)
                    Circle()
                        .fill(Fur.cream)
                        .frame(width: size * 0.075, height: size * 0.075)
                        .offset(y: size * -0.53)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 降水道具（#605）

/// 小雨伞：橘色伞面 + 伞柄，撑在动物身侧偏上（不遮脸）。
/// 下雨动物**不消失**，只是打个伞继续在场（用户 2026-10 拍板）。
private struct LittleUmbrella: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // 伞柄
            Capsule()
                .fill(Fur.umbrellaDeep)
                .frame(width: max(1.4, size * 0.022), height: size * 0.26)
                .offset(x: size * 0.30, y: size * 0.16)
            // 伞面：四瓣圆拼成一条伞沿（相切无缝、两色交替 = 波浪边）
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index % 2 == 0 ? Fur.umbrellaTop : Fur.umbrellaDeep)
                    .frame(width: size * 0.13, height: size * 0.13)
                    .offset(x: size * (0.30 - 0.195 + Double(index) * 0.13),
                            y: size * -0.18)
            }
            // 伞顶小尖
            Circle()
                .fill(Fur.umbrellaDeep)
                .frame(width: size * 0.035, height: size * 0.035)
                .offset(x: size * 0.30, y: size * -0.235)
        }
        .frame(width: size, height: size)
    }
}
