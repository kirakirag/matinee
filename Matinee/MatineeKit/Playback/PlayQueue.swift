/// An ordered list of things to play and where the player is in it.
public struct PlayQueue<Element: Sendable>: Sendable {
    private var items: [Element]
    public private(set) var position: Int

    /// `start` is clamped into the list.
    public init(_ items: [Element], start: Int) {
        self.items = items
        position = min(max(start, 0), max(items.count - 1, 0))
    }

    public var count: Int { items.count }
    public var current: Element? { items.indices.contains(position) ? items[position] : nil }

    /// The next item, now current; nil at the end, where the queue stays put.
    public mutating func next() -> Element? {
        guard position + 1 < items.count else { return nil }
        position += 1
        return items[position]
    }

    /// Adds items after the current end, e.g. later pages of a playlist; the position stays.
    public mutating func append(contentsOf more: [Element]) {
        items += more
    }

    /// The previous item, now current; nil at the start, where the queue stays put.
    public mutating func previous() -> Element? {
        guard position > 0, !items.isEmpty else { return nil }
        position -= 1
        return items[position]
    }
}
