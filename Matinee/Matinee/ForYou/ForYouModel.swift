import CoreGraphics
import Foundation
import MatineeKit
import Observation
import OSLog

/// For You: the videos YouTube suggests next to your recent history, ranked together on the Mac (Recommender), then
/// reweighted by how much their titles are like what you watched (TitleSimilarity, an on-device model).
/// Lists come from RelatedService's cache when fresh, so only new or stale history items cost a request.
/// With "Local AI ranking" (LocalModels) the list shows as above at once, then is refined in the background: e5
/// reweights by title and description instead of Apple's title model, and the JevK5 judge re-sorts the top 40.
@MainActor @Observable
final class ForYouModel {
    /// Settings' "Up next and For You"; on by default.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "recommendations") as? Bool ?? true }
    /// Recent history items whose suggestions are ranked.
    private static let seedCount = 20
    /// At once: the list worker runs four requests in parallel.
    private static let parallel = 4

    private(set) var rows: [SearchRow] = []
    private(set) var isLoading = false
    /// Lists fetched or read so far, of `seedTotal`.
    private(set) var loaded = 0
    private(set) var seedTotal = 0
    private(set) var hasHistory = true
    private(set) var error: String?
    /// "Refining…" while the local models work on the list already shown.
    private(set) var isRefining = false
    /// Set by the app: "Local AI ranking"'s models, and the worker's paced description fetch.
    @ObservationIgnored var localModels: LocalModels?
    @ObservationIgnored var describe: (([String]) async throws -> (descriptions: [String: String], stopped: Bool))?
    /// Set by the app: subscribed channels count less (the feed has them).
    @ObservationIgnored var subscriptions: Subscriptions?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let related: RelatedService
    @ObservationIgnored private let dearrow: DeArrowService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var seeds: [String] = []
    @ObservationIgnored private var lists: [String: [ListedEntry]] = [:]
    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private var ranked: [ListedEntry] = []
    @ObservationIgnored private var branding: [String: Branding] = [:]
    @ObservationIgnored private var affinity: [String: Double] = [:]
    @ObservationIgnored private var history: [(id: String, title: String)] = []
    /// Watches per channel in the last 100.
    @ObservationIgnored private var channelWatches: [String: Int] = [:]
    /// "Not interested", newest first: hidden, and taught to the title model as dislikes.
    @ObservationIgnored private var dismissals: [Dismissal] = []
    /// This session's, newest last, for ⌘Z.
    @ObservationIgnored private var undoable: [Dismissal] = []
    @ObservationIgnored private var candidates: [(id: String, title: String)] = []
    /// Store writes in order, so an undo can't be overtaken by its dismissal.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    /// Caches each title's vector, in memory and in the store across launches.
    @ObservationIgnored private let similarity: TitleSimilarity
    /// Apple's title model's affinity, the fallback; `e5Affinity` replaces it while local AI ranking has one.
    @ObservationIgnored private var e5Affinity: [String: Double]?
    /// The judge's order of its top 40, put first; for the profile it was made for.
    @ObservationIgnored private var judgedOrder: [String] = []
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var embedder: E5Embedder?
    /// Set by the app: a video is playing or loading, so background ranking waits (the GPU work could stutter it).
    @ObservationIgnored var isPlaying: (() -> Bool)?
    @ObservationIgnored private var awayTimer: Timer?
    /// While a background ranking runs: stops it as soon as the Mac is used again.
    @ObservationIgnored private var returnWatch: Timer?
    /// No keyboard, mouse or trackpad input on the Mac, in any app, for this long counts as away.
    private static let idleSeconds: Double = 600
    /// `Store.profileStamp()` when the current ranking was made.
    @ObservationIgnored private var rankedStamp: [Double]?
    /// The setting as last seen, to act on changes made in Settings while For You isn't on screen.
    @ObservationIgnored private var localEnabled = LocalModels.isEnabled
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    /// YouTube throttled the description fetch: no more this session.
    @ObservationIgnored private var descriptionsStopped = false
    /// The full history, newest first, for the judge's profile.
    @ObservationIgnored private var recentWatches: [HistoryEntry] = []
    /// Description fetches per refresh, at a second each (the worker paces them).
    private static let descriptionBudget = 60
    /// Candidates the judge reads.
    private static let judged = 40

    init(store: Store, related: RelatedService, dearrow: DeArrowService) {
        self.store = store
        self.related = related
        self.dearrow = dearrow
        similarity = TitleSimilarity(store: store)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, LocalModels.isEnabled != self.localEnabled else { return }
                self.localEnabled = LocalModels.isEnabled
                self.localModelsChanged()
            }
        }
    }

    /// Keeps For You ranked while the Mac isn't in use: once there's been no input on it for 10 minutes and no video
    /// is playing, a changed profile (a watch, an import, a dismissal) is ranked again in the background, so opening
    /// For You finds it ready. Never while you're using the Mac. Checked every minute while Matinee runs (it keeps
    /// running with its window closed).
    func startBackgroundRanking() {
        guard awayTimer == nil else { return }
        awayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rankIfAway() }
        }
        awayTimer?.tolerance = 20
    }

    private func rankIfAway() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard Self.isEnabled, idle >= Self.idleSeconds, !(isPlaying?() ?? false), task == nil else { return }
        Logger(subsystem: "local.kirakirag.matinee", category: "ForYou")
            .info("background: Mac idle \(Int(idle), privacy: .public) s, checking the profile")
        load()   // a no-op when nothing changed since the last ranking
        returnWatch?.invalidate()
        returnWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopIfBack() }
        }
    }

    /// Back at the Mac during a background ranking: stop now and finish in the next idle period.
    private func stopIfBack() {
        guard task != nil || isRefining else {
            returnWatch?.invalidate()
            returnWatch = nil
            return
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 5 else { return }
        task?.cancel()
        stopRefining()
        rankedStamp = nil
        returnWatch?.invalidate()
        returnWatch = nil
    }

    /// Ranks again from the current history; lists still fresh come from the cache. Opening For You (`force` false)
    /// re-ranks only when a watch, an import or a dismissal changed the profile since the last ranking: running the
    /// models again on every visit would cost a judge run per key press when switching sections quickly. ⌘R forces it.
    func load(force: Bool = false) {
        guard Self.isEnabled, task == nil else { return }
        task = Task {
            let store = store
            let stamp = await Task.detached { try? store.profileStamp() }.value
            if force || stamp == nil || stamp != rankedStamp || rows.isEmpty {
                await run()
                rankedStamp = error == nil ? stamp : nil
            }
            task = nil
        }
    }

    private func run() async {
        stopRefining()
        isLoading = true
        error = nil
        let store = store
        let (history, dismissals) = await Task.detached {
            // Matinee's history and the watches imported from Google Takeout, one per video, most recent first.
            let own = (try? store.history()) ?? [], imported = (try? store.importedWatches(limit: 1_000_000)) ?? []
            var seen = Set<String>()
            let merged = (own + imported).sorted { $0.watchedAt > $1.watchedAt }.filter { seen.insert($0.videoId).inserted }
            return (merged, (try? store.dismissals()) ?? [])
        }.value
        self.dismissals = dismissals
        recentWatches = Array(history.prefix(50))
        watched = Set(history.map(\.videoId))
        seeds = Array(history.prefix(Self.seedCount).map(\.videoId))
        self.history = history.prefix(Self.seedCount).map { ($0.videoId, $0.title) }
        channelWatches = history.prefix(100).compactMap(\.channelId).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        affinity = [:]
        hasHistory = !seeds.isEmpty
        lists = [:]
        loaded = 0
        seedTotal = seeds.count
        let related = related, seeds = seeds
        await withTaskGroup(of: (String, [ListedEntry]?).self) { group in
            var next = 0
            func start() {
                guard next < seeds.count else { return }
                let id = seeds[next]
                next += 1
                group.addTask { (id, try? await related.related(id)) }
            }
            for _ in 0..<Self.parallel { start() }
            for await (id, list) in group {
                loaded += 1
                if let list { lists[id] = list }
                rank()   // rows fill in as lists arrive
                start()
            }
        }
        if lists.isEmpty, !seeds.isEmpty { error = "Couldn't load recommendations. Check the connection and press ⌘R." }
        // Every candidate, not only the current top: the model may lift one from further down.
        var seen = Set<String>()
        candidates = lists.values.joined().filter { !watched.contains($0.id) && seen.insert($0.id).inserted }
            .map { (id: $0.id, title: $0.title) }
        await learn()
        isLoading = false
        branding = await dearrow.branding(for: ranked.map(\.id))
        rebuild()
        refine()
    }

    /// The title model from the history (liked) and the dismissals (disliked), then a new ranking.
    private func learn() async {
        affinity = await similarity.affinity(history: history, candidates: candidates,
                                             disliked: dismissals.map { ($0.videoId, $0.title) })
        rank()
    }

    private func rank() {
        let local = e5Affinity != nil && LocalModels.isEnabled
        let order = Recommender.rank(seeds: seeds.compactMap { id in lists[id].map { (id, $0) } }, watched: watched,
                                     subscribed: subscriptions?.ids ?? [], affinity: local ? e5Affinity! : affinity,
                                     affinityWeight: local ? Recommender.e5AffinityWeight : Recommender.affinityWeight, channelWatches: channelWatches,
                                     hiddenVideos: Set(dismissals.map(\.videoId)),
                                     hiddenChannels: Set(dismissals.filter(\.hidesChannel).compactMap(\.channelId)))
        // The judge's top first, as far as those videos are still in the list (a dismissal removes one).
        let judged = local ? judgedOrder : []
        let byId = Dictionary(order.map { ($0.id, $0) }) { a, _ in a }
        let first = judged.compactMap { byId[$0] }
        let placed = Set(first.map(\.id))
        ranked = first + order.filter { !placed.contains($0.id) }
        rebuild()
    }

    // MARK: Local AI ranking

    /// "Local AI ranking" turned on or off in Settings, or its models arrived: off drops back to the title model at once.
    func localModelsChanged() {
        if LocalModels.isEnabled {
            refine()
        } else {
            stopRefining()
            e5Affinity = nil
            judgedOrder = []
            embedder = nil
            rank()
        }
    }

    private func stopRefining() {
        refineTask?.cancel()
        refineTask = nil
        isRefining = false
    }

    /// The profile a refinement was made for: the seeds and the dismissals. Results for another are dropped.
    private var profileKey: [String] { seeds + ["|"] + dismissals.map(\.videoId) }

    /// Descriptions → e5 affinity → re-rank → judge → re-sort, in the background, over the list already shown.
    private func refine() {
        guard LocalModels.isEnabled, let models = localModels, models.state == .ready, !seeds.isEmpty, !ranked.isEmpty else {
            return
        }
        let previous = refineTask
        stopRefining()
        isRefining = true
        let key = profileKey
        let e5Dir = models.directory(LocalModels.e5), judgeDir = models.directory(LocalModels.judge)
        if embedder == nil { embedder = E5Embedder(directory: e5Dir) }
        let embedder = embedder!
        refineTask = Task {
            // One at a time: a cancelled run may still be loading the judge, and two 8 GB loads mustn't overlap.
            await previous?.value
            defer { if profileKey == key { isRefining = false } }
            let log = Logger(subsystem: "local.kirakirag.matinee", category: "ForYou"), start = ContinuousClock.now
            func elapsed() -> String { String(format: "%.1f s", (ContinuousClock.now - start) / .seconds(1)) }
            do {
                try Task.checkCancellation()
                // 1. Descriptions for the history and the top candidates, at most 60 fetched.
                let wanted = seeds + ranked.prefix(Self.descriptionBudget).map(\.id)
                let descriptions = try await self.descriptions(for: wanted)
                try Task.checkCancellation()
                log.info("refine: \(descriptions.count) descriptions known at \(elapsed(), privacy: .public)")
                // 2. e5 over every candidate, the history and the dismissals.
                let titles = Dictionary((history + candidates + dismissals.map { ($0.videoId, $0.title) }).map { ($0.0, $0.1) }) { a, _ in a }
                let vectors = try await self.e5Vectors(titles: titles, descriptions: descriptions, embedder: embedder)
                try Task.checkCancellation()
                guard profileKey == key else { return }
                let pick = { (ids: [String]) in ids.compactMap { id in vectors[id].map { (id: id, vector: $0) } } }
                let affinity = VectorSimilarity.affinity(history: pick(history.map(\.id)), candidates: pick(candidates.map(\.id)),
                                                         disliked: pick(dismissals.map(\.videoId)))
                e5Affinity = affinity
                rank()   // the previous judged order stays on top until the new verdicts arrive
                log.info("refine: e5 over \(vectors.count) videos, re-ranked at \(elapsed(), privacy: .public)")
                // 3. The judge on the new top 40.
                let top = Array(ranked.prefix(Self.judged))
                let profile = JudgePrompt.profile(
                    subscriptions: (subscriptions?.channels ?? []).map(\.name),
                    recent: recentWatches.map { h in
                        (h.title, h.channelName, h.lengthSeconds.flatMap { $0 > 0 ? h.positionSeconds / Double($0) : nil })
                    },
                    dismissed: dismissals.map(\.title))
                let judge = JevJudge(directory: judgeDir)
                let logits = try await judge.logits(profile: profile, candidates: top.map {
                    ($0.id, $0.title, $0.channel ?? "", $0.duration)
                })
                try Task.checkCancellation()
                guard profileKey == key, LocalModels.isEnabled else { return }
                judgedOrder = JudgeFusion.resort(top.map(\.id), logits: logits)
                rank()
                log.info("refine: judged \(logits.count) at \(elapsed(), privacy: .public)")
            } catch {
                log.info("refine: stopped (\(String(describing: error), privacy: .public)) at \(elapsed(), privacy: .public)")
                // Cancelled, or a model failed: the list stays as it is (title model or e5 without the judge).
            }
        }
    }

    /// Cached descriptions of `ids`, plus up to 60 fetched for the rest unless YouTube throttled this session.
    private func descriptions(for ids: [String]) async throws -> [String: String] {
        let store = store
        var known = await Task.detached { (try? store.descriptions(ids: ids)) ?? [:] }.value
        let missing = Array(ids.filter { known[$0] == nil }.prefix(Self.descriptionBudget))
        guard !missing.isEmpty, !descriptionsStopped, let describe else { return known }
        do {
            let got = try await describe(missing)
            if got.stopped { descriptionsStopped = true }
            known.merge(got.descriptions) { $1 }
            let fetched = got.descriptions
            await Task.detached { try? store.saveDescriptions(fetched, at: .now) }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The worker failed: titles alone for these this time.
        }
        return known
    }

    /// e5 vectors by id, from the store when they were made from the same text, else embedded now and saved.
    private func e5Vectors(titles: [String: String], descriptions: [String: String], embedder: E5Embedder) async throws
        -> [String: [Float]] {
        let store = store, ids = Array(titles.keys)
        let stored = await Task.detached { (try? store.e5Vectors(ids: ids)) ?? [:] }.value
        var out: [String: [Float]] = [:]
        var todo: [(id: String, text: String)] = []
        for (id, title) in titles {
            let description = descriptions[id]
            if let s = stored[id], s.described || description == nil {
                out[id] = s.vector
            } else {
                let text = description.map { $0.isEmpty ? title : title + ". " + $0 } ?? title
                todo.append((id, "passage: " + text))
            }
        }
        guard !todo.isEmpty else { return out }
        let fresh = try await embedder.vectors(todo)
        out.merge(fresh) { $1 }
        let rows = fresh.map { (id: $0.key, described: descriptions[$0.key] != nil, vector: $0.value) }
        await Task.detached { try? store.saveE5Vectors(rows, at: .now) }.value
        return out
    }

    /// "Not interested" (`x`), or the whole channel (⇧X): gone at once, and similar titles rank lower from now on.
    func dismiss(_ row: SearchRow, channel: Bool) {
        let d = Dismissal(videoId: row.id, title: row.entry.title, channelId: row.entry.channelId,
                          hidesChannel: channel && row.entry.channelId != nil, at: .now)
        dismissals.insert(d, at: 0)
        undoable.append(d)
        rank()   // hidden now; the model catches up below
        write { try $0.dismiss(d) }
        Task { await learn(); refine() }
    }

    /// Takes back the newest dismissal this session; false when there's none.
    @discardableResult func undoDismiss() -> Bool {
        guard let d = undoable.popLast() else { return false }
        dismissals.removeAll { $0.videoId == d.videoId }
        rank()
        write { try $0.undoDismissal(videoId: d.videoId) }
        Task { await learn(); refine() }
        return true
    }

    private func write(_ change: @escaping @Sendable (Store) throws -> Void) {
        let store = store, previous = lastWrite
        lastWrite = Task {
            await previous?.value
            await Task.detached { try? change(store) }.value
        }
    }

    /// Rows after new data or a DeArrow settings change.
    func rebuild() {
        let defaults = UserDefaults.standard
        let useTitles = defaults.object(forKey: "dearrowTitles") as? Bool ?? true
        let useThumbnails = defaults.object(forKey: "dearrowThumbnails") as? Bool ?? true
        rows = ranked.map { e in
            let b = branding[e.id]
            return SearchRow(entry: e, title: (useTitles ? b?.title : nil) ?? e.title,
                             thumbnail: useThumbnails ? b?.thumbnailTime.flatMap { DeArrow.thumbnailURL(videoId: e.id, time: $0) } : nil,
                             progress: nil, subscribed: false)
        }
    }
}
