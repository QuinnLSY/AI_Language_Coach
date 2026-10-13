import Foundation

/// 森林里「伙伴什么时候多一位」（⑦-C③）。
///
/// ⚠️ 判据只用**累计练习时长**，不用「连续 N 天」：连续天数会断，
/// 而这一位伙伴一旦来了就**不许再收回去** —— 断一次签林子里少一只，
/// 那是惩罚，不是激励。累计时长只增不减，到过 8 位就永远是 8 位。
///
/// ⚠️ 这一层只给**数**（几位 / 还差多少 / 下一位的下标），不给物种名：
/// `AnimalKind` 住在 AppUI，领域层不认识它。顺序与名字由 `AnimalKind.unlockOrder` 接。
public enum ForestUnlock {

    /// 开林就有几位。
    ///
    /// 取 4 而不是 1：林子空荡荡的看不出「这是个有人住的森林」，
    /// 而 4 位正好铺满一条正常宽度的地面带（窄面板本来就只排 1–3 只，不受影响）。
    public static let baseCompanions = 4

    /// 每再练多少分钟来一位。
    public static let minutesPerCompanion = 25

    /// 上限（= 物种总数；由接线层的哨兵测试钉住两边一致）。
    public static let maxCompanions = 8

    /// 现在林子里有几位。
    public static func companions(totalSeconds: TimeInterval) -> Int {
        let minutes = Int(max(totalSeconds, 0) / 60)
        let grown = baseCompanions + minutes / max(minutesPerCompanion, 1)
        return min(max(min(grown, maxCompanions), 0), maxCompanions)
    }

    /// 还差多少分钟来下一位（nil = 满员了）。
    public static func minutesToNext(totalSeconds: TimeInterval) -> Int? {
        guard companions(totalSeconds: totalSeconds) < maxCompanions else { return nil }
        let minutes = Int(max(totalSeconds, 0) / 60)
        return max(minutesPerCompanion - minutes % max(minutesPerCompanion, 1), 1)
    }

    /// 下一位在解锁顺序里的下标（nil = 满员）。界面拿它去问「是谁要来」。
    public static func nextIndex(totalSeconds: TimeInterval) -> Int? {
        let count = companions(totalSeconds: totalSeconds)
        return count < maxCompanions ? count : nil
    }

    // MARK: - 文案

    /// 墙头那句（「林子里 5 位伙伴」）。
    public static func headline(totalSeconds: TimeInterval) -> String {
        "林子里 \(companions(totalSeconds: totalSeconds)) 位伙伴"
    }

    /// 预告那句。满员之后**不再挂倒计时** —— 挂着一句永远兑现不了的
    /// 「再练 N 分钟」，那句就成了假话。
    public static func previewText(totalSeconds: TimeInterval) -> String {
        guard let minutes = minutesToNext(totalSeconds: totalSeconds) else {
            return "\(maxCompanions) 位伙伴都到齐了"
        }
        return "再练 \(minutes) 分钟，林子里多一位伙伴"
    }
}
