import AppKit
import MatineeKit
import SwiftUI

/// The in-window player: mpv's view, the list's thumbnail and title until the first frame, the phase and the controls.
/// It stays in the window while dismissed, hidden: mpv's view is never re-created, and it only reports the first
/// frame while it draws. The mini player (I) is the same view, shrunk to the window's bottom-right corner.
struct PlayerView: View {
    let player: PlaybackController
    @State private var controlsVisible = true
    @State private var hideControls: Task<Void, Never>?
    /// The controls' height with their margin, measured, for Live Text and the skip notice to stay above them.
    @State private var controlsHeight: CGFloat = 0
    /// The window's content area, which the mini player and the side panel are sized from.
    @State private var space: CGSize = .zero

    var body: some View {
        ZStack {
            // mpv's view passes clicks through to here; there is no single-click action to delay.
            Color.black.onTapGesture(count: 2) { player.handle(.fullscreen) }
            VideoSurface(view: player.videoView)
            // Not while dismissed (which pauses): that would read back and analyse a frame nobody sees, on the main
            // thread just as the list takes keys, and its selection would keep ⌘C from copying the list's link.
            if player.phase == .playing, player.isPaused, player.isPresented {
                // Paused, the controls stay shown; the mini player has none.
                LiveTextLayer(player: player, covered: player.isMini ? NSEdgeInsets() : NSEdgeInsets(
                    top: 0, left: 0, bottom: controlsHeight, right: showsPanel ? panelWidth : 0))
            }
            if player.phase != .playing, let item = player.item {
                if player.isMini {
                    Thumbnail(videoId: item.videoId, url: item.thumbnailURL, channelId: item.channelId).overlay { status }
                } else {
                    placeholder(item)
                }
            }
            if player.phase == .playing, player.isBuffering {
                ProgressView().controlSize(player.isMini ? .regular : .large).padding(player.isMini ? 8 : 16)
                    .background(.black.opacity(0.5), in: .circle)
            }
            if player.isMini {
                MiniOverlay(player: player)
            } else {
                fullOverlays
            }
        }
        .frame(width: player.isMini ? miniWidth : nil, height: player.isMini ? miniWidth * 9 / 16 : nil)
        .clipShape(.rect(cornerRadius: player.isMini ? 10 : 0))
        .shadow(color: .black.opacity(player.isMini ? 0.35 : 0), radius: 12, y: 4)
        .padding(player.isMini ? 16 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { space = $0 }
        .ignoresSafeArea(edges: player.isFullscreen ? .all : [])
        .opacity(player.isPresented || player.isMini ? 1 : 0)
        .allowsHitTesting(player.isPresented || player.isMini)
        .onContinuousHover { if case .active = $0 { showControls() } }
        .onChange(of: player.commandCount) { showControls() }
        .onChange(of: player.isPaused) { showControls() }
        .onChange(of: player.phase) { showControls() }
        .animation(.easeInOut(duration: 0.2), value: player.skipNotice)
        // Only between two visible states: closing the mini player hides it at once rather than growing a black box.
        .animation(player.isPresented || player.isMini ? .easeInOut(duration: 0.25) : nil, value: player.isMini)
    }

    /// A quarter of the window wide, at 16:9.
    private var miniWidth: CGFloat { space.width / 4 }
    /// A third of the window wide.
    private var panelWidth: CGFloat { space.width / 3 }

    private var showsPanel: Bool {
        player.panelVisible && (PlaybackController.commentsEnabled || PlaybackController.upNextEnabled)
    }

    /// The full player's controls, notices, side panel and quality list.
    @ViewBuilder private var fullOverlays: some View {
        if player.phase == .playing {
            PlayerControls(player: player)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
        }
        if let notice = player.skipNotice {
            // Above the controls, and shown while they are hidden too.
            Text(notice)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.regularMaterial, in: .capsule)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, controlsHeight)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
        if showsPanel {
            SidePanel(player: player)
                .frame(width: panelWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .transition(.move(edge: .trailing))
        }
        if let selected = player.qualityMenuIndex {
            QualityList(choices: player.qualityChoices, savedHeight: player.savedHeight, selected: selected)
        }
    }

    private func placeholder(_ item: PlaybackController.Item) -> some View {
        VStack(spacing: 14) {
            Thumbnail(videoId: item.videoId, url: item.thumbnailURL, channelId: item.channelId, maxPixelSize: 1440)   // up to 480 pt wide
                .frame(maxWidth: 480)
                .overlay { status }
            Text(item.displayTitle ?? (item.title.isEmpty ? "Loading…" : item.title)).font(.title3.weight(.medium)).multilineTextAlignment(.center).lineLimit(2)
            if case .failed(let f) = player.phase {
                Text(f.message).foregroundStyle(.secondary)
                if f == .needsAccount {
                    Button("Open in Brave  ↩") { player.openInBrave() }
                    if let braveError = player.braveError { Text(braveError).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(40)
    }

    @ViewBuilder private var status: some View {
        switch player.phase {
        case .resolving, .loading:
            ProgressView().controlSize(.large).padding(16).background(.black.opacity(0.5), in: .circle)
        case .waiting(let n):
            Text("Starting in \(n) s").padding(8).background(.black.opacity(0.6), in: .rect(cornerRadius: 6))
        default:
            EmptyView()
        }
    }

    /// Shows the controls, then hides them (and the cursor) after 2 s without mouse movement or player keys while playing.
    private func showControls() {
        controlsVisible = true
        hideControls?.cancel()
        hideControls = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, player.isPresented, player.phase == .playing, !player.isPaused else { return }
            withAnimation { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

private func qualityName(_ choice: QualityChoice, savedHeight: Int?) -> String {
    switch choice {
    case .saved: savedHeight.map { "Saved \($0)p" } ?? "Saved"
    case .best: "Best"
    case .height(let h): "\(h)p"
    }
}

/// The list `q` opens: ↑/↓ move, Return applies, Escape closes (keys come through the Navigator's monitor).
private struct QualityList: View {
    let choices: [QualityChoice]
    let savedHeight: Int?
    let selected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(choices.enumerated()), id: \.offset) { i, choice in
                Text(qualityName(choice, savedHeight: savedHeight)).monospacedDigit()
                    .frame(minWidth: 90, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(i == selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 6))
            }
        }
        .padding(6)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }
}

/// The mini player's controls: a click brings the full player back; on hover, play/pause, expand and close.
private struct MiniOverlay: View {
    let player: PlaybackController
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear.contentShape(.rect).onTapGesture { player.resume() }
            if hovering {
                Color.black.opacity(0.35).allowsHitTesting(false)
                Button { player.handle(.togglePause) } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.title)
                }
                .help(player.isPaused ? "Play" : "Pause")
                VStack {
                    HStack {
                        Button { player.resume() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .help("Back to the Player (⌘P)")
                        Spacer()
                        Button { player.dismiss() } label: { Image(systemName: "xmark") }
                            .help("Close")
                    }
                    Spacer()
                }
                .font(.title3)
                .padding(10)
            }
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .foregroundStyle(.white)
        .overlay(alignment: .bottom) { progress }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder private var progress: some View {
        if player.phase == .playing, let duration = player.duration, duration > 0 {
            GeometryReader { g in
                Color.accentColor.frame(width: g.size.width * min(max(player.position / duration, 0), 1))
            }
            .frame(height: 3)
            .allowsHitTesting(false)
        }
    }
}

/// Holds mpv's view and never takes the mouse, so the hidden player can't swallow clicks meant for the list.
private struct VideoSurface: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = PassThrough()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {}

    private final class PassThrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Play/pause, a scrubber with times, volume and speed.
private struct PlayerControls: View {
    let player: PlaybackController
    /// The scrubber's value while it is dragged; seeking happens on release.
    @State private var scrub: Double?

    private static let speeds = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        HStack(spacing: 12) {
            if let q = player.queueInfo {
                Button { player.handle(.previous) } label: { Image(systemName: "backward.end.fill") }
                    .disabled(q.position == 0)
            }
            Button { player.handle(.togglePause) } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill").frame(width: 18)
            }
            if player.queueInfo == nil, PlaybackController.upNextEnabled, let next = player.upNext.first {
                Button { player.handle(.next) } label: { Image(systemName: "forward.end.fill") }
                    .help("Up next: \(next.title) (N)")
            }
            if let q = player.queueInfo {
                Button { player.handle(.next) } label: { Image(systemName: "forward.end.fill") }
                    .disabled(q.position + 1 >= q.count)
                if let title = player.queueTitle, !title.isEmpty {
                    Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .trailing)
                }
                Text("\(q.position + 1) of \(q.count)").monospacedDigit()
            }
            Text(time(scrub ?? player.position)).monospacedDigit()
            Slider(value: Binding(get: { scrub ?? player.position }, set: { scrub = $0 }),
                   in: 0...max(player.duration ?? 0, 1)) { editing in
                if !editing, let scrub {
                    player.seek(to: scrub)
                    self.scrub = nil
                }
            }
            Text(time(player.duration ?? 0)).monospacedDigit()
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...100)
                .frame(width: 80)
            Menu("\(player.speed.formatted())×") {
                ForEach(Self.speeds, id: \.self) { s in
                    Button("\(s.formatted())×") { player.setSpeed(s) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if !player.qualityChoices.isEmpty {
                Menu(player.playingSaved ? qualityName(.saved, savedHeight: player.savedHeight)
                                         : player.currentHeight.map { "\($0)p" } ?? "Best") {
                    Picker("Quality", selection: Binding(get: { player.selectedQuality }, set: { player.setQuality($0) })) {
                        ForEach(player.qualityChoices, id: \.self) { Text(qualityName($0, savedHeight: player.savedHeight)).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if PlaybackController.commentsEnabled || PlaybackController.upNextEnabled {
                let upNext = PlaybackController.upNextEnabled
                Button { player.handle(.toggleComments) } label: {
                    Image(systemName: upNext ? "sidebar.right" : player.panelVisible ? "text.bubble.fill" : "text.bubble")
                }
                .help(upNext && PlaybackController.commentsEnabled ? "Up next and comments (O)" : upNext ? "Up next (O)" : "Comments (O)")
            }
            Button { player.handle(.fullscreen) } label: {
                Image(systemName: player.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(player.isFullscreen ? "Exit Full Screen (F)" : "Full Screen (F)")
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
        .padding(16)
    }

    private func time(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// The current video's top comments, read-only. Text is shown verbatim: no links or Markdown are interpreted.
/// The player's side panel (O): Up next and comments, with a switch when both are on.
private struct SidePanel: View {
    let player: PlaybackController

    var body: some View {
        let both = PlaybackController.upNextEnabled && PlaybackController.commentsEnabled
        let tab = PlaybackController.upNextEnabled ? (both ? player.panelTab : .upNext) : .comments
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if both {
                    Picker("Show", selection: Binding(get: { player.panelTab }, set: { player.panelTab = $0 })) {
                        Text("Up next").tag(PlaybackController.PanelTab.upNext)
                        Text("Comments").tag(PlaybackController.PanelTab.comments)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                } else {
                    Text(tab == .upNext ? "Up next" : "Comments").font(.headline)
                }
                if tab == .comments, let count = player.commentCount {
                    Text(count.formatted()).foregroundStyle(.secondary)
                }
                Spacer()
                Button { player.handle(.toggleComments) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close (O)")
            }
            .padding(12)
            Divider()
            if tab == .upNext { UpNextList(player: player) } else { CommentsList(player: player) }
        }
        // Opaque: a material over the playing video re-blurs every frame, which made scrolling lag.
        .background(Color(white: 0.11))
        .environment(\.colorScheme, .dark)
    }
}

/// The watch page's suggestions; a click plays one.
private struct UpNextList: View {
    let player: PlaybackController

    var body: some View {
        switch player.upNextStatus {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Text("Couldn't load suggestions: \(message)").foregroundStyle(.secondary)
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .loaded where player.upNext.isEmpty:
            Text("No suggestions").foregroundStyle(.secondary)
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .loaded:
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {   // about 20 rows
                    ForEach(Array(player.upNext.enumerated()), id: \.element.id) { i, e in
                        Button { player.playUpNext(e) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Thumbnail(videoId: e.id, channelId: e.channelId)
                                    .containerRelativeFrame(.horizontal) { width, _ in width / 3 }   // a third of the panel
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                                    if let channel = e.channel { Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    if let d = e.duration {
                                        Text(Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                                            .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(6)
                            .background(i == player.upNextSelection ? Color.accentColor.opacity(0.35) : .clear, in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(e.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: player.upNextSelection) { _, i in
                if player.upNext.indices.contains(i) { proxy.scrollTo(player.upNext[i].id) }
            }
            }
        }
    }
}

private struct CommentsList: View {
    let player: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch player.commentsStatus {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Text("Couldn't load comments: \(message)").foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .loaded where player.comments.isEmpty:
                Text("No comments").foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .loaded:
                ScrollViewReader { proxy in
                ScrollView {
                    // Lazy: pages keep coming as it scrolls, so there can be thousands of rows.
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(player.comments.enumerated()), id: \.element.id) { i, comment in
                            CommentRow(comment: comment, player: player)
                                .padding(6)
                                .background(i == player.commentSelection ? Color.accentColor.opacity(0.25) : .clear,
                                            in: .rect(cornerRadius: 8))
                                .id(comment.id)
                                // Ten rows early, so the next page is usually there before the end is reached.
                                .onAppear { if i >= player.comments.count - 10 { player.loadNextComments() } }
                        }
                        switch player.moreComments {
                        case .loading:
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        case .failed(let message):
                            HStack {
                                Text("Couldn't load more: \(message)").foregroundStyle(.secondary)
                                Button("Try again") { player.loadNextComments() }
                            }
                            .font(.caption)
                        case .idle, .loaded:
                            EmptyView()
                        }
                    }
                    .padding(6)
                }
                .onChange(of: player.commentSelection) { _, i in
                    if player.comments.indices.contains(i) { proxy.scrollTo(player.comments[i].id) }
                }
                }
            }
        }
    }
}

private struct CommentRow: View {
    let comment: VideoComment
    /// Nil for a reply: replies have no replies of their own here.
    let player: PlaybackController?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: comment.author.isEmpty ? "Unknown" : comment.author)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, comment.isUploader ? 6 : 0)
                    .background(comment.isUploader ? AnyShapeStyle(.tint.opacity(0.3)) : AnyShapeStyle(.clear), in: .capsule)
                if let time = comment.time { Text(verbatim: time).font(.caption).foregroundStyle(.secondary) }
            }
            Text(verbatim: comment.text).font(.callout).textSelection(.enabled)
            HStack(spacing: 10) {
                if let likes = comment.likes, likes > 0 {
                    Label(likes.formatted(.number.notation(.compactName)), systemImage: "hand.thumbsup")
                }
                if comment.hearted { Image(systemName: "heart.fill").foregroundStyle(.pink).help("Hearted by the uploader") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let player, comment.hasReplies {
                replies(player.replyThreads[comment.id], player: player)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func replies(_ thread: PlaybackController.ReplyThread?, player: PlaybackController) -> some View {
        let expanded = thread?.expanded == true
        Button { player.toggleReplies(of: comment.id) } label: {
            Label(expanded ? "Hide replies" : replyLabel, systemImage: expanded ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.borderless)
        .font(.caption.weight(.semibold))
        if let thread, expanded {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(thread.replies) { CommentRow(comment: $0, player: nil) }
                switch thread.status {
                case .loading:
                    ProgressView().controlSize(.small)
                case .failed(let message):
                    HStack {
                        Text("Couldn't load replies: \(message)").foregroundStyle(.secondary)
                        Button("Try again") { player.loadMoreReplies(of: comment.id) }
                    }
                    .font(.caption)
                case .idle, .loaded:
                    if !thread.done {
                        Button("Show more replies") { player.loadMoreReplies(of: comment.id) }
                            .buttonStyle(.borderless).font(.caption.weight(.semibold))
                    }
                }
            }
            .padding(.leading, 20)
        }
    }

    private var replyLabel: String {
        switch comment.replyCount {
        case nil: "Replies"
        case 1: "1 reply"
        case let n?: "\(n.formatted()) replies"
        }
    }
}
