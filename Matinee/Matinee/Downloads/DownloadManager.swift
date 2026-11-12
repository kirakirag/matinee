import Foundation
import MatineeKit
import Observation

/// Saves videos for offline viewing: owns the `download` table and runs at most two downloads at a time through
/// its own worker, oldest first.
@MainActor @Observable final class DownloadManager {
    private static let maxRunning = 2

    /// Newest first.
    private(set) var items: [Download] = []
    private(set) var progress: [String: DownloadProgress] = [:]
    /// Downloads queued or running.
    var activeCount: Int { items.count { $0.state == .queued || $0.state == .downloading } }

    /// The running downloads together, by bytes; nil while none has a known total.
    var overallFraction: Double? {
        let known = items.filter { $0.state == .downloading }.compactMap { progress[$0.videoId] }.filter { $0.total != nil }
        let total = known.reduce(0) { $0 + ($1.total ?? 0) }
        guard total > 0 else { return nil }
        return min(Double(known.reduce(0) { $0 + min($1.downloaded, $1.total ?? 0) }) / Double(total), 1)
    }

    /// Set by the app: shows a short notice in the window.
    @ObservationIgnored var onNotice: ((String) -> Void)?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let worker: WorkerClient
    @ObservationIgnored private let sponsorBlock: SponsorBlockService?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    /// Finished downloads whose subtitles are still being saved.
    @ObservationIgnored private var savingSubtitles: [String: Task<Void, Never>] = [:]

    init(store: Store, worker: WorkerClient, sponsorBlock: SponsorBlockService?, directory: URL = DownloadFiles.directory) {
        self.store = store
        self.worker = worker
        self.sponsorBlock = sponsorBlock
        self.directory = directory
        let rows = (try? store.downloads()) ?? []
        items = DownloadQueue.requeueInterrupted(rows)
        for (old, new) in zip(rows, items) where old != new { try? store.upsertDownload(new) }
        startNext()
    }

    /// Queues the video. Already saved or on its way: nothing happens; failed before: tried again.
    func save(videoId: String, title: String, channelName: String, channelId: String?, lengthSeconds: Int?) {
        guard VideoID.isValid(videoId) else { return }
        if let existing = items.first(where: { $0.videoId == videoId }) {
            if case .failed = existing.state { retry(videoId) }
            return
        }
        let d = Download(videoId: videoId, title: title, channelName: channelName, channelId: channelId,
                         lengthSeconds: lengthSeconds, state: .queued, bytes: nil, addedAt: .now)
        items.insert(d, at: 0)
        try? store.upsertDownload(d)
        onNotice?("Saving “\(title.isEmpty ? videoId : title)” for offline")
        startNext()
    }

    func retry(_ videoId: String) {
        guard let i = items.firstIndex(where: { $0.videoId == videoId }), case .failed = items[i].state else { return }
        update(videoId) { $0.state = .queued }
        startNext()
    }

    /// Stops a running download (the worker removes its partial files) and deletes the row and every file.
    func delete(_ videoId: String) {
        running.removeValue(forKey: videoId)?.cancel()
        savingSubtitles.removeValue(forKey: videoId)?.cancel()
        items.removeAll { $0.videoId == videoId }
        progress[videoId] = nil
        try? store.removeDownload(videoId: videoId)
        try? DownloadFiles.removeAll(videoId: videoId, in: directory)
        startNext()
    }

    private func startNext() {
        // `items` is newest first, so the oldest queued row is the last one.
        while running.count < Self.maxRunning,
              let next = items.last(where: { $0.state == .queued && running[$0.videoId] == nil }) {
            start(next.videoId)
        }
    }

    private func start(_ videoId: String) {
        update(videoId) { $0.state = .downloading }
        let worker = worker, directory = directory, sponsorBlock = sponsorBlock
        let quality = UserDefaults.standard.integer(forKey: "defaultQuality")   // Settings' default; 0 is Best
        running[videoId] = Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let result = try await worker.download(videoId, to: directory, maxHeight: quality > 0 ? quality : nil) { p in
                    Task { @MainActor [weak self] in
                        if self?.running[videoId] != nil { self?.progress[videoId] = p }
                    }
                }
                // Stored with the download, so skipping works offline too.
                _ = await sponsorBlock?.segments(for: videoId)
                finish(videoId) { d in
                    d.state = .done
                    d.bytes = result.bytes
                    if d.title.isEmpty { d.title = result.title ?? "" }
                    if d.channelName.isEmpty { d.channelName = result.channel ?? "" }
                    d.channelId = d.channelId ?? result.channelId
                    d.lengthSeconds = d.lengthSeconds ?? result.duration.map { Int($0) }
                }
                saveSubtitles(videoId, result.subtitles)
            } catch is CancellationError {
                // Deleted while downloading: `delete` already cleaned up.
            } catch {
                finish(videoId) { $0.state = .failed(Self.message(for: error)) }
            }
        }
    }

    /// Keeps the video's caption tracks next to its file, so they show offline. Runs after the download is done
    /// (about a second per track), outside the two download slots.
    private func saveSubtitles(_ videoId: String, _ tracks: [SubtitleTrack]) {
        guard !tracks.isEmpty, items.contains(where: { $0.videoId == videoId && $0.state == .done }) else { return }
        let directory = directory
        savingSubtitles[videoId] = Task {
            await SubtitleStore(directory: directory).save(videoId: videoId, tracks: tracks, in: directory)
            // Deleted while saving: a file written after `delete` cleaned up goes too.
            if !items.contains(where: { $0.videoId == videoId }) {
                try? DownloadFiles.removeAll(videoId: videoId, in: directory)
            }
            savingSubtitles[videoId] = nil
        }
    }

    private func finish(_ videoId: String, _ change: (inout Download) -> Void) {
        guard running.removeValue(forKey: videoId) != nil else { return }
        progress[videoId] = nil
        update(videoId, change)
        startNext()
    }

    private func update(_ videoId: String, _ change: (inout Download) -> Void) {
        guard let i = items.firstIndex(where: { $0.videoId == videoId }) else { return }
        change(&items[i])
        try? store.upsertDownload(items[i])
    }

    private static func message(for error: any Error) -> String {
        if case .failed(let message)? = error as? WorkerError { return String(message.prefix(200)) }
        return PlaybackFailure.classify(error).message
    }
}
