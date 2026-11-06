import SwiftUI

/// The current video while the player is dismissed. Click it, or Return when it has focus, to go back.
struct NowPlayingBanner: View {
    @Environment(PlaybackController.self) private var player: PlaybackController?

    var body: some View {
        if let player, let item = player.item, !player.isPresented, !player.isMini {
            Button { player.resume() } label: {
                HStack(spacing: 10) {
                    Thumbnail(videoId: item.videoId, url: item.thumbnailURL, channelId: item.channelId).frame(width: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle ?? item.title).font(.body.weight(.medium)).lineLimit(1)
                        Text(item.channelName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "play.fill").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable()
            .onKeyPress(.return) { player.resume(); return .handled }
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .help("Return to Player (⌘P)")
        }
    }
}
