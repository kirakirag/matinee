import Foundation
import MatineeKit
import MediaPlayer
import Observation

/// Makes Matinee the system's Now Playing app, so AirPods taps, the keyboard's media keys and Control Center
/// play, pause, skip and seek the window's player, and show its title and position.
@MainActor final class NowPlaying {
    private weak var player: PlaybackController?
    /// What was last published, to republish only when the system's own extrapolation would be off (a seek).
    private var publishedAt = ContinuousClock.now
    private var publishedPosition = 0.0
    private var publishedRate = 0.0

    init(player: PlaybackController) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()
        add(center.togglePlayPauseCommand) { p, _ in p.isPaused || !p.isPresented ? p.resume() : p.handle(.togglePause) }
        add(center.playCommand) { p, _ in if p.isPaused || !p.isPresented { p.resume() } }
        add(center.pauseCommand) { p, _ in if !p.isPaused { p.handle(.togglePause) } }
        add(center.nextTrackCommand) { p, _ in p.handle(.next) }
        add(center.previousTrackCommand) { p, _ in p.handle(.previous) }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { p, _ in p.handle(.seek(10)) }
        add(center.skipBackwardCommand) { p, _ in p.handle(.seek(-10)) }
        add(center.changePlaybackPositionCommand) { p, event in
            if let e = event as? MPChangePlaybackPositionCommandEvent { p.seek(to: e.positionTime) }
        }
        observe()
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlaybackController, MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        command.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let p = self?.player, p.item != nil else { return .noActionableNowPlayingItem }
                action(p, event)
                return .success
            }
        }
    }

    /// Republishes whenever the item, pause state, rate or duration changes, and when the position jumps.
    private func observe() {
        withObservationTracking {
            publishIfNeeded()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func publishIfNeeded() {
        guard let p = player else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let item = p.item, p.phase == .playing || p.isPresented else {
            if center.nowPlayingInfo != nil { center.nowPlayingInfo = nil; center.playbackState = .stopped }
            return
        }
        let rate = p.isPaused || p.phase != .playing ? 0 : p.speed
        let expected = publishedPosition + publishedRate * ((ContinuousClock.now - publishedAt) / .seconds(1))
        let title = item.displayTitle ?? item.title
        let changed = rate != publishedRate || abs(p.position - expected) > 1.5
            || center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String != title
            || center.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double != p.duration
        guard changed else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: item.channelName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p.position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let d = p.duration { info[MPMediaItemPropertyPlaybackDuration] = d }
        center.nowPlayingInfo = info
        center.playbackState = rate > 0 ? .playing : .paused
        publishedAt = .now
        publishedPosition = p.position
        publishedRate = rate
    }
}
