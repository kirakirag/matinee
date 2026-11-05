import Testing
@testable import MatineeKit

struct SeekCoalescerTests {
    @Test func firstSeekStartsAtOnce() {
        var c = SeekCoalescer()
        #expect(c.request(by: 5, from: 10, duration: 100, exact: true) == .init(seconds: 15, exact: true))
        #expect(c.isSeeking)
    }

    @Test func seeksDuringFlightOnlyMoveTheTarget() {
        var c = SeekCoalescer()
        _ = c.request(by: 5, from: 10, duration: 100, exact: true)
        #expect(c.request(by: 5, from: 10, duration: 100, exact: true) == nil)
        #expect(c.request(by: 5, from: 10, duration: 100, exact: true) == nil)
        #expect(c.target == 25)
        #expect(c.restarted() == .init(seconds: 25, exact: true))
        #expect(c.restarted() == nil)
        #expect(!c.isSeeking && c.target == nil)
    }

    @Test func absoluteSeekReplacesPendingTarget() {
        var c = SeekCoalescer()
        _ = c.request(by: 5, from: 10, duration: 100, exact: true)
        #expect(c.request(to: 70, duration: 100, exact: false) == nil)
        #expect(c.restarted() == .init(seconds: 70, exact: false))
    }

    @Test func targetIsClampedToTheVideo() {
        var c = SeekCoalescer()
        #expect(c.request(by: -5, from: 2, duration: 100, exact: true)?.seconds == 0)
        _ = c.restarted()
        #expect(c.request(by: 5, from: 98, duration: 100, exact: true)?.seconds == 100)
    }

    @Test func resetDropsEverything() {
        var c = SeekCoalescer()
        _ = c.request(by: 5, from: 10, duration: 100, exact: true)
        _ = c.request(by: 5, from: 10, duration: 100, exact: true)
        c.reset()
        #expect(!c.isSeeking && c.target == nil && c.restarted() == nil)
    }
}
