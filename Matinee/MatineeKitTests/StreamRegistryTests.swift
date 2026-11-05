import Foundation
import Testing
@testable import MatineeKit

private func resolved(audio: String?) -> Resolved {
    var json: [String: Any] = ["video_url": "https://example.com/v?clen=5", "height": 1080, "expire": 100_000, "headers": [:] as [String: String]]
    if let audio { json["audio_url"] = audio }
    return try! JSONDecoder().decode(Resolved.self, from: JSONSerialization.data(withJSONObject: json))
}

struct StreamRegistryTests {
    @Test func opensOnlyTheCurrentLoad() {
        let registry = StreamRegistry()
        let first = registry.register(resolved(audio: "https://example.com/a?clen=7"))
        #expect(registry.open(first.video)?.size() == 5)
        #expect(registry.open(first.audio!)?.size() == 7)
        let second = registry.register(resolved(audio: nil))
        #expect(second.audio == nil)
        #expect(registry.open(first.video) == nil)
        #expect(registry.open(second.video) != nil)
        #expect(registry.open("matinee-yt://a/" + second.video.split(separator: "/").last!) == nil)
    }

    @Test func clearForgetsTheLoadAndItsFailure() {
        let registry = StreamRegistry()
        let first = registry.register(resolved(audio: nil))
        registry.clear()   // a local file is playing: nothing of the old load may open or count as its failure
        #expect(registry.open(first.video) == nil)
        #expect(registry.failure == nil)
    }

    /// mpv may still read the previous video's stream after the next load registered; its failure isn't the new one's.
    @Test func failureOfAnEarlierLoadIsIgnored() async {
        let registry = StreamRegistry(fetch: { _ in throw RangedStream.BadStatus(code: 403) })
        let old = registry.open(registry.register(resolved(audio: nil)).video)!
        let current = registry.open(registry.register(resolved(audio: nil)).video)!
        #expect(await readByte(old) == -1)
        #expect(registry.failure == nil)
        #expect(await readByte(current) == -1)
        #expect(registry.failure == "HTTP error 403")
    }
}

/// A blocking read, off the cooperative pool as on mpv's threads.
private func readByte(_ s: RangedStream) async -> Int {
    await withCheckedContinuation { c in
        DispatchQueue.global().async {
            var byte: UInt8 = 0
            c.resume(returning: s.read(into: &byte, count: 1))
        }
    }
}
