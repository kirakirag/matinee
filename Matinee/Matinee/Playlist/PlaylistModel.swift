import Foundation
import MatineeKit
import Observation

struct PlaylistRow: Identifiable, Equatable {
    let entry: ListedEntry
    /// DeArrow's title when enabled and available, else the listing's.
    let title: String
    /// DeArrow's thumbnail when enabled and available; nil shows the placeholder.
    let thumbnail: URL?
    let progress: Double?
    var id: String { entry.id }
}

/// One playlist page: the first page as soon as it arrives, then the rest in the background until done,
/// so that a queue started from any row has the whole list.
@MainActor @Observable
final class PlaylistModel {
    private static let firstPageSize = 100
    private static let pageSize = 200

    private(set) var title: String?
    private(set) var channel: String?
    private(set) var rows: [PlaylistRow] = []
    private(set) var error: String?
    private(set) var isLoading = false
    /// True once every page has arrived.
    private(set) var finished = false

    private let store: Store
    private let worker: WorkerClient
    private let dearrow: DeArrowService
    private let id: String

    private var entries: [ListedEntry] = []
    private var progress: [String: Double] = [:]
    private var branding: [String: Branding] = [:]
    private var pager = SearchPager()
    private var firstPageDone = false
    private var task: Task<Void, Never>?
    /// The cancelled run, which a resumed run waits for so the pager is no longer marked as loading.
    private var stopping: Task<Void, Never>?
    private var generation = 0

    init(store: Store, worker: WorkerClient, dearrow: DeArrowService, id: String, title: String?) {
        self.store = store
        self.worker = worker
        self.dearrow = dearrow
        self.id = id
        self.title = title
    }

    /// The player and token of a queue started from this page; later pages are appended to it.
    private var queue: (player: PlaybackController, token: Int)?
    /// A video already playing alone that becomes this list's queue once a page shows it (see `attach`).
    private var pendingAttach: (videoId: String, player: PlaybackController, token: Int)?
    private var attached = false

    /// Plays from `videoId` with the whole list as the queue, including pages that arrive later.
    func play(from videoId: String, in player: PlaybackController) {
        let items = rows.map(Self.item)
        guard let start = items.firstIndex(where: { $0.videoId == videoId }) else { return }
        queue = (player, player.open(items, start: start, title: title))
    }

    /// Loads the list in the background and, once a page contains `videoId`, makes it the queue of that video,
    /// which `player` is already playing alone (`token` is from its single open). Not found: nothing happens.
    func attach(videoId: String, player: PlaybackController, token: Int) {
        pendingAttach = (videoId, player, token)
        attached = true
        load()
    }

    private static func item(_ r: PlaylistRow) -> PlaybackController.Item {
        let e = r.entry
        return .init(videoId: e.id, title: e.title, channelName: e.channel ?? "", channelId: e.channelId,
                     lengthSeconds: e.duration, publishedAt: nil, displayTitle: r.title, thumbnailURL: r.thumbnail)
    }

    /// Starts or resumes loading; does nothing when everything is loaded or loading.
    func load() {
        guard task == nil, !finished else { return }
        generation += 1
        let g = generation, previous = stopping
        isLoading = true
        task = Task {
            await previous?.value
            await run()
            if generation == g { task = nil; isLoading = false }
        }
    }

    /// Stops the page's network work, e.g. when it is popped, so abandoned requests don't hold the shared worker.
    /// Keeps loading while the player's queue is the one started here, so that queue still gets the whole list.
    func cancel() {
        if let queue, queue.player.isCurrentQueue(queue.token) { return }
        task?.cancel()
        stopping = task
        task = nil
        isLoading = false
    }

    /// Recomputes rows after new data or a DeArrow settings change.
    func rebuild() {
        let defaults = UserDefaults.standard
        let useTitles = defaults.object(forKey: "dearrowTitles") as? Bool ?? true
        let useThumbnails = defaults.object(forKey: "dearrowThumbnails") as? Bool ?? true
        rows = entries.map { e in
            let b = branding[e.id]
            return PlaylistRow(entry: e, title: (useTitles ? b?.title : nil) ?? e.title,
                               thumbnail: useThumbnails ? b?.thumbnailTime.flatMap { DeArrow.thumbnailURL(videoId: e.id, time: $0) } : nil,
                               progress: progress[e.id])
        }
    }

    private func run() async {
        var token = 0
        do {
            if !firstPageDone {
                token = pager.start()
                let page = try await worker.list(.playlist(id), first: Self.firstPageSize)
                guard !Task.isCancelled else { _ = pager.failed(token: token); return }
                guard let new = pager.received(page, token: token) else { return }
                firstPageDone = true
                if let t = page.title, !t.isEmpty { title = t }
                channel = page.channel
                received(new)
                touch(count: page.done ? entries.count : nil)
                let store = store
                progress = await Task.detached { (try? store.progress()) ?? [:] }.value
                rebuild()
                if page.done { finished = true; return }
            }
            while let cursor = pager.cursor, let t = pager.loadMore() {
                token = t
                let page = try await worker.more(cursor: cursor, n: Self.pageSize)
                guard !Task.isCancelled else { _ = pager.failed(token: token); return }
                guard let new = pager.received(page, token: token) else { return }
                received(new)
                if page.done {
                    finished = true
                    touch(count: entries.count)
                }
            }
        } catch {
            _ = pager.failed(token: token)
            guard !Task.isCancelled else { return }
            self.error = Self.message(for: error)
        }
    }

    private func received(_ new: [ListedEntry]) {
        error = nil
        entries += new
        rebuild()
        if let queue { queue.player.appendToQueue(rows.suffix(new.count).map(Self.item), token: queue.token) }
        if let a = pendingAttach, let index = rows.firstIndex(where: { $0.entry.id == a.videoId }) {
            pendingAttach = nil
            // Nil: the user opened something else meanwhile, so the rest of the list isn't needed.
            if let token = a.player.adoptQueue(rows.map(Self.item), at: index, title: title ?? "", token: a.token) {
                queue = (a.player, token)
            } else {
                cancel()
            }
        }
        let dearrow = dearrow, ids = new.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            branding.merge(await dearrow.branding(for: ids)) { $1 }
            rebuild()
        }
    }

    /// Records the playlist under recents; the count is only known once every page has arrived.
    private func touch(count: Int?) {
        guard !attached else { return }   // the user never opened this list; it isn't a recent
        let store = store
        let p = RecentPlaylist(id: id, title: title ?? id, channelName: channel, videoCount: count, openedAt: .now)
        Task.detached { try? store.touchPlaylist(p) }
    }

    private static func message(for error: any Error) -> String {
        let failure = PlaybackFailure.classify(error)
        switch failure {
        case .network, .timedOut: return "Couldn't load the playlist: \(failure.message)"
        default:
            if case .failed(let message)? = error as? WorkerError { return "Couldn't load the playlist: \(message.prefix(200))" }
            return "Couldn't load the playlist: \(failure.message)"
        }
    }
}
