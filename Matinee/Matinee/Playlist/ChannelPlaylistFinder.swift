import MatineeKit

/// Plays a channel playlist by default: when a video is opened alone, asks the worker which of its channel's
/// playlists may contain it and, once the first one is seen to, makes that playlist the queue.
@MainActor final class ChannelPlaylistFinder {
    private let store: Store
    private let worker: WorkerClient
    private let dearrow: DeArrowService
    /// The playlist checked or queued for the latest single open; kept alive while its queue is current.
    private var model: PlaylistModel?
    private var task: Task<Void, Never>?

    init(store: Store, worker: WorkerClient, dearrow: DeArrowService) {
        self.store = store
        self.worker = worker
        self.dearrow = dearrow
    }

    func find(_ videoId: String, player: PlaybackController, token: Int) {
        task?.cancel()
        model?.cancel()   // a new single open made its queue stale, so this stops its paging
        model = nil
        let worker = worker
        task = Task { [weak self] in
            // Recommendations aren't proof of membership; attach only queues the list if it contains the video.
            guard let first = try? await worker.playlists(of: videoId).first, !Task.isCancelled, let self else { return }
            let model = PlaylistModel(store: store, worker: worker, dearrow: dearrow, id: first.id, title: first.title)
            self.model = model
            model.attach(videoId: videoId, player: player, token: token)
        }
    }
}
