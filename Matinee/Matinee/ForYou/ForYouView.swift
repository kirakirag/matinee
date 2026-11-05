import MatineeKit
import SwiftUI

/// For You: Return plays, c opens the channel, d subscribes, s saves for offline, x is "Not interested", ⇧X hides the
/// channel, ⌘Z undoes that, ⌘R ranks again.
struct ForYouView: View {
    let model: ForYouModel
    @Environment(Navigator.self) private var nav
    @Environment(PlaybackController.self) private var player: PlaybackController?
    @Environment(DownloadManager.self) private var downloads: DownloadManager?
    @Environment(Subscriptions.self) private var subscriptions: Subscriptions?
    @AppStorage("dearrowTitles") private var dearrowTitles = true
    @AppStorage("dearrowThumbnails") private var dearrowThumbnails = true
    @State private var selection: String?
    @State private var listFocus = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("For You").font(.title2.weight(.semibold))
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    Text("\(model.loaded) of \(model.seedTotal)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if model.isRefining {
                    ProgressView().controlSize(.small)
                    Text("Refining…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            TableList(items: model.rows, selection: $selection, rowHeight: 78, focusRequest: listFocus,
                      onActivate: { play($0) }, onDwell: { player?.prefetch($0.id) }, onKey: { key($0, $1) },
                      thumbnailAhead: { $0.thumbnail ?? Thumbnail.frameURL($0.id) },
                      contextMenu: [("Copy Link", { nav.copy(YouTubeURL.watchURL(videoId: $0.id)) }),
                                    ("Save for Offline", { _ = save($0) }),
                                    ("Not Interested", { dismiss($0, channel: false) }),
                                    ("Hide Channel", { dismiss($0, channel: true) })]) { row in
                SearchRowView(row: row)
            }
        }
        .overlay {
            if !model.hasHistory {
                ContentUnavailableView("Nothing to go on yet", systemImage: "sparkles",
                                       description: Text("Watch a few videos and their suggestions are ranked here."))
            } else if let error = model.error {
                ContentUnavailableView("No recommendations", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.rows.isEmpty, model.isLoading {
                ProgressView()
            }
        }
        .onChange(of: model.rows) {
            if selection == nil || !model.rows.contains(where: { $0.id == selection }) { selection = model.rows.first?.id }
        }
        .onChange(of: nav.refreshRequest) {
            guard nav.section == .forYou else { return }
            model.load(force: true)
        }
        .onChange(of: nav.copyRequest) {
            guard isFront, let selection else { return }
            nav.copy(YouTubeURL.watchURL(videoId: selection))
        }
        // ⇧X (the table only passes unmodified keys on) and ⌘Z; a hidden or covered For You doesn't take them.
        .background {
            Button("") { if let row = selectedRow { dismiss(row, channel: true) } }
                .keyboardShortcut("x", modifiers: .shift).opacity(0).allowsHitTesting(false)
            Button("") { if model.undoDismiss() { nav.show(notice: "Brought back") } }
                .keyboardShortcut("z", modifiers: .command).opacity(0).allowsHitTesting(false)
        }
        .onChange(of: dearrowTitles) { model.rebuild() }
        .onChange(of: dearrowThumbnails) { model.rebuild() }
        .onAppear {
            listFocus += 1
            model.load()
        }
    }

    private var isFront: Bool { nav.section == .forYou && (nav.paths[.forYou]?.isEmpty ?? true) }

    private var selectedRow: SearchRow? { model.rows.first { $0.id == selection } }

    /// The selection moves to the next row first, so the list doesn't jump to the top.
    private func dismiss(_ row: SearchRow, channel: Bool) {
        if let i = model.rows.firstIndex(where: { $0.id == row.id }) {
            let rest = model.rows[(i + 1)...].first { !channel || $0.entry.channelId != row.entry.channelId }
            selection = rest?.id ?? (i > 0 ? model.rows[i - 1].id : nil)
        }
        model.dismiss(row, channel: channel)
        let name = row.entry.channel ?? "this channel"
        nav.show(notice: channel ? "Hiding \(name) · ⌘Z to undo" : "Not interested · ⌘Z to undo")
    }

    private func play(_ row: SearchRow) {
        let e = row.entry
        player?.open(.init(videoId: e.id, title: e.title, channelName: e.channel ?? "", channelId: e.channelId,
                           lengthSeconds: e.duration, publishedAt: nil, displayTitle: row.title, thumbnailURL: row.thumbnail))
    }

    private func save(_ row: SearchRow) -> Bool {
        let e = row.entry
        downloads?.save(videoId: e.id, title: e.title, channelName: e.channel ?? "", channelId: e.channelId, lengthSeconds: e.duration)
        return downloads != nil
    }

    private func key(_ row: SearchRow, _ key: Character) -> Bool {
        let e = row.entry
        switch key {
        case "x":
            dismiss(row, channel: false)
            return true
        case "s": return save(row)
        case "d":
            subscriptions?.toggle(e.channelId, name: e.channel)
            return subscriptions != nil
        case "c":
            guard let id = e.channelId, ChannelID.isValid(id) else { return false }
            nav.push(.channel(.id(id), name: e.channel))
            return true
        default:
            return false
        }
    }
}
