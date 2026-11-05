import Foundation
import Testing
@testable import MatineeKit

private let videoURL = "https://r1---sn-x.googlevideo.com/videoplayback?clen=3000000&id=v"
private let audioURL = "https://r1---sn-x.googlevideo.com/videoplayback?clen=400&id=a"

private func resolved(video: String = videoURL, audio: String? = audioURL) -> Resolved {
    var json: [String: Any] = ["video_url": video, "height": 1080, "expire": 2_000_000_000, "headers": ["User-Agent": "UA"]]
    if let audio { json["audio_url"] = audio }
    return try! JSONDecoder().decode(Resolved.self, from: JSONSerialization.data(withJSONObject: json))
}

/// Answers any range with that many bytes, and records every request.
private final class FakeServer: @unchecked Sendable {
    /// Its own object, held strongly by `fetch`: a stream can still fetch its next chunk after a test returns.
    private final class Log: @unchecked Sendable {
        let lock = NSLock()
        var urls: [String] = []
    }
    private let log = Log()
    var requests: [String] { log.lock.withLock { log.urls } }

    lazy var fetch: RangedStream.Fetch = { [log] request in
        let url = request.url!.absoluteString
        log.lock.withLock { log.urls.append(url) }
        let range = url.components(separatedBy: "range=").last!.split(separator: "-").map { Int($0)! }
        let total = Int(URLComponents(string: url)!.queryItems!.first { $0.name == "clen" }!.value!)!
        let count = min(range[1], total - 1) - range[0] + 1
        let body = Data(repeating: UInt8(range[0] % 251), count: count)
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil,
                                       headerFields: ["Content-Length": "\(count)"])!
        return (response, AsyncThrowingStream { $0.yield(body); $0.finish() })
    }
}

@Test func warmFetchesTheFirstBytesOfVideoAndAudio() async {
    let server = FakeServer()
    let warmer = StreamWarmer(fetch: server.fetch, size: 1000)
    await warmer.warm(resolved())
    #expect(server.requests.sorted() == [audioURL + "&range=0-399", videoURL + "&range=0-999"].sorted())
    await warmer.warm(resolved())   // already warm: nothing new
    #expect(server.requests.count == 2)
}

@Test func streamStartsFromWarmBytesWithoutTheNetwork() async {
    let server = FakeServer()
    let warmer = StreamWarmer(fetch: server.fetch, size: 1 << 20)
    await warmer.warm(resolved(audio: nil))
    #expect(server.requests.count == 1)
    let stream = RangedStream(url: URL(string: videoURL)!, headers: [:], fetch: warmer.fetch)
    let first = await read(stream, 16)
    #expect(first == [UInt8](repeating: 0, count: 16))
    // The first chunk came from memory; only what follows it goes to the server.
    #expect(server.requests.dropFirst().allSatisfy { !$0.contains("range=0-") })
    stream.cancel()
}

@Test func otherRangesAndUnwarmedURLsGoToTheNetwork() async throws {
    let server = FakeServer()
    let warmer = StreamWarmer(fetch: server.fetch, size: 1000)
    await warmer.warm(resolved(audio: nil))
    _ = try await warmer.fetch(URLRequest(url: URL(string: videoURL + "&range=1000-1999")!))
    _ = try await warmer.fetch(URLRequest(url: URL(string: videoURL + "&range=0-4999")!))   // more than is warm
    _ = try await warmer.fetch(URLRequest(url: URL(string: audioURL + "&range=0-399")!))
    #expect(server.requests.count == 4)
}

@Test func onlyGooglevideoMediaIsWarmedAndOnlyAFewVideosAreKept() async {
    let server = FakeServer()
    let warmer = StreamWarmer(fetch: server.fetch, size: 100, capacity: 2)
    await warmer.warm(resolved(video: "https://example.com/live.m3u8?clen=500", audio: nil))
    #expect(server.requests.isEmpty)
    for i in 0..<3 {
        await warmer.warm(resolved(video: "https://r1.googlevideo.com/videoplayback?clen=500&id=\(i)", audio: nil))
    }
    #expect(warmer.warmCount == 2)
}

@Test func prefetchReportsItsResultButAnOpenDoesNot() async throws {
    let reported = Reported()
    let resolver = PlaybackResolver(resolve: { id, _, _ in
        try JSONDecoder().decode(Resolved.self, from: Data(#"{"video_url": "https://v/\#(id)", "height": 1080, "expire": 2000000000}"#.utf8))
    }, onPrefetched: { await reported.add($0.videoURL.lastPathComponent) })
    await resolver.prefetch("aaaaaaaaaaa")
    _ = try await resolver.resolve("bbbbbbbbbbb")
    for _ in 0..<50 where await reported.ids.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await reported.ids == ["aaaaaaaaaaa"])
}

private actor Reported {
    var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}

/// A blocking read, off the cooperative pool as on mpv's threads.
private func read(_ s: RangedStream, _ count: Int) async -> [UInt8] {
    await withCheckedContinuation { c in
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 1, count: count)
            let n = buffer.withUnsafeMutableBytes { s.read(into: $0.baseAddress!, count: count) }
            c.resume(returning: Array(buffer.prefix(max(n, 0))))
        }
    }
}
