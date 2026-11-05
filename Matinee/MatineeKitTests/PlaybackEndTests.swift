import Testing
@testable import MatineeKit

struct PlaybackEndTests {
    private func decide(playing: Bool = true, loaded: Bool = true, position: Double = 600, duration: Double? = 600,
                        failure: String? = nil, hasNext: Bool = true) -> PlaybackEnd {
        PlaybackEnd.decide(isPlaying: playing, fileLoaded: loaded, position: position, duration: duration,
                           streamFailure: failure, hasNext: hasNext)
    }

    @Test func staleEofDoesNotAdvance() {
        #expect(decide(playing: false) == .ignore)
        #expect(decide(loaded: false) == .ignore)
    }

    @Test func eofWithStreamFailureFails() {
        #expect(decide(failure: "HTTP error 403") == .failed("Playback stopped: HTTP error 403"))
    }

    @Test func eofShortOfDurationFails() {
        #expect(decide(position: 300) == .failed("Playback stopped."))
        #expect(decide(position: 300, hasNext: false) == .failed("Playback stopped."))
    }

    @Test func eofAtEndAdvancesWhenNext() {
        #expect(decide() == .advance)
        #expect(decide(position: 598.5) == .advance)
    }

    @Test func eofAtEndStaysWithoutNext() {
        #expect(decide(hasNext: false) == .stay)
    }
}
