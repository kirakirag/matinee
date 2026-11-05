import Testing
@testable import MatineeKit

struct PlayQueueTests {
    @Test func startsAtIndex() {
        let q = PlayQueue(["a", "b", "c"], start: 1)
        #expect(q.current == "b")
        #expect(q.position == 1)
        #expect(q.count == 3)
    }

    @Test func nextAndPrevious() {
        var q = PlayQueue(["a", "b", "c"], start: 0)
        #expect(q.next() == "b")
        #expect(q.next() == "c")
        #expect(q.previous() == "b")
        #expect(q.current == "b")
    }

    @Test func nextAtEndIsNil() {
        var q = PlayQueue(["a", "b"], start: 1)
        #expect(q.next() == nil)
        #expect(q.current == "b")
        #expect(q.position == 1)
    }

    @Test func previousAtStartIsNil() {
        var q = PlayQueue(["a", "b"], start: 0)
        #expect(q.previous() == nil)
        #expect(q.current == "a")
        #expect(q.position == 0)
    }

    @Test func appendExtendsPastTheOldEnd() {
        var q = PlayQueue(["a", "b"], start: 1)
        q.append(contentsOf: ["c"])
        #expect(q.count == 3)
        #expect(q.position == 1)
        #expect(q.current == "b")
        #expect(q.next() == "c")
        #expect(q.next() == nil)
    }

    @Test func emptyQueue() {
        var q = PlayQueue<String>([], start: 0)
        #expect(q.current == nil)
        #expect(q.count == 0)
        #expect(q.next() == nil)
        #expect(q.previous() == nil)
    }
}
