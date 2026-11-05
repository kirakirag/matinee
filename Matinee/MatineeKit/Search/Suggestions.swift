import Foundation

/// YouTube search suggestions (the Firefox-format endpoint).
public struct SuggestionService: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    private struct BadResponse: Error {}

    private let fetch: Fetch

    public init(fetch: @escaping Fetch = SuggestionService.urlSession) {
        self.fetch = fetch
    }

    public static let urlSession: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await PrivateHTTP.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BadResponse() }
        return data
    }

    public func suggestions(for query: String) async throws -> [String] {
        guard !query.isEmpty else { return [] }
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search?client=firefox&ds=yt")!
        // URLComponents leaves "+" and "&" alone in a query value, so encode it by hand.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        components.percentEncodedQuery! += "&q=\(encoded)"
        guard let url = components.url else { throw BadResponse() }
        let data = try await fetch(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any], root.count > 1,
              let list = root[1] as? [String] else { throw BadResponse() }
        return Array(list.prefix(10))
    }
}

/// Drops suggestion results that arrive after a newer keystroke or after the query was submitted.
public struct SuggestionGate: Sendable {
    private var latest = 0
    private var submitted = 0

    public init() {}

    public mutating func begin() -> Int {
        latest += 1
        return latest
    }

    public mutating func submit() {
        submitted = latest
    }

    public func accepts(_ token: Int) -> Bool {
        token == latest && token > submitted
    }
}
