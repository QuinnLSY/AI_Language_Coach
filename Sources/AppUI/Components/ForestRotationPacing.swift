import Foundation

/// 轮换节奏的纯函数（可单测）：小动物进离场的「错落感」全靠这几处随机。
///
/// 旧编排的毛病：一只走了另一只**紧跟着**回来、间隔恒定——太程序化，
/// 看久了就是一条传送带。新节奏的三个自由度：
/// ① 一批走几只（可结伴两只前后脚走）；② 各自什么时候回来（独立随机，
/// 有快得像「提前来」的、也有大半天不见影的）；③ 下一批告别前安静多久
/// （平时有波动，偶尔一段长歇——林子不是一直都有动静）。
enum ForestRotationPacing {

    /// 下一批告别前的静默期（秒）：平时 0.5–1.5 个基准周期（25–55s），
    /// 一成概率来一段 2.2–3.2 个周期的长歇（留白也是错落感的一部分）。
    static func nextDepartureDelay(frequency: Double, roll: Double, spread: Double) -> TimeInterval {
        let base = 55 - max(0, min(1, frequency)) * 30
        if roll < 0.10 {
            return base * (2.2 + max(0, min(1, spread)))
        }
        return base * (0.5 + max(0, min(1, spread)))
    }

    /// 这一批走几只：够两只时约三成概率结伴，否则一只（绝不超出现存数）。
    static func groupSize(present: Int, roll: Double) -> Int {
        guard present >= 2, roll < 0.3 else { return 1 }
        return 2
    }

    /// 归期（秒）：各自独立 4–45——快慢完全看缘分。
    static func returnDelay(roll: Double) -> TimeInterval {
        4 + max(0, min(1, roll)) * 41
    }

    /// 结伴离场的错落间隔（秒）：第二只晚 0.9–1.8s 动身，不齐步走。
    static func staggerDelay(roll: Double) -> TimeInterval {
        0.9 + max(0, min(1, roll)) * 0.9
    }
}
