/// A row of the player's quality list.
public enum QualityChoice: Hashable, Sendable {
    /// The downloaded file.
    case saved
    /// Streams the best the video has.
    case best
    /// Streams at most this height.
    case height(Int)

    /// A saved video lists its file first, then the streams (Best works before the heights are known). A streamed
    /// video lists nothing until it is resolved.
    public static func list(saved: Bool, heights: [Int]) -> [QualityChoice] {
        guard saved || !heights.isEmpty else { return [] }
        return (saved ? [.saved] : []) + [.best] + heights.map(QualityChoice.height)
    }
}
