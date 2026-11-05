import Foundation

/// Compares two snapshots of a list. Same ids in the same order yield the indexes whose content changed;
/// any other change to the id sequence yields nil, meaning the table must reload fully.
public enum RowDiff {
    public static func changedRows<T: Identifiable & Equatable>(old: [T], new: [T]) -> IndexSet? {
        guard old.map(\.id) == new.map(\.id) else { return nil }
        return IndexSet(old.indices.filter { old[$0] != new[$0] })
    }
}
