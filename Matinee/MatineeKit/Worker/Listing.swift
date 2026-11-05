import Foundation

/// One search result or playlist row from the worker's flat listing.
public struct ListedEntry: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable { case video, channel, playlist }

    public let kind: Kind
    public let id: String
    public let title: String
    public let channel: String?
    public let channelId: String?
    public let duration: Int?
    public let views: Int?
    public let thumbnail: URL?
    public let count: Int?

    private enum CodingKeys: String, CodingKey {
        case kind, id, title, channel, channelId, duration, views, thumbnail, count
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        channelId = try c.decodeIfPresent(String.self, forKey: .channelId)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        views = try c.decodeIfPresent(Int.self, forKey: .views)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        let url = try c.decodeIfPresent(String.self, forKey: .thumbnail).flatMap { URL(string: $0) }
        thumbnail = url?.scheme == "https" ? url : nil
    }

    /// Encoded with the same keys it decodes (the store caches related lists this way).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(channel, forKey: .channel)
        try c.encodeIfPresent(channelId, forKey: .channelId)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(views, forKey: .views)
        try c.encodeIfPresent(thumbnail?.absoluteString, forKey: .thumbnail)
        try c.encodeIfPresent(count, forKey: .count)
    }

    var hasValidID: Bool {
        switch kind {
        case .video: VideoID.isValid(id)
        case .channel: ChannelID.isValid(id)
        case .playlist: PlaylistID.isValid(id)
        }
    }
}

/// One page of a listing. `cursor` continues it via `WorkerClient.more`; it is nil once `done`.
public struct ListPage: Sendable, Decodable {
    public let cursor: Int?
    public let title: String?
    public let channelId: String?
    public let channel: String?
    public let entries: [ListedEntry]
    public let done: Bool

    func keepingValidEntries() -> ListPage {
        ListPage(cursor: cursor, title: title, channelId: channelId, channel: channel,
                 entries: entries.filter(\.hasValidID), done: done)
    }
}

/// A playlist of the video's own channel that its watch page recommends: a candidate, not proof of membership.
public struct ChannelPlaylist: Sendable, Equatable, Decodable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
