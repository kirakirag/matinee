import MatineeKit
import SwiftUI

struct PlaylistView: View {
    let section: AppSection
    let id: String
    let title: String?
    @State private var model: PlaylistModel
    @Environment(Navigator.self) private var nav
    @Environment(PlaybackController.self) private var player: PlaybackController?
    @Environment(DownloadManager.self) private var downloads: DownloadManager?
    @Environment(Subscriptions.self) private var subscriptions: Subscriptions?

    @AppStorage("dearrowTitles") private var dearrowTitles = true
    @AppStorage("dearrowThumbnails") private var dearrowThumbnails = true
    @State private var selection: String?
    @State private var listFocus = 0

    init(section: AppSection, store: Store, worker: WorkerClient, dearrow: DeArrowService, id: String, title: String?) {
        self.section = section
        self.id = id
        self.title = title
        _model = State(initialValue: PlaylistModel(store: store, worker: worker, dearrow: dearrow, id: id, title: title))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.title ?? title ?? "Playlist").font(.title2.weight(.semibold)).lineLimit(1)
                if let channel = model.channel { Text(channel).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if !model.rows.isEmpty {
                    Text("\(model.rows.count)\(model.finished ? "" : "+") videos").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            TableList(items: model.rows, selection: $selection, rowHeight: 78, focusRequest: listFocus,
                      onActivate: { play($0) }, onDwell: { player?.prefetch($0.id) },
                      onKey: { $1 == "s" ? save($0.entry) : channelKey($0.entry, $1) }, onReachEnd: { model.load() },
                      thumbnailAhead: { $0.thumbnail },
                      contextMenu: [("Copy Link", { nav.copy(YouTubeURL.watchURL(videoId: $0.id)) }),
                                    ("Save for Offline", { _ = save($0.entry) })]) { row in
                PlaylistRowView(row: row)
            }
            .overlay {
                if model.rows.isEmpty, model.isLoading {
                    ProgressView()
                } else if model.rows.isEmpty, model.finished {
                    ContentUnavailableView("No videos", systemImage: "list.bullet.rectangle")
                }
            }
            if model.isLoading, !model.rows.isEmpty {
                ProgressView().controlSize(.small).padding(6)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        .onChange(of: nav.copyRequest) {
            guard nav.section == section, nav.paths[section]?.last == .playlist(id: id, title: title),
                  let row = model.rows.first(where: { $0.id == selection }) else { return }
            nav.copy(YouTubeURL.watchURL(videoId: row.id))
        }
        .onChange(of: dearrowTitles) { model.rebuild() }
        .onChange(of: dearrowThumbnails) { model.rebuild() }
        .onChange(of: model.rows.first?.id) { if selection == nil { selection = model.rows.first?.id } }
        .onAppear { listFocus += 1; model.load() }
        .onDisappear { model.cancel() }
    }

    private func play(_ row: PlaylistRow) {
        if let player { model.play(from: row.id, in: player) }
    }

    private func save(_ e: ListedEntry) -> Bool {
        downloads?.save(videoId: e.id, title: e.title, channelName: e.channel ?? "", channelId: e.channelId, lengthSeconds: e.duration)
        return downloads != nil
    }

    /// `c` opens the video's channel, `d` subscribes to it or unsubscribes.
    private func channelKey(_ e: ListedEntry, _ key: Character) -> Bool {
        if key == "d", let subscriptions { subscriptions.toggle(e.channelId, name: e.channel); return true }
        guard key == "c", let id = e.channelId, ChannelID.isValid(id) else { return false }
        nav.push(.channel(.id(id), name: e.channel))
        return true
    }
}

private struct PlaylistRowView: View {
    let row: PlaylistRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(videoId: row.id, url: row.thumbnail, channelId: row.entry.channelId).frame(width: 120)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.body.weight(.medium)).lineLimit(2)
                if let channel = row.entry.channel { Text(channel).foregroundStyle(.secondary).lineLimit(1) }
                if let d = row.entry.duration {
                    Text(Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                        .font(.caption).foregroundStyle(.tertiary)
                }
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
