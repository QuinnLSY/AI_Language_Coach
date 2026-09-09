import AIDomain
import Foundation

/// 示例闯关数据。V1 阶段由本地种子生成，后续替换为数据库 / 学习记忆驱动的真实进度。
public enum SampleProgress {

    public static func make() -> LearnerProgress {
        let levels: [TreeLevel] = [
            TreeLevel(id: "l1", title: "树根营地", subtitle: "打招呼", heightFraction: 0.06, branch: .left,
                      state: .completed, requiredStars: 3, earnedStars: 3),
            TreeLevel(id: "l2", title: "苔藓石阶", subtitle: "自我介绍", heightFraction: 0.18, branch: .right,
                      state: .completed, requiredStars: 3, earnedStars: 3),
            TreeLevel(id: "l3", title: "松鼠枝桠", subtitle: "点咖啡", heightFraction: 0.30, branch: .left,
                      state: .completed, requiredStars: 4, earnedStars: 4),
            TreeLevel(id: "l4", title: "蜂鸟花丛", subtitle: "过去时", heightFraction: 0.42, branch: .right,
                      state: .inProgress, requiredStars: 4, earnedStars: 2),
            TreeLevel(id: "l5", title: "溪流平台", subtitle: "问路", heightFraction: 0.54, branch: .left,
                      state: .unlocked, requiredStars: 5, earnedStars: 0),
            TreeLevel(id: "l6", title: "云雀高枝", subtitle: "观点表达", heightFraction: 0.66, branch: .right,
                      state: .locked, requiredStars: 5, earnedStars: 0),
            TreeLevel(id: "l7", title: "星语树冠", subtitle: "辩论", heightFraction: 0.78, branch: .left,
                      state: .locked, requiredStars: 6, earnedStars: 0),
            TreeLevel(id: "l8", title: "日出观景台", subtitle: "自由演讲", heightFraction: 0.92, branch: .right,
                      state: .locked, requiredStars: 6, earnedStars: 0),
        ]
        let stars = levels.reduce(0) { $0 + $1.earnedStars }
        return LearnerProgress(totalStars: stars, climbFraction: 0.42, levels: levels)
    }
}
