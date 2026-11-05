/// Decides, on each time report, whether playback is inside a segment to skip.
public struct SponsorSkipper {
    private let segments: [SponsorSegment]
    private var undone: Set<String> = []
    private var last: SponsorSegment?

    public init(segments: [SponsorSegment], enabled: Set<String>) {
        self.segments = segments.filter { enabled.contains($0.category) }.sorted { $0.start < $1.start }
    }

    /// The segment to skip at `position`, if any. Every entry into a segment skips it again, unless it was undone;
    /// the last half second is left alone, as skipping it would save nothing.
    public mutating func check(position: Double) -> SponsorSegment? {
        guard let s = segments.first(where: { !undone.contains($0.uuid) && $0.start <= position && position < $0.end - 0.5 })
        else { return nil }
        last = s
        return s
    }

    /// Where to go back to for the last skip, which is then never skipped again.
    public mutating func undo() -> Double? {
        guard let s = last else { return nil }
        last = nil
        undone.insert(s.uuid)
        return s.start
    }
}
