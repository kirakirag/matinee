import Foundation

/// A YouTube or youtu.be URL, split into its path components and query items. Nil for anything else.
private struct YouTubeLocation {
    let isShortHost: Bool
    let path: [String]
    let query: [String: String]

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2048 else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let parts = URLComponents(string: withScheme),
              parts.scheme == "http" || parts.scheme == "https",
              var host = parts.host?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        guard host == "youtube.com" || host == "youtu.be" else { return nil }
        isShortHost = host == "youtu.be"
        path = parts.path.split(separator: "/").map(String.init)
        query = (parts.queryItems ?? []).reduce(into: [:]) { dict, item in
            if dict[item.name] == nil, let value = item.value { dict[item.name] = value }
        }
    }
}

public enum ChannelRef: Hashable, Sendable {
    case id(String)
    case handle(String)

    /// A bare `UC…` ID or `@handle`, or a youtube.com `/channel/UC…` or `/@handle` URL.
    public static func parse(_ text: String) -> ChannelRef? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ChannelID.isValid(trimmed) { return .id(trimmed) }
        if ChannelHandle.isValid(trimmed) { return .handle(trimmed) }
        return YouTubeLocation(trimmed).flatMap(from)
    }

    fileprivate static func from(_ location: YouTubeLocation) -> ChannelRef? {
        guard !location.isShortHost, let first = location.path.first else { return nil }
        if first == "channel", location.path.count > 1, ChannelID.isValid(location.path[1]) { return .id(location.path[1]) }
        if ChannelHandle.isValid(first) { return .handle(first) }
        return nil
    }
}

public enum PlaylistLink {
    /// The `list=` value of a YouTube URL, or a bare playlist ID.
    public static func parse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if PlaylistID.isValid(trimmed) { return trimmed }
        guard let id = YouTubeLocation(trimmed)?.query["list"], PlaylistID.isValid(id) else { return nil }
        return id
    }
}

public enum PastedLink: Equatable, Sendable {
    case video(id: String, start: Double?)
    case playlist(String)
    case channel(ChannelRef)

    /// URL forms and `@handle` only, so a typed search word is never mistaken for an ID.
    public static func parse(_ text: String) -> PastedLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ChannelHandle.isValid(trimmed) { return .channel(.handle(trimmed)) }
        guard let location = YouTubeLocation(trimmed) else { return nil }
        let start = (location.query["t"] ?? location.query["start"]).flatMap(seconds)
        let path = location.path
        if location.isShortHost {
            guard let id = path.first, VideoID.isValid(id) else { return nil }
            return .video(id: id, start: start)
        }
        switch path.first {
        case "watch":
            guard let id = location.query["v"], VideoID.isValid(id) else { return nil }
            return .video(id: id, start: start)
        case "shorts", "live", "embed":
            guard path.count > 1, VideoID.isValid(path[1]) else { return nil }
            return .video(id: path[1], start: start)
        case "playlist":
            guard let id = location.query["list"], PlaylistID.isValid(id) else { return nil }
            return .playlist(id)
        default:
            return ChannelRef.from(location).map(PastedLink.channel)
        }
    }

    /// `90`, `90s` or `1h2m3s` as seconds; nil for anything else.
    private static func seconds(_ s: String) -> Double? {
        if let plain = s.wholeMatch(of: /\d+/) { return Double(plain.output) }
        guard !s.isEmpty, let m = s.wholeMatch(of: /(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?/) else { return nil }
        let parts = [m.output.1, m.output.2, m.output.3].map { $0.flatMap { Double($0) } ?? 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

public enum YouTubeURL: Sendable {
    case search(String, SearchFilter)
    case channel(ChannelRef)
    case channelPlaylists(ChannelRef)
    case playlist(String)

    public static func watchURL(videoId: String) -> URL? {
        VideoID.isValid(videoId) ? URL(string: "https://www.youtube.com/watch?v=\(videoId)") : nil
    }

    public var url: URL? {
        switch self {
        case let .search(query, filter):
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return nil }
            var string = "https://www.youtube.com/results?search_query=" + Self.encode(q)
            if let sp = filter.sp { string += "&sp=" + Self.encode(sp) }
            return URL(string: string)
        case let .channel(.id(id)):
            return ChannelID.isValid(id) ? URL(string: "https://www.youtube.com/channel/\(id)") : nil
        case let .channel(.handle(handle)):
            return ChannelHandle.isValid(handle) ? URL(string: "https://www.youtube.com/\(handle)") : nil
        case let .channelPlaylists(.id(id)):
            return ChannelID.isValid(id) ? URL(string: "https://www.youtube.com/channel/\(id)/playlists") : nil
        case let .channelPlaylists(.handle(handle)):
            return ChannelHandle.isValid(handle) ? URL(string: "https://www.youtube.com/\(handle)/playlists") : nil
        case let .playlist(id):
            return PlaylistID.isValid(id) ? URL(string: "https://www.youtube.com/playlist?list=\(id)") : nil
        }
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?/#")
        return set
    }()

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? s
    }
}
