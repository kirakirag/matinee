import Foundation

/// The ⌘K list filter: every word of the query must appear in the title or channel name,
/// ignoring case and diacritics.
public enum HistoryFilter {
    public static func apply(_ query: String, to entries: [HistoryEntry]) -> [HistoryEntry] {
        let q = Query(query)
        guard !q.isEmpty else { return entries }
        return entries.filter { q.matches($0.title, $0.channelName) }
    }

    /// True when every word of `q` appears in at least one of `fields`; an empty query matches everything.
    public static func matches(_ q: String, _ fields: String...) -> Bool {
        Query(q).matches(fields)
    }

    /// A query split into words once, for filtering a whole list per keystroke rather than re-splitting it per row.
    public struct Query: Sendable {
        let words: [String]

        public init(_ q: String) {
            words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        }

        public var isEmpty: Bool { words.isEmpty }

        /// True when every word appears in at least one of `fields`; an empty query matches everything.
        public func matches(_ fields: String...) -> Bool { matches(fields) }

        func matches(_ fields: [String]) -> Bool {
            guard !words.isEmpty else { return true }
            let haystack = fields.joined(separator: "\n")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
