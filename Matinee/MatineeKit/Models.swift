import Foundation

public struct Channel: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var thumbnailURL: URL?
    public var subscribedAt: Date

    public init(id: String, name: String, thumbnailURL: URL?, subscribedAt: Date) {
        self.id = id
        self.name = name
        self.thumbnailURL = thumbnailURL
        self.subscribedAt = subscribedAt
    }
}

public struct HistoryEntry: Sendable, Equatable, Identifiable {
    public let videoId: String
    public var title: String
    public var channelId: String?
    public var channelName: String
    public var lengthSeconds: Int?
    public var publishedAt: Date?
    public var watchedAt: Date
    public var positionSeconds: Double
    public var id: String { videoId }

    public init(videoId: String, title: String, channelId: String?, channelName: String, lengthSeconds: Int?,
                publishedAt: Date?, watchedAt: Date, positionSeconds: Double) {
        self.videoId = videoId
        self.title = title
        self.channelId = channelId
        self.channelName = channelName
        self.lengthSeconds = lengthSeconds
        self.publishedAt = publishedAt
        self.watchedAt = watchedAt
        self.positionSeconds = positionSeconds
    }
}

public struct RecentPlaylist: Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var channelName: String?
    public var videoCount: Int?
    public var openedAt: Date

    public init(id: String, title: String, channelName: String?, videoCount: Int?, openedAt: Date) {
        self.id = id
        self.title = title
        self.channelName = channelName
        self.videoCount = videoCount
        self.openedAt = openedAt
    }
}
