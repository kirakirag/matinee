import Foundation
import Testing
import MatineeKit

private struct Row: Identifiable, Equatable {
    let id: Int
    var text: String
}

private func rows(_ texts: [String]) -> [Row] {
    texts.enumerated().map { Row(id: $0.offset, text: $0.element) }
}

@Test func identicalIsEmpty() {
    let a = rows(["a", "b", "c"])
    #expect(RowDiff.changedRows(old: a, new: a) == IndexSet())
}

@Test func differentIdsIsNil() {
    let a = rows(["a", "b", "c"])
    #expect(RowDiff.changedRows(old: a, new: Array(a.reversed())) == nil)
    #expect(RowDiff.changedRows(old: a, new: a + [Row(id: 9, text: "d")]) == nil)
}

@Test func sameIdsChangedContentReloadsOnlyThoseRows() {
    let old = rows(["a", "b", "c", "d", "e"])
    var new = old
    new[1].text = "B"
    new[3].text = "D"
    #expect(RowDiff.changedRows(old: old, new: new) == IndexSet([1, 3]))
}
