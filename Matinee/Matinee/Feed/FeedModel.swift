import Foundation
import MatineeKit
import Observation
import os

struct FeedRow: Identifiable, Equatable {
    let video: FeedVideo
    /// DeArrow's title when enabled and available, else the RSS title.
    let title: String
    /// DeArrow's thumbnail when enabled and available; nil shows the placeholder.
    let thumbnail: URL?
    /// Watched fraction (0...1) when the video is in history.
    let progress: Double?
    var id: String { video.videoId }
}

/// The subscription feed: cached rows first, then a background refresh, then DeArrow.
/// Each phase replaces `rows` with a new array; `TableList` diffs it and reloads only changed rows.
@MainActor @Observable
final class FeedModel {
    private static let log = Logger(subsystem: "local.kirakirag.matinee", category: "Feed")
    /// DeArrow is only fetched for the newest rows; the rest show the RSS title.
    private static let dearrowLimit = 200

    private let store: Store
    private let service: FeedService
    private let dearrow: DeArrowService

    private(set) var rows: [FeedRow] = []
    private(set) var isRefreshing = false
    private(set) var lastResult: FeedRefreshResult?

    private var videos: [FeedVideo] = []
    private var progress: [String: Double] = [:]
    private var branding: [String: Branding] = [:]

    init(store: Store, service: FeedService, dearrow: DeArrowService) {
        self.store = store
        self.service = service
        self.dearrow = dearrow
    }

    private var loaded = false

    /// Runs once; later calls (the tab reappearing) do nothing. The work is unstructured so that
    /// leaving the tab doesn't cancel the refresh.
    func load() async {
        guard !loaded else { return }
        loaded = true
        await Task {
            await reloadCache()
            Self.log.debug("loaded \(self.rows.count) rows from cache")
            // Cached branding shows as soon as it's ready, but a slow DeArrow must not delay the refresh;
            // refresh applies branding again once the new rows are in.
            async let cachedBranding: Void = applyBranding()
            await refresh()
            await cachedBranding
        }.value
    }

    /// Set by a refresh asked for while one runs (e.g. a new subscription), which read the channels too early.
    private var refreshAgain = false

    func refresh() async {
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            let store = store
            let channels = await Task.detached { (try? store.subscriptions()) ?? [] }.value
            let result = await service.refresh(channels: channels)
            lastResult = result
            Self.log.debug("refresh: updated \(result.updated), failed \(result.failed.count)")
            await reloadCache()
            await applyBranding()
        } while refreshAgain
    }

    /// Refreshes after a subscription was added or removed elsewhere.
    func subscriptionsChanged() {
        Task { await refresh() }
    }

    private var brandingRun = 0

    private func applyBranding() async {
        brandingRun += 1
        let run = brandingRun
        let result = await dearrow.branding(for: videos.prefix(Self.dearrowLimit).map(\.videoId))
        guard run == brandingRun else { return }   // a newer call (after a refresh) covers more rows
        branding = result
        rebuild()
        let titles = branding.values.filter { $0.title != nil }.count
        let thumbs = branding.values.filter { $0.thumbnailTime != nil }.count
        Self.log.debug("dearrow: \(self.branding.count) branded, \(titles) titles, \(thumbs) thumbnails")
    }

    /// Recomputes rows after the DeArrow settings change.
    func rebuild() {
        let defaults = UserDefaults.standard
        let useTitles = defaults.object(forKey: "dearrowTitles") as? Bool ?? true
        let useThumbnails = defaults.object(forKey: "dearrowThumbnails") as? Bool ?? true
        rows = videos.map { v in
            let b = branding[v.videoId]
            return FeedRow(video: v,
                           title: (useTitles ? b?.title : nil) ?? v.title,
                           thumbnail: useThumbnails ? b?.thumbnailTime.flatMap { DeArrow.thumbnailURL(videoId: v.videoId, time: $0) } : nil,
                           progress: progress[v.videoId])
        }
    }

    private func reloadCache() async {
        let store = store
        (videos, progress) = await Task.detached {
            let videos = (try? store.feed()) ?? []
            let progress = (try? store.progress()) ?? [:]
            return (videos, progress)
        }.value
        rebuild()
    }
}
