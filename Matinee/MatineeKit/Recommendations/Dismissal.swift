import Foundation

/// "Not interested" on a For You row: the video never shows again, nor its channel when `hidesChannel`, and its
/// title teaches the title model what isn't wanted (TitleSimilarity's dislikes).
public struct Dismissal: Sendable, Equatable {
    public let videoId: String
    public let title: String
    public let channelId: String?
    public let hidesChannel: Bool
    public let at: Date

    public init(videoId: String, title: String, channelId: String?, hidesChannel: Bool, at: Date) {
        self.videoId = videoId
        self.title = title
        self.channelId = channelId
        self.hidesChannel = hidesChannel
        self.at = at
    }
}
