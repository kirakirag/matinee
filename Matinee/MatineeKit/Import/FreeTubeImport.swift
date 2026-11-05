import Foundation

public struct ImportReport: Equatable, Sendable {
    public var channels, history, skippedHistory, badLines: Int

    public init(channels: Int, history: Int, skippedHistory: Int, badLines: Int) {
        self.channels = channels
        self.history = history
        self.skippedHistory = skippedHistory
        self.badLines = badLines
    }
}

/// One-time import of FreeTube's subscriptions (`profiles.db`) and watch history (`history.db`).
public enum FreeTubeImport {
    public static func run(profiles: Data, history: Data, into store: Store) throws -> ImportReport {
        let now = Date()
        let p = NeDB.load(profiles)
        let h = NeDB.load(history)
        var report = ImportReport(channels: 0, history: 0, skippedHistory: 0, badLines: p.badLines + h.badLines)

        var channels: [String: Channel] = [:]
        let all = p.records.first { $0["_id"] as? String == "allChannels" }
        for sub in all?["subscriptions"] as? [[String: Any]] ?? [] {
            guard let id = sub["id"] as? String, ChannelID.isValid(id) else { continue }
            channels[id] = Channel(id: id, name: sub["name"] as? String ?? id,
                                   thumbnailURL: (sub["thumbnail"] as? String).flatMap(URL.init(string:)), subscribedAt: now)
        }

        var entries: [HistoryEntry] = []
        for r in h.records {
            guard let videoId = r["videoId"] as? String, VideoID.isValid(videoId) else {
                report.skippedHistory += 1
                continue
            }
            // Only plausible lengths (a huge value would trap in Int(); a negative one would break the clamp).
            let length = number(r["lengthSeconds"]).flatMap { $0 > 0 && $0 < 1_000_000 ? Int($0) : nil }
            var position = max(0, number(r["watchProgress"]) ?? 0)
            if let length { position = min(position, Double(length)) }
            entries.append(HistoryEntry(
                videoId: videoId, title: r["title"] as? String ?? "Untitled",
                channelId: r["authorId"] as? String, channelName: r["author"] as? String ?? "",
                lengthSeconds: length, publishedAt: number(r["published"]).map { Date(timeIntervalSince1970: $0 / 1000) },
                watchedAt: number(r["timeWatched"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? now,
                positionSeconds: position))
        }

        try store.upsert(Array(channels.values))
        try store.upsert(entries)
        report.channels = channels.count
        report.history = Set(entries.map(\.videoId)).count
        return report
    }

    /// A JSON number (not a bool, not a string).
    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
}
