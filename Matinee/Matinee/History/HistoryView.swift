import MatineeKit
import SwiftUI

struct HistoryItem: Identifiable, Equatable {
    let entry: HistoryEntry
    /// DeArrow's title when enabled and available, else the stored (original) title.
    let title: String
    /// DeArrow's thumbnail when enabled and available; nil shows the placeholder.
    let thumbnail: URL?
    var id: String { entry.id }
}

struct HistoryView: View {
    /// DeArrow is only looked up for the newest rows, as in the feed.
    private static let dearrowLimit = 200

    let store: Store
    let dearrow: DeArrowService
    @Environment(Navigator.self) private var nav
    @Environment(PlaybackController.self) private var player: PlaybackController?
    @Environment(DownloadManager.self) private var downloads: DownloadManager?
    @Environment(Subscriptions.self) private var subscriptions: Subscriptions?

    @AppStorage("dearrowTitles") private var dearrowTitles = true
    @AppStorage("dearrowThumbnails") private var dearrowThumbnails = true
    @State private var all: [HistoryEntry] = []
    @State private var branding: [String: Branding] = [:]
    /// IDs whose DeArrow lookup finished this session (with or without branding); they aren't looked up again.
    @State private var brandingTried: Set<String> = []
    @State private var brandingTask: Task<Void, Never>?
    /// Every entry as a row; `shown` is these filtered by the query.
    @State private var items: [HistoryItem] = []
    @State private var shown: [HistoryItem] = []
    @State private var query = ""
    @State private var showFilter = false
    @State private var loaded = false
    @State private var selection: String?
    @State private var listFocus = 0
    /// Removed with ⌘⌫ this session, newest last: ⌘Z puts them back one by one.
    @State private var removed: [HistoryEntry] = []
    /// The last delete or restore: each waits for the one before, so a quick ⌘Z can't be overtaken by its delete.
    @State private var lastWrite: Task<Void, Never>?
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showFilter {
                TextField("Filter history", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .onKeyPress(.downArrow) {
                        if selection == nil { selection = shown.first?.id }
                        listFocus += 1
                        return .handled
                    }
                    .onKeyPress(.escape) { closeFilter(); return .handled }
                    .padding(8)
            }
            TableList(items: shown, selection: $selection, rowHeight: 78, focusRequest: listFocus,
                      onActivate: { open($0) }, onDwell: { player?.prefetch($0.id) }, onKey: { $1 == "s" ? save($0) : channelKey($0.entry.channelId, $0.entry.channelName, $1) },
                      thumbnailAhead: { $0.thumbnail },
                      contextMenu: [("Copy Link", { nav.copy(YouTubeURL.watchURL(videoId: $0.entry.videoId)) }),
                                    ("Save for Offline", { _ = save($0) }),
                                    ("Remove from History", { remove($0) })]) { item in
                HistoryRow(item: item)
            }
        }
        .overlay {
            if all.isEmpty == false, shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .onChange(of: query) { filter() }
        .onChange(of: dearrowTitles) { rebuild() }
        .onChange(of: dearrowThumbnails) { rebuild() }
        .onChange(of: nav.filterRequest) {
            guard nav.section == .history, nav.paths[.history]?.isEmpty ?? true else { return }
            showFilter = true
            filterFocused = true
        }
        .onChange(of: nav.copyRequest) {
            guard nav.section == .history, nav.paths[.history]?.isEmpty ?? true,
                  let item = shown.first(where: { $0.id == selection }) else { return }
            nav.copy(YouTubeURL.watchURL(videoId: item.entry.videoId))
        }
        .onChange(of: nav.deleteRequest) {
            guard isFront, let item = shown.first(where: { $0.id == selection }) else { return }
            remove(item)
        }
        // ⌘Z puts back the last one removed (a covered or hidden History doesn't take it).
        .background {
            Button("") { undoRemove() }.keyboardShortcut("z", modifiers: .command).opacity(0).allowsHitTesting(false)
                .disabled(removed.isEmpty)
        }
        .onAppear { listFocus += 1 }
        // The stack root reappears on every pop, so loading is tied to entering the section, not to appearing:
        // a pop keeps the list as it was, while coming back to History shows what was watched meanwhile.
        .onChange(of: nav.section) { _, s in if s == .history { Task { await reload() } } }
        .onChange(of: player?.isPresented) { _, shown in if shown == false, nav.section == .history { Task { await reload() } } }
        .task {
            guard !loaded else { return }
            loaded = true
            await reload()
        }
    }

    private var isFront: Bool { nav.section == .history && (nav.paths[.history]?.isEmpty ?? true) }

    /// Removes it at once, the selection moving to the next row; ⌘Z undoes it.
    private func remove(_ item: HistoryItem) {
        if let i = shown.firstIndex(where: { $0.id == item.id }) {
            selection = shown.indices.contains(i + 1) ? shown[i + 1].id : (i > 0 ? shown[i - 1].id : nil)
        }
        let entry = item.entry, store = store
        all.removeAll { $0.videoId == entry.videoId }
        rebuild()
        removed.append(entry)
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            await Task.detached { try? store.deleteHistory(videoId: entry.videoId) }.value
        }
        nav.show(notice: "Removed from History · ⌘Z to undo")
    }

    private func undoRemove() {
        guard let entry = removed.popLast() else { return }
        let store = store, previous = lastWrite
        let write = Task {
            await previous?.value
            await Task.detached { try? store.upsert([entry]) }.value
        }
        lastWrite = write
        Task {
            await write.value
            await reload()
            selection = entry.videoId
        }
    }

    private func reload() async {
        let store = store
        all = await Task.detached { (try? store.history()) ?? [] }.value
        rebuild()
        brandingTask?.cancel()   // a newer reload takes over the lookups the old one hadn't finished
        let task = Task { await applyBranding() }
        brandingTask = task
        await task.value
    }

    /// Cached branding first, then DeArrow's answer, as the feed does, for rows not looked up yet this session,
    /// so reloads with nothing new cost nothing. Display only: history keeps the original titles.
    private func applyBranding() async {
        let store = store, tried = brandingTried
        let ids = all.prefix(Self.dearrowLimit).map(\.videoId).filter { !tried.contains($0) }
        guard !ids.isEmpty else { return }
        let cached = await Task.detached { (try? store.branding(videoIds: ids)) ?? [:] }.value
        guard !Task.isCancelled else { return }
        branding.merge(cached.compactMapValues { c in
            c.title == nil && c.thumbnailTime == nil ? nil : Branding(title: c.title, thumbnailTime: c.thumbnailTime)
        }) { $1 }
        rebuild()
        let fetched = await dearrow.branding(for: ids)
        guard !Task.isCancelled else { return }   // the newer run looks these up again
        brandingTried.formUnion(ids)
        branding.merge(fetched) { $1 }
        rebuild()
    }

    /// Rebuilds every row after new entries, branding or DeArrow settings, then filters.
    private func rebuild() {
        items = all.map { e in
            let b = branding[e.videoId]
            return HistoryItem(entry: e, title: (dearrowTitles ? b?.title : nil) ?? e.title,
                               thumbnail: dearrowThumbnails ? b?.thumbnailTime.flatMap { DeArrow.thumbnailURL(videoId: e.videoId, time: $0) } : nil)
        }
        filter()
    }

    /// Runs per keystroke, so it only filters the rows `rebuild` made.
    private func filter() {
        let q = HistoryFilter.Query(query)
        shown = q.isEmpty ? items : items.filter { q.matches($0.entry.title, $0.title, $0.entry.channelName) }
    }

    private func open(_ item: HistoryItem) {
        let e = item.entry
        player?.open(.init(videoId: e.videoId, title: e.title, channelName: e.channelName, channelId: e.channelId,
                           lengthSeconds: e.lengthSeconds, publishedAt: e.publishedAt,
                           displayTitle: item.title, thumbnailURL: item.thumbnail))
    }

    private func save(_ item: HistoryItem) -> Bool {
        let e = item.entry
        downloads?.save(videoId: e.videoId, title: e.title, channelName: e.channelName, channelId: e.channelId,
                        lengthSeconds: e.lengthSeconds)
        return downloads != nil
    }

    /// `c` opens the video's channel, `d` subscribes to it or unsubscribes.
    private func channelKey(_ id: String?, _ name: String, _ key: Character) -> Bool {
        if key == "d", let subscriptions { subscriptions.toggle(id, name: name); return true }
        guard key == "c", let id, ChannelID.isValid(id) else { return false }
        nav.push(.channel(.id(id), name: name))
        return true
    }

    private func closeFilter() {
        query = ""
        showFilter = false
        listFocus += 1
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    private var entry: HistoryEntry { item.entry }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(videoId: entry.videoId, url: item.thumbnail, channelId: entry.channelId).frame(width: 120)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                Text(entry.channelName).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.watchedAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.tertiary)
                if entry.positionSeconds > 0, let length = entry.lengthSeconds, length > 0 {
                    ProgressView(value: min(entry.positionSeconds / Double(length), 1))
                        .progressViewStyle(.linear).controlSize(.small).frame(maxWidth: 160)
                }
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
