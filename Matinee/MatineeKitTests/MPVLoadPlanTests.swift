import Foundation
import Testing
@testable import MatineeKit

private func resolved(video: String = "https://example.com/v.mp4", audio: String? = nil, headers: [String: String] = [:]) -> Resolved {
    var json: [String: Any] = ["video_url": video, "height": 1080, "expire": 100_000, "headers": headers]
    if let audio { json["audio_url"] = audio }
    return try! JSONDecoder().decode(Resolved.self, from: JSONSerialization.data(withJSONObject: json))
}

struct MPVLoadPlanTests {
    @Test func onlyHttpsStreamsAreAcceptable() {
        #expect(MPVLoadPlan.isAcceptable(resolved(audio: "https://a.example.com/a")))
        #expect(MPVLoadPlan.isAcceptable(resolved()))
        #expect(!MPVLoadPlan.isAcceptable(resolved(audio: "http://a.example.com/a")))
        #expect(!MPVLoadPlan.isAcceptable(resolved(audio: "file:///etc/passwd")))
        let json = #"{"video_url": "ftp://example.com/v", "height": 1, "expire": 1, "headers": {}}"#
        #expect(!MPVLoadPlan.isAcceptable(try! JSONDecoder().decode(Resolved.self, from: Data(json.utf8))))
    }

    @Test func headersSplitUserAgent() {
        let plan = MPVLoadPlan(resolved(headers: ["X-B": "2", "User-Agent": "UA/1", "Accept": "*/*"]), start: 0)
        #expect(plan.userAgent == "UA/1")
        #expect(plan.headerFields == ["Accept: */*", "X-B: 2"])
    }

    @Test func audioFileIsLengthQuoted() {
        let url = "https://a.example.com/audio?x=1,2"
        let plan = MPVLoadPlan(resolved(audio: url), start: 0)
        #expect(plan.loadfile == ["loadfile", "https://example.com/v.mp4", "replace", "-1", "audio-file=%\(url.utf8.count)%\(url)"])
    }

    @Test func startOmittedAtZero() {
        #expect(MPVLoadPlan(resolved(), start: 0).loadfile.count == 4)
    }

    @Test func startFormatted() {
        #expect(MPVLoadPlan(resolved(), start: 73.5).loadfile.last == "start=73.5")
    }

    @Test func noOptionsWithoutAudioOrStart() {
        #expect(MPVLoadPlan(resolved(), start: 0).loadfile == ["loadfile", "https://example.com/v.mp4", "replace", "-1"])
    }

    @Test func audioAndStartAreCommaJoined() {
        let plan = MPVLoadPlan(resolved(audio: "https://a.example.com/a"), start: 12)
        #expect(plan.loadfile.last == "audio-file=%23%https://a.example.com/a,start=12.0")
    }

    @Test func videoplaybackGoesThroughRangedStream() {
        let r = resolved(video: "https://rr1---sn-x.googlevideo.com/videoplayback?id=1", audio: "https://rr2---sn-x.googlevideo.com/videoplayback?id=2")
        #expect(MPVLoadPlan.usesRangedStream(r))
        #expect(MPVLoadPlan.usesRangedStream(resolved(video: "https://rr1---sn-x.googlevideo.com/videoplayback?id=1")))
        let plan = MPVLoadPlan(r, start: 0, streams: (video: "matinee-yt://v/t", audio: "matinee-yt://a/t"))
        #expect(plan.loadfile == ["loadfile", "matinee-yt://v/t", "replace", "-1", "audio-file=%16%matinee-yt://a/t"])
    }

    /// Live streams are HLS manifests: mpv must open them itself so it can refresh the playlist.
    @Test func otherURLsAreLoadedDirectly() {
        let manifest = "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/1/index.m3u8"
        let media = "https://rr1---sn-x.googlevideo.com/videoplayback?id=1"
        #expect(!MPVLoadPlan.usesRangedStream(resolved(video: manifest)))
        #expect(!MPVLoadPlan.usesRangedStream(resolved(video: "https://example.com/videoplayback?id=1")))
        #expect(!MPVLoadPlan.usesRangedStream(resolved(video: "https://rr1---sn-x.googlevideo.com/videoplayback")))
        #expect(!MPVLoadPlan.usesRangedStream(resolved(video: media, audio: manifest)))
        #expect(MPVLoadPlan(resolved(video: manifest), start: 0).loadfile == ["loadfile", manifest, "replace", "-1"])
    }
}
