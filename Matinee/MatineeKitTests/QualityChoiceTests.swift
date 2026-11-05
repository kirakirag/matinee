import Testing
import MatineeKit

@Test func streamedVideoListsBestThenHeights() {
    #expect(QualityChoice.list(saved: false, heights: [1080, 720]) == [.best, .height(1080), .height(720)])
}

@Test func streamedVideoHasNoListUntilResolved() {
    #expect(QualityChoice.list(saved: false, heights: []) == [])
}

@Test func savedVideoListsTheFileFirstEvenBeforeHeightsAreKnown() {
    #expect(QualityChoice.list(saved: true, heights: []) == [.saved, .best])
    #expect(QualityChoice.list(saved: true, heights: [1080, 360]) == [.saved, .best, .height(1080), .height(360)])
}
