import Foundation

/// A video from a subscribed channel's RSS feed, cached in the store.
public struct FeedVideo: Sendable, Equatable, Identifiable {
    public var id: String { videoId }
    public let videoId: String
    public var channelId: String
    /// From the RSS author name; `Store.feed()` prefers the subscription's name.
    public var channelName: String
    public var title: String
    public var publishedAt: Date
    public var views: Int?

    public init(videoId: String, channelId: String, channelName: String, title: String, publishedAt: Date, views: Int?) {
        self.videoId = videoId
        self.channelId = channelId
        self.channelName = channelName
        self.title = title
        self.publishedAt = publishedAt
        self.views = views
    }
}

/// A cached DeArrow result; nil fields mean DeArrow has no replacement.
public struct CachedBranding: Sendable, Equatable {
    public var title: String?
    public var thumbnailTime: Double?
    public var fetchedAt: Date

    public init(title: String?, thumbnailTime: Double?, fetchedAt: Date) {
        self.title = title
        self.thumbnailTime = thumbnailTime
        self.fetchedAt = fetchedAt
    }
}
