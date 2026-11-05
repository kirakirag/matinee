import MatineeKit
import SwiftUI

struct FeedView: View {
    let model: FeedModel
    @Environment(Navigator.self) private var nav
    @Environment(PlaybackController.self) private var player: PlaybackController?
    @Environment(DownloadManager.self) private var downloads: DownloadManager?
    @Environment(Subscriptions.self) private var subscriptions: Subscriptions?

    @AppStorage("dearrowTitles") private var dearrowTitles = true
    @AppStorage("dearrowThumbnails") private var dearrowThumbnails = true
    @State private var query = ""
    @State private var showFilter = false
    @State private var selection: String?
    @State private var listFocus = 0
    @FocusState private var filterFocused: Bool

    @State private var shown: [FeedRow] = []
    /// Channels instead of their videos; kept across launches.
    @AppStorage("subscriptionsShowChannels") private var showChannels = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("Show", selection: $showChannels) {
                    Text("Videos").tag(false)
                    Text("Channels").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("tab").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
            .padding(.top, 8)
            if showFilter {
                TextField(showChannels ? "Filter channels" : "Filter subscriptions", text: $query)
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
            if showChannels, let subscriptions {
                ChannelsList(subscriptions: subscriptions, query: query, focusRequest: listFocus)
            } else {
                TableList(items: shown, selection: $selection, rowHeight: 78, focusRequest: listFocus,
                          onActivate: { open($0) }, onDwell: { player?.prefetch($0.id) }, onKey: { $1 == "s" ? save($0) : channelKey($0.video.channelId, $0.video.channelName, $1) },
                          thumbnailAhead: { $0.thumbnail ?? Thumbnail.frameURL($0.id) },
                          contextMenu: [("Copy Link", { nav.copy(YouTubeURL.watchURL(videoId: $0.video.videoId)) }),
                                        ("Save for Offline", { _ = save($0) })]) { row in
                    FeedRowView(row: row)
                }
                if let failed = model.lastResult?.failed, !failed.isEmpty {
                    Text("\(failed.count) channels didn't refresh")
                        .font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
        }
        .overlay {
            if !showChannels, !model.rows.isEmpty, shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .onChange(of: query) { filter() }
        .onChange(of: model.rows) { filter() }
        .onChange(of: nav.filterRequest) {
            guard nav.section == .subscriptions, nav.paths[.subscriptions]?.isEmpty ?? true else { return }
            showFilter = true
            filterFocused = true
        }
        .onChange(of: showChannels) { listFocus += 1 }
        // Tab switches Videos and Channels, from the list or the filter field.
        .background {
            Button("") { showChannels.toggle() }.keyboardShortcut(.tab, modifiers: []).opacity(0).allowsHitTesting(false)
        }
        .onChange(of: nav.copyRequest) {
            guard !showChannels, nav.section == .subscriptions, nav.paths[.subscriptions]?.isEmpty ?? true,
                  let row = shown.first(where: { $0.id == selection }) else { return }
            nav.copy(YouTubeURL.watchURL(videoId: row.video.videoId))
        }
        .onChange(of: nav.refreshRequest) {
            guard nav.section == .subscriptions else { return }
            Task { await model.refresh() }
        }
        .onChange(of: dearrowTitles) { model.rebuild() }
        .onChange(of: dearrowThumbnails) { model.rebuild() }
        .onAppear { listFocus += 1; filter() }
        .task { await model.load() }
    }

    private func filter() {
        let q = HistoryFilter.Query(query)
        shown = q.isEmpty ? model.rows : model.rows.filter { q.matches($0.title, $0.video.channelName) }
    }

    private func open(_ row: FeedRow) {
        let v = row.video
        player?.open(.init(videoId: v.videoId, title: v.title, channelName: v.channelName, channelId: v.channelId,
                           lengthSeconds: nil, publishedAt: v.publishedAt, displayTitle: row.title, thumbnailURL: row.thumbnail))
    }

    private func save(_ row: FeedRow) -> Bool {
        let v = row.video
        downloads?.save(videoId: v.videoId, title: v.title, channelName: v.channelName, channelId: v.channelId, lengthSeconds: nil)
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

private struct FeedRowView: View {
    let row: FeedRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(videoId: row.video.videoId, url: row.thumbnail, channelId: row.video.channelId).frame(width: 120)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.body.weight(.medium)).lineLimit(2)
                Text(row.video.channelName).foregroundStyle(.secondary).lineLimit(1)
                Text(row.video.publishedAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.tertiary)
                if let progress = row.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear).controlSize(.small).frame(maxWidth: 160)
                }
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
