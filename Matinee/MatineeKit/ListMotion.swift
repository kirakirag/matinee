/// Keyboard moves in a list. Without a selection, moves start at the top visible row
/// (NSTableView's own ↑ jumps to the last row). Home/End select the first/last row.
/// Rows that `isSelectable` rejects (e.g. a divider) are skipped.
public enum ListMotion {
    public enum Move { case up, down, home, end }

    public static func target(_ move: Move, selected: Int, firstVisible: Int, count: Int,
                              isSelectable: (Int) -> Bool = { _ in true }) -> Int? {
        guard count > 0 else { return nil }
        /// The first selectable row from `start` stepping by `step`, within the list.
        func scan(_ start: Int, _ step: Int) -> Int? {
            var i = start
            while i >= 0 && i < count {
                if isSelectable(i) { return i }
                i += step
            }
            return nil
        }
        switch move {
        case .home: return scan(0, 1)
        case .end: return scan(count - 1, -1)
        case .up, .down:
            guard selected >= 0 else {
                let start = min(firstVisible, count - 1)
                return scan(start, 1) ?? scan(start, -1)
            }
            let step = move == .down ? 1 : -1
            let next = min(max(selected + step, 0), count - 1)
            return scan(next, step) ?? selected
        }
    }
}
