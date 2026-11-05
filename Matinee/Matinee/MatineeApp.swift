import MatineeKit
import SwiftUI

/// Matinee stays running with its window closed (the Dock icon brings the window back), so For You can be ranked
/// while the Mac is idle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MatineeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var nav: Navigator
    @State private var store: Result<Store, any Error>
    /// Built once here so the services aren't recreated with the views.
    @State private var feed: FeedModel?
    @State private var search: SearchModel?
    @State private var historyDearrow: DeArrowService?
    @State private var worker: WorkerClient
    /// Runs searches and listings, so they never queue behind a video resolve.
    @State private var listWorker: WorkerClient
    /// Saves videos for offline viewing, through its own worker.
    @State private var downloads: DownloadManager?
    /// Owns the app's one MPVPlayer.
    @State private var player: PlaybackController?
    /// The subscribed channels, toggled with `d` anywhere.
    @State private var subscriptions: Subscriptions?
    /// For You; its related lists are cached and shared with Up next.
    @State private var forYou: ForYouModel?
    /// "Local AI ranking"'s two models, for For You and Settings.
    @State private var localModels: LocalModels
    /// ~/.config/matinee/settings.json, kept the same as the settings both ways.
    @State private var settingsSync: SettingsSync?

    init() {
        // Decides the renderer and sets MoltenVK's VK_DRIVER_FILES (setenv) before other threads start.
        _ = MPVPlayer.usesMetal
        let store = Result {
            KeyBench.isRequested ? try KeyBench.seededStore() : try Store(path: Store.defaultURL())
        }
        _store = State(initialValue: store)
        // The bench must not touch the network.
        let offline: @Sendable (URL) async throws -> Data = { _ in throw URLError(.notConnectedToInternet) }
        let feed = try? store.get().makeFeedModel(offline: KeyBench.isRequested ? offline : nil)
        _feed = State(initialValue: feed)
        let historyDearrow = (try? store.get()).map {
            KeyBench.isRequested ? DeArrowService(store: $0, fetch: offline) : DeArrowService(store: $0)
        }
        _historyDearrow = State(initialValue: historyDearrow)
        // Two at once: the resolver runs at most one prefetch, so opening a video never waits behind it.
        let worker = WorkerClient.bundled(parallel: 2)
        // A prefetched video's first megabyte is fetched too, so Return starts from memory.
        let warmer = StreamWarmer()
        let listWorker = WorkerClient.bundled(parallel: 4)   // a new search never waits behind a page fetch
        _listWorker = State(initialValue: listWorker)
        let search = try? store.get().makeSearchModel(worker: listWorker, offline: KeyBench.isRequested ? offline : nil)
        _search = State(initialValue: search)
        // The bench's list moves would otherwise prefetch through the worker.
        let resolver = KeyBench.isRequested ? PlaybackResolver { _, _, _ in throw URLError(.notConnectedToInternet) }
                                            : PlaybackResolver(resolve: { id, clients, maxHeight in
                                                try await worker.resolve(id, clients: clients, maxHeight: maxHeight)
                                            }, onPrefetched: { await warmer.warm($0) }, store: try? store.get())
        let sponsorBlock = (try? store.get()).map {
            KeyBench.isRequested ? SponsorBlockService(store: $0, fetch: offline) : SponsorBlockService(store: $0)
        }
        let player = (try? store.get()).map {
            PlaybackController(store: $0, resolver: resolver, player: MPVPlayer(streamFetch: warmer.fetch), sponsorBlock: sponsorBlock)
        }
        // A third worker, so a download never holds up playback or listings. Progress lines restart its timeout.
        let downloads = (try? store.get()).map {
            DownloadManager(store: $0, worker: WorkerClient.bundled(parallel: 2, timeout: .seconds(60)), sponsorBlock: sponsorBlock)
        }
        _downloads = State(initialValue: downloads)
        let nav = Navigator()
        nav.player = player
        downloads?.onNotice = { [weak nav] in nav?.show(notice: $0) }
        if !KeyBench.isRequested {   // the bench's settings stay out of the file
            let sync = SettingsSync { [weak nav] in nav?.show(notice: $0) }
            sync.start()
            _settingsSync = State(initialValue: sync)
        }
        if !KeyBench.isRequested {   // the bench stays offline
            player?.loadComments = { id in try await listWorker.comments(of: id, first: 20) }
            player?.loadMoreComments = { cursor in try await listWorker.moreComments(cursor: cursor, n: 20) }
            player?.loadReplies = { cursor, id in try await listWorker.replies(cursor: cursor, of: id, n: 10) }
        }
        player?.onSaveOffline = { [weak downloads] item in
            downloads?.save(videoId: item.videoId, title: item.title, channelName: item.channelName,
                            channelId: item.channelId, lengthSeconds: item.lengthSeconds)
        }
        player?.onOpenChannel = { [weak nav] ref, name in nav?.push(.channel(ref, name: name)) }
        let subscriptions = (try? store.get()).map { Subscriptions(store: $0) }
        subscriptions?.onChange = { [weak feed] in feed?.subscriptionsChanged() }
        subscriptions?.onNotice = { [weak nav] in nav?.show(notice: $0) }
        player?.onToggleSubscription = { [weak subscriptions] item in
            subscriptions?.toggle(item.channelId, name: item.channelName)
        }
        _subscriptions = State(initialValue: subscriptions)
        search?.subscriptions = subscriptions
        // The bench stays offline.
        let bench = KeyBench.isRequested
        let related = (try? store.get()).map { s in
            RelatedService(store: s, fetch: { id in
                if bench { throw URLError(.notConnectedToInternet) }
                return try await listWorker.related(of: id)
            })
        }
        let forYou = (try? store.get()).flatMap { s in related.map { ForYouModel(store: s, related: $0, dearrow: DeArrowService(store: s)) } }
        forYou?.subscriptions = subscriptions
        let localModels = LocalModels()
        forYou?.localModels = localModels
        forYou?.describe = { try await listWorker.descriptions(of: $0) }
        localModels.onReady = { [weak forYou] in forYou?.localModelsChanged() }
        forYou?.isPlaying = { [weak player] in
            guard let player else { return false }
            return player.phase == .resolving || player.phase == .loading || (player.phase == .playing && !player.isPaused)
        }
        if !KeyBench.isRequested, !ModelSelfTest.isRequested { forYou?.startBackgroundRanking() }
        if LocalModels.isEnabled, !ModelSelfTest.isRequested { localModels.download() }   // resumes an interrupted one
        _localModels = State(initialValue: localModels)
        if let related { player?.loadRelated = { try await related.related($0) } }
        _forYou = State(initialValue: forYou)
        // A video opened alone plays its channel playlist once membership is confirmed. The bench stays offline.
        if !KeyBench.isRequested, let s = try? store.get(), let historyDearrow {
            let finder = ChannelPlaylistFinder(store: s, worker: listWorker, dearrow: historyDearrow)
            player?.onSingleOpen = { [weak player] item, token in
                guard let player else { return }
                finder.find(item.videoId, player: player, token: token)
            }
        }
        _worker = State(initialValue: worker)
        _player = State(initialValue: player)
        _nav = State(initialValue: nav)
        // Closing the window pauses and saves the position (quitting is handled by the controller).
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard window?.canBecomeMain == true else { return }
                player?.dismiss()   // saves history and pauses
            }
        }
    }

    var body: some Scene {
        Window("Matinee", id: "main") {
            RootView(store: store, feed: feed, search: search, historyDearrow: historyDearrow, listWorker: listWorker,
                     forYou: forYou)
                .environment(nav)
                .environment(player)
                .environment(downloads)
                .environment(subscriptions)
                .environment(localModels)
                .frame(minWidth: 760, minHeight: 500)
                .task {
                    await subscriptions?.load()
                    if !KeyBench.isRequested { Task { await worker.warmUp() }; Task { await listWorker.warmUp() } }   // the bench stays offline
                    if KeyBench.isRequested { await KeyBench(nav: nav).run() }
                    if let id = WorkerSelfTest.requestedID { await WorkerSelfTest.run(id) }
                    if MPVSelfTest.isRequested { MPVSelfTest.run() }
                    if ModelSelfTest.isRequested { await ModelSelfTest.run(localModels) }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // Lists the global keys. Presses are handled by Navigator's key monitor before the menu sees them.
            CommandMenu("Go") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { nav.perform(.section(s)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                Button("Find…") { nav.perform(.focusSearch) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Filter List") { nav.perform(.filterList) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Refresh") { nav.perform(.refresh) }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Return to Player") { nav.perform(.resumePlayer) }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(player?.item == nil)
            }
        }
    }
}

private extension Store {
    @MainActor func makeFeedModel(offline: (@Sendable (URL) async throws -> Data)?) -> FeedModel {
        if let offline {
            return FeedModel(store: self, service: FeedService(store: self, fetch: offline),
                             dearrow: DeArrowService(store: self, fetch: offline))
        }
        return FeedModel(store: self, service: FeedService(store: self), dearrow: DeArrowService(store: self))
    }

    @MainActor func makeSearchModel(worker: WorkerClient, offline: (@Sendable (URL) async throws -> Data)?) -> SearchModel {
        if let offline {
            return SearchModel(store: self, worker: worker, dearrow: DeArrowService(store: self, fetch: offline),
                               suggestions: SuggestionService(fetch: offline))
        }
        return SearchModel(store: self, worker: worker, dearrow: DeArrowService(store: self),
                           suggestions: SuggestionService())
    }
}
