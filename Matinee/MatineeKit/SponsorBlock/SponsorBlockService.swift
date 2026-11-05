import Foundation

/// Fetches a video's SponsorBlock segments, falling back to the stored ones when offline, slow or failing.
public actor SponsorBlockService {
    public typealias Fetch = DeArrowService.Fetch

    private struct BadStatus: Error {}

    private let store: Store
    private let fetch: Fetch
    private let timeout: Duration

    public init(store: Store, fetch: @escaping Fetch = SponsorBlockService.urlSession, timeout: Duration = .seconds(5)) {
        self.store = store
        self.fetch = fetch
        self.timeout = timeout
    }

    /// The server answers 404 when no video with the prefix has segments: that is an empty answer, not a failure.
    public static let urlSession: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await PrivateHTTP.session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return data
        case 404: return Data("[]".utf8)
        default: throw BadStatus()
        }
    }

    /// All categories (filtering happens at use). Never throws, and gives up on the network after `timeout`.
    public func segments(for videoId: String) async -> [SponsorSegment] {
        guard VideoID.isValid(videoId) else { return [] }
        let fetch = fetch, timeout = timeout
        let url = SponsorBlock.skipSegmentsURL(prefix: DeArrow.hashPrefix(videoId))
        let request = Task { try await fetch(url) }
        let timer = Task {
            try await Task.sleep(for: timeout)
            request.cancel()
        }
        let data = try? await request.value
        timer.cancel()
        if let data, let parsed = try? SponsorBlock.parse(data, videoId: videoId) {
            try? store.saveSegments(parsed, videoId: videoId, fetchedAt: .now)
            return parsed
        }
        return (try? store.segments(videoId: videoId)) ?? []
    }
}
