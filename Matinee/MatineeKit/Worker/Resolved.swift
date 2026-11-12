import Foundation

/// Playable streams for one video, as resolved by the yt-dlp worker.
public struct Resolved: Sendable, Codable, Equatable {
    public var videoURL: URL
    public var audioURL: URL?
    public var height: Int
    public var vcodec: String?
    /// When the stream URLs stop working (~6 h after resolving).
    public var expire: Date
    /// HTTP headers the player must send with the stream requests.
    public var headers: [String: String]
    /// Streams answer 403 until this moment (YouTube's pre-roll ad wait); nil when there is no wait.
    public var availableAt: Date?
    /// Heights the video is available in, highest first.
    public var qualities: [Int]
    /// "deno" when the Deno JS-challenge provider ran for this request.
    public var jsc: String?
    /// Video metadata, nil when the worker didn't send it (older workers) or YouTube left it out.
    public var title: String?
    public var channel: String?
    public var channelId: String?
    /// Length in seconds.
    public var duration: Double?
    /// Caption tracks: uploaded ones, then the auto-generated one. Empty for results stored by an older version.
    public var subtitles: [SubtitleTrack]
    /// The audio languages, the default first; empty unless the video has several.
    public var audioTracks: [AudioTrack]

    private enum CodingKeys: String, CodingKey {
        case videoURL = "video_url", audioURL = "audio_url", height, vcodec, expire, headers, availableAt = "available_at", qualities, jsc,
             title, channel, channelId = "channel_id", duration, subtitles, audioTracks = "audio_tracks"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoURL = try c.decode(URL.self, forKey: .videoURL)
        audioURL = try c.decodeIfPresent(URL.self, forKey: .audioURL)
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        vcodec = try c.decodeIfPresent(String.self, forKey: .vcodec)
        expire = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .expire))
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        let available = try c.decodeIfPresent(Double.self, forKey: .availableAt) ?? 0
        availableAt = available > 0 ? Date(timeIntervalSince1970: available) : nil
        qualities = try c.decodeIfPresent([Int].self, forKey: .qualities) ?? []
        jsc = try c.decodeIfPresent(String.self, forKey: .jsc)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        channel = (try? c.decodeIfPresent(String.self, forKey: .channel)) ?? nil
        channelId = (try? c.decodeIfPresent(String.self, forKey: .channelId)) ?? nil
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? nil
        // Element by element: one malformed track doesn't cost the rest, or the video.
        subtitles = ((try? c.decodeIfPresent([Lenient<SubtitleTrack>].self, forKey: .subtitles)) ?? nil)?.compactMap(\.value) ?? []
        audioTracks = ((try? c.decodeIfPresent([Lenient<AudioTrack>].self, forKey: .audioTracks)) ?? nil)?.compactMap(\.value) ?? []
    }

    /// The worker's shape, so a stored result decodes like a fresh one.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(videoURL, forKey: .videoURL)
        try c.encodeIfPresent(audioURL, forKey: .audioURL)
        try c.encode(height, forKey: .height)
        try c.encodeIfPresent(vcodec, forKey: .vcodec)
        try c.encode(expire.timeIntervalSince1970, forKey: .expire)
        try c.encode(headers, forKey: .headers)
        try c.encode(availableAt?.timeIntervalSince1970 ?? 0, forKey: .availableAt)
        try c.encode(qualities, forKey: .qualities)
        try c.encodeIfPresent(jsc, forKey: .jsc)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(channel, forKey: .channel)
        try c.encodeIfPresent(channelId, forKey: .channelId)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encode(subtitles, forKey: .subtitles)
        try c.encode(audioTracks, forKey: .audioTracks)
    }
}

/// Decodes to nil instead of failing the array it is in.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

public enum WorkerError: Error, Equatable {
    case invalidID
    case failed(String)
    case crashed
    case timedOut
}
