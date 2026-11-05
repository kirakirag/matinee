import AppKit
import ImageIO
import MatineeKit
import SwiftUI

/// Thumbnails and avatars from explicit URLs (for videos: DeArrow's, else YouTube's automatic mid-video frame; the
/// uploader's designed thumbnail is never shown),
/// cached on disk by URLCache and decoded images in memory, keyed by URL.
/// Fetching and decoding happen off the main actor; the view shows a placeholder until the image is ready.
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let memory = NSCache<NSString, NSImage>()
    /// URLs that failed this session (DeArrow renders on demand and can hang); not retried.
    private var failed: Set<URL> = []
    private let session: URLSession = {
        // Cached on disk, but no cookies (see PrivateHTTP).
        let config = PrivateHTTP.configuration(cache: URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20,
                                                               directory: URL.cachesDirectory.appending(path: "Thumbnails")))
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Decoded images are per size; the downloaded bytes are shared through the URL cache.
    private static func key(_ url: URL, _ maxPixelSize: Int) -> NSString { "\(maxPixelSize) \(url.absoluteString)" as NSString }

    func cached(_ url: URL, maxPixelSize: Int) -> NSImage? {
        memory.object(forKey: Self.key(url, maxPixelSize))
    }

    /// Loads in flight, so a row and a prefetch asking for the same image share one fetch and decode.
    private var loading: [NSString: Task<NSImage?, Never>] = [:]

    func load(_ url: URL, maxPixelSize: Int) async -> NSImage? {
        if let hit = cached(url, maxPixelSize: maxPixelSize) { return hit }
        let key = Self.key(url, maxPixelSize)
        if let running = loading[key] { return await running.value }
        let task = Task { await fetch(url, maxPixelSize: maxPixelSize) }
        loading[key] = task
        defer { loading[key] = nil }
        return await task.value
    }

    /// Starts loading thumbnails the list is about to show, so scrolling doesn't reveal placeholders.
    func prefetch(_ urls: [URL], maxPixelSize: Int = 480) {
        for url in urls where cached(url, maxPixelSize: maxPixelSize) == nil && !failed.contains(url)
            && loading[Self.key(url, maxPixelSize)] == nil {
            Task { _ = await load(url, maxPixelSize: maxPixelSize) }
        }
    }

    private func fetch(_ url: URL, maxPixelSize: Int) async -> NSImage? {
        guard !failed.contains(url) else { return nil }
        let cg: CGImage?
        do {
            cg = try await Self.fetchAndDecode(url, maxPixelSize: maxPixelSize, timeout: 5, session: session)
        } catch {
            // A cancelled load (the row was reused or scrolled away) or a connection problem says nothing
            // about the URL; only a timeout does (DeArrow can hang rendering a frame).
            if !Task.isCancelled, (error as? URLError)?.code == .timedOut { failed.insert(url) }
            return nil
        }
        guard let cg else {
            failed.insert(url)   // a bad HTTP status or an undecodable image
            return nil
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        memory.setObject(image, forKey: Self.key(url, maxPixelSize))
        return image
    }

    /// Nil for a bad status or undecodable data; throws the transport error otherwise.
    @concurrent private static func fetchAndDecode(_ url: URL, maxPixelSize: Int, timeout: TimeInterval,
                                                   session: URLSession) async throws -> CGImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Decoded here at the size it's shown (a 120 pt row needs a few hundred pixels, not the full frame), and now
        // rather than lazily on the main thread at first draw.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct Thumbnail: View {
    let videoId: String
    /// DeArrow's thumbnail. Without one, or when it fails, YouTube's automatic frame from the middle of the video
    /// (as FreeTube's "middle" setting): a real frame, never the uploader's designed thumbnail.
    var url: URL?
    /// The video's channel: with no frame either, a subscribed channel's avatar fills the placeholder.
    var channelId: String?
    /// Longest side in pixels to decode: enough for a 120 pt row on a 3x display. Bigger views pass more.
    var maxPixelSize = 480
    @State private var image: NSImage?
    @State private var avatar: NSImage?
    @State private var imageVideoId: String?

    var body: some View {
        let avatarURL = channelId.flatMap { ChannelAvatars.shared.urls[$0] }
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if let avatar {
                    // The avatar, round, over a blurred and darkened copy of itself.
                    GeometryReader { g in
                        Image(nsImage: avatar).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: g.size.width, height: g.size.height)
                            .blur(radius: g.size.height / 6)
                            .overlay(.black.opacity(0.3))
                        Image(nsImage: avatar).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: g.size.height * 0.6, height: g.size.height * 0.6)
                            .clipShape(.circle)
                            .position(x: g.size.width / 2, y: g.size.height / 2)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 5))
            .task(id: "\(videoId) \(url?.absoluteString ?? "") \(avatarURL?.absoluteString ?? "")") {
                if imageVideoId != videoId { image = nil; avatar = nil }   // a reused row must not show another video's
                imageVideoId = videoId
                for candidate in [url, Self.frameURL(videoId)].compactMap({ $0 }) {
                    if let hit = ThumbnailLoader.shared.cached(candidate, maxPixelSize: maxPixelSize) { image = hit; return }
                    image = nil
                    let loaded = await ThumbnailLoader.shared.load(candidate, maxPixelSize: maxPixelSize)
                    guard !Task.isCancelled else { return }   // the row was reused for another video while loading
                    image = loaded
                    if loaded != nil { return }
                }
                image = nil
                guard let avatarURL else { avatar = nil; return }
                if let hit = ThumbnailLoader.shared.cached(avatarURL, maxPixelSize: Self.avatarPixels) { avatar = hit; return }
                let loaded = await ThumbnailLoader.shared.load(avatarURL, maxPixelSize: Self.avatarPixels)
                guard !Task.isCancelled else { return }
                avatar = loaded
            }
    }

    /// mq2 is the frame YouTube captures halfway through, 320×180. Nil for a playlist's ID.
    static func frameURL(_ videoId: String) -> URL? {
        VideoID.isValid(videoId) ? URL(string: "https://i.ytimg.com/vi/\(videoId)/mq2.jpg") : nil
    }

    /// The avatar is drawn at most ~290 pt (60% of a 480 pt-wide player placeholder's height) on a 3x display.
    private static let avatarPixels = 600
}
