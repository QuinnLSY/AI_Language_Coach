import Foundation

/// 语义排序的纯数学部分。
///
/// 刻意做成**纯函数、零依赖**：向量从哪来（本地 runtime / 云端 / mock）不归它管，
/// 它只回答「哪个候选跟当前这句话更像」。这样相关性排序可以脱机单测。
public enum SemanticRanking {

    /// 余弦相似度（-1...1）。
    ///
    /// 维度不一致或存在零向量时返回 0 —— 那是「无法比较」，既不是相似也不是错误，
    /// 调用方按「不相关」处理即可，不要让它变成 NaN 污染后续排序。
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for index in a.indices {
            let x = Double(a[index])
            let y = Double(b[index])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// 按与 query 的相似度排序候选，返回 (key, score)，相似度降序。
    ///
    /// 相似度为负（方向相反）的候选会被 `floor` 挡掉：它们与当前话题是**反相关**，
    /// 硬塞给老师只会添乱。相同得分的候选按传入顺序稳定排列，保证结果可复现。
    public static func ranking(
        query: [Float],
        candidates: [(key: String, vector: [Float])],
        floor: Double = 0,
        limit: Int = .max
    ) -> [(key: String, score: Double)] {
        guard limit > 0, !candidates.isEmpty else { return [] }
        let scored = candidates.enumerated().map { index, candidate in
            (key: candidate.key, score: cosineSimilarity(query, candidate.vector), index: index)
        }
        return scored
            .filter { $0.score >= floor }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
            .prefix(limit)
            .map { (key: $0.key, score: $0.score) }
    }
}
