import Foundation

/// Fetches the first bytes of a prefetched video's streams, so pressing Return starts playback from memory instead of
/// waiting for a connection and the first chunk. `fetch` is a RangedStream.Fetch that answers a stream's first
/// request from those bytes and sends everything else to the network. Only googlevideo media is warmed (what
/// RangedStream plays), and only the last `capacity` videos are kept.
public final class StreamWarmer: @unchecked Sendable {
    private let upstream: RangedStream.Fetch
    private let size: Int64
    private let capacity: Int
    private let lock = NSLock()
    /// Guarded by `lock`: the first bytes per stream URL, and which videos (their stream URLs) were warmed, oldest first.
    private var bytes: [String: Data] = [:]
    private var videos: [[String]] = []

    public init(fetch: @escaping RangedStream.Fetch = RangedStream.urlSession, size: Int64 = 1 << 20, capacity: Int = 2) {
        upstream = fetch
        self.size = size
        self.capacity = max(capacity, 1)
    }

    /// Videos currently held.
    var warmCount: Int { lock.withLock { videos.count } }

    public func warm(_ r: Resolved) async {
        guard MPVLoadPlan.usesRangedStream(r) else { return }
        let urls = [r.videoURL] + (r.audioURL.map { [$0] } ?? [])
        let keys = urls.map(\.absoluteString)
        guard lock.withLock({ !videos.contains(keys) }) else { return }
        await withTaskGroup(of: (String, Data?).self) { group in
            for url in urls {
                group.addTask { (url.absoluteString, try? await self.firstBytes(url, headers: r.headers)) }
            }
            for await (key, data) in group {
                guard let data, !data.isEmpty else { continue }
                lock.withLock { bytes[key] = data }
            }
        }
        lock.withLock {
            videos.append(keys)
            while videos.count > capacity {
                for key in videos.removeFirst() { bytes[key] = nil }
            }
        }
    }

    private func firstBytes(_ url: URL, headers: [String: String]) async throws -> Data {
        // Capped at the file's `clen`, as RangedStream caps its own first request.
        let clen = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "clen" }?.value.flatMap { Int64($0) }
        let request = RangedStream.rangeRequest(url, headers: headers, from: 0, to: min(size, clen ?? size) - 1)
        let (response, body) = try await upstream(request)
        guard (200..<300).contains(response.statusCode) else { throw RangedStream.BadStatus(code: response.statusCode) }
        var data = Data()
        for try await piece in body {
            data.append(piece)
            if data.count > size { throw RangedStream.RangeIgnored() }
        }
        return data
    }

    public var fetch: RangedStream.Fetch {
        { [self] request in
            if let hit = warmAnswer(for: request) { return hit }
            return try await upstream(request)
        }
    }

    /// The held bytes for a `range=0-end` request on a warmed URL that they fully cover.
    private func warmAnswer(for request: URLRequest) -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>)? {
        guard let url = request.url?.absoluteString, let marker = url.range(of: "range=0-", options: .backwards),
              let end = Int(url[marker.upperBound...]) else { return nil }
        let base = String(url[..<url.index(before: marker.lowerBound)])   // without the "&" or "?" before range=
        guard let held = lock.withLock({ bytes[base] }), held.count >= end + 1 || isWhole(held, base) else { return nil }
        let body = held.prefix(end + 1)
        guard let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil,
                                             headerFields: ["Content-Length": "\(body.count)"]) else { return nil }
        return (response, AsyncThrowingStream { $0.yield(Data(body)); $0.finish() })
    }

    /// The held bytes are the whole file (its `clen` is no bigger), so any range from 0 is covered.
    private func isWhole(_ held: Data, _ url: String) -> Bool {
        guard let clen = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "clen" })?.value.flatMap(Int.init)
        else { return false }
        return held.count >= clen
    }
}
