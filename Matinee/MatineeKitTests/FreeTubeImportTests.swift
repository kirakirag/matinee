import Foundation
import Testing
import MatineeKit

private func lines(_ s: String...) -> Data { Data(s.joined(separator: "\n").utf8) }

private let chanA = "UCaaaaaaaaaaaaaaaaaaaaaa"
private let chanB = "UCbbbbbbbbbbbbbbbbbbbbbb"

private func historyLine(_ id: String, _ extra: String = #""lengthSeconds":600,"watchProgress":30"#) -> String {
    #"{"_id":"\#(id)","videoId":"\#(id)","title":"T \#(id)","author":"Auth","authorId":"\#(chanA)","published":1600000000000,"timeWatched":1700000000000,\#(extra)}"#
}

private let profiles = lines(
    #"{"_id":"allChannels","name":"All Channels","subscriptions":[{"id":"\#(chanA)","name":"A","thumbnail":"https://yt3.ggpht.com/a"},{"id":"\#(chanB)","name":"B","thumbnail":"https://yt3.ggpht.com/b"}]}"#,
    #"{"_id":"other","name":"Music","subscriptions":[{"id":"\#(chanA)","name":"A"}]}"#)

@Test func lastStateWins() {
    let (records, bad) = NeDB.load(lines(#"{"_id":"x","v":1}"#, #"{"_id":"x","v":2}"#))
    #expect(bad == 0)
    #expect(records.count == 1)
    #expect(records.first?["v"] as? Int == 2)
}

@Test func deletedIsDropped() {
    let (records, _) = NeDB.load(lines(#"{"_id":"x","v":1}"#, #"{"_id":"y","v":1}"#, #"{"$$deleted":true,"_id":"x"}"#))
    #expect(records.compactMap { $0["_id"] as? String } == ["y"])
}

@Test func readdedKeepsItsFirstPlace() {
    let (records, _) = NeDB.load(lines(#"{"_id":"x","v":1}"#, #"{"_id":"y","v":1}"#, #"{"$$deleted":true,"_id":"x"}"#,
                                       #"{"_id":"z","v":1}"#, #"{"_id":"x","v":2}"#))
    #expect(records.compactMap { $0["_id"] as? String } == ["x", "y", "z"])
    #expect(records.first?["v"] as? Int == 2)
}

@Test func truncatedLastLineIsSkipped() throws {   // Review Focus 3
    let history = lines(historyLine("aaaaaaaaaaa"), historyLine("bbbbbbbbbbb"), #"{"_id":"ccccccccccc","videoId":"ccc"#)
    let s = try Store.inMemory()
    let report = try FreeTubeImport.run(profiles: profiles, history: history, into: s)
    #expect(report.badLines == 1)
    #expect(report.history == 2)
    #expect(try s.history().map(\.videoId).sorted() == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
}

@Test func missingFieldsImportAsNil() throws {   // Review Focus 4
    let history = lines(historyLine("aaaaaaaaaaa", #""watchProgress":30"#),
                        historyLine("bbbbbbbbbbb", #""lengthSeconds":600,"watchProgress":900"#),
                        #"{"_id":"ccccccccccc","videoId":"ccccccccccc","timeWatched":1700000000000}"#)
    let s = try Store.inMemory()
    _ = try FreeTubeImport.run(profiles: profiles, history: history, into: s)
    let byId = Dictionary(uniqueKeysWithValues: try s.history().map { ($0.videoId, $0) })
    #expect(byId["aaaaaaaaaaa"]?.lengthSeconds == nil)
    #expect(byId["aaaaaaaaaaa"]?.positionSeconds == 30)
    #expect(byId["bbbbbbbbbbb"]?.positionSeconds == 600)
    #expect(byId["ccccccccccc"]?.title == "Untitled")
    #expect(byId["ccccccccccc"]?.channelId == nil)
    #expect(byId["ccccccccccc"]?.publishedAt == nil)
}

@Test func invalidVideoIdIsSkipped() throws {
    let history = lines(historyLine("aaaaaaaaaaa"), historyLine("bad id/../x"))
    let s = try Store.inMemory()
    let report = try FreeTubeImport.run(profiles: profiles, history: history, into: s)
    #expect(report.skippedHistory == 1)
    #expect(report.history == 1)
}

@Test func importsProfilesAndHistory() throws {
    let s = try Store.inMemory()
    let report = try FreeTubeImport.run(profiles: profiles, history: lines(historyLine("aaaaaaaaaaa")), into: s)
    #expect(report == ImportReport(channels: 2, history: 1, skippedHistory: 0, badLines: 0))
    let counts = try s.counts()
    #expect(counts.channels == report.channels)
    #expect(counts.history == report.history)
    let a = try s.subscriptions().first
    #expect(a?.id == chanA)
    #expect(a?.thumbnailURL == URL(string: "https://yt3.ggpht.com/a"))
    #expect(try s.history().first?.watchedAt == Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func absurdLengthIsIgnored() throws {   // final review: huge length trapped in Int(), negative skipped the clamp
    let history = lines(historyLine("aaaaaaaaaaa", #""lengthSeconds":1e20,"watchProgress":30"#),
                        historyLine("bbbbbbbbbbb", #""lengthSeconds":-5,"watchProgress":30"#))
    let s = try Store.inMemory()
    _ = try FreeTubeImport.run(profiles: profiles, history: history, into: s)
    let byId = Dictionary(uniqueKeysWithValues: try s.history().map { ($0.videoId, $0) })
    #expect(byId["aaaaaaaaaaa"]?.lengthSeconds == nil)
    #expect(byId["bbbbbbbbbbb"]?.lengthSeconds == nil)
    #expect(byId["bbbbbbbbbbb"]?.positionSeconds == 30)
}
