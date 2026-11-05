import AppKit
import MatineeKit
import SwiftUI

struct SearchView: View {
    @Bindable var model: SearchModel
    @Environment(Navigator.self) private var nav
    @Environment(PlaybackController.self) private var player: PlaybackController?
    @Environment(DownloadManager.self) private var downloads: DownloadManager?
    @Environment(Subscriptions.self) private var subscriptions: Subscriptions?

    @AppStorage("dearrowTitles") private var dearrowTitles = true
    @AppStorage("dearrowThumbnails") private var dearrowThumbnails = true
    @State private var listFocus = 0
    @State private var suggestionFocus = 0
    @State private var suggestionSelection: String?
    /// True from the field taking focus until a search runs or focus moves to the results.
    @State private var suggesting = false
    @State private var visible = false
    /// The last `searchFocusRequest` acted on; a newer one is handled on appearing if it came while hidden.
    @State private var seenFocusRequest = 0
    @FocusState private var fieldFocused: Bool

    private var showSuggestions: Bool {
        suggesting && model.query != model.searched && !model.suggestions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search YouTube", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) { down() }
                    .onKeyPress(.escape) {
                        guard !model.rows.isEmpty || model.isSearching else { return .ignored }
                        focusResults()
                        return .handled
                    }
                HStack {
                    Picker("Sort", selection: $model.filter.sort) {
                        ForEach(SearchFilter.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Date", selection: $model.filter.date) {
                        ForEach(SearchFilter.UploadDate.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Type", selection: $model.filter.type) {
                        ForEach(SearchFilter.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Duration", selection: $model.filter.duration) {
                        ForEach(SearchFilter.Length.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("⌥1–⌥4").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .padding(8)
            // ⌥1–⌥4 step through Sort, Date, Type and Duration (⇧ goes back), even while typing in the field.
            .background {
                ForEach(0..<8, id: \.self) { i in
                    let back = i >= 4, n = i % 4
                    Button("") { cycleFilter(n, by: back ? -1 : 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n + 1)")), modifiers: back ? [.option, .shift] : .option)
                        .opacity(0).allowsHitTesting(false)
                }
            }
            TableList(items: model.rows, selection: $model.selection, rowHeight: 78, focusRequest: listFocus,
                      onActivate: { endSuggesting(); activate($0) },
                      onDwell: { endSuggesting(); if $0.entry.kind == .video { player?.prefetch($0.id) } },
                      onKey: { key($0, $1) }, onReachEnd: { model.loadMore() }, onRowShown: { model.rowShown($0) },
                      thumbnailAhead: { $0.entry.kind == .video ? $0.thumbnail ?? Thumbnail.frameURL($0.id) : nil },
                      contextMenu: [("Copy Link", { nav.copy(link($0)) }), ("Save for Offline", { _ = save($0) })]) { row in
                SearchRowView(row: row)
            }
            .overlay { status }
            // Over the results rather than above them, so the field and filters never move.
            .overlay(alignment: .top) {
                if showSuggestions {
                    TableList(items: model.suggestions, selection: $suggestionSelection, rowHeight: 24, focusRequest: suggestionFocus,
                              onActivate: { model.query = $0.text; submit(); focusResults() }) { s in
                        Text(s.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: CGFloat(model.suggestions.count) * 24 + 12)
                    .background(.background)
                    .overlay(alignment: .bottom) { Divider() }
                    .shadow(radius: 4, y: 2)
                }
            }
            if model.waitingForMore {
                ProgressView().controlSize(.small).padding(6)
            }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        .onChange(of: model.query) {
            if fieldFocused { suggesting = true }   // typing after a search brings suggestions back
            model.queryChanged()
        }
        .onChange(of: model.filter) { model.filterChanged() }
        .onChange(of: fieldFocused) { _, focused in if focused { suggesting = true } }
        // A hidden tab can't take focus, so a request that comes with the switch here is handled in onAppear.
        .onChange(of: nav.searchFocusRequest) { _, request in
            guard visible else { return }
            seenFocusRequest = request
            fieldFocused = true
        }
        .onChange(of: nav.copyRequest) {
            guard nav.section == .search, nav.paths[.search]?.isEmpty ?? true,
                  let row = model.rows.first(where: { $0.id == model.selection }) else { return }
            nav.copy(link(row))
        }
        .onChange(of: dearrowTitles) { model.rebuild() }
        .onChange(of: subscriptions?.ids) { model.rebuild() }
        .onChange(of: dearrowThumbnails) { model.rebuild() }
        .onAppear {
            visible = true
            if nav.searchFocusRequest != seenFocusRequest || model.rows.isEmpty {
                seenFocusRequest = nav.searchFocusRequest
                fieldFocused = true
            } else {
                listFocus += 1
            }
        }
        .onDisappear { visible = false }
    }

    @ViewBuilder private var status: some View {
        if let error = model.error {
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.isSearching, model.rows.isEmpty {
            ProgressView()
        } else if let searched = model.searched, !model.isSearching, model.rows.isEmpty {
            ContentUnavailableView.search(text: searched)
        }
    }

    private func cycleFilter(_ n: Int, by step: Int) {
        switch n {
        case 0: model.filter.sort = model.filter.sort.cycled(by: step)
        case 1: model.filter.date = model.filter.date.cycled(by: step)
        case 2: model.filter.type = model.filter.type.cycled(by: step)
        default: model.filter.duration = model.filter.duration.cycled(by: step)
        }
    }

    private func endSuggesting() {
        if suggesting { suggesting = false }
    }

    private func submit() {
        suggesting = false
        if let link = PastedLink.parse(model.query) { nav.open(link); return }
        model.search()
    }

    private func focusResults() {
        endSuggesting()
        if model.rows.isEmpty {
            model.selectFirstOnArrival = true   // the first page is still loading
        } else if model.selection == nil {
            model.selection = model.rows.first?.id
        }
        listFocus += 1
    }

    private func down() -> KeyPress.Result {
        if showSuggestions {
            suggestionSelection = model.suggestions.first?.id
            suggestionFocus += 1
            return .handled
        }
        guard !model.rows.isEmpty || model.isSearching else { return .ignored }
        focusResults()
        return .handled
    }

    private func activate(_ row: SearchRow) {
        let e = row.entry
        switch e.kind {
        case .video:
            player?.open(.init(videoId: e.id, title: e.title, channelName: e.channel ?? "", channelId: e.channelId,
                               lengthSeconds: e.duration, publishedAt: nil, displayTitle: row.title, thumbnailURL: row.thumbnail))
        case .channel:
            nav.push(.channel(.id(e.id), name: e.title))
        case .playlist:
            nav.push(.playlist(id: e.id, title: e.title))
        }
    }

    /// Videos only; channel rows keep `s` = subscribe.
    private func save(_ row: SearchRow) -> Bool {
        let e = row.entry
        guard e.kind == .video, let downloads else { return false }
        downloads.save(videoId: e.id, title: e.title, channelName: e.channel ?? "", channelId: e.channelId, lengthSeconds: e.duration)
        return true
    }

    private func link(_ row: SearchRow) -> URL? {
        switch row.entry.kind {
        case .video: YouTubeURL.watchURL(videoId: row.entry.id)
        case .channel: YouTubeURL.channel(.id(row.entry.id)).url
        case .playlist: YouTubeURL.playlist(row.entry.id).url
        }
    }

    private func key(_ row: SearchRow, _ key: Character) -> Bool {
        let e = row.entry
        switch (key, e.kind) {
        case ("d", .channel):
            subscriptions?.toggle(e.id, name: e.title, thumbnail: e.thumbnail)
            return subscriptions != nil
        case ("d", .video):
            subscriptions?.toggle(e.channelId, name: e.channel)
            return subscriptions != nil
        case ("s", .video):
            return save(row)
        case ("c", .video):
            guard let id = e.channelId, ChannelID.isValid(id) else { return false }
            nav.push(.channel(.id(id), name: e.channel))
            return true
        default:
            return false
        }
    }
}

/// A search result row; For You uses it too.
struct SearchRowView: View {
    let row: SearchRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch row.entry.kind {
            case .channel:
                Avatar(id: row.id, url: row.thumbnail).frame(width: 60, height: 60).frame(width: 120)
            default:
                Thumbnail(videoId: row.id, url: row.thumbnail, channelId: row.entry.channelId).frame(width: 120)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.body.weight(.medium)).lineLimit(2)
                switch row.entry.kind {
                case .video:
                    if let channel = row.entry.channel { Text(channel).foregroundStyle(.secondary).lineLimit(1) }
                    Text(details).font(.caption).foregroundStyle(.tertiary)
                    if let progress = row.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear).controlSize(.small).frame(maxWidth: 160)
                    }
                case .channel:
                    if row.subscribed {
                        Text("Subscribed").font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                case .playlist:
                    if let channel = row.entry.channel { Text(channel).foregroundStyle(.secondary).lineLimit(1) }
                    if let count = row.entry.count { Text("\(count) videos").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: String {
        var parts: [String] = []
        if let d = row.entry.duration {
            parts.append(Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
        if let v = row.entry.views { parts.append("\(v.formatted(.number.notation(.compactName))) views") }
        return parts.joined(separator: " · ")
    }
}

/// A round channel avatar.
struct Avatar: View {
    /// Shown 60 pt across: 360 px covers a 3x display with room to spare.
    private static let maxPixelSize = 360
    let id: String
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Circle()
            .fill(.quaternary)
            .overlay {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            }
            .clipShape(.circle)
            .task(id: id) {
                guard let url else { image = nil; return }
                if let hit = ThumbnailLoader.shared.cached(url, maxPixelSize: Self.maxPixelSize) { image = hit; return }
                image = nil   // a reused row must not show another channel's avatar
                let loaded = await ThumbnailLoader.shared.load(url, maxPixelSize: Self.maxPixelSize)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}
