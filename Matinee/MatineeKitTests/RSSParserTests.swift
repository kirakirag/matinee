import Foundation
import Testing
import MatineeKit

private let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures").appending(path: "feed_channel.xml")

private func parseFixture() throws -> [FeedVideo] { try RSSParser.parse(Data(contentsOf: fixture)) }

private func iso(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }

@Test func parsesEntries() throws {
    let videos = try parseFixture()
    #expect(videos.count == 2)
    let first = try #require(videos.first)
    #expect(first.videoId == "k3Jx9QpLm2A")
    #expect(first.title == "Building a Tiny Compiler in Rust")
    #expect(first.channelId == "UCq2fDk8Tn3ZbWm0yLpXeR7A")
    #expect(first.channelName == "Ferris Lab")
    #expect(first.publishedAt == iso("2026-10-30T15:00:12+00:00"))
    let second = try #require(videos.last)
    #expect(second.views == 1234)
    #expect(second.title.contains("&"))
}

@Test func dropsShorts() throws {
    let ids = try parseFixture().map(\.videoId)
    #expect(!ids.contains("SHORTxxxxx1"))
}

@Test func rejectsEntriesWithInvalidIds() throws {
    let videos = try parseFixture()
    #expect(!videos.contains { $0.videoId == "bad/id" })
    #expect(videos.allSatisfy { VideoID.isValid($0.videoId) && ChannelID.isValid($0.channelId) })
}

@Test func malformedThrows() {
    #expect(throws: RSSParser.Error.malformed) { try RSSParser.parse(Data("<feed><entry>".utf8)) }
}

@Test func emptyFeedIsEmpty() throws {
    let empty = Data(#"<feed xmlns="http://www.w3.org/2005/Atom"></feed>"#.utf8)
    #expect(try RSSParser.parse(empty).isEmpty)
}
