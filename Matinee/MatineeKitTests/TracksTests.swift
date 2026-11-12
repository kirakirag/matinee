import Foundation
import Testing
@testable import MatineeKit

private func sub(_ lang: String, auto: Bool = false) -> SubtitleTrack {
    SubtitleTrack(lang: lang, name: lang, url: URL(string: "https://www.youtube.com/api/timedtext?lang=\(lang)&fmt=json3")!, auto: auto)
}

private func audio(_ lang: String, original: Bool = false) -> AudioTrack {
    AudioTrack(lang: lang, name: lang, url: URL(string: "https://a.example.com/\(lang)")!, original: original)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

struct TracksTests {
    @Test func resolvedDecodesTracksAndSkipsMalformedOnes() throws {
        let json = """
        {"video_url": "https://v.example.com/v", "audio_url": "https://a.example.com/en", "height": 1080, "expire": 1, "headers": {},
         "subtitles": [{"lang": "en", "name": "English", "url": "https://www.youtube.com/api/timedtext?v=x", "auto": false}, {"lang": 3}],
         "audio_tracks": [{"lang": "en", "name": "English original", "url": "https://a.example.com/en", "original": true},
                          {"lang": "fr", "name": "French", "url": "https://a.example.com/fr", "original": false}]}
        """
        let r = try JSONDecoder().decode(Resolved.self, from: Data(json.utf8))
        #expect(r.subtitles.map(\.lang) == ["en"])
        #expect(r.audioTracks.map(\.lang) == ["en", "fr"])
        // A stored result decodes like a fresh one, and one from before tracks existed has none.
        #expect(try JSONDecoder().decode(Resolved.self, from: JSONEncoder().encode(r)) == r)
        let old = #"{"video_url": "https://v.example.com/v", "height": 1, "expire": 1, "headers": {}}"#
        #expect(try JSONDecoder().decode(Resolved.self, from: Data(old.utf8)).subtitles.isEmpty)
    }

    @Test func subtitlePreferenceTakesUploadedBeforeAutoAndExactBeforeVariant() {
        let tracks = [sub("en-GB"), sub("pt-BR"), sub("en", auto: true), sub("de")]
        #expect(TrackChoice.subtitles(tracks, preferred: "en") == sub("en-GB"))
        #expect(TrackChoice.subtitles(tracks + [sub("en")], preferred: "en") == sub("en"))
        #expect(TrackChoice.subtitles(tracks, preferred: "pt") == sub("pt-BR"))
        #expect(TrackChoice.subtitles([sub("en", auto: true)], preferred: "en-US") == sub("en", auto: true))
        #expect(TrackChoice.subtitles(tracks, preferred: "ja") == nil)
        #expect(TrackChoice.subtitles(tracks, preferred: "") == nil)
    }

    @Test func audioPreferenceFallsBackToTheOriginal() {
        let tracks = [audio("en-US", original: true), audio("fr"), audio("es-419")]
        #expect(TrackChoice.audio(tracks, preferred: "fr") == audio("fr"))
        #expect(TrackChoice.audio(tracks, preferred: "es") == audio("es-419"))
        #expect(TrackChoice.audio(tracks, preferred: "ja") == audio("en-US", original: true))
        #expect(TrackChoice.audio(tracks, preferred: "") == audio("en-US", original: true))
        #expect(TrackChoice.audio([], preferred: "fr") == nil)
    }

    @Test func anotherAudioLanguageReplacesOnlyTheAudioStream() throws {
        let json = #"{"video_url": "https://v.example.com/v", "audio_url": "https://a.example.com/en", "height": 1, "expire": 1, "headers": {}}"#
        let r = try JSONDecoder().decode(Resolved.self, from: Data(json.utf8))
        #expect(r.playing(audio("fr")).audioURL == URL(string: "https://a.example.com/fr"))
        #expect(r.playing(audio("fr")).videoURL == r.videoURL)
        #expect(r.playing(audio("en")) == r)
        #expect(r.playing(nil) == r)
        // A single muxed stream has no separate audio to swap.
        var muxed = r
        muxed.audioURL = nil
        #expect(muxed.playing(audio("fr")) == muxed)
    }

    @Test func onlyYouTubesCaptionEndpointIsFetched() {
        #expect(sub("en").isAcceptable)
        for bad in ["http://www.youtube.com/api/timedtext?v=x", "https://evil.example.com/api/timedtext", "https://www.youtube.com/watch?v=x", "file:///etc/passwd"] {
            #expect(!SubtitleTrack(lang: "en", name: "", url: URL(string: bad)!, auto: false).isAcceptable)
        }
    }
}

struct SubtitleCuesTests {
    @Test func uploadedCuesKeepTheirTimesAndLoseStyleDuplicatesAndPadding() {
        let json = """
        {"events": [
          {"tStartMs": 133, "dDurationMs": 1801, "segs": [{"utf8": "\u{200B}", "pPenId": 1}, {"utf8": "\u{200B} \u{200B}- I've \u{200B} \u{200B}", "pPenId": 3}, {"utf8": "\u{200B}\\n\u{200B}"}, {"utf8": " recreated every set "}]},
          {"tStartMs": 133, "dDurationMs": 1801, "segs": [{"utf8": "- I've", "pPenId": 4}, {"utf8": "\\n"}, {"utf8": "recreated every set", "pPenId": 4}]},
          {"tStartMs": 1934, "dDurationMs": 4000, "segs": [{"utf8": "from the show"}]},
          {"tStartMs": 3000, "dDurationMs": 1000, "segs": [{"utf8": "[music]"}]},
          {"tStartMs": 9000, "dDurationMs": 500, "segs": [{"utf8": " \u{200B} "}]}
        ]}
        """
        #expect(SubtitleCues.parse(json3: Data(json.utf8), rollUp: false) == [
            .init(start: 0.133, end: 1.934, text: "- I've\nrecreated every set"),
            .init(start: 1.934, end: 5.934, text: "from the show"),   // overlaps the next cue, as uploaded
            .init(start: 3, end: 4, text: "[music]"),
        ])
    }

    @Test func autoGeneratedLinesDontOverlap() {
        let json = """
        {"events": [
          {"tStartMs": 0, "dDurationMs": 1537559, "id": 1, "wpWinPosId": 1},
          {"tStartMs": 80, "dDurationMs": 4320, "wWinId": 1, "segs": [{"utf8": "i"}, {"utf8": " recreated", "tOffsetMs": 240}]},
          {"tStartMs": 2550, "dDurationMs": 1850, "wWinId": 1, "aAppend": 1, "segs": [{"utf8": "\\n"}]},
          {"tStartMs": 2560, "dDurationMs": 4719, "wWinId": 1, "segs": [{"utf8": "game"}, {"utf8": " in", "tOffsetMs": 319}]}
        ]}
        """
        #expect(SubtitleCues.parse(json3: Data(json.utf8), rollUp: true) == [
            .init(start: 0.08, end: 2.56, text: "i recreated"),
            .init(start: 2.56, end: 7.279, text: "game in"),
        ])
    }

    @Test func anythingElseIsNotCaptions() {
        #expect(SubtitleCues.parse(json3: Data("WEBVTT".utf8), rollUp: false) == nil)
        #expect(SubtitleCues.parse(json3: Data(#"{"error": 1}"#.utf8), rollUp: false) == nil)
    }

    @Test func subRipOutput() {
        let srt = SubtitleCues.srt([.init(start: 0.08, end: 2.56, text: "one\ntwo"), .init(start: 3723.004, end: 3725, text: "three")])
        #expect(srt == "1\n00:00:00,080 --> 00:00:02,560\none\ntwo\n\n2\n01:02:03,004 --> 01:02:05,000\nthree\n\n")
    }
}

struct SubtitleStoreTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appending(path: "subs-\(UUID().uuidString)") }
    private let body = Data(#"{"events": [{"tStartMs": 0, "dDurationMs": 1000, "segs": [{"utf8": "hello"}]}]}"#.utf8)

    @Test func fetchesOnceThenReusesTheFile() async throws {
        let dir = directory(), calls = Counter(), body = body
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SubtitleStore(directory: dir) { _ in calls.bump(); return (body, 200) }
        let file = try await store.file(videoId: "aaaaaaaaaaa", track: sub("en"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "1\n00:00:00,000 --> 00:00:01,000\nhello\n\n")
        #expect(try await store.file(videoId: "aaaaaaaaaaa", track: sub("en")) == file)
        #expect(calls.value == 1)
        // The auto-generated track of the same language is another file.
        #expect(try await store.file(videoId: "aaaaaaaaaaa", track: sub("en", auto: true)) != file)
        #expect(calls.value == 2)
    }

    @Test func aMonthOldFileIsFetchedAgain() async throws {
        let dir = directory(), calls = Counter(), body = body
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await SubtitleStore(directory: dir) { _ in calls.bump(); return (body, 200) }.file(videoId: "aaaaaaaaaaa", track: sub("en"))
        let later = SubtitleStore(directory: dir, fetch: { _ in calls.bump(); return (body, 200) }, now: { Date(timeIntervalSinceNow: 31 * 24 * 3600) })
        _ = try await later.file(videoId: "aaaaaaaaaaa", track: sub("en"))
        #expect(calls.value == 2)
    }

    @Test func failuresAreNamedAndLeaveNoFile() async {
        let dir = directory()
        let track = sub("en")
        await #expect(throws: SubtitleError.throttled) {
            try await SubtitleStore(directory: dir) { _ in (Data(), 429) }.file(videoId: "aaaaaaaaaaa", track: track)
        }
        await #expect(throws: SubtitleError.http(404)) {
            try await SubtitleStore(directory: dir) { _ in (Data(), 404) }.file(videoId: "aaaaaaaaaaa", track: track)
        }
        await #expect(throws: SubtitleError.unreadable) {
            try await SubtitleStore(directory: dir) { _ in (Data("<html>".utf8), 200) }.file(videoId: "aaaaaaaaaaa", track: track)
        }
        await #expect(throws: SubtitleError.notAllowed) {
            try await SubtitleStore(directory: dir) { _ in (Data(), 200) }.file(videoId: "../../etc", track: track)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func aDownloadsTracksAreSavedAndShownWithoutTheNetwork() async throws {
        let cache = directory(), saved = directory(), calls = Counter(), body = body
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: saved); try? FileManager.default.removeItem(at: cache) }
        let fetching = SubtitleStore(directory: cache) { url in
            calls.bump()
            return url.query()?.contains("lang=de") == true ? (Data(), 404) : (body, 200)
        }
        let bad = SubtitleTrack(lang: "fr", name: "fr", url: URL(string: "https://evil.example.com/api/timedtext")!, auto: false)
        let done = await fetching.save(videoId: "aaaaaaaaaaa", tracks: [sub("en"), bad, sub("de"), sub("en", auto: true)],
                                       in: saved, gap: .zero)
        // The unacceptable address isn't asked; the failing track is left out and the rest go on.
        #expect(done == [sub("en"), sub("en", auto: true)])
        #expect(calls.value == 3)
        #expect(SubtitleStore.saved(videoId: "aaaaaaaaaaa", in: saved) == done)
        #expect(SubtitleStore.saved(videoId: "bbbbbbbbbbb", in: saved) == [])

        let offline = SubtitleStore(directory: cache, saved: saved) { _ in throw URLError(.notConnectedToInternet) }
        let file = try await offline.file(videoId: "aaaaaaaaaaa", track: sub("en", auto: true))
        #expect(file.deletingLastPathComponent().standardizedFileURL == saved.standardizedFileURL)
        #expect(file.lastPathComponent == "aaaaaaaaaaa.en.auto.srt")
    }

    @Test func savingStopsAtTheFirstThrottle() async throws {
        let dir = directory(), calls = Counter()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SubtitleStore(directory: dir) { _ in calls.bump(); return (Data(), 429) }
        #expect(await store.save(videoId: "aaaaaaaaaaa", tracks: [sub("en"), sub("de")], in: dir, gap: .zero) == [])
        #expect(calls.value == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [])
    }

    @Test func aSavedTrackWhoseFileIsGoneIsNotListed() async throws {
        let dir = directory(), body = body
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        await SubtitleStore(directory: dir) { _ in (body, 200) }.save(videoId: "aaaaaaaaaaa", tracks: [sub("en"), sub("de")], in: dir, gap: .zero)
        try FileManager.default.removeItem(at: dir.appending(path: "aaaaaaaaaaa.de.srt"))
        #expect(SubtitleStore.saved(videoId: "aaaaaaaaaaa", in: dir) == [sub("en")])
    }

    @Test func mergedKeepsTheResolvesTracksAndAddsSavedOnes() {
        let fresh = SubtitleTrack(lang: "en", name: "English", url: URL(string: "https://www.youtube.com/api/timedtext?new")!, auto: false)
        #expect(TrackChoice.merged([fresh], saved: [sub("en"), sub("en", auto: true)]) == [fresh, sub("en", auto: true)])
        #expect(TrackChoice.merged([], saved: [sub("de")]) == [sub("de")])
    }

    @Test func aDownloadReplyCarriesItsTracks() throws {
        let json = #"""
        {"file": "/m/a.mp4", "bytes": 5, "title": null, "channel_id": "UC", "duration": 3.0,
         "subtitles": [{"lang": "en", "name": "English", "url": "https://www.youtube.com/api/timedtext?lang=en", "auto": false}, {"lang": 3}]}
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let d = try decoder.decode(Downloaded.self, from: Data(json.utf8))
        #expect(d.subtitles.map(\.lang) == ["en"])
        #expect(d.channelId == "UC")
        let old = try decoder.decode(Downloaded.self, from: Data(#"{"file": "/m/a.mp4", "bytes": 5}"#.utf8))
        #expect(old.subtitles == [])
    }
}
