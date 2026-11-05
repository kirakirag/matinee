import MatineeKit
import SwiftUI

struct ChannelView: View {
    let section: AppSection
    let ref: ChannelRef
    let name: String?
    @State private var model: ChannelModel
    @Environment(Navigator.self) private var nav
    @Environment(PlaybackController.self) private var player: PlaybackController?
    @Environment(Subscriptions.self) private var subscriptions: Subscriptions?

    @AppStorage("dearrowTitles") private var dearrowTitles = true
    @AppStorage("dearrowThumbnails") private var dearrowThumbnails = true
    @State private var selection: String?
    @State private var listFocus = 0

    init(section: AppSection, store: Store, worker: WorkerClient, dearrow: DeArrowService, ref: ChannelRef, name: String?) {
        self.section = section
        self.ref = ref
        self.name = name
        _model = State(initialValue: ChannelModel(store: store, worker: worker, dearrow: dearrow, ref: ref, name: name))
    }

    private var title: String {
        model.name ?? name ?? subscriptions?.channels.first { $0.id == model.channelId }?.name ?? "Channel"
    }

    private var subscribed: Bool { subscriptions?.contains(model.channelId) ?? false }

    /// The page's title is the name to save: the RSS feed's, or the one the page was opened with.
    private func toggleSubscription() {
        subscriptions?.toggle(model.channelId, name: model.name ?? name)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title2.weight(.semibold)).lineLimit(1)
                Spacer()
                Button(subscribed ? "Unsubscribe" : "Subscribe") { toggleSubscription(); listFocus += 1 }
                    .disabled(model.notFound || model.channelId == nil || subscriptions?.isLoaded != true)
                Text("d").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
            .padding(8)
            if let error = model.videosError {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            }
            TableList(items: model.rows, selection: $selection, rowHeight: 78, focusRequest: listFocus,
                      onActivate: { activate($0) },
                      onDwell: { if case .video(let v, _, _, _) = $0.kind { player?.prefetch(v.videoId) } },
                      onKey: { _, key in
                          guard key == "d" else { return false }
                          toggleSubscription()
                          return true
                      },
                      onReachEnd: { model.loadMorePlaylists() },
                      isSelectable: { $0.isSelectable },
                      contextMenu: [("Copy Link", { nav.copy(link($0)) })]) { row in
                ChannelRowView(row: row)
            }
            .overlay {
                if model.notFound {
                    ContentUnavailableView("Channel not found", systemImage: "person.crop.circle.badge.questionmark")
                } else if model.rows.isEmpty, model.isLoadingPlaylists {
                    ProgressView()
                }
            }
            if model.isLoadingPlaylists, !model.rows.isEmpty {
                ProgressView().controlSize(.small).padding(6)
            }
            if let error = model.playlistsError {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        // `d` also works with no row selected (an empty or failed list), where the table passes no key on.
        .background {
            Button("") { toggleSubscription() }.keyboardShortcut("d", modifiers: []).opacity(0).allowsHitTesting(false)
        }
        .onChange(of: nav.deleteRequest) {
            guard subscribed, nav.section == section, nav.paths[section]?.last == .channel(ref, name: name) else { return }
            toggleSubscription()
        }
        .onChange(of: nav.copyRequest) {
            guard nav.section == section, nav.paths[section]?.last == .channel(ref, name: name),
                  let row = model.rows.first(where: { $0.id == selection }) else { return }
            nav.copy(link(row))
        }
        .onChange(of: dearrowTitles) { model.rebuild() }
        .onChange(of: dearrowThumbnails) { model.rebuild() }
        .onChange(of: model.rows) {
            // Never the divider: it can move down while selected when the videos arrive.
            if selection == nil || selection == "divider", let first = model.rows.first(where: \.isSelectable) { selection = first.id }
        }
        .onAppear { listFocus += 1; model.load() }
        .onDisappear { model.cancel() }
    }

    private func link(_ row: ChannelRow) -> URL? {
        switch row.kind {
        case .video(let v, _, _, _): YouTubeURL.watchURL(videoId: v.videoId)
        case .playlist(let p): YouTubeURL.playlist(p.id).url
        case .allVideos(let id): YouTubeURL.playlist(id).url
        case .divider: nil
        }
    }

    private func activate(_ row: ChannelRow) {
        switch row.kind {
        case .video(let v, _, _, _):
            let items = model.queueItems
            if let start = items.firstIndex(where: { $0.videoId == v.videoId }) { player?.open(items, start: start) }
        case .playlist(let p):
            nav.push(.playlist(id: p.id, title: p.title))
        case .allVideos(let id):
            nav.push(.playlist(id: id, title: "All videos by \(title)"))
        case .divider:
            break
        }
    }
}

private struct ChannelRowView: View {
    let row: ChannelRow

    var body: some View {
        switch row.kind {
        case .video(let v, let title, let thumbnail, let progress):
            HStack(alignment: .top, spacing: 10) {
                Thumbnail(videoId: v.videoId, url: thumbnail, channelId: v.channelId).frame(width: 120)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium)).lineLimit(2)
                    Text(v.publishedAt, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.tertiary)
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear).controlSize(.small).frame(maxWidth: 160)
                    }
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .playlist(let p):
            HStack(alignment: .top, spacing: 10) {
                Thumbnail(videoId: p.id, url: nil).frame(width: 120)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).font(.body.weight(.medium)).lineLimit(2)
                    if let count = p.count { Text("\(count) videos").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .allVideos:
            Label("All videos", systemImage: "list.bullet")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .divider:
            VStack(spacing: 2) {
                Spacer(minLength: 0)
                Text("Playlists").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
        }
    }
}
