import Foundation
import MatineeKit
import Observation

struct ChannelRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case video(FeedVideo, title: String, thumbnail: URL?, progress: Double?)
        /// Opens the channel's uploads playlist: RSS has only the latest 15 videos.
        case allVideos(playlistId: String)
        /// Separates the latest videos from the playlists; not selectable.
        case divider
        case playlist(ListedEntry)
    }

    let kind: Kind
    let id: String

    var isSelectable: Bool { kind != .divider }
}

/// One channel page: the latest videos from RSS and the playlists from the list worker, loaded independently
/// so that a failure of one doesn't hide the other.
@MainActor @Observable
final class ChannelModel {
    private static let playlistPageSize = 30

    private(set) var name: String?
    private(set) var rows: [ChannelRow] = []
    private(set) var videosError: String?
    private(set) var playlistsError: String?
    private(set) var notFound = false
    private(set) var isLoadingPlaylists = false

    private let store: Store
    private let worker: WorkerClient
    private let dearrow: DeArrowService
    private let fetch: FeedService.Fetch
    private let ref: ChannelRef

    /// Known from the ref, or once the playlists page names it (a handle ref).
    private(set) var channelId: String?
    private var videos: [FeedVideo] = []
    private var playlists: [ListedEntry] = []
    private var progress: [String: Double] = [:]
    private var branding: [String: Branding] = [:]
    private var pager = SearchPager()
    private var videosDone = false
    private var firstPageDone = false
    private var videosTask: Task<Void, Never>?
    private var playlistsTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?

    init(store: Store, worker: WorkerClient, dearrow: DeArrowService, ref: ChannelRef, name: String?,
         fetch: @escaping FeedService.Fetch = FeedService.urlSession) {
        self.store = store
        self.worker = worker
        self.dearrow = dearrow
        self.ref = ref
        self.name = name
        self.fetch = fetch
    }

    /// The channel's latest videos as player items, for the queue, with what the rows show.
    var queueItems: [PlaybackController.Item] {
        rows.compactMap { row in
            guard case .video(let v, let title, let thumbnail, _) = row.kind else { return nil }
            return .init(videoId: v.videoId, title: v.title, channelName: v.channelName, channelId: v.channelId,
                         lengthSeconds: nil, publishedAt: v.publishedAt, displayTitle: title, thumbnailURL: thumbnail)
        }
    }

    /// Starts whatever isn't loaded or loading; calling it again when the page reappears resumes what `cancel` stopped.
    func load() {
        if case .id(let id) = ref { channelId = id }
        if playlistsTask == nil, !firstPageDone { loadPlaylists() }
        if channelId != nil, videosTask == nil, !videosDone { loadVideos() }
    }

    /// Stops the page's network work, e.g. when it is popped, so abandoned requests don't hold the shared worker.
    func cancel() {
        videosTask?.cancel()
        playlistsTask?.cancel()
        moreTask?.cancel()
        videosTask = nil
        playlistsTask = nil
        moreTask = nil
        isLoadingPlaylists = false
    }

    func loadMorePlaylists() {
        guard moreTask == nil, let cursor = pager.cursor, let token = pager.loadMore() else { return }
        isLoadingPlaylists = true
        moreTask = Task {
            do {
                let page = try await worker.more(cursor: cursor, n: Self.playlistPageSize)
                guard !Task.isCancelled else { _ = pager.failed(token: token); return }
                moreTask = nil
                guard let new = pager.received(page, token: token) else { return }
                isLoadingPlaylists = false
                playlistsError = nil
                playlists += new
                rebuild()
                // A page of only repeats changes nothing on screen, so nothing else would ask for the next one.
                if new.isEmpty { loadMorePlaylists() }
            } catch {
                guard !Task.isCancelled else { _ = pager.failed(token: token); return }
                moreTask = nil
                guard pager.failed(token: token) else { return }
                isLoadingPlaylists = false
                playlistsError = Self.message(for: error)
            }
        }
    }

    /// Recomputes rows after new data or a DeArrow settings change.
    func rebuild() {
        let defaults = UserDefaults.standard
        let useTitles = defaults.object(forKey: "dearrowTitles") as? Bool ?? true
        let useThumbnails = defaults.object(forKey: "dearrowThumbnails") as? Bool ?? true
        var result = videos.map { v in
            let b = branding[v.videoId]
            let thumbnail = useThumbnails ? b?.thumbnailTime.flatMap { DeArrow.thumbnailURL(videoId: v.videoId, time: $0) } : nil
            return ChannelRow(kind: .video(v, title: (useTitles ? b?.title : nil) ?? v.title, thumbnail: thumbnail,
                                           progress: progress[v.videoId]), id: v.videoId)
        }
        // A channel's uploads playlist is its ID with UU for UC.
        if !videos.isEmpty, let id = channelId {
            result.append(ChannelRow(kind: .allVideos(playlistId: "UU" + id.dropFirst(2)), id: "all-videos"))
        }
        if !playlists.isEmpty {
            result.append(ChannelRow(kind: .divider, id: "divider"))
            result += playlists.map { ChannelRow(kind: .playlist($0), id: $0.id) }
        }
        rows = result
    }

    private func loadVideos() {
        guard let id = channelId, let url = FeedService.feedURL(channelId: id) else {
            videosError = "Couldn't load the latest videos"
            return
        }
        let fetch = fetch, store = store, dearrow = dearrow
        videosTask = Task {
            do {
                let parsed = try RSSParser.parse(try await fetch(url))
                guard !Task.isCancelled else { return }
                videosDone = true
                videosError = nil
                videos = parsed
                if name == nil { name = parsed.first?.channelName }
                rebuild()
                progress = await Task.detached { (try? store.progress()) ?? [:] }.value
                rebuild()
                branding = await dearrow.branding(for: parsed.map(\.videoId))
                rebuild()
                videosTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                videosTask = nil
                videosError = "Couldn't load the latest videos: \(PlaybackFailure.classify(error).message)"
            }
        }
    }

    private func loadPlaylists() {
        isLoadingPlaylists = true
        let token = pager.start()
        playlistsTask = Task {
            do {
                let page = try await worker.list(.channelPlaylists(ref), first: Self.playlistPageSize)
                guard !Task.isCancelled else { _ = pager.failed(token: token); return }
                playlistsTask = nil
                guard let new = pager.received(page, token: token) else { return }
                isLoadingPlaylists = false
                if case .handle = ref {
                    guard let id = page.channelId, ChannelID.isValid(id) else { notFound = true; return }
                    channelId = id
                    if name == nil { name = page.channel }
                    loadVideos()
                }
                firstPageDone = true
                playlistsError = nil
                playlists = new
                rebuild()
            } catch {
                guard !Task.isCancelled else { _ = pager.failed(token: token); return }
                playlistsTask = nil
                guard pager.failed(token: token) else { return }
                isLoadingPlaylists = false
                // A handle YouTube can't resolve makes the listing fail; a network problem is not "not found".
                if case .handle = ref, case .failed? = error as? WorkerError { notFound = true; return }
                playlistsError = Self.message(for: error)
            }
        }
    }

    private static func message(for error: any Error) -> String {
        let failure = PlaybackFailure.classify(error)
        switch failure {
        case .network, .timedOut: return "Couldn't load playlists: \(failure.message)"
        default:
            if case .failed(let message)? = error as? WorkerError { return "Couldn't load playlists: \(message.prefix(200))" }
            return "Couldn't load playlists: \(failure.message)"
        }
    }
}
