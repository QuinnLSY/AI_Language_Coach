import CoreGraphics
import Foundation

/// 物种性格（批次五 · D）：同一张动作表，每只小动物演出来的样子不一样。
///
/// 批次二把动作做成了语义表（10 个动作），但**谁**来演还是随机的 ——
/// 兔子跟考拉一个演法，看着就是「一群一样的动物在抽风」。性格参数化之后，
/// 「这只更爱蹦、那只动不动打盹」才成立。
///
/// ⚠️ 这里只放**偏好与权重**，动作本身的实现仍在 `LivelyAnimal`：
/// 加动作还是「枚举加一项」，性格只是决定它更常演哪一项。
public struct AnimalPersona: Sendable, Equatable {

    /// 独角戏偏好池（重复出现的项权重更高）。
    public var soloActions: [LivelyAnimalAction]
    /// 招牌动作：一定概率顶掉随机抽到的那一档（兔子更爱蹦、考拉爱打盹…）。
    public var signature: LivelyAnimalAction
    /// 活跃度（0.6…1.4）：心跳挑谁上场时按它加权。
    public var energy: Double
    /// 爱飞上枝桠（目前只有猫头鹰）。
    public var favorsPerch: Bool
    /// 一句性格说明（无障碍汇总 / 测试可读性都用它）。
    public var trait: String

    public init(soloActions: [LivelyAnimalAction], signature: LivelyAnimalAction,
                energy: Double, favorsPerch: Bool, trait: String) {
        self.soloActions = soloActions
        self.signature = signature
        self.energy = energy
        self.favorsPerch = favorsPerch
        self.trait = trait
    }
}

/// 物种 → 性格的**唯一**对照表 + 三个可单测的选择函数。
public enum AnimalPersonaBook {

    /// 招牌动作的上场概率（剩下的走随机档，性格是「偏」不是「只」）。
    public static let signatureChance = 0.3

    public static func persona(for kind: AnimalKind) -> AnimalPersona {
        switch kind {
        case .fox:
            return AnimalPersona(soloActions: [.dig, .dig, .spin, .tilt], signature: .dig,
                                 energy: 1.2, favorsPerch: false,
                                 trait: "机灵，动不动就刨两下土找东西")
        case .panda:
            return AnimalPersona(soloActions: [.stretch, .nod, .nod, .dig], signature: .nod,
                                 energy: 0.7, favorsPerch: false,
                                 trait: "懒洋洋，走两步就想打盹")
        case .tiger:
            return AnimalPersona(soloActions: [.stretch, .stretch, .spin, .tilt], signature: .stretch,
                                 energy: 1.15, favorsPerch: false,
                                 trait: "精神足，动之前先伸个懒腰")
        case .owl:
            return AnimalPersona(soloActions: [.listen, .listen, .tilt], signature: .listen,
                                 energy: 0.8, favorsPerch: true,
                                 trait: "爱停在枝桠上听林子里的动静")
        case .rabbit:
            return AnimalPersona(soloActions: [.spin, .dig, .tilt], signature: .hop,
                                 energy: 1.35, favorsPerch: false,
                                 trait: "停不下来，最爱蹦蹦跳跳")
        case .bear:
            return AnimalPersona(soloActions: [.nod, .nod, .stretch, .dig], signature: .nod,
                                 energy: 0.75, favorsPerch: false,
                                 trait: "憨厚，爱打盹点头")
        case .squirrel:
            return AnimalPersona(soloActions: [.spin, .spin, .dig, .stretch], signature: .spin,
                                 energy: 1.25, favorsPerch: false,
                                 trait: "尾巴闲不住，追着转圈玩")
        case .hedgehog:
            return AnimalPersona(soloActions: [.dig, .dig, .nod, .shy], signature: .dig,
                                 energy: 0.9, favorsPerch: false,
                                 trait: "爱刨土，被看见就害羞")
        }
    }

    /// 独角戏演哪个：从本物种的偏好池里抽（池子里重复项 = 加权）。
    public static func soloAction(for kind: AnimalKind, roll: Double) -> LivelyAnimalAction {
        let pool = persona(for: kind).soloActions
        guard !pool.isEmpty else { return .dig }
        let index = Int(min(max(roll, 0), 0.999) * Double(pool.count))
        return pool[index]
    }

    /// 随机档里要不要改演招牌动作（「兔子更爱蹦」就靠这一条）。
    public static func action(for kind: AnimalKind, roll: Double,
                              fallback: LivelyAnimalAction) -> LivelyAnimalAction {
        roll < signatureChance ? persona(for: kind).signature : fallback
    }

    /// 心跳挑谁上场：按活跃度加权（精力旺的更常被点到）。
    ///
    /// ⚠️ 传进来的 `kinds` 是**当前**各槽位的物种（轮换会换人），
    /// 拿初始 `order` 去判会让「换过物种之后性格不跟着换」。
    public static func pick(kinds: [AnimalKind], present: [Int], roll: Double) -> Int? {
        guard !present.isEmpty else { return nil }
        let weights = present.map { persona(for: kinds.indices.contains($0) ? kinds[$0] : .fox).energy }
        let total = weights.reduce(0, +)
        guard total > 0 else { return present.first }
        var cursor = min(max(roll, 0), 0.999) * total
        for (offset, weight) in weights.enumerated() where weight > 0 {
            cursor -= weight
            if cursor <= 0 { return present[offset] }
        }
        return present.last
    }
}

/// 学员的小伙伴（批次五 · D）：一只**固定**的小动物，陪着学员一起爬树。
///
/// 「固定」是这一条的核心：轮换是为了让林子有生气，但伙伴是要认得的 ——
/// 每次换一只就不是伙伴了。它跟着学员换配饰、跟着学员爬，
/// 通关时先跑到下一个关卡那边等着。
public enum ForestCompanion {

    /// 伙伴站在学员旁边一点、稍低一点（相对学员位置的偏移）。
    ///
    /// ⚠️ 只影响**伙伴自己的** `position`：学员的 `learnerY` 与滚动锚点算式
    /// 一根手指都不能碰（那是 `TreeScrollViewTests` 钉死的）。
    public static let besideLearner = CGSize(width: 54, height: 34)
    /// 伙伴个头小一号（学员 64，伙伴 40），一眼分得出谁是谁。
    public static let size: CGFloat = 40
    /// 「先跑过去等着」的横向距离。
    public static let dashDistance: CGFloat = 46

    /// 默认伙伴：每个学员物种有固定搭档（不是随机 —— 伙伴要认得）。
    public static func partner(for student: AnimalKind) -> AnimalKind {
        switch student {
        case .fox: return .rabbit
        case .panda: return .hedgehog
        case .tiger: return .squirrel
        case .owl: return .squirrel
        case .rabbit: return .hedgehog
        case .bear: return .squirrel
        case .squirrel: return .rabbit
        case .hedgehog: return .rabbit
        }
    }

    /// 通关那一刻伙伴往哪儿跑：下一关在左枝就往左，在右枝就往右；
    /// 没有下一关（全通关了）就原地不动，陪着一起庆祝。
    public static func dashX(nextBranchIsLeft: Bool?) -> CGFloat {
        guard let nextBranchIsLeft else { return 0 }
        return nextBranchIsLeft ? -dashDistance : dashDistance
    }
}
