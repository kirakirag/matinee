import AppKit
import MatineeKit
import Observation

/// Window-level navigation state, so menu commands and global keys can switch sections and move focus.
@MainActor @Observable
final class Navigator {
    var section: AppSection = .subscriptions
    /// Bumped to ask the search field to take focus.
    private(set) var searchFocusRequest = 0
    /// Bumped to ask the current list's filter field to take focus.
    private(set) var filterRequest = 0
    /// Bumped to ask the current section to reload.
    private(set) var refreshRequest = 0
    /// Bumped by ⌘⌫.
    private(set) var deleteRequest = 0
    /// Bumped by ⌘C while the player is closed: the visible list copies its selected row's link.
    private(set) var copyRequest = 0
    /// Pushed pages per section; each tab's NavigationStack binds to its own entry.
    var paths: [AppSection: [Route]] = Dictionary(uniqueKeysWithValues: AppSection.allCases.map { ($0, []) })
    /// A short message for the window (e.g. a pasted link that isn't YouTube's), cleared after 2 s.
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Set once at launch. While it is presented, player keys go to it.
    @ObservationIgnored var player: PlaybackController?

    func perform(_ cmd: GlobalCommand) {
        switch cmd {
        case .section(let s):
            guard s != .forYou || ForYouModel.isEnabled else { return }   // hidden while Recommendations is off
            dismissPlayer()
            section = s
        case .focusSearch:
            dismissPlayer()
            section = .search
            searchFocusRequest += 1
        case .filterList:
            dismissPlayer()
            filterRequest += 1
        case .refresh: refreshRequest += 1
        case .toggleSidebar: NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        case .resumePlayer: player?.resume()
        case .paste: pasteLink()
        case .delete: deleteRequest += 1
        case .copyLink:
            if let player, player.isPresented {
                copy(player.item.flatMap { YouTubeURL.watchURL(videoId: $0.videoId) })
            } else {
                copyRequest += 1
            }
        }
    }

    func push(_ r: Route) {
        dismissPlayer()
        paths[section, default: []].append(r)
    }

    /// Opens a pasted or typed link: a video in the player, a channel or playlist on the current section's stack.
    func open(_ link: PastedLink) {
        switch link {
        case .video(let id, let start):
            player?.open(.init(videoId: id, title: "", channelName: "", channelId: nil, lengthSeconds: nil, publishedAt: nil, startAt: start))
        case .channel(let ref): push(.channel(ref, name: nil))
        case .playlist(let id): push(.playlist(id: id, title: nil))
        }
    }

    func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// Puts a link on the pasteboard and says so. Nil (an ID that failed validation) copies nothing.
    func copy(_ url: URL?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        show(notice: "Link copied")
    }

    private func pasteLink() {
        guard let link = NSPasteboard.general.string(forType: .string).flatMap(PastedLink.parse) else {
            show(notice: "That's not a YouTube link")
            return
        }
        open(link)
    }

    @discardableResult func pop() -> Bool {
        guard paths[section]?.popLast() != nil else { return false }
        return true
    }

    private func dismissPlayer() {
        if let player, player.isPresented { player.dismiss() }
    }

    private nonisolated static let specialKeys: [UInt16: SpecialKey] = [123: .left, 124: .right, 125: .down, 126: .up, 53: .escape, 49: .space]

    private var keyMonitor: Any?

    /// Global chords are handled here, before the menu bar sees them: going through the menu makes AppKit
    /// flash the menu title on every press (~20 ms each), so fast ⌘1…⌘6 runs queue up into visible lag.
    /// The Go menu still lists them. While the player is up, its keys come next.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] original in
            // Shortcuts by physical key under a non-Latin layout; what's passed on (lists, buttons) gets the same.
            let event = original.window?.firstResponder is NSText ? original : KeyLayout.latin(original)
            guard let self, event.window?.attachedSheet == nil,
                  let chars = event.charactersIgnoringModifiers?.lowercased() else { return event }
            let flags = event.modifierFlags
            let chord = KeyChord(key: chars, command: flags.contains(.command), shift: flags.contains(.shift),
                                 option: flags.contains(.option), control: flags.contains(.control))
            let keyCode = event.keyCode, window = event.window, special = Self.specialKeys[keyCode]
            // ⌘C with text selected in a paused frame copies that text (the overlay handles it), not the video's link.
            if chord == KeyChord(key: "c", command: true),
               MainActor.assumeIsolated({ LiveTextLayer.hasSelection }) { return event }
            let handled = MainActor.assumeIsolated {
                switch KeyRouting.route(chord: chord, keyCode: keyCode, special: special,
                                        playerPresented: self.player?.isPresented ?? false,
                                        textFieldFocused: window?.firstResponder is NSText,
                                        hasRoute: !(self.paths[self.section]?.isEmpty ?? true),
                                        playerNeedsAccount: self.player?.phase == .failed(.needsAccount),
                                        qualityMenuOpen: self.player?.qualityMenuIndex != nil,
                                        fullscreen: self.player?.isFullscreen ?? false,
                                        panelOpen: self.player?.panelOpen ?? false) {
                case .global(let cmd): self.perform(cmd)
                case .player(let cmd): self.player?.handle(cmd)
                case .qualityMenu(let key): self.player?.qualityMenu(key)
                case .panel(let key): self.player?.panelKey(key)
                case .openBrave: self.player?.openInBrave()
                case .pop: self.pop()
                case .swallow: break
                case .pass: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }
}
