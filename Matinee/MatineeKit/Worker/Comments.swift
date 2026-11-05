import Foundation

/// A top-level YouTube comment, read-only.
public struct VideoComment: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let text: String
    public let author: String
    /// Only a valid channel ID, so it can open the channel.
    public let authorId: String?
    public let likes: Int?
    /// YouTube's relative time ("2 days ago").
    public let time: String?
    public let isUploader: Bool
    /// Hearted by the uploader.
    public let hearted: Bool
    /// YouTube's count of replies, when it gave one.
    public let replyCount: Int?
    /// The replies can be loaded (`WorkerClient.replies`); false for replies themselves.
    public let hasReplies: Bool

    public init(id: String, text: String, author: String, authorId: String?, likes: Int?, time: String?,
                isUploader: Bool, hearted: Bool, replyCount: Int? = nil, hasReplies: Bool = false) {
        self.id = id
        self.text = text
        self.author = author
        self.authorId = authorId
        self.likes = likes
        self.time = time
        self.isUploader = isUploader
        self.hearted = hearted
        self.replyCount = replyCount
        self.hasReplies = hasReplies
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, author, authorId, likes, time, isUploader, hearted, replyCount, hasReplies
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        authorId = try c.decodeIfPresent(String.self, forKey: .authorId).flatMap { ChannelID.isValid($0) ? $0 : nil }
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        isUploader = try c.decodeIfPresent(Bool.self, forKey: .isUploader) ?? false
        hearted = try c.decodeIfPresent(Bool.self, forKey: .hearted) ?? false
        replyCount = try c.decodeIfPresent(Int.self, forKey: .replyCount)
        hasReplies = try c.decodeIfPresent(Bool.self, forKey: .hasReplies) ?? false
    }
}

/// A page of a video's top-level comments, best first. The first page carries YouTube's total count when it gave one,
/// and a cursor for the next pages unless it was the last.
public struct CommentPage: Sendable, Decodable {
    public let comments: [VideoComment]
    public let count: Int?
    public let cursor: Int?
    public let done: Bool
}

/// A comment's next replies, oldest first.
public struct ReplyPage: Sendable, Decodable {
    public let replies: [VideoComment]
    public let done: Bool
}
