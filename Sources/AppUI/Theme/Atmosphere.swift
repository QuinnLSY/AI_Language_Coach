import Foundation

/// 学员配饰成长线（批次三）：攒星换装——红领巾 → 小背包 → 望远镜 → 毕业帽。
///
/// 判据是**总星数**（`LearnerProgress.totalStars`）：每关最多 3 星，
/// 档位按「大约几关的努力」划线，与 climbFraction 无关（树的高度照旧由
/// 星数比例决定，配饰只管「走到哪一站了」的叙事）。
public enum StudentProgression {

    /// 换上小背包：约两关的努力（6 星）。
    public static let backpackStars = 6
    /// 换上望远镜：约四关（12 星）。
    public static let telescopeStars = 12
    /// 戴上毕业帽：约六关（18 星）——森林里的最高荣誉。
    public static let graduationStars = 18

    /// 当前该戴的配饰（负数钳到 0，照样从红领巾起步）。
    public static func accessory(totalStars: Int) -> AnimalAccessory {
        let stars = max(0, totalStars)
        if stars >= graduationStars { return .studentGraduation }
        if stars >= telescopeStars { return .studentTelescope }
        if stars >= backpackStars { return .studentBackpack }
        return .student
    }

    /// 下一档还差几颗星（已在最高档时返回 nil——「没有下一档了」也是一句可以说的话）。
    public static func starsToNextTier(totalStars: Int) -> Int? {
        let stars = max(0, totalStars)
        for threshold in [backpackStars, telescopeStars, graduationStars] where stars < threshold {
            return threshold - stars
        }
        return nil
    }
}

/// 时段问候（批次三）：中间栏空态的三档文案——早上/下午/晚上各一句，
/// 让学员每次打开应用都像被林子里的老师打了个招呼。
public enum PeriodGreeting {

    /// 问候分界（24 小时制）：[5, 11) 早晨、[11, 18) 下午、其余夜晚。
    public static let morningStart = 5
    public static let afternoonStart = 11
    public static let eveningStart = 18

    /// 问候语（三档）。深夜（0–5 点）也归「晚上」档——那是「还没睡呀」的语气。
    public static func line(hour: Int) -> String {
        let hour = (0...23).contains(hour) ? hour : 0
        if hour >= morningStart, hour < afternoonStart {
            return "早上好，今天的林子很清醒！"
        }
        if hour >= afternoonStart, hour < eveningStart {
            return "下午好，来和老师聊两句吧！"
        }
        return "晚上好，夜色里的单词记得更牢哦～"
    }

    /// 空态引导的完整两行：问候 + 原本的邀请（ inviting 语气不分档，问候才分档）。
    public static func emptyStateLines(hour: Int) -> (greeting: String, invite: String) {
        (line(hour: hour), "和老师打个招呼，开始今天的攀爬吧 🌿")
    }
}
