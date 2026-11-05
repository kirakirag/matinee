import Foundation
@testable import MatineeKit
import Testing

private let sample = """
[{"header":"YouTube","title":"Watched Stanford CS336 Lecture 3","titleUrl":"https://www.youtube.com/watch?v\\u003dlVynu4bo1rY",
  "subtitles":[{"name":"Stanford Online","url":"https://www.youtube.com/channel/UCBa5G_ESCn8Yd4vw5U-gIcg"}],
  "time":"2026-11-01T12:34:56.789Z","products":["YouTube"],"activityControls":["YouTube watch history"]},
 {"header":"YouTube","title":"Watched Some ad","titleUrl":"https://www.youtube.com/watch?v\\u003daaaaaaaaaaa",
  "time":"2026-11-01T12:30:00Z","products":["YouTube"],"details":[{"name":"From Google Ads"}]},
 {"header":"YouTube","title":"Watched a video that has been removed","time":"2026-10-30T10:00:00Z","products":["YouTube"]},
 {"header":"YouTube Music","title":"Watched A song","titleUrl":"https://music.youtube.com/watch?v\\u003dbbbbbbbbbbb",
  "time":"2026-10-29T10:00:00Z","products":["YouTube"]},
 {"header":"YouTube","title":"Watched Lecture 3 again","titleUrl":"https://www.youtube.com/watch?v\\u003dlVynu4bo1rY",
  "time":"2026-10-20T08:00:00Z","products":["YouTube"]},
 {"header":"YouTube","title":"Watched No channel","titleUrl":"https://www.youtube.com/watch?v\\u003dddddddddddd",
  "time":"2026-10-18T08:00:00.5Z","products":["YouTube"]}]
"""

@Test func takeoutHistoryKeepsYouTubeWatchesNewestPerVideo() throws {
    let watches = try TakeoutHistory.parse(Data(sample.utf8))
    #expect(watches.map(\.videoId) == ["lVynu4bo1rY", "ddddddddddd"], "no ads, removed videos or Music; one per video")
    let first = watches[0]
    #expect(first.title == "Stanford CS336 Lecture 3" && first.channelName == "Stanford Online")
    #expect(first.channelId == "UCBa5G_ESCn8Yd4vw5U-gIcg")
    #expect(first.watchedAt == ISO8601DateFormatter().date(from: "2026-11-01T12:34:56Z")!.addingTimeInterval(0.789))
    #expect(watches[1].channelId == nil && watches[1].channelName == "")
}

@Test func takeoutHistoryRejectsOtherFiles() {
    #expect(throws: TakeoutHistory.NotTakeout.self) { try TakeoutHistory.parse(Data(#"{"a":1}"#.utf8)) }
    #expect(throws: TakeoutHistory.NotTakeout.self) { try TakeoutHistory.parse(Data("<html></html>".utf8)) }
}

@Test func importedWatchesAreStoredApartFromHistory() throws {
    let s = try Store.inMemory()
    let w = try TakeoutHistory.parse(Data(sample.utf8))
    #expect(try s.saveImportedWatches(w) == 2)
    #expect(try s.saveImportedWatches(w) == 0, "importing the same file again adds nothing")
    #expect(try s.importedWatches(limit: 10).map(\.videoId) == ["lVynu4bo1rY", "ddddddddddd"], "newest first")
    #expect(try s.history().isEmpty, "History stays as it was")
}
