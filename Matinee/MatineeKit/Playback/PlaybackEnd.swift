/// What mpv's end-of-file means. With keep-open, a stream that dies mid-play also ends this way, so it only
/// counts as a real end when no stream failure is recorded and the position is at the duration.
public enum PlaybackEnd: Equatable, Sendable {
    /// Not the file now playing (a stale event).
    case ignore
    case advance
    case stay
    case failed(String)

    public static func decide(isPlaying: Bool, fileLoaded: Bool, position: Double, duration: Double?,
                              streamFailure: String?, hasNext: Bool) -> PlaybackEnd {
        guard isPlaying, fileLoaded else { return .ignore }
        if let streamFailure { return .failed("Playback stopped: \(streamFailure)") }
        if let duration, position < duration - 2 { return .failed("Playback stopped.") }
        return hasNext ? .advance : .stay
    }
}
