import Foundation
import MatineeKit
import Observation
import os

struct SearchRow: Identifiable, Equatable {
    let entry: ListedEntry
    /// DeArrow's title for videos when enabled and available, else the listing's.
    let title: String
    /// DeArrow's thumbnail for videos when enabled and available, a channel's avatar, else nil (the placeholder).
    let thumbnail: URL?
    let progress: Double?
    let subscribed: Bool
    var id: String { entry.id }
}

struct Suggestion: Identifiable, Equatable {
    let text: String
    var id: String { text }
}

/// The Search section: query, filters, paged results and suggestions. Created once by the app, so its
/// state survives section switches and the player. Everything slow runs in tasks; no method waits.
@MainActor @Observable
final class SearchModel {
    /// YouTube's first search API page often has only ~19 usable entries, so 20 would cost a second call.
    private static let firstPageSize = 15
    private static let pageSize = 20
    private static let log = Logger(subsystem: "local.kirakirag.matinee", category: "search")

    var query = ""
    var filter = SearchFilter()
    var selection: String?
    /// The query the current results are for.
    private(set) var searched: String?
    private(set) var rows: [SearchRow] = []
    private(set) var suggestions: [Suggestion] = []
    private(set) var error: String?
    private(set) var isSearching = false
    private(set) var isLoadingMore = false
    /// Shown under the results, e.g. a subscription that couldn't be saved.
    private(set) var notice: String?
    /// Set when the results were asked to take focus before the first page arrived: its first row gets selected.
    var selectFirstOnArrival = false

    private let store: Store
    private let worker: WorkerClient
    private let dearrow: DeArrowService
    private let suggestionService: SuggestionService

    private var pager = SearchPager()
    private var gate = SuggestionGate()
    private var suggestionTask: Task<Void, Never>?
    private var entries: [ListedEntry] = []
    /// The furthest row the list has shown for the current results.
    private var lastShown = -1
    private var progress: [String: Double] = [:]
    private var branding: [String: Branding] = [:]
    /// Set by the app: which channel rows show "Subscribed".
    @ObservationIgnored var subscriptions: Subscriptions?

    init(store: Store, worker: WorkerClient, dearrow: DeArrowService, suggestions: SuggestionService) {
        self.store = store
        self.worker = worker
        self.dearrow = dearrow
        self.suggestionService = suggestions
    }

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searched = query
        gate.submit()
        suggestionTask?.cancel()
        suggestions = []
        error = nil
        notice = nil
        selectFirstOnArrival = false
        isSearching = true
        isLoadingMore = false
        // The old results go at once, so the spinner shows instead of results for the previous query.
        entries = []
        lastShown = -1
        selection = nil
        rebuild()
        let token = pager.start()
        let url = YouTubeURL.search(q, filter)
        let started = ContinuousClock.now
        Task {
            do {
                let page = try await worker.list(url, first: Self.firstPageSize)
                Self.log.info("SEARCHTIMING list=\((ContinuousClock.now - started) / .milliseconds(1), privacy: .public) ms")
                guard let new = pager.received(page, token: token) else { return }
                isSearching = false
                entries = new
                // A selection the user made while loading stays; a request to focus the results selects the first row.
                if selectFirstOnArrival, selection == nil { selection = new.first?.id }
                selectFirstOnArrival = false
                rebuild()
                decorate(new)
                prefetch()
            } catch {
                guard pager.failed(token: token) else { return }
                isSearching = false
                entries = []
                rebuild()
                self.error = Self.message(for: error)
            }
        }
    }

    /// Re-runs the last search with the current filters.
    func filterChanged() {
        guard let searched else { return }
        query = searched
        search()
    }

    func loadMore() {
        guard let cursor = pager.cursor, let token = pager.loadMore() else { return }
        isLoadingMore = true
        Task {
            do {
                let page = try await worker.more(cursor: cursor, n: Self.pageSize)
                guard let new = pager.received(page, token: token) else { return }
                isLoadingMore = false
                entries += new
                rebuild()
                decorate(new)
                prefetch()   // also covers a page of only repeats, which changes nothing on screen
            } catch {
                guard pager.failed(token: token) else { return }
                isLoadingMore = false
                notice = Self.message(for: error)
            }
        }
    }

    /// A background prefetch stays quiet; the spinner shows only once the user has reached the last row.
    var waitingForMore: Bool { isLoadingMore && lastShown >= rows.count - 1 }

    func rowShown(_ row: Int) {
        lastShown = max(lastShown, row)
        prefetch()
    }

    /// Keeps two pages loaded below the furthest row shown, so scrolling rarely waits on YouTube.
    private func prefetch() {
        if pager.wantsMore(rows: rows.count, lastShown: lastShown) { loadMore() }
    }

    /// Fetches suggestions 150 ms after the last keystroke; late answers are dropped by the gate.
    func queryChanged() {
        suggestionTask?.cancel()
        let token = gate.begin()
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty, q != searched else { suggestions = []; return }
        let service = suggestionService
        suggestionTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let list = (try? await service.suggestions(for: q)) ?? []
            guard gate.accepts(token) else { return }
            suggestions = list.map(Suggestion.init)
        }
    }

    /// Loads progress and DeArrow branding for newly shown entries, then rebuilds the rows.
    private func decorate(_ new: [ListedEntry]) {
        let store = store, dearrow = dearrow
        let videoIds = new.filter { $0.kind == .video }.map(\.id)
        Task {
            progress = await Task.detached { (try? store.progress()) ?? [:] }.value
            rebuild()
            guard !videoIds.isEmpty else { return }
            branding.merge(await dearrow.branding(for: videoIds)) { $1 }
            rebuild()
        }
    }

    /// Recomputes rows after new data or a DeArrow settings change.
    func rebuild() {
        let defaults = UserDefaults.standard
        let useTitles = defaults.object(forKey: "dearrowTitles") as? Bool ?? true
        let useThumbnails = defaults.object(forKey: "dearrowThumbnails") as? Bool ?? true
        rows = entries.map { e in
            let b = e.kind == .video ? branding[e.id] : nil
            let dearrowThumb = useThumbnails ? b?.thumbnailTime.flatMap { DeArrow.thumbnailURL(videoId: e.id, time: $0) } : nil
            return SearchRow(entry: e,
                             title: (useTitles ? b?.title : nil) ?? e.title,
                             thumbnail: e.kind == .channel ? e.thumbnail : dearrowThumb,
                             progress: e.kind == .video ? progress[e.id] : nil,
                             subscribed: e.kind == .channel && subscriptions?.contains(e.id) == true)
        }
    }

    /// Network failures get PlaybackFailure's short messages; anything else shows the worker's message.
    private static func message(for error: any Error) -> String {
        let failure = PlaybackFailure.classify(error)
        switch failure {
        case .network, .timedOut: return failure.message
        default:
            if case .failed(let message)? = error as? WorkerError { return "Search failed: \(message.prefix(200))" }
            return "Search failed: \(failure.message)"
        }
    }
}
