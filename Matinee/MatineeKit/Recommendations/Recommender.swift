import Foundation

/// Ranks the videos suggested next to recent watches into one list, on the Mac: YouTube only ever sees which watch
/// pages were fetched, never the combined profile.
public enum Recommender {
    /// How much each older watch counts, relative to the one after it.
    static let recency = 0.85
    /// Subscribed channels' videos already reach the Subscriptions feed.
    static let subscribedWeight = 0.4
    /// Each pick from a channel lowers that channel's remaining videos a little, so one channel can't fill the top.
    /// Light, because series get watched in a row: on the user's own history (2026-11-05), 0.9 kept ~14 channels in
    /// the top 20 and almost all of the gain of no spreading, where 0.6 cost a third of the hits.
    static let channelRepeat = 0.9
    /// Channels watched recently but not subscribed to: × (1 + ln(1 + watches)); the strongest signal for what gets
    /// watched next outside the feed.
    static let channelWeight = 1.0
    /// How strongly the title model's affinity reweights: a score × e^z, so z = ±2 is about ×7 or ÷7. Logged-out
    /// suggestions carry generic filler (news, talk shows) next to unrelated videos; at 0.6 it still made ~8% of the
    /// top 20, at 1.0 ~2%, with the same hits on the user's history (2026-11-05); 1.5 and up started to cost hits.
    public static let affinityWeight = 1.0
    /// The same for e5 on titles and descriptions (local AI ranking): its best on the history's validation quarter
    /// (Scripts/recommendations/README.md).
    public static let e5AffinityWeight = 1.5

    /// `seeds` are watched videos with their suggestions, most recent first. A video scores
    /// Σ recency^seed × 1/(1 + its position in that seed's list); watched videos and the seeds themselves are dropped.
    /// `affinity` is TitleSimilarity's z-score per video: how much more its title is like the history than average.
    /// `channelWatches` counts recent watches per channel (the app passes the last 100). Dismissed videos and the
    /// channels hidden with them never rank.
    public static func rank(seeds: [(videoId: String, related: [ListedEntry])], watched: Set<String>,
                            subscribed: Set<String>, affinity: [String: Double] = [:], affinityWeight: Double = affinityWeight,
                            channelWatches: [String: Int] = [:], hiddenVideos: Set<String> = [],
                            hiddenChannels: Set<String> = [], limit: Int = 100) -> [ListedEntry] {
        let excluded = watched.union(seeds.map(\.videoId)).union(hiddenVideos)
        var score: [String: Double] = [:]
        var entry: [String: ListedEntry] = [:]
        var order: [String] = []   // first appearance, for stable ties
        for (i, seed) in seeds.enumerated() {
            let weight = pow(recency, Double(i))
            for (position, e) in seed.related.enumerated() where e.kind == .video && e.hasValidID && !excluded.contains(e.id)
                && !(e.channelId.map(hiddenChannels.contains) ?? false) {
                if entry[e.id] == nil { entry[e.id] = e; order.append(e.id) }
                score[e.id, default: 0] += weight / Double(1 + position)
            }
        }
        for (id, e) in entry {
            guard let channel = e.channelId else { continue }
            if subscribed.contains(channel) {
                score[id]! *= subscribedWeight
            } else if let n = channelWatches[channel], n > 0 {
                score[id]! *= 1 + channelWeight * log(1 + Double(n))
            }
        }
        for (id, z) in affinity where score[id] != nil { score[id]! *= exp(affinityWeight * z) }
        // Greedy: the best remaining each time, then that channel's others count less.
        var remaining = order
        var result: [ListedEntry] = []
        while !remaining.isEmpty, result.count < limit {
            var best = 0
            for i in remaining.indices.dropFirst() where score[remaining[i]]! > score[remaining[best]]! { best = i }
            let picked = entry[remaining.remove(at: best)]!
            result.append(picked)
            if let channel = picked.channelId {
                for id in remaining where entry[id]!.channelId == channel { score[id]! *= channelRepeat }
            }
        }
        return result
    }
}
