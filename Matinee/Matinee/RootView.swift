import AppKit
import MatineeKit
import SwiftUI

struct RootView: View {
    let store: Result<Store, any Error>
    let feed: FeedModel?
    let search: SearchModel?
    let historyDearrow: DeArrowService?
    let listWorker: WorkerClient
    let forYou: ForYouModel?
    /// Settings' Recommendations: For You is in the sidebar only while it's on.
    @AppStorage("recommendations") private var recommendations = true
    @Environment(Navigator.self) private var nav
    @Environment(PlaybackController.self) private var player: PlaybackController?
    @Environment(DownloadManager.self) private var downloads: DownloadManager?

    var body: some View {
        @Bindable var nav = nav
        // TabView keeps each tab's state with only the visible tab in the window: hidden tabs can't
        // hold keyboard focus, and nothing is rebuilt on a switch.
        TabView(selection: $nav.section) {
            ForEach(AppSection.allCases.filter { $0 != .forYou || recommendations }, id: \.self) { s in
                Tab(value: s) {
                    SectionStack(section: s, root: { tab(s) }, page: { destination($0, in: s) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .safeAreaInset(edge: .top, spacing: 0) { NowPlayingBanner() }
                } label: {
                    Label { Text(s.title) } icon: { Image(nsImage: sidebarIcons[s]!) }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Always in the window (PlayerView hides itself when dismissed); this body reads nothing from the player.
        .overlay { if let player { PlayerView(player: player) } }
        .overlay(alignment: .bottom) { NoticeView() }
        .modifier(FullscreenToolbar())
        .onAppear { nav.installKeyMonitor() }
        .onChange(of: recommendations) { _, on in if !on, nav.section == .forYou { nav.section = .subscriptions } }
        // One toolbar for every tab, and it must not read nav.section: anything it reads from the
        // current section makes SwiftUI rebuild the window toolbar on every switch (~20 ms each).
        .toolbar {
            DownloadsIndicator()
            Button { nav.perform(.refresh) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    @ViewBuilder private func destination(_ route: Route, in section: AppSection) -> some View {
        switch route {
        case .channel(let ref, let name):
            if case .success(let store) = store, let historyDearrow {
                ChannelView(section: section, store: store, worker: listWorker, dearrow: historyDearrow, ref: ref, name: name)
            }
        case .playlist(let id, let title):
            if case .success(let store) = store, let historyDearrow {
                PlaylistView(section: section, store: store, worker: listWorker, dearrow: historyDearrow, id: id, title: title)
            }
        }
    }

    @ViewBuilder private func tab(_ section: AppSection) -> some View {
        switch (section, store) {
        case (.history, .success(let store)):
            if let historyDearrow { HistoryView(store: store, dearrow: historyDearrow) }
        case (.history, .failure(let error)):
            ContentUnavailableView("Can't open the database", systemImage: "exclamationmark.triangle",
                                   description: Text(error.localizedDescription))
        case (.search, .success):
            if let search { SearchView(model: search) }
        case (.subscriptions, .success):
            if let feed { FeedView(model: feed) }
        case (.playlists, .success(let store)):
            PlaylistsSection(store: store)
        case (.forYou, .success):
            if let forYou { ForYouView(model: forYou) }
        case (.downloads, .success):
            if let downloads, let historyDearrow { DownloadsView(manager: downloads, dearrow: historyDearrow) }
        case (.settings, _):
            SettingsView(store: try? store.get())
        default:
            ContentUnavailableView(section.title, systemImage: section.symbol,
                                   description: Text("Coming in a later build"))
        }
    }
}

/// Hides the window toolbar while the player is up in fullscreen. A modifier, so RootView's body doesn't read the player.
private struct FullscreenToolbar: ViewModifier {
    @Environment(PlaybackController.self) private var player: PlaybackController?

    func body(content: Content) -> some View {
        content.toolbarVisibility(player.map { $0.isFullscreen && $0.isPresented } == true ? .hidden : .automatic, for: .windowToolbar)
    }
}

/// Navigator's transient notice. Its own view, so a notice doesn't re-evaluate RootView's body.
private struct NoticeView: View {
    @Environment(Navigator.self) private var nav

    var body: some View {
        if let notice = nav.notice {
            Text(notice)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 24)
                .allowsHitTesting(false)
        }
    }
}

/// One section's pages over its main view. Not NavigationStack: inside the sidebar TabView, macOS hosts every
/// section's stack in one shared split view, and they mixed up (a page pushed in one section showed in another, or
/// never). Covered views stay loaded, like NavigationStack's, so going back keeps results, selection and scrolling.
private struct SectionStack<Root: View, Page: View>: View {
    let section: AppSection
    @ViewBuilder let root: () -> Root
    @ViewBuilder let page: (Route) -> Page
    @Environment(Navigator.self) private var nav
    /// The first responder before each push, given back when that page is popped (covered views don't reappear).
    @State private var responders: [WeakResponder] = []

    var body: some View {
        let path = nav.paths[section] ?? []
        ZStack {
            covered(root(), visible: path.isEmpty)
            ForEach(Array(path.enumerated()), id: \.offset) { i, route in
                covered(VStack(alignment: .leading, spacing: 0) {
                    Button { nav.pop() } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                        .help("Back (Esc)")
                        .padding(.horizontal, 10).padding(.top, 6)
                    page(route)
                }
                .background(.background), visible: i == path.count - 1)
                .id(route)   // another route at the same depth is a new page
            }
        }
        .onChange(of: path.count) { old, new in
            if new > old {
                responders.append(WeakResponder(NSApp.keyWindow?.firstResponder))
            } else {
                let restore = responders.count > new ? responders[new].value : nil
                responders.removeLast(max(0, responders.count - new))
                if let view = restore as? NSView { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
            }
        }
    }

    private func covered(_ view: some View, visible: Bool) -> some View {
        // Disabled too: a covered view's single-key shortcuts (a channel page's D) must not fire from underneath.
        view.opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible).disabled(!visible)
    }
}

private struct WeakResponder {
    weak var value: NSResponder?
    init(_ value: NSResponder?) { self.value = value }
}
