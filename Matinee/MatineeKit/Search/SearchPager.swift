/// Paging state for one search at a time: drops pages from superseded searches and entries already shown.
public struct SearchPager: Sendable {
    private var token = 0
    private var inFlight = false
    private var done = true
    private var seen: Set<String> = []
    public private(set) var cursor: Int?

    public init() {}

    public var canLoadMore: Bool { !inFlight && !done && cursor != nil }

    /// Rows kept loaded below the last row shown: two pages, so scrolling rarely reaches the end.
    public static let prefetchRows = 40

    /// Whether to fetch the next page now, given how many rows there are and the last one shown.
    public func wantsMore(rows: Int, lastShown: Int) -> Bool {
        canLoadMore && rows - 1 - lastShown < Self.prefetchRows
    }

    /// Begins a new search. Pages for earlier tokens are dropped from now on.
    public mutating func start() -> Int {
        token += 1
        inFlight = true
        done = false
        cursor = nil
        seen = []
        return token
    }

    /// Begins loading the next page of the current search; nil when `canLoadMore` is false.
    public mutating func loadMore() -> Int? {
        guard canLoadMore else { return nil }
        inFlight = true
        return token
    }

    /// The entries to append, without IDs already shown; nil when the token is stale.
    public mutating func received(_ page: ListPage, token: Int) -> [ListedEntry]? {
        guard token == self.token else { return nil }
        inFlight = false
        // The cursor belongs to the whole listing: `more` replies don't repeat it.
        if let c = page.cursor { cursor = c }
        done = page.done
        if done { cursor = nil }
        return page.entries.filter { seen.insert($0.id).inserted }
    }

    /// Ends a failed request so the page can be retried; false when the token is stale.
    public mutating func failed(token: Int) -> Bool {
        guard token == self.token else { return false }
        inFlight = false
        return true
    }
}
