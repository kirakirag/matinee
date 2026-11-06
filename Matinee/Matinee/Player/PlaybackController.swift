import AppKit
import AVFoundation
import MatineeKit
import Observation
import os

/// Window-level playback state: which video is current, the phase it is in, and its history position.
@MainActor @Observable final class PlaybackController {
    enum Phase: Equatable { case idle, resolving, waiting(seconds: Int), loading, playing, failed(PlaybackFailure) }

    struct Item: Equatable {
        let videoId: String
        /// Empty for a pasted link until the resolve fills it in, with the channel and length.
        var title: String
        var channelName: String
        var channelId: String?
        var lengthSeconds: Int?
        let publishedAt: Date?
        /// What the list showed (e.g. DeArrow's), for the player and banner only; history keeps `title`.
        var displayTitle: String? = nil
        var thumbnailURL: URL? = nil
        /// Where to start (a pasted link's `t=`), instead of the history's resume position.
        var startAt: Double? = nil
    }

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let resolver: PlaybackResolver
    @ObservationIgnored private let sponsorBlock: SponsorBlockService?
    /// The current video's segments to skip; nil until SponsorBlock answers (it never holds up playback).
    @ObservationIgnored private var skipper: SponsorSkipper?
    @ObservationIgnored private var segmentsTask: Task<Void, Never>?
    @ObservationIgnored private var skipNoticeTask: Task<Void, Never>?
    @ObservationIgnored private let player: MPVPlayer
    @ObservationIgnored private var session = PlaybackSession()
    @ObservationIgnored private var openTask: Task<Void, Never>?
    /// False from `open` until the stream is handed to mpv.
    @ObservationIgnored private var loaded = false
    /// True once mpv has loaded the current open's file; time reports before that belong to the previous file.
    @ObservationIgnored private var fileLoaded = false
    /// True once mpv has reported a position for the current open: only then is there a history entry to write.
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var openedAt = ContinuousClock.now
    @ObservationIgnored private var resolveMs = 0
    @ObservationIgnored private var cached = false
    /// The current video already got a fresh resolve after a 403; a second 403 is shown.
    @ObservationIgnored private var retriedRefused = false
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Matinee", category: "playback")

    private(set) var item: Item?
    @ObservationIgnored private var queue: PlayQueue<Item>?
    /// Bumped by every `open`, so a page that started an earlier queue can't extend the current one.
    @ObservationIgnored private var queueToken = 0
    /// Position in the queue and its length, nil without one.
    private(set) var queueInfo: (position: Int, count: Int)?
    /// The playlist the queue came from, shown beside "n of N".
    private(set) var queueTitle: String?
    /// Set by the Navigator: opens the current video's channel page.
    /// AirPods, media keys and Control Center.
    @ObservationIgnored private var nowPlaying: NowPlaying?
    @ObservationIgnored var onOpenChannel: ((ChannelRef, String) -> Void)?
    /// Set by the app: saves the current video for offline viewing (`s` in the player).
    @ObservationIgnored var onSaveOffline: ((Item) -> Void)?
    /// Set by the app: subscribes to the current video's channel, or unsubscribes (`d` in the player).
    @ObservationIgnored var onToggleSubscription: ((Item) -> Void)?
    /// Set by the app: the first page of a video's comments, and the page after a cursor (read-only), from the list worker.
    @ObservationIgnored var loadComments: ((String) async throws -> CommentPage)?
    @ObservationIgnored var loadMoreComments: ((Int) async throws -> CommentPage)?
    /// Set by the app: a comment's next replies, from the cursor of the comments' first page.
    @ObservationIgnored var loadReplies: ((Int, String) async throws -> ReplyPage)?
    /// The first page's cursor, which stays valid for replies after the last page.
    @ObservationIgnored private var repliesCursor: Int?
    @ObservationIgnored private var commentsTask: Task<Void, Never>?
    /// Where the next page of comments starts; nil once they're all loaded.
    @ObservationIgnored private var commentsCursor: Int?
    /// The video the comments below belong to.
    @ObservationIgnored private var commentsVideoId: String?
    /// Set by the app: a video opened alone, with its queue token, so its channel playlist can become the queue.
    @ObservationIgnored var onSingleOpen: ((Item, Int) -> Void)?
    private(set) var phase = Phase.idle
    private(set) var isPresented = false
    /// Shrunk to a corner of the window (I), still playing while you browse.
    private(set) var isMini = false
    private(set) var braveError: String?
    /// "Skipped Sponsor · U to undo", shown briefly after a SponsorBlock skip.
    private(set) var skipNotice: String?
    enum CommentsStatus: Equatable { case idle, loading, loaded, failed(String) }
    /// The side panel (O) is open: Up next and/or comments, whichever are switched on. Both also load once a
    /// video's first frame is shown.
    private(set) var panelVisible = false
    enum PanelTab: Equatable { case upNext, comments }
    /// Up next when it's on; switching to comments loads them if they aren't yet.
    var panelTab = PanelTab.upNext {
        didSet { if panelTab == .comments, panelVisible { loadCommentsIfNeeded() } }
    }
    /// The selected row in each list, moved with ↑/↓ while the panel is open.
    private(set) var upNextSelection = 0
    private(set) var commentSelection = 0
    /// The panel is shown and takes ↑/↓/Return/Tab/Escape.
    var panelOpen: Bool { panelVisible && (Self.commentsEnabled || Self.upNextEnabled) }
    /// The videos the watch page suggests next (Settings' Recommendations).
    private(set) var upNext: [ListedEntry] = []
    private(set) var upNextStatus = CommentsStatus.idle
    /// Set by the app: the watch page's suggestions, from RelatedService's cache.
    @ObservationIgnored var loadRelated: ((String) async throws -> [ListedEntry])?
    @ObservationIgnored private var upNextTask: Task<Void, Never>?
    @ObservationIgnored private var upNextVideoId: String?
    /// Settings' "Up next and For You".
    static var upNextEnabled: Bool { ForYouModel.isEnabled }
    private(set) var comments: [VideoComment] = []
    private(set) var commentCount: Int?
    private(set) var commentsStatus = CommentsStatus.idle
    /// The next page of comments: loading, or why it failed.
    private(set) var moreComments = CommentsStatus.idle
    /// A comment's replies, fetched ten at a time once its "N replies" is clicked.
    struct ReplyThread: Equatable {
        var replies: [VideoComment] = []
        var status = CommentsStatus.idle
        var done = false
        var expanded = false
    }
    /// By comment id.
    private(set) var replyThreads: [String: ReplyThread] = [:]
    /// Settings' "Show comments".
    static var commentsEnabled: Bool { UserDefaults.standard.bool(forKey: "showComments") }
    private(set) var position = 0.0
    private(set) var duration: Double?
    private(set) var isPaused = false
    /// Playback is stalled waiting for data.
    private(set) var isBuffering = false
    @ObservationIgnored private var stalledAt: ContinuousClock.Instant?
    private(set) var volume = 100.0
    /// Heights the current video is available in, highest first; empty until it is resolved.
    private(set) var qualities: [Int] = []
    /// Height of the stream playing now.
    private(set) var currentHeight: Int?
    /// The chosen cap for the current video; nil is "Best". Each new video starts at Settings' default.
    private(set) var maxHeight: Int?
    /// The current video has a finished download, so the quality list offers it.
    private(set) var hasSavedCopy = false
    /// The download is what's playing (not a stream).
    private(set) var playingSaved = false
    /// The download's video height, once read from the file.
    private(set) var savedHeight: Int?
    /// The user picked a stream quality for a downloaded video; reloads stream instead of playing the file.
    @ObservationIgnored private var streamSaved = false
    /// Selected row of the quality list opened with `q`, nil while it is closed.
    private(set) var qualityMenuIndex: Int?
    private(set) var speed = 1.0
    /// The window is in macOS fullscreen, as its notifications report (so the green button and ⌃⌘F count too).
    private(set) var isFullscreen = false
    @ObservationIgnored private weak var fullscreenWindow: NSWindow?
    /// Bumped on every player command, so the view can show its controls.
    private(set) var commandCount = 0
    /// mpv's render view. It lives as long as the player, so it stays in the window rather than being re-created.
    var videoView: NSView { player.view }

    init(store: Store, resolver: PlaybackResolver, player: MPVPlayer, sponsorBlock: SponsorBlockService? = nil) {
        self.store = store
        self.resolver = resolver
        self.sponsorBlock = sponsorBlock
        self.player = player
        player.onTime = { [weak self] position, duration in self?.timeChanged(position, duration) }
        player.onPause = { [weak self] in self?.isPaused = $0 }
        player.onVolume = { [weak self] in self?.volume = $0 }
        player.onSpeed = { [weak self] in self?.speed = $0 }
        player.onBuffering = { [weak self] in self?.buffering($0) }
        player.onFileLoaded = { [weak self] in if self?.phase == .loading { self?.fileLoaded = true } }
        player.onFirstFrame = { [weak self] in self?.firstFrame() }
        player.onEndOfFile = { [weak self] in self?.endOfFile() }
        player.onLoadError = { [weak self] in self?.loadFailed($0) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveHistory() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                self?.fullscreenWindow = window
                self?.isFullscreen = true
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isFullscreen = false }
        }
        nowPlaying = NowPlaying(player: self)
    }

    /// Opens one video and clears any queue.
    func open(_ item: Item) {
        isMini = false
        queueToken += 1
        queue = nil
        queueInfo = nil
        queueTitle = nil
        start(item)
        onSingleOpen?(item, queueToken)
    }

    /// Opens `items[start]` and queues the rest, so next/previous and end of file move through them.
    /// Returns a token for `appendToQueue`, valid until the next `open`.
    @discardableResult func open(_ items: [Item], start: Int, title: String? = nil) -> Int {
        queueToken += 1
        let queue = PlayQueue(items, start: start)
        guard let first = queue.current else { return queueToken }
        isMini = false
        self.queue = queue
        queueTitle = title
        publishQueue()
        self.start(first)
        return queueToken
    }

    /// Adds items to the end of the queue `token` came from; ignored once another video or queue was opened.
    func appendToQueue(_ items: [Item], token: Int) {
        guard token == queueToken, var q = queue, !items.isEmpty else { return }
        q.append(contentsOf: items)
        queue = q
        publishQueue()
    }

    /// Makes `items` the queue around the video playing now, without restarting it. Only while nothing else was
    /// opened since the single open `token` came from, and the video is still `items[index]`.
    /// Returns a token for `appendToQueue`, or nil when it no longer applies.
    func adoptQueue(_ items: [Item], at index: Int, title: String, token: Int) -> Int? {
        guard token == queueToken, queue == nil, items.indices.contains(index),
              item?.videoId == items[index].videoId else { return nil }
        queueToken += 1
        queue = PlayQueue(items, start: index)
        queueTitle = title
        publishQueue()
        return queueToken
    }

    /// True while the queue `token` came from is still the player's, so its source should keep loading.
    func isCurrentQueue(_ token: Int) -> Bool { token == queueToken && queue != nil }

    private func publishQueue() {
        queueInfo = queue.map { (position: $0.position, count: $0.count) }
    }

    private func advance(_ move: (inout PlayQueue<Item>) -> Item?) {
        guard var q = queue, let next = move(&q) else { return }
        queue = q
        publishQueue()
        start(next)
    }

    private func start(_ item: Item) {
        saveHistory()
        openTask?.cancel()
        let token = session.begin()
        self.item = item
        retriedRefused = false
        maxHeight = Self.defaultMaxHeight
        qualities = []
        currentHeight = nil
        qualityMenuIndex = nil
        hasSavedCopy = false
        playingSaved = false
        savedHeight = nil
        streamSaved = false
        isPresented = !isMini   // the queue advancing keeps a mini player mini
        phase = .resolving
        braveError = nil
        position = 0
        duration = item.lengthSeconds.map(Double.init)
        isPaused = false
        isBuffering = false
        stalledAt = nil
        loaded = false
        fileLoaded = false
        started = false
        lastSave = .distantPast
        openedAt = .now
        player.stop()
        player.play()   // mpv keeps the pause state across loadfile, so a dismiss or Space during resolving survives
        openTask = Task { await run(item, token) }
        loadSegments(for: item.videoId)
        if panelVisible { loadPanel() }
    }

    func dismiss() {
        leaveFullscreen()
        qualityMenuIndex = nil
        saveHistory()
        player.pause()
        isPresented = false
        isMini = false
    }

    func resume() {
        guard item != nil else { return }
        isMini = false
        isPresented = true
        player.play()
    }

    func handle(_ c: PlayerCommand) {
        commandCount += 1
        switch c {
        case .close: dismiss()
        case .miniPlayer:
            if isMini { resume(); return }
            guard isPresented else { return }
            leaveFullscreen()
            qualityMenuIndex = nil
            isPresented = false
            isMini = true
        case .fullscreen: NSApp.keyWindow?.toggleFullScreen(nil)
        case .exitFullscreen: leaveFullscreen()
        case .next:
            if queue == nil { playUpNext() } else { advance { $0.next() } }
        case .previous: advance { $0.previous() }
        case .openChannel:
            if let item, let id = item.channelId, ChannelID.isValid(id) { onOpenChannel?(.id(id), item.channelName) }
        case .quality:
            if !qualityChoices.isEmpty { qualityMenuIndex = qualityChoices.firstIndex(of: selectedQuality) ?? 0 }
        case .toggleComments:
            let comments = Self.commentsEnabled && loadComments != nil, upNext = Self.upNextEnabled && loadRelated != nil
            guard comments || upNext else { return }
            if !upNext { panelTab = .comments } else if !comments { panelTab = .upNext }
            panelVisible.toggle()
            if panelVisible { loadPanel() }
        case .saveOffline:
            if let item { onSaveOffline?(item) }
        case .toggleSubscription:
            if let item { onToggleSubscription?(item) }
        case .undoSkip:
            if let start = skipper?.undo() {
                seek(to: start)
                skipNoticeTask?.cancel()
                skipNotice = nil
            }
        default: player.perform(c)
        }
    }

    /// Only toggles a window that is in fullscreen now.
    private func leaveFullscreen() {
        guard isFullscreen, let window = fullscreenWindow, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    var qualityChoices: [QualityChoice] { QualityChoice.list(saved: hasSavedCopy, heights: qualities) }

    /// What's playing: the download, or the stream at the chosen cap.
    var selectedQuality: QualityChoice { playingSaved ? .saved : maxHeight.map(QualityChoice.height) ?? .best }

    func qualityMenu(_ key: QualityMenuKey) {
        commandCount += 1
        guard let i = qualityMenuIndex else { return }
        switch key {
        case .up: qualityMenuIndex = max(i - 1, 0)
        case .down: qualityMenuIndex = min(i + 1, qualityChoices.count - 1)
        case .close: qualityMenuIndex = nil
        case .apply:
            qualityMenuIndex = nil
            setQuality(qualityChoices[i])
        }
    }

    /// Switches to the download, or re-resolves the stream at the chosen cap, and reloads where it is, keeping the
    /// pause state. The queue stays as it is.
    func setQuality(_ choice: QualityChoice) {
        guard item != nil, choice != selectedQuality else { return }
        switch choice {
        case .saved: streamSaved = false
        case .best: streamSaved = true; maxHeight = nil
        case .height(let h): streamSaved = true; maxHeight = h
        }
        reload()
    }

    /// Resolves the current video again (at `maxHeight`) and reloads it where it was, keeping the pause state.
    private func reload() {
        guard let item else { return }
        saveHistory()
        let at = started ? position : nil
        openTask?.cancel()
        let token = session.begin()
        phase = .resolving
        isBuffering = false
        stalledAt = nil
        loaded = false
        fileLoaded = false
        started = false
        openedAt = .now
        player.stop()
        openTask = Task { await run(item, token, start: at) }
    }

    func seek(to seconds: Double) {
        position = seconds
        player.seek(to: seconds)
    }
    func currentFrame() async -> CGImage? { await player.currentFrame() }
    func setVolume(_ v: Double) { player.set(volume: v) }
    func setSpeed(_ s: Double) { player.set(speed: s) }

    /// Starts resolving a video the user may open next.
    func prefetch(_ videoId: String) {
        let resolver = resolver
        let maxHeight = Self.defaultMaxHeight
        Task { await resolver.prefetch(videoId, maxHeight: maxHeight) }
    }

    /// Opens the current video in Brave (the needs-account action); shared by the button and Return.
    func openInBrave() {
        guard let videoId = item?.videoId else { return }
        braveError = nil
        let profile = UserDefaults.standard.string(forKey: "braveProfile") ?? ""
        Task {
            do { try await BraveLauncher.open(videoId: videoId, profile: profile) }
            catch { braveError = error.localizedDescription }
        }
    }

    func saveHistory() {
        guard let item, started else { return }
        lastSave = .now
        let entry = HistoryEntry(videoId: item.videoId, title: item.title, channelId: item.channelId, channelName: item.channelName,
                                 lengthSeconds: item.lengthSeconds ?? duration.map { Int($0) }, publishedAt: item.publishedAt, watchedAt: .now, positionSeconds: position)
        do { try store.upsert([entry]) } catch { logger.error("history save failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Opening

    /// Settings' "Default quality": 0 is Best.
    private static var defaultMaxHeight: Int? {
        let h = UserDefaults.standard.integer(forKey: "defaultQuality")
        return h > 0 ? h : nil
    }

    /// `start` overrides the item's `startAt` and the history's resume position (a quality change reloads where it was).
    private func run(_ item: Item, _ token: Int, start: Double? = nil) async {
        let file = localFile(for: item)
        hasSavedCopy = file != nil
        if let file, !streamSaved {
            // A saved download plays without resolving, so it works offline; SponsorBlock falls back to stored segments.
            let at = start ?? item.startAt ?? resumePosition(for: item)
            position = at
            playingSaved = true
            currentHeight = savedHeight
            phase = .loading
            loaded = true
            player.loadFile(file, start: at)
            if savedHeight == nil { readSavedHeight(file, token) }
            if qualities.isEmpty { lookUpStreamQualities(item.videoId, token) }
            return
        }
        playingSaved = false
        do {
            let resolveStart = ContinuousClock.now
            let resolved = try await resolver.resolve(item.videoId, maxHeight: maxHeight)
            guard session.isCurrent(token) else { return }
            fillMetadata(from: resolved)
            let elapsed = ContinuousClock.now - resolveStart
            resolveMs = Int(elapsed / .milliseconds(1))
            cached = elapsed < .milliseconds(20)   // the resolver does not say whether it hit its cache
            while let n = StartDelay.seconds(until: resolved.availableAt, now: .now) {
                phase = .waiting(seconds: n)
                let remaining = resolved.availableAt?.timeIntervalSinceNow ?? 0
                try await Task.sleep(for: .seconds(min(1, remaining + 0.3)))
                guard session.isCurrent(token) else { return }
            }
            guard MPVLoadPlan.isAcceptable(resolved) else {
                phase = .failed(.other("Unexpected stream address."))
                return
            }
            let start = start ?? item.startAt ?? resumePosition(for: item)
            position = start
            qualities = resolved.qualities
            currentHeight = resolved.height > 0 ? resolved.height : nil
            phase = .loading
            loaded = true
            player.load(resolved, start: start)
        } catch is CancellationError {
        } catch {
            guard session.isCurrent(token) else { return }
            phase = .failed(PlaybackFailure.classify(error))
        }
    }

    /// Fills `savedHeight` (and the menu's label) from the file's video track.
    private func readSavedHeight(_ file: URL, _ token: Int) {
        Task {
            guard let track = try? await AVURLAsset(url: file).loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize), session.isCurrent(token) else { return }
            savedHeight = Int(size.height.rounded())
            if playingSaved { currentHeight = savedHeight }
        }
    }

    /// Resolves a downloaded video in the background so its quality list can offer the streams too. Offline, the
    /// list keeps just the file and Best.
    private func lookUpStreamQualities(_ videoId: String, _ token: Int) {
        let resolver = resolver, cap = maxHeight
        Task {
            guard let r = try? await resolver.resolve(videoId, maxHeight: cap), session.isCurrent(token) else { return }
            qualities = r.qualities
        }
    }

    /// The finished download's file, unless it was removed meanwhile (then the video streams). Fills a pasted
    /// link's metadata from the download row.
    private func localFile(for item: Item) -> URL? {
        guard let d = try? store.download(videoId: item.videoId),
              let file = LocalCopy.file(for: d, exists: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        if var current = self.item, current.videoId == d.videoId, current.title.isEmpty {
            current.title = d.title
            current.channelName = d.channelName
            current.channelId = d.channelId
            current.lengthSeconds = d.lengthSeconds
            self.item = current
            if duration == nil { duration = d.lengthSeconds.map(Double.init) }
        }
        return file
    }

    /// A pasted link opens with no metadata; the resolve supplies it, so the player, banner and history show real values.
    private func fillMetadata(from r: Resolved) {
        guard var current = item, current.title.isEmpty else { return }
        current.title = r.title ?? ""
        current.channelName = r.channel ?? ""
        current.channelId = r.channelId
        current.lengthSeconds = r.duration.map { Int($0) }
        item = current
        if duration == nil { duration = r.duration }
    }

    /// Resumes past 10 s, unless the video was nearly over.
    private func resumePosition(for item: Item) -> Double {
        guard let entry = try? store.historyEntry(videoId: item.videoId), entry.positionSeconds > 10 else { return 0 }
        if let length = item.lengthSeconds ?? entry.lengthSeconds, entry.positionSeconds >= Double(length) - 15 { return 0 }
        return entry.positionSeconds
    }

    // MARK: Player events

    private func timeChanged(_ newPosition: Double, _ newDuration: Double?) {
        guard fileLoaded else { return }
        let first = !started
        started = true
        position = newPosition
        if let newDuration { duration = newDuration }
        if let segment = skipper?.check(position: newPosition) { skip(segment) }
        if first || Date.now.timeIntervalSince(lastSave) >= 10 { saveHistory() }
    }

    // MARK: Comments

    /// Loads the current video's comments unless they're loaded or loading; a newer video cancels an older load.
    private func loadCommentsIfNeeded() {
        guard let id = item?.videoId, let loadComments else { return }
        if commentsVideoId == id, commentsStatus != .idle, !isFailed(commentsStatus) { return }
        commentsTask?.cancel()
        commentsVideoId = id
        comments = []
        commentCount = nil
        commentsCursor = nil
        commentSelection = 0
        repliesCursor = nil
        replyThreads = [:]
        moreComments = .idle
        commentsStatus = .loading
        commentsTask = Task {
            do {
                let page = try await loadComments(id)
                guard !Task.isCancelled, commentsVideoId == id else { return }
                comments = page.comments
                commentCount = page.count
                commentsCursor = page.done ? nil : page.cursor
                repliesCursor = page.cursor
                commentsStatus = .loaded
            } catch is CancellationError {
            } catch {
                guard commentsVideoId == id else { return }
                commentsStatus = .failed(PlaybackFailure.classify(error).message)
            }
        }
    }

    /// The next page, when the panel has scrolled to the last comment (or after a failed page, on "Try again").
    func loadNextComments() {
        guard commentsStatus == .loaded, moreComments != .loading, let cursor = commentsCursor, let loadMoreComments,
              let id = commentsVideoId else { return }
        moreComments = .loading
        commentsTask = Task {
            do {
                let page = try await loadMoreComments(cursor)
                guard !Task.isCancelled, commentsVideoId == id else { return }
                let seen = Set(comments.map(\.id))   // ForEach needs unique ids
                comments += page.comments.filter { !seen.contains($0.id) }
                commentsCursor = page.done ? nil : commentsCursor
                moreComments = .idle
            } catch is CancellationError {
            } catch {
                guard commentsVideoId == id else { return }
                moreComments = .failed(PlaybackFailure.classify(error).message)
            }
        }
    }

    private func loadPanel() {
        if panelTab == .comments, Self.commentsEnabled { loadCommentsIfNeeded() }
        if panelTab == .upNext, Self.upNextEnabled { loadUpNextIfNeeded() }
    }

    // MARK: Up next

    /// The current video's suggestions unless loaded or loading; a newer video cancels an older load.
    private func loadUpNextIfNeeded() {
        guard let id = item?.videoId, let loadRelated else { return }
        if upNextVideoId == id, upNextStatus != .idle, !isFailed(upNextStatus) { return }
        upNextTask?.cancel()
        upNextVideoId = id
        upNext = []
        upNextSelection = 0
        upNextStatus = .loading
        upNextTask = Task {
            do {
                let videos = try await loadRelated(id)
                guard !Task.isCancelled, upNextVideoId == id else { return }
                upNext = videos.filter { $0.id != id }
                upNextStatus = .loaded
            } catch is CancellationError {
            } catch {
                guard upNextVideoId == id else { return }
                upNextStatus = .failed(PlaybackFailure.classify(error).message)
            }
        }
    }

    /// The panel's keys: the tab shown is the one acted on.
    func panelKey(_ key: PanelKey) {
        let both = Self.upNextEnabled && Self.commentsEnabled
        let tab = Self.upNextEnabled ? (both ? panelTab : .upNext) : .comments
        switch key {
        case .close:
            panelVisible = false
        case .switchTab:
            if both { panelTab = panelTab == .upNext ? .comments : .upNext }
        case .up, .down:
            let step = key == .up ? -1 : 1
            if tab == .upNext {
                upNextSelection = max(0, min(upNext.count - 1, upNextSelection + step))
            } else {
                commentSelection = max(0, min(comments.count - 1, commentSelection + step))
                if commentSelection >= comments.count - 10 { loadNextComments() }
            }
        case .activate:
            if tab == .upNext {
                if isFailed(upNextStatus) { loadUpNextIfNeeded() }
                else if upNext.indices.contains(upNextSelection) { playUpNext(upNext[upNextSelection]) }
            } else if isFailed(commentsStatus) {
                loadCommentsIfNeeded()
            } else if comments.indices.contains(commentSelection), comments[commentSelection].hasReplies {
                // Open the replies, then each Return loads ten more, and once they're all shown it hides them.
                let id = comments[commentSelection].id
                let thread = replyThreads[id]
                if let thread, thread.expanded, isFailed(thread.status) || !thread.done {
                    loadMoreReplies(of: id)
                } else {
                    toggleReplies(of: id)
                }
            }
        }
    }

    /// Plays a suggestion on its own (it gets its own Up next); without one given, the first.
    func playUpNext(_ entry: ListedEntry? = nil) {
        guard Self.upNextEnabled, let e = entry ?? upNext.first else { return }
        open(Item(videoId: e.id, title: e.title, channelName: e.channel ?? "", channelId: e.channelId,
                  lengthSeconds: e.duration, publishedAt: nil))
    }

    /// Shows or hides a comment's replies; the first time, fetches the first ten.
    func toggleReplies(of id: String) {
        var thread = replyThreads[id] ?? ReplyThread()
        thread.expanded.toggle()
        replyThreads[id] = thread
        if thread.expanded, thread.replies.isEmpty { loadMoreReplies(of: id) }
    }

    /// The next ten replies ("Show more replies", or "Try again" after a failure).
    func loadMoreReplies(of id: String) {
        guard let cursor = repliesCursor, let loadReplies, let videoId = commentsVideoId else { return }
        var thread = replyThreads[id] ?? ReplyThread()
        guard thread.status != .loading, !thread.done else { return }
        thread.status = .loading
        replyThreads[id] = thread
        Task {
            do {
                let page = try await loadReplies(cursor, id)
                guard commentsVideoId == videoId, var thread = replyThreads[id] else { return }
                let seen = Set(thread.replies.map(\.id))
                thread.replies += page.replies.filter { !seen.contains($0.id) }
                thread.done = page.done
                thread.status = .idle
                replyThreads[id] = thread
            } catch {
                guard commentsVideoId == videoId, var thread = replyThreads[id] else { return }
                thread.status = .failed(PlaybackFailure.classify(error).message)
                replyThreads[id] = thread
            }
        }
    }

    private func isFailed(_ s: CommentsStatus) -> Bool { if case .failed = s { true } else { false } }

    // MARK: SponsorBlock

    /// Fetches segments alongside the resolve; a quality change keeps the video, so it keeps them too.
    private func loadSegments(for videoId: String) {
        segmentsTask?.cancel()
        skipper = nil
        skipNoticeTask?.cancel()
        skipNotice = nil
        guard let sponsorBlock else { return }
        segmentsTask = Task {
            let segments = await sponsorBlock.segments(for: videoId)
            guard !Task.isCancelled, item?.videoId == videoId else { return }
            skipper = SponsorSkipper(segments: segments, enabled: SponsorBlock.enabledCategories(.standard))
        }
    }

    private func skip(_ segment: SponsorSegment) {
        seek(to: segment.end)
        let name = SponsorBlock.categories.first { $0.id == segment.category }?.title ?? segment.category
        skipNotice = "Skipped \(name) · U to undo"
        skipNoticeTask?.cancel()
        skipNoticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { skipNotice = nil }
        }
    }

    private func buffering(_ waiting: Bool) {
        isBuffering = waiting
        if waiting { stalledAt = .now; return }
        guard let stalledAt else { return }
        self.stalledAt = nil
        logger.info("PLAYTIMING stall=\(Int((ContinuousClock.now - stalledAt) / .milliseconds(1)), privacy: .public) at=\(Int(self.position), privacy: .public)")
    }

    private func firstFrame() {
        guard phase == .loading else { return }
        phase = .playing
        // Now, not at open: the video has started, so these don't compete with it, and they're usually ready before
        // the panel opens.
        if Self.commentsEnabled { loadCommentsIfNeeded() }
        if Self.upNextEnabled { loadUpNextIfNeeded() }
        if let queue, queue.position + 1 < queue.count {
            var upcoming = queue
            if let next = upcoming.next() { prefetch(next.videoId) }
        }
        let total = Int((ContinuousClock.now - openedAt) / .milliseconds(1))
        let line = "PLAYTIMING open→firstFrame=\(total) resolve=\(resolveMs) cached=\(cached)"
        logger.info("\(line, privacy: .public)")
        if UserDefaults.standard.bool(forKey: "playtiming") { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }

    /// End of file: only a real end of the file now playing advances the queue; a dropped stream shows an error.
    private func endOfFile() {
        let hasNext = queue.map { $0.position + 1 < $0.count } ?? false
        switch PlaybackEnd.decide(isPlaying: phase == .playing, fileLoaded: fileLoaded, position: position, duration: duration,
                                  streamFailure: player.streamFailure, hasNext: hasNext) {
        case .ignore: break
        case .stay:
            saveHistory()
            leaveFullscreen()
        case .advance: advance { $0.next() }   // start() saves the history
        case .failed(let message):
            saveHistory()
            loadFailed(message)
        }
    }

    private func loadFailed(_ message: String) {
        guard loaded else { return }
        if message.contains("403"), !retriedRefused, let videoId = item?.videoId {
            // Usually stale URLs (resolved on another network, or kept since an earlier launch): resolve afresh once.
            retriedRefused = true
            let resolver = resolver
            Task {
                await resolver.invalidate(videoId)
                guard item?.videoId == videoId else { return }
                reload()
            }
            return
        }
        phase = .failed(message.contains("403") ? .other("YouTube refused the stream. Try again.") : .other(message))
    }
}
