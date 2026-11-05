import Foundation
import Testing
@testable import MatineeKit

struct PlaybackSessionTests {
    @Test func laterOpenWinsOverSlowerEarlierResolve() {
        var s = PlaybackSession()
        let a = s.begin()
        let b = s.begin()
        #expect(!s.isCurrent(a) && s.isCurrent(b))
    }

    @Test func startDelayRoundsUp() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(StartDelay.seconds(until: now.addingTimeInterval(4.2), now: now) == 5)
    }

    @Test func startDelayNilWhenPastOrAbsent() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(StartDelay.seconds(until: now.addingTimeInterval(-3), now: now) == nil)
        #expect(StartDelay.seconds(until: now, now: now) == nil)
        #expect(StartDelay.seconds(until: nil, now: now) == nil)
    }
}
