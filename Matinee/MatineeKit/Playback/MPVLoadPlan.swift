import Foundation

/// What to hand to mpv for one video: the request headers and the `loadfile` command.
public struct MPVLoadPlan: Equatable, Sendable {
    public var userAgent: String?
    /// "Name: value" for every header except User-Agent, sorted by name.
    public var headerFields: [String]
    /// ["loadfile", videoURL, "replace", "-1", options]; the options are left out when empty.
    public var loadfile: [String]

    /// yt-dlp-controlled strings reach mpv's protocol handlers, so only https streams are loaded.
    public static func isAcceptable(_ r: Resolved) -> Bool {
        r.videoURL.scheme == "https" && (r.audioURL.map { $0.scheme == "https" } ?? true)
    }

    /// Whether every stream is a googlevideo media URL (`/videoplayback?…`), which the ranged stream serves faster than
    /// mpv's single throttled GET. Anything else, such as a live HLS manifest, is opened by mpv itself.
    public static func usesRangedStream(_ r: Resolved) -> Bool {
        func isMedia(_ url: URL) -> Bool {
            url.host?.hasSuffix(".googlevideo.com") == true && url.path == "/videoplayback" && url.query != nil
        }
        return isMedia(r.videoURL) && (r.audioURL.map(isMedia) ?? true)
    }

    /// `streams` are the registry's URLs to open instead of the resolved ones.
    public init(_ r: Resolved, start: Double, streams: (video: String, audio: String?)? = nil) {
        userAgent = r.headers["User-Agent"]
        headerFields = r.headers.filter { $0.key != "User-Agent" }.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        var options: [String] = []
        if let audio = streams.map({ $0.audio }) ?? r.audioURL?.absoluteString {
            // %len% quoting keeps commas in the URL from splitting the option list
            options.append("audio-file=%\(audio.utf8.count)%\(audio)")
        }
        if start > 0 { options.append("start=" + String(format: "%.1f", start)) }
        loadfile = ["loadfile", streams?.video ?? r.videoURL.absoluteString, "replace", "-1"]
        if !options.isEmpty { loadfile.append(options.joined(separator: ",")) }
    }
}
