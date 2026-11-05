import Foundation
import Testing
import MatineeKit

private func page(_ ids: [String], cursor: Int?, done: Bool = false) throws -> ListPage {
    let entries = ids.map { #"{"kind":"video","id":"\#($0)","title":"t"}"# }.joined(separator: ",")
    let cursorJSON = cursor.map(String.init) ?? "null"
    let json = #"{"cursor":\#(cursorJSON),"entries":[\#(entries)],"done":\#(done)}"#
    return try JSONDecoder().decode(ListPage.self, from: Data(json.utf8))
}

@Test func firstPageReplaces() throws {
    var pager = SearchPager()
    let first = pager.start()
    let a = pager.received(try page(["aaaaaaaaaaa", "bbbbbbbbbbb"], cursor: 1), token: first)
    #expect(a?.map(\.id) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
    // A new search starts over: entries seen in the previous search come back.
    let second = pager.start()
    let b = pager.received(try page(["aaaaaaaaaaa"], cursor: 1), token: second)
    #expect(b?.map(\.id) == ["aaaaaaaaaaa"])
}

@Test func staleMorePageIsDropped() throws {
    var pager = SearchPager()
    let first = pager.start()
    _ = pager.start()
    let staleFirst = pager.received(try page(["aaaaaaaaaaa"], cursor: 1), token: first)
    #expect(staleFirst == nil)
    // A `more` page from a superseded search is dropped too.
    let token = pager.start()
    _ = pager.received(try page(["aaaaaaaaaaa"], cursor: 1), token: token)
    let next = pager.loadMore()
    let more = try #require(next)
    _ = pager.start()
    let staleMore = pager.received(try page(["bbbbbbbbbbb"], cursor: nil), token: more)
    #expect(staleMore == nil)
}

@Test func cannotLoadMoreWhileInFlightOrDone() throws {
    var pager = SearchPager()
    #expect(!pager.canLoadMore)
    let token = pager.start()
    #expect(!pager.canLoadMore)
    _ = pager.received(try page(["aaaaaaaaaaa"], cursor: 1), token: token)
    #expect(pager.canLoadMore)
    let next = pager.loadMore()
    let more = try #require(next)
    #expect(!pager.canLoadMore)
    let again = pager.loadMore()
    #expect(again == nil)
    _ = pager.received(try page(["bbbbbbbbbbb"], cursor: nil, done: true), token: more)
    #expect(!pager.canLoadMore)
}

@Test func cursorFromFirstPage() throws {
    var pager = SearchPager()
    let token = pager.start()
    _ = pager.received(try page(["aaaaaaaaaaa"], cursor: 4), token: token)
    #expect(pager.cursor == 4)
}

@Test func duplicateIdsAcrossPagesAreDropped() throws {
    var pager = SearchPager()
    let token = pager.start()
    _ = pager.received(try page(["aaaaaaaaaaa", "bbbbbbbbbbb"], cursor: 1), token: token)
    let next = pager.loadMore()
    let more = try #require(next)
    let added = pager.received(try page(["bbbbbbbbbbb", "ccccccccccc", "ccccccccccc"], cursor: nil), token: more)
    #expect(added?.map(\.id) == ["ccccccccccc"])
}

@Test func failedRequestAllowsRetry() throws {
    var pager = SearchPager()
    let token = pager.start()
    _ = pager.received(try page(["aaaaaaaaaaa"], cursor: 1), token: token)
    let next = pager.loadMore()
    let more = try #require(next)
    let current = pager.failed(token: more)
    #expect(current)
    #expect(pager.canLoadMore)
    _ = pager.start()
    let stale = pager.failed(token: more)
    #expect(!stale)
}

@Test func moreReplyWithoutCursorKeepsTheListingCursor() throws {
    var pager = SearchPager()
    let token = pager.start()
    _ = pager.received(try page(["aaaaaaaaaaa"], cursor: 7), token: token)
    // The worker's `more` replies carry only entries and done.
    for id in ["bbbbbbbbbbb", "ccccccccccc"] {
        let next = pager.loadMore()
        let more = try #require(next)
        _ = pager.received(try page([id], cursor: nil), token: more)
        #expect(pager.canLoadMore)
        #expect(pager.cursor == 7)
    }
    let next = pager.loadMore()
    let last = try #require(next)
    _ = pager.received(try page([], cursor: nil, done: true), token: last)
    #expect(!pager.canLoadMore)
}

@Test func prefetchKeepsTwoPagesAhead() throws {
    var pager = SearchPager()
    let token = pager.start()
    _ = pager.received(try page(["aaaaaaaaaaa"], cursor: 1), token: token)
    // 15 rows, row 7 shown: fewer than 40 below it, so fetch.
    #expect(pager.wantsMore(rows: 15, lastShown: 7))
    // 55 rows, row 10 shown: 44 below, enough.
    #expect(!pager.wantsMore(rows: 55, lastShown: 10))
    #expect(pager.wantsMore(rows: 55, lastShown: 20))
    // Not while a page is in flight.
    _ = pager.loadMore()
    #expect(!pager.wantsMore(rows: 15, lastShown: 7))
}
