import Foundation

/// How much each candidate is like the history, in one vector space. Vectors are centred on the candidates' mean
/// (raw embeddings all point much the same way) and compared by cosine. A candidate's similarity is the mean of its
/// 3 best matches in the history; the result is that as a z-score across the candidates. With `disliked` videos
/// ("Not interested"), the z-score of similarity to them is subtracted, so videos like a dismissed one fall too.
public enum VectorSimilarity {
    /// z-scores by candidate ID; empty without history.
    public static func affinity(history: [(id: String, vector: [Float])], candidates: [(id: String, vector: [Float])],
                                disliked: [(id: String, vector: [Float])] = []) -> [String: Double] {
        let double = { (items: [(id: String, vector: [Float])]) in items.map { ($0.id, $0.vector.map(Double.init)) } }
        let raw = scores(history: double(history).map(\.1), candidates: double(candidates),
                         disliked: double(disliked).map(\.1))
        return combine(raw)
    }

    /// z(liked) − z(disliked), over all the candidates scored.
    static func combine(_ raw: (liked: [String: Double], disliked: [String: Double])) -> [String: Double] {
        zScores(raw.liked).merging(zScores(raw.disliked).mapValues { -$0 }) { $0 + $1 }
    }

    /// Mean of the 3 best cosines to the history and to the dislikes (absent without dislikes), before z-scoring.
    static func scores(history: [[Double]], candidates: [(String, [Double])], disliked: [[Double]])
        -> (liked: [String: Double], disliked: [String: Double]) {
        guard !history.isEmpty, let dimension = candidates.first?.1.count else { return ([:], [:]) }
        var mean = [Double](repeating: 0, count: dimension)
        for (_, v) in candidates { for i in 0..<dimension { mean[i] += v[i] / Double(candidates.count) } }
        let pastUnits = history.map { unit($0, minus: mean) }
        let dislikedUnits = disliked.map { unit($0, minus: mean) }
        var liked: [String: Double] = [:], unliked: [String: Double] = [:]
        for (id, v) in candidates {
            let u = unit(v, minus: mean)
            liked[id] = bestMatches(u, in: pastUnits)
            if !dislikedUnits.isEmpty { unliked[id] = bestMatches(u, in: dislikedUnits) }
        }
        return (liked, unliked)
    }

    /// The mean of the 3 best cosines (unit vectors).
    private static func bestMatches(_ u: [Double], in units: [[Double]]) -> Double {
        let best = units.map { p in zip(p, u).reduce(0) { $0 + $1.0 * $1.1 } }.sorted(by: >).prefix(3)
        return best.reduce(0, +) / Double(best.count)
    }

    static func zScores(_ values: [String: Double]) -> [String: Double] {
        guard values.count > 1 else { return values.mapValues { _ in 0 } }
        let mean = values.values.reduce(0, +) / Double(values.count)
        let sd = (values.values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
        guard sd > 1e-9 else { return values.mapValues { _ in 0 } }
        return values.mapValues { ($0 - mean) / sd }
    }

    private static func unit(_ v: [Double], minus mean: [Double]) -> [Double] {
        let c = zip(v, mean).map { $0 - $1 }
        let n = c.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? c.map { $0 / n } : c
    }
}
