import Foundation

/// Maps the `matinee-yt://` URLs handed to mpv to the YouTube streams of the current load.
/// Holds only the latest load, so registering a new one forgets the previous one. Thread-safe.
public final class StreamRegistry: @unchecked Sendable {
    public static let scheme = "matinee-yt"

    private let lock = NSLock()
    /// Guarded by `lock`.
    private var token = ""
    private var resolved: Resolved?
    private var lastFailure: String?
    /// Every stream opened, kept until the registry goes: mpv can call a stream's cancel callback right after closing
    /// it, so mpv's own reference can't be the last. A closed stream is cancelled and holds no data.
    private var opened: [RangedStream] = []
    private let fetch: RangedStream.Fetch

    public init() { fetch = RangedStream.urlSession }

    /// `fetch` is what the streams fetch with, e.g. StreamWarmer's, which serves prefetched first bytes.
    public init(fetch: @escaping RangedStream.Fetch) { self.fetch = fetch }

    /// Replaces the previous load; returns the URLs to give mpv instead of the YouTube ones.
    public func register(_ r: Resolved) -> (video: String, audio: String?) {
        let t = UUID().uuidString
        lock.withLock {
            token = t
            resolved = r
            lastFailure = nil
        }
        return ("\(Self.scheme)://v/\(t)", r.audioURL.map { _ in "\(Self.scheme)://a/\(t)" })
    }

    /// Forgets the current load, e.g. when a local file plays instead.
    public func clear() {
        lock.withLock {
            token = UUID().uuidString
            resolved = nil
            lastFailure = nil
        }
    }

    /// A new stream for a URL of the current load; nil for any other URL.
    public func open(_ uri: String) -> RangedStream? {
        lock.withLock { () -> RangedStream? in
            guard let resolved else { return nil }
            let url: URL?
            switch uri {
            case "\(Self.scheme)://v/\(token)": url = resolved.videoURL
            case "\(Self.scheme)://a/\(token)": url = resolved.audioURL
            default: url = nil
            }
            // A stream of an earlier load can still fail after the next load registered (mpv closes it later).
            let load = token
            guard let url else { return nil }
            let stream = RangedStream(url: url, headers: resolved.headers, fetch: fetch, onFailure: { [weak self] in self?.failed($0, load: load) })
            opened.append(stream)
            return stream
        }
    }

    /// The last fetch failure of the current load (e.g. "HTTP error 403"), which mpv's own error does not carry.
    public var failure: String? { lock.withLock { lastFailure } }

    private func failed(_ message: String, load: String) { lock.withLock { if token == load { lastFailure = message } } }
}
