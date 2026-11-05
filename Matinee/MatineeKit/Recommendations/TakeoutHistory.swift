import Foundation

/// Reads the YouTube watch history from a Google Takeout export (YouTube and YouTube Music → history →
/// watch-history.json, JSON format). Only YouTube watches with a video link are kept: no ads ("From Google Ads"),
/// removed videos or YouTube Music; one entry per video, at its latest watch, newest first.
/// They feed For You's profile without entering History.
public enum TakeoutHistory {
    public struct NotTakeout: Error {}

    public static func parse(_ data: Data) throws -> [HistoryEntry] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw NotTakeout() }
        var latest: [String: HistoryEntry] = [:]
        for item in items {
            guard item["header"] as? String == "YouTube",
                  !((item["details"] as? [[String: Any]])?.contains { ($0["name"] as? String)?.contains("Ads") == true } ?? false),
                  let link = (item["titleUrl"] as? String).flatMap(URLComponents.init(string:)),
                  link.host?.hasSuffix("youtube.com") == true, link.host != "music.youtube.com", link.path == "/watch",
                  let id = link.queryItems?.first(where: { $0.name == "v" })?.value, VideoID.isValid(id),
                  let time = (item["time"] as? String).flatMap(date) else { continue }
            var title = item["title"] as? String ?? ""
            if title.hasPrefix("Watched ") { title.removeFirst("Watched ".count) }
            let channel = (item["subtitles"] as? [[String: Any]])?.first
            let channelId = (channel?["url"] as? String).flatMap { URL(string: $0)?.lastPathComponent }.flatMap {
                ChannelID.isValid($0) ? $0 : nil
            }
            if let seen = latest[id], seen.watchedAt >= time { continue }
            latest[id] = HistoryEntry(videoId: id, title: title, channelId: channelId,
                                      channelName: channel?["name"] as? String ?? "", lengthSeconds: nil,
                                      publishedAt: nil, watchedAt: time, positionSeconds: 0)
        }
        return latest.values.sorted { $0.watchedAt > $1.watchedAt }
    }

    private static func date(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
