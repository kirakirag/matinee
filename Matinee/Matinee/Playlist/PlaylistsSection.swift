import MatineeKit
import SwiftUI

/// The Playlists section: a field for a playlist link and the recently opened playlists, newest first.
struct PlaylistsSection: View {
    let store: Store
    @Environment(Navigator.self) private var nav

    @State private var recents: [RecentPlaylist] = []
    @State private var loaded = false
    @State private var link = ""
    @State private var message: String?
    @State private var selection: String?
    @State private var listFocus = 0
    @State private var removing: RecentPlaylist?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Playlist link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) {
                        guard !recents.isEmpty else { return .ignored }
                        if selection == nil { selection = recents.first?.id }
                        listFocus += 1
                        return .handled
                    }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            TableList(items: recents, selection: $selection, rowHeight: 78, focusRequest: listFocus,
                      onActivate: { nav.push(.playlist(id: $0.id, title: $0.title)) },
                      contextMenu: [("Copy Link", { nav.copy(YouTubeURL.playlist($0.id).url) })]) { p in
                RecentPlaylistRow(playlist: p)
            }
            .overlay {
                if loaded, recents.isEmpty {
                    ContentUnavailableView("Paste a YouTube playlist link", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .onChange(of: link) { message = nil }
        .onChange(of: nav.deleteRequest) {
            guard nav.section == .playlists, nav.paths[.playlists]?.isEmpty ?? true,
                  let p = recents.first(where: { $0.id == selection }) else { return }
            removing = p
        }
        .onChange(of: nav.copyRequest) {
            guard nav.section == .playlists, nav.paths[.playlists]?.isEmpty ?? true,
                  let p = recents.first(where: { $0.id == selection }) else { return }
            nav.copy(YouTubeURL.playlist(p.id).url)
        }
        .confirmationDialog("Remove \(removing?.title ?? "") from recent playlists?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { p in
            Button("Remove", role: .destructive) { remove(p) }.keyboardShortcut(.defaultAction)   // Return
        }
        .onChange(of: removing) { _, p in if p == nil { listFocus += 1 } }
        // The stack root reappears on every pop and section switch, so a playlist just opened shows up.
        .onAppear {
            Task {
                await reload()
                if recents.isEmpty { fieldFocused = true } else { listFocus += 1 }
            }
        }
    }

    private func reload() async {
        let store = store
        recents = await Task.detached { (try? store.recentPlaylists()) ?? [] }.value
        loaded = true
        if selection == nil || !recents.contains(where: { $0.id == selection }) { selection = recents.first?.id }
    }

    private func submit() {
        guard let id = PlaylistLink.parse(link) else {
            message = "That's not a playlist link."
            return
        }
        link = ""
        nav.push(.playlist(id: id, title: nil))
    }

    private func remove(_ p: RecentPlaylist) {
        let store = store
        guard let i = recents.firstIndex(where: { $0.id == p.id }) else { return }
        recents.remove(at: i)
        if selection == p.id { selection = recents.isEmpty ? nil : recents[min(i, recents.count - 1)].id }
        // A failed delete brings the row back on the reload.
        Task {
            await Task.detached { try? store.removePlaylist(id: p.id) }.value
            await reload()
        }
    }
}

private struct RecentPlaylistRow: View {
    let playlist: RecentPlaylist

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(videoId: playlist.id, url: nil).frame(width: 120)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title).font(.body.weight(.medium)).lineLimit(2)
                if let channel = playlist.channelName { Text(channel).foregroundStyle(.secondary).lineLimit(1) }
                if let count = playlist.videoCount { Text("\(count) videos").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
