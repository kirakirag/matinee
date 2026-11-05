import Testing
@testable import MatineeKit

struct ListMotionTests {
    @Test func upWithoutSelectionStartsAtTopVisibleRowNotTheEnd() {
        #expect(ListMotion.target(.up, selected: -1, firstVisible: 40, count: 500) == 40)
    }

    @Test func downWithoutSelectionStartsAtTopVisibleRow() {
        #expect(ListMotion.target(.down, selected: -1, firstVisible: 0, count: 500) == 0)
    }

    @Test func stepsAreClamped() {
        #expect(ListMotion.target(.up, selected: 0, firstVisible: 0, count: 5) == 0)
        #expect(ListMotion.target(.down, selected: 4, firstVisible: 0, count: 5) == 4)
        #expect(ListMotion.target(.down, selected: 2, firstVisible: 0, count: 5) == 3)
    }

    @Test func homeAndEndSelectFirstAndLast() {
        #expect(ListMotion.target(.home, selected: 300, firstVisible: 290, count: 500) == 0)
        #expect(ListMotion.target(.end, selected: 3, firstVisible: 0, count: 500) == 499)
    }

    @Test func emptyListHasNoTarget() {
        #expect(ListMotion.target(.down, selected: -1, firstVisible: 0, count: 0) == nil)
    }

    // Row 2 is a divider.
    private let notTwo: (Int) -> Bool = { $0 != 2 }

    @Test func movesSkipUnselectableRows() {
        #expect(ListMotion.target(.down, selected: 1, firstVisible: 0, count: 5, isSelectable: notTwo) == 3)
        #expect(ListMotion.target(.up, selected: 3, firstVisible: 0, count: 5, isSelectable: notTwo) == 1)
    }

    @Test func staysWhenNothingSelectableLiesAhead() {
        #expect(ListMotion.target(.down, selected: 4, firstVisible: 0, count: 5, isSelectable: { $0 < 2 }) == 4)
        #expect(ListMotion.target(.up, selected: 1, firstVisible: 0, count: 3, isSelectable: { $0 >= 2 }) == 1)
    }

    @Test func withoutSelectionAnUnselectableStartMovesToTheNextRow() {
        #expect(ListMotion.target(.down, selected: -1, firstVisible: 2, count: 5, isSelectable: notTwo) == 3)
    }

    @Test func homeAndEndLandOnSelectableRows() {
        #expect(ListMotion.target(.home, selected: 3, firstVisible: 0, count: 5, isSelectable: { $0 > 0 }) == 1)
        #expect(ListMotion.target(.end, selected: 0, firstVisible: 0, count: 5, isSelectable: { $0 < 4 }) == 3)
    }
}
