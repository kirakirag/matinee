import Foundation
@testable import MatineeKit
import Testing

/// A video entry as the worker's related op sends it.
private func video(_ id: String, channel: String = "UCaaaaaaaaaaaaaaaaaaaaaa") -> ListedEntry {
    let json = """
        {"kind":"video","id":"\(id)","title":"T \(id)","channel":"C","channelId":"\(channel)","duration":60,"views":5}
        """
    return try! JSONDecoder().decode(ListedEntry.self, from: Data(json.utf8))
}

private func vid(_ n: Int) -> String { String(format: "v%010d", n) }

@Test func relatedListsAreCachedAndExpire() async throws {
    let store = try Store.inMemory()
    let calls = Counter()
    let now = Clock(Date(timeIntervalSince1970: 1_000_000))
    let service = RelatedService(store: store, fetch: { id in
        calls.bump()
        return [video(vid(1)), video(vid(2))]
    }, ttl: 3600, now: { now.value })
    #expect(try await service.related(vid(0)).map(\.id) == [vid(1), vid(2)])
    #expect(try await service.related(vid(0)).map(\.id) == [vid(1), vid(2)])
    #expect(calls.value == 1, "the second read is the cache")
    now.value += 3601
    _ = try await service.related(vid(0))
    #expect(calls.value == 2, "an expired list is fetched again")
}

@Test func aFailedFetchFallsBackToAStaleList() async throws {
    let store = try Store.inMemory()
    try store.saveRelated([video(vid(1))], videoId: vid(0), at: Date(timeIntervalSince1970: 0))
    let service = RelatedService(store: store, fetch: { _ in throw URLError(.notConnectedToInternet) }, ttl: 60,
                                 now: { Date(timeIntervalSince1970: 1_000_000) })
    #expect(try await service.related(vid(0)).map(\.id) == [vid(1)])
    let empty = RelatedService(store: try Store.inMemory(), fetch: { _ in throw URLError(.notConnectedToInternet) })
    await #expect(throws: URLError.self) { try await empty.related(vid(0)) }
}

@Test func rankingFavoursVideosSuggestedNextToSeveralRecentWatches() {
    // Seeds most recent first, weighted 1 and 0.85; a list's nth suggestion counts 1/(1+n).
    // vid(12): 1. vid(10), second next to both: 0.5 + 0.425 = 0.925. vid(11), first next to the older one: 0.85.
    let ranked = Recommender.rank(seeds: [
        (vid(0), [video(vid(12)), video(vid(10))]),
        (vid(1), [video(vid(11)), video(vid(10))]),
    ], watched: [], subscribed: [])
    #expect(ranked.map(\.id) == [vid(12), vid(10), vid(11)])
}

@Test func rankingDropsWatchedVideosAndTheSeedsThemselves() {
    let ranked = Recommender.rank(seeds: [(vid(0), [video(vid(1)), video(vid(2)), video(vid(3))]),
                                          (vid(1), [video(vid(0))])],
                                  watched: [vid(2)], subscribed: [])
    #expect(ranked.map(\.id) == [vid(3)])
}

@Test func rankingLowersSubscribedChannelsAndSpreadsChannels() {
    let sub = "UCsssssssssssssssssssss1", a = "UCaaaaaaaaaaaaaaaaaaaaa1", b = "UCbbbbbbbbbbbbbbbbbbbbb1"
    let subscribed = Recommender.rank(seeds: [(vid(0), [video(vid(1), channel: sub), video(vid(2), channel: a)])],
                                      watched: [], subscribed: [sub])
    #expect(subscribed.map(\.id) == [vid(2), vid(1)], "first but subscribed, 1 × 0.4, falls below second, 1/2: the feed already has those")
    // Four from one channel at the top, then one from another: the other channel isn't buried below all four.
    let spread = Recommender.rank(seeds: [(vid(0), [video(vid(1), channel: a), video(vid(2), channel: a),
                                                    video(vid(3), channel: a), video(vid(4), channel: a),
                                                    video(vid(5), channel: b)])],
                                  watched: [], subscribed: [])
    #expect(spread.firstIndex { $0.id == vid(5) }! < 4)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

@Test func affinityReordersEqualScores() {
    let seeds = [(vid(0), [video(vid(1), channel: "UCaaaaaaaaaaaaaaaaaaaaa1"), video(vid(2), channel: "UCbbbbbbbbbbbbbbbbbbbbb1")])]
    // vid(1) first at 1, vid(2) second at 0.5; liked ×e^1.5 ≈ 4.5, disliked ×e^-1.5 ≈ 0.22.
    let ranked = Recommender.rank(seeds: seeds, watched: [], subscribed: [], affinity: [vid(1): -1.5, vid(2): 1.5])
    #expect(ranked.map(\.id) == [vid(2), vid(1)])
    #expect(Recommender.rank(seeds: seeds, watched: [], subscribed: []).map(\.id) == [vid(1), vid(2)])
}

#if canImport(NaturalLanguage)
@Test(.enabled(if: TitleSimilarity.isAvailable))
func titlesLikeTheHistoryScoreAboveOthers() async {
    let similarity = TitleSimilarity()
    let history = [("h1", "Stanford lecture: language modeling from scratch"), ("h2", "Transformers and LLMs, lecture 3"),
                   ("h3", "Jazz piano improvisation lesson")]
    let candidates = [("c1", "Deep learning lecture: attention and transformers"), ("c2", "Relaxing jazz piano standards"),
                      ("c3", "Celebrity goes completely unfiltered for 8 minutes"),
                      ("c4", "When motorcycle chases get out of control"), ("c5", "Midterm election results explained")]
    let z = await similarity.affinity(history: history, candidates: candidates)
    #expect(z["c1"]! > z["c3"]! && z["c1"]! > z["c4"]! && z["c1"]! > z["c5"]!)
    #expect(z["c2"]! > z["c3"]! && z["c2"]! > z["c5"]!)
    let again = await similarity.affinity(history: history, candidates: candidates)
    #expect(Set(again.keys) == Set(z.keys) && z.allSatisfy { abs($0.value - again[$0.key]!) < 1e-9 }, "vectors are cached by id")
}
#endif

@Test func channelsWatchedBeforeButNotSubscribedRankHigher() {
    let watchedChannel = "UCwwwwwwwwwwwwwwwwwwwww1", other = "UCooooooooooooooooooooo1"
    let seeds = [(vid(0), [video(vid(1), channel: other), video(vid(2), channel: watchedChannel)])]
    // vid(2): 1/2 × (1 + ln(1 + 3)) ≈ 1.19 beats vid(1): 1.
    let ranked = Recommender.rank(seeds: seeds, watched: [], subscribed: [], channelWatches: [watchedChannel: 3])
    #expect(ranked.map(\.id) == [vid(2), vid(1)])
    // Subscribed channels get no boost: the feed has them.
    let subscribed = Recommender.rank(seeds: seeds, watched: [], subscribed: [watchedChannel], channelWatches: [watchedChannel: 3])
    #expect(subscribed.map(\.id) == [vid(1), vid(2)])
}

@Test func dismissalsAreStoredAndUndone() throws {
    let s = try Store.inMemory()
    try s.dismiss(Dismissal(videoId: vid(1), title: "Talk show clip", channelId: "UCkkkkkkkkkkkkkkkkkkkkk1", hidesChannel: false,
                            at: Date(timeIntervalSince1970: 1)))
    try s.dismiss(Dismissal(videoId: vid(2), title: "Another clip", channelId: "UCkkkkkkkkkkkkkkkkkkkkk2", hidesChannel: true,
                            at: Date(timeIntervalSince1970: 2)))
    let all = try s.dismissals()
    #expect(all.map(\.videoId) == [vid(2), vid(1)], "newest first")
    #expect(all[0].hidesChannel && !all[1].hidesChannel)
    try s.undoDismissal(videoId: vid(2))
    #expect(try s.dismissals().map(\.videoId) == [vid(1)])
}

@Test func dismissedVideosAndChannelsNeverRank() {
    let hidden = "UChhhhhhhhhhhhhhhhhhhhh1"
    let ranked = Recommender.rank(seeds: [(vid(0), [video(vid(1)), video(vid(2), channel: hidden), video(vid(3))])],
                                  watched: [], subscribed: [], hiddenVideos: [vid(1)], hiddenChannels: [hidden])
    #expect(ranked.map(\.id) == [vid(3)])
}

#if canImport(NaturalLanguage)
@Test(.enabled(if: TitleSimilarity.isAvailable))
func dismissedTitlesPushSimilarCandidatesDown() async {
    let history = [("h1", "Stanford lecture: language modeling from scratch"), ("h2", "Jazz piano improvisation lesson"),
                   ("h3", "Building a satellite ground station")]
    let candidates = [("c1", "Late night host mocks the president's election loss"), ("c2", "Transformers lecture 4"),
                      ("c3", "Relaxing jazz piano standards"), ("c4", "Comedian roasts senators after the midterms"),
                      ("c5", "DIY radio telescope from old dishes")]
    let without = await TitleSimilarity().affinity(history: history, candidates: candidates)
    let with = await TitleSimilarity().affinity(history: history, candidates: candidates,
                                                disliked: [("d1", "Talk show host jokes about the midterm election results")])
    // The other political comedy clip falls relative to the lecture, and further than it did without the dislike.
    #expect(with["c4"]! - with["c2"]! < without["c4"]! - without["c2"]!)
    #expect(with["c1"]! - with["c2"]! < without["c1"]! - without["c2"]!)
}
#endif

@Test func titleVectorsAreStoredAndOldOnesDropped() throws {
    let s = try Store.inMemory()
    let now = Date(timeIntervalSince1970: 100 * 86400)
    try s.saveTitleVectors([(vid(1), "Latn", [0.5, -1, 2])], at: now.addingTimeInterval(-91 * 86400))
    try s.saveTitleVectors([(vid(2), "Kore", [1, 2, 3])], at: now)
    let got = try s.titleVectors(ids: [vid(1), vid(2), vid(3)])
    #expect(got.keys.sorted() == [vid(2)], "older than 90 days is dropped on save")
    #expect(got[vid(2)]?.script == "Kore" && got[vid(2)]?.vector == [1, 2, 3])
}

@Test func relatedListsStayFreshForTwoWeeks() async throws {
    let store = try Store.inMemory()
    let calls = Counter()
    let now = Clock(Date(timeIntervalSince1970: 10_000_000))
    let service = RelatedService(store: store, fetch: { _ in calls.bump(); return [video(vid(1))] }, now: { now.value })
    _ = try await service.related(vid(0))
    now.value += 13 * 86400
    _ = try await service.related(vid(0))
    #expect(calls.value == 1)
    now.value += 2 * 86400
    _ = try await service.related(vid(0))
    #expect(calls.value == 2)
}

#if canImport(NaturalLanguage)
@Test(.enabled(if: TitleSimilarity.isAvailable))
func titleVectorsAreReadFromTheStoreNextTime() async throws {
    let store = try Store.inMemory()
    let history = [("h1", "Stanford lecture on language models"), ("h2", "Jazz piano lesson")]
    let candidates = [("c1", "Transformers lecture"), ("c2", "Late night talk show")]
    let first = await TitleSimilarity(store: store).affinity(history: history, candidates: candidates)
    #expect(try store.titleVectors(ids: ["h1", "h2", "c1", "c2"]).count == 4)
    let second = await TitleSimilarity(store: store).affinity(history: history, candidates: candidates)
    #expect(first.allSatisfy { abs($0.value - second[$0.key]!) < 1e-6 })
}
#endif

@Test func descriptionsAreStoredAndRead() throws {
    let s = try Store.inMemory()
    try s.saveDescriptions([vid(1): "A lecture on attention.", vid(2): ""], at: Date(timeIntervalSince1970: 1))
    let got = try s.descriptions(ids: [vid(1), vid(2), vid(3)])
    #expect(got == [vid(1): "A lecture on attention.", vid(2): ""], "an empty description is known, so not fetched again")
}

@Test func e5VectorsAreStoredWithWhetherTheyReadADescription() throws {
    let s = try Store.inMemory()
    try s.saveE5Vectors([(vid(1), true, [0.5, -1]), (vid(2), false, [1, 2])], at: Date(timeIntervalSince1970: 1))
    let got = try s.e5Vectors(ids: [vid(1), vid(2), vid(3)])
    #expect(got.count == 2 && got[vid(1)]?.described == true && got[vid(1)]?.vector == [0.5, -1])
    #expect(got[vid(2)]?.described == false)
}

@Test func judgePromptMatchesTheBlindTestPrompt() throws {
    struct Fixture: Decodable {
        struct Recent: Decodable { let title: String; let channel: String; let watched: Double? }
        struct Candidate: Decodable { let title: String; let channel: String; let seconds: Int?; let prompt: String }
        let subscriptions: [String], recent: [Recent], dismissed: [String], profile: String, candidates: [Candidate]
    }
    let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/judge_prompts.json")
    let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    let profile = JudgePrompt.profile(subscriptions: f.subscriptions, recent: f.recent.map { ($0.title, $0.channel, $0.watched) },
                                      dismissed: f.dismissed)
    #expect(profile == f.profile)
    for c in f.candidates {
        #expect(JudgePrompt.prompt(profile: profile, candidate: (c.title, c.channel, c.seconds)) == c.prompt)
    }
    #expect(!JudgePrompt.profile(subscriptions: [], recent: [], dismissed: []).contains("not interested"))
}

@Test func fusionUsesRankAndRelativeLogit() {
    let top = [vid(1), vid(2), vid(3)]
    // ln(1/(1+rank)) = 0, −0.69, −1.10; logits 0, 0, 6 → z −0.71, −0.71, 1.41: the third wins.
    #expect(JudgeFusion.resort(top, logits: [vid(1): 0, vid(2): 0, vid(3): 6]) == [vid(3), vid(1), vid(2)])
    #expect(JudgeFusion.resort(top, logits: [vid(1): 2, vid(2): 2, vid(3): 2]) == top, "equal verdicts keep the order")
    #expect(JudgeFusion.resort(top, logits: [vid(3): 6]) == top, "without a verdict for each, the order stays")
}

@Test func vectorSimilarityRanksByBestMatchesAndSubtractsDislikes() {
    // History near the x axis; c1 is near it, c2 near the y axis, c3 near the disliked z axis.
    let history: [(id: String, vector: [Float])] = [("h1", [1, 0.1, 0]), ("h2", [0.9, 0, 0.1])]
    let candidates: [(id: String, vector: [Float])] = [("c1", [1, 0.05, 0]), ("c2", [0, 1, 0]), ("c3", [0.1, 0, 1])]
    let z = VectorSimilarity.affinity(history: history, candidates: candidates)
    #expect(z["c1"]! > z["c2"]! && z["c1"]! > z["c3"]!)
    #expect(abs(z.values.reduce(0, +)) < 1e-9, "z-scores")
    let disliked = VectorSimilarity.affinity(history: history, candidates: candidates, disliked: [("d1", [0, 0, 1])])
    #expect(disliked["c3"]! - disliked["c2"]! < z["c3"]! - z["c2"]!)
    #expect(VectorSimilarity.affinity(history: [], candidates: candidates).isEmpty)
}

@Test func e5AffinityCanWeighMoreThanTheTitleModel() {
    // vid(1) first at 1, vid(2) third at 1/3 (vid(3) between, at 1/2). z = +1 for vid(2):
    // weight 1.0 gives 1/3 × e ≈ 0.91 < 1; weight 1.5 gives 1/3 × e^1.5 ≈ 1.49 > 1.
    let seeds = [(vid(0), [video(vid(1), channel: "UCaaaaaaaaaaaaaaaaaaaaa1"), video(vid(3), channel: "UCccccccccccccccccccccc1"),
                           video(vid(2), channel: "UCbbbbbbbbbbbbbbbbbbbbb1")])]
    #expect(Recommender.rank(seeds: seeds, watched: [], subscribed: [], affinity: [vid(2): 1]).first?.id == vid(1))
    #expect(Recommender.rank(seeds: seeds, watched: [], subscribed: [], affinity: [vid(2): 1], affinityWeight: 1.5).first?.id == vid(2))
}

@Test func theProfileStampChangesOnlyWithWatchesImportsAndDismissals() throws {
    let s = try Store.inMemory()
    let entry = { (id: String, at: Double) in
        HistoryEntry(videoId: id, title: "T", channelId: nil, channelName: "C", lengthSeconds: 60, publishedAt: nil,
                     watchedAt: Date(timeIntervalSince1970: at), positionSeconds: 1)
    }
    let empty = try s.profileStamp()
    #expect(try s.profileStamp() == empty, "nothing changed")
    try s.upsert([entry(vid(1), 10)])
    let watched = try s.profileStamp()
    #expect(watched != empty)
    try s.upsert([entry(vid(1), 20)])
    #expect(try s.profileStamp() != watched, "watching again moves it")
    let rewatched = try s.profileStamp()
    try s.saveImportedWatches([entry(vid(2), 5)])
    #expect(try s.profileStamp() != rewatched)
    let imported = try s.profileStamp()
    try s.dismiss(Dismissal(videoId: vid(3), title: "X", channelId: nil, hidesChannel: false, at: Date(timeIntervalSince1970: 30)))
    #expect(try s.profileStamp() != imported)
    try s.undoDismissal(videoId: vid(3))
    #expect(try s.profileStamp() == imported, "an undone dismissal is the same profile")
}
