import Foundation

/// 批次二「小剧场」的节奏纯函数（可单测）：
/// 双人配对、一问一答的节拍、捡词往返的各段时长。
///
/// 与 `ForestRotationPacing` 同一思路：编排层只管照着节拍演，
/// 数字集中在这里，测试钉住「错落感」不被改回齐步走。
enum ForestTheatrePacing {

    /// 捡词叙事：从「看见词」到跑出画面的酝酿时长（秒）。
    static let fetchNoticeSeconds: TimeInterval = 1.0
    /// 捡词叙事：在画外翻找的停留时长（秒）。
    static let fetchLingerSeconds: TimeInterval = 1.2
    /// 捡词叙事：词卡展示时长（秒）——太短看不清词，太长挡树。
    static let wordCardHoldSeconds: TimeInterval = 2.8

    /// 在场居民里挑 x 距离最近的一对（双人小对话 / 结对跳舞都找邻居，
    /// 隔着整条草坡对话会显得莫名其妙）。`x` 按居民槽位索引取横向位置；
    /// 返回 nil = 凑不齐两只（或取不到坐标）。
    static func closestPair(x: [Int: CGFloat], present: [Int]) -> (Int, Int)? {
        guard present.count >= 2 else { return nil }
        var best: (Int, Int)?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 0..<present.count {
            for j in (i + 1)..<present.count {
                let a = present[i], b = present[j]
                guard let xa = x[a], let xb = x[b] else { continue }
                let distance = abs(xa - xb)
                if distance < bestDistance {
                    bestDistance = distance
                    best = (a, b)
                }
            }
        }
        return best
    }

    /// 一问一答的节拍：第 i 句在 `start` 秒时冒出、挂 `hold` 秒。
    /// 每句 2.4s 一拍（说完留半口气回应），末句多挂一会儿收尾。
    static func dialogueCues(lineCount: Int) -> [(start: Double, hold: Double)] {
        guard lineCount > 0 else { return [] }
        var cues: [(start: Double, hold: Double)] = []
        for i in 0..<lineCount {
            cues.append((start: Double(i) * 2.4, hold: i == lineCount - 1 ? 3.0 : 2.2))
        }
        return cues
    }
}
