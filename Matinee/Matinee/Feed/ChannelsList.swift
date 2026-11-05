import MatineeKit
import SwiftUI

struct ChannelListRow: Identifiable, Equatable {
    let channel: Channel
    /// False for a channel unsubscribed since the list was opened: it stays, dimmed, so `d` can undo.
    let subscribed: Bool
    var id: String { channel.id }
}

/// The subscribed channels, by name: Return opens one, `d` unsubscribes (and again resubscribes).
struct ChannelsList: View {
    let subscriptions: Subscriptions
    /// The Subscriptions section's ⌘K filter.
    let query: String
    let focusRequest: Int
    @Environment(Navigator.self) private var nav
    @State private var selection: String?

    private var rows: [ChannelListRow] {
        let q = HistoryFilter.Query(query)
        return subscriptions.channels
            .filter { q.isEmpty || q.matches($0.name, "") }
            .map { ChannelListRow(channel: $0, subscribed: subscriptions.ids.contains($0.id)) }
    }

    var body: some View {
        let rows = rows
        TableList(items: rows, selection: $selection, rowHeight: 52, focusRequest: focusRequest,
                  onActivate: { nav.push(.channel(.id($0.id), name: $0.channel.name)) },
                  onKey: { row, key in
                      guard key == "d" else { return false }
                      toggle(row)
                      return true
                  },
                  contextMenu: [("Copy Link", { nav.copy(YouTubeURL.channel(.id($0.id)).url) }),
                                ("Subscribe or Unsubscribe", { toggle($0) })]) { row in
            HStack(spacing: 12) {
                Avatar(id: row.id, url: row.channel.thumbnailURL).frame(width: 40, height: 40)
                Text(row.channel.name).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                if !row.subscribed { Text("Unsubscribed").font(.caption).foregroundStyle(.secondary) }
            }
            .opacity(row.subscribed ? 1 : 0.5)
            .padding(.vertical, 4)
        }
        .overlay {
            if subscriptions.isLoaded, subscriptions.channels.isEmpty {
                ContentUnavailableView("No subscriptions", systemImage: "person.2",
                                       description: Text("Press D on a video or channel to subscribe."))
            } else if !query.isEmpty, rows.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .onAppear {
            subscriptions.prune()
            if selection == nil { selection = rows.first?.id }
        }
        .onChange(of: nav.deleteRequest) {
            guard isFront, let row = rows.first(where: { $0.id == selection }), row.subscribed else { return }
            toggle(row)
        }
        .onChange(of: nav.copyRequest) {
            guard isFront, let selection else { return }
            nav.copy(YouTubeURL.channel(.id(selection)).url)
        }
    }

    /// Shown, and not under a pushed page.
    private var isFront: Bool { nav.section == .subscriptions && (nav.paths[.subscriptions]?.isEmpty ?? true) }

    private func toggle(_ row: ChannelListRow) {
        subscriptions.toggle(row.id, name: row.channel.name, thumbnail: row.channel.thumbnailURL)
    }
}
