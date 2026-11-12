import Foundation

public enum SubtitleError: Error, Equatable, LocalizedError {
    case notAllowed, throttled, http(Int), unreadable

    public var errorDescription: String? {
        switch self {
        case .notAllowed: "Unexpected subtitle address."
        case .throttled: "YouTube is limiting subtitle requests. Try again in a while."
        case .http(let status): "Subtitles failed to load (HTTP \(status))."
        case .unreadable: "Subtitles came back in an unknown format."
        }
    }
}

/// Fetches a caption track once and keeps it as a SubRip file mpv can open. A track is asked for only when it is
/// shown (YouTube throttles caption requests quickly), and the file is reused for a month, so a video watched again
/// or reloaded at another quality asks nothing. A downloaded video's tracks are saved next to its file for good, so
/// they show offline.
public struct SubtitleStore: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    private let directory: URL
    /// Where downloads keep their tracks; looked in first.
    private let saved: URL?
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private static let keep: TimeInterval = 30 * 24 * 3600

    public init(directory: URL, saved: URL? = nil, fetch: @escaping Fetch = SubtitleStore.http,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.saved = saved
        self.fetch = fetch
        self.now = now
    }

    /// Without cookies, like every other request to YouTube.
    public static let http: Fetch = { url in
        let (data, response) = try await PrivateHTTP.session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The track as a file, from disk when it was fetched before.
    public func file(videoId: String, track: SubtitleTrack) async throws -> URL {
        guard VideoID.isValid(videoId), track.isAcceptable else { throw SubtitleError.notAllowed }
        let name = Self.fileName(videoId: videoId, track: track)
        if let saved, FileManager.default.fileExists(atPath: saved.appending(path: name).path) {
            return saved.appending(path: name)
        }
        let file = directory.appending(path: name)
        if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           now().timeIntervalSince(modified) < Self.keep {
            return file
        }
        let srt = try await srt(of: track)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try srt.write(to: file, options: .atomic)
        prune()
        return file
    }

    /// Saves a downloaded video's tracks into `dir` (the downloads folder), one request at a time with `gap` between
    /// them, and lists the ones saved in `<id>.subtitles.json`. Stops at the first throttle; a track that fails
    /// otherwise is left out. Returns the tracks saved.
    @discardableResult
    public func save(videoId: String, tracks: [SubtitleTrack], in dir: URL, gap: Duration = .seconds(1)) async -> [SubtitleTrack] {
        guard VideoID.isValid(videoId) else { return [] }
        var done: [SubtitleTrack] = []
        for (i, track) in tracks.filter(\.isAcceptable).enumerated() {
            if i > 0 { try? await Task.sleep(for: gap) }
            if Task.isCancelled { break }
            do {
                try await srt(of: track).write(to: dir.appending(path: Self.fileName(videoId: videoId, track: track)), options: .atomic)
                done.append(track)
            } catch SubtitleError.throttled {
                break
            } catch {}
        }
        if !done.isEmpty, let list = try? JSONEncoder().encode(done) {
            try? list.write(to: Self.listFile(videoId: videoId, in: dir), options: .atomic)
        }
        return done
    }

    /// The tracks saved with a download, empty when there are none.
    public static func saved(videoId: String, in dir: URL) -> [SubtitleTrack] {
        guard VideoID.isValid(videoId), let data = try? Data(contentsOf: listFile(videoId: videoId, in: dir)),
              let list = try? JSONDecoder().decode([Lenient<SubtitleTrack>].self, from: data) else { return [] }
        let fm = FileManager.default
        return list.compactMap(\.value).filter {
            $0.isAcceptable && fm.fileExists(atPath: dir.appending(path: fileName(videoId: videoId, track: $0)).path)
        }
    }

    /// `<id>.<lang>[.auto].srt`. Starts with the id, so deleting a download's `<id>.*` files takes these too.
    static func fileName(videoId: String, track: SubtitleTrack) -> String {
        let lang = track.lang.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(35)
        return "\(videoId).\(lang)\(track.auto ? ".auto" : "").srt"
    }

    private static func listFile(videoId: String, in dir: URL) -> URL { dir.appending(path: "\(videoId).subtitles.json") }

    private func srt(of track: SubtitleTrack) async throws -> Data {
        let (data, status) = try await fetch(track.url)
        guard status != 429 else { throw SubtitleError.throttled }
        guard status == 200 else { throw SubtitleError.http(status) }
        guard let cues = SubtitleCues.parse(json3: data, rollUp: track.auto) else { throw SubtitleError.unreadable }
        return Data(SubtitleCues.srt(cues).utf8)
    }

    /// Drops files past their month.
    private func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            if let modified = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now().timeIntervalSince(modified) >= Self.keep {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}
