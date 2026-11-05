import Testing
@testable import MatineeKit

struct SearchFilterTests {
    @Test func defaultsHaveNoSp() { #expect(SearchFilter().sp == nil) }

    @Test func knownValues() {
        #expect(SearchFilter(type: .channel).sp == "EgIQAg==")
        #expect(SearchFilter(type: .video).sp == "EgIQAQ==")
        #expect(SearchFilter(type: .playlist).sp == "EgIQAw==")
        #expect(SearchFilter(type: .movie).sp == "EgIQBA==")
        #expect(SearchFilter(sort: .uploadDate).sp == "CAI=")
        #expect(SearchFilter(sort: .rating).sp == "CAE=")
        #expect(SearchFilter(date: .today).sp == "EgIIAg==")
        #expect(SearchFilter(duration: .short).sp == "EgIYAQ==")
        #expect(SearchFilter(duration: .long).sp == "EgIYAg==")
        #expect(SearchFilter(duration: .medium).sp == "EgIYAw==")
    }

    @Test func combined() {
        #expect(SearchFilter(sort: .viewCount, type: .video, duration: .long).sp == "CAMSBBABGAI=")
    }
}

@Test func filtersCycleBothWaysAndWrap() {
    let last = SearchFilter.Sort.allCases.last!, first = SearchFilter.Sort.allCases.first!
    #expect(first.cycled(by: 1) == SearchFilter.Sort.allCases[1])
    #expect(last.cycled(by: 1) == first)
    #expect(first.cycled(by: -1) == last)
}
