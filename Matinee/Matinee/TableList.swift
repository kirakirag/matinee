import AppKit
import MatineeKit
import SwiftUI

/// A single-column list backed by `NSTableView`, with SwiftUI rows.
/// SwiftUI's `List` spends ~4 ms of main-thread time per selection change (measured, even with plain-text
/// rows); here moving the selection is an AppKit highlight change, so arrow keys stay within a frame.
/// Keys: ↑/↓, j/k, Home/End, and the table scrolls the selection into view.
struct TableList<Item: Identifiable & Equatable, Row: View>: NSViewRepresentable where Item.ID: Hashable {
    let items: [Item]
    @Binding var selection: Item.ID?
    let rowHeight: CGFloat
    /// Bump to make the table the first responder.
    var focusRequest: Int = 0
    /// Called with the selected item on Return/Enter or double-click.
    var onActivate: ((Item) -> Void)?
    /// Called with the selected item once the user's selection has stayed on it for 150 ms.
    var onDwell: ((Item) -> Void)?
    /// Called with the selected item for an unmodified letter key; true means handled.
    var onKey: ((Item, Character) -> Bool)?
    /// Called when ↓ is pressed on the last row and when the last row scrolls into view (e.g. to load a next page).
    var onReachEnd: (() -> Void)?
    /// Called with a row's index each time it is shown (e.g. to fetch further pages ahead of the scroll).
    var onRowShown: ((Int) -> Void)?
    /// A row's thumbnail; when set, showing a row starts loading the next few rows' thumbnails.
    var thumbnailAhead: ((Item) -> URL?)?
    /// Items it rejects (e.g. a divider) can't be selected and are skipped by the keys.
    var isSelectable: ((Item) -> Bool)?
    /// Right-click menu entries for a (selectable) row. Empty means no menu.
    var contextMenu: [(title: String, action: (Item) -> Void)] = []
    @ViewBuilder let row: (Item) -> Row

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTable()
        table.headerView = nil
        table.style = .inset
        table.rowHeight = rowHeight
        table.usesAutomaticRowHeights = false
        table.allowsEmptySelection = true
        // Type-to-select builds a view for every row (so a stray "1" fired onReachEnd), and can't read SwiftUI cells anyway.
        table.allowsTypeSelect = false
        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.activate = { [weak coordinator = context.coordinator, weak table] in coordinator?.activate(row: table?.selectedRow ?? -1) }
        table.onKey = { [weak coordinator = context.coordinator, weak table] ch in coordinator?.key(ch, row: table?.selectedRow ?? -1) ?? false }
        table.isSelectable = { [weak coordinator = context.coordinator] i in
            guard let c = coordinator, i < c.items.count else { return true }
            return c.parent?.isSelectable?(c.items[i]) ?? true
        }
        table.onDownAtEnd = { [weak coordinator = context.coordinator] in coordinator?.parent?.onReachEnd?() }
        if !contextMenu.isEmpty {
            table.menu = NSMenu()
            table.menu?.delegate = context.coordinator
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if items != c.items {   // O(1) when both share storage, e.g. on a selection-only update
            let changed = RowDiff.changedRows(old: c.items, new: items)
            c.items = items
            if items.isEmpty { c.table?.scroll(.zero) }   // the next contents start at the top
            if changed == nil {
                c.table?.reloadData()
            } else if let changed, !changed.isEmpty {
                c.table?.reloadData(forRowIndexes: changed, columnIndexes: [0])
            }
        } else {
            // Equal contents in new storage (e.g. a reload that found nothing new): keep the new storage,
            // or every later update compares all rows element by element (~9 ms for 20,000 rows).
            c.items = items
        }
        c.applySelection()
        if focusRequest != c.focusRequest, let table = c.table {
            c.focusRequest = focusRequest
            DispatchQueue.main.async { table.window?.makeFirstResponder(table) }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: TableList?
        weak var table: KeyTable?
        var items: [Item] = []
        var focusRequest = 0
        private var applying = false

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard let isSelectable = parent?.isSelectable, row >= 0, row < items.count else { return true }
            return isSelectable(items[row])
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, row < items.count else { return nil }
            let cell = tableView.makeView(withIdentifier: HostCell.id, owner: nil) as? HostCell ?? HostCell()
            cell.show(AnyView(parent.row(items[row])))
            if let onRowShown = parent.onRowShown {
                DispatchQueue.main.async { onRowShown(row) }   // not during the table's layout pass
            }
            if let thumbnailAhead = parent.thumbnailAhead {
                let ahead = items[(row + 1)..<min(row + 9, items.count)].compactMap(thumbnailAhead)
                if !ahead.isEmpty { DispatchQueue.main.async { ThumbnailLoader.shared.prefetch(ahead) } }
            }
            if row == items.count - 1, let onReachEnd = parent.onReachEnd {
                DispatchQueue.main.async { onReachEnd() }   // not during the table's layout pass
            }
            return cell
        }

        private var dwell: Task<Void, Never>?

        @objc func doubleClicked() { activate(row: table?.clickedRow ?? -1) }

        func activate(row r: Int) {
            guard let onActivate = parent?.onActivate, r >= 0 && r < items.count else { return }
            onActivate(items[r])
        }

        func key(_ ch: Character, row r: Int) -> Bool {
            guard let onKey = parent?.onKey, r >= 0 && r < items.count else { return false }
            return onKey(items[r], ch)
        }

        private var menuRow: Item?

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            menuRow = nil
            guard let parent, let r = table?.clickedRow, r >= 0, r < items.count,
                  parent.isSelectable?(items[r]) ?? true else { return }
            menuRow = items[r]
            for (i, entry) in parent.contextMenu.enumerated() {
                let item = NSMenuItem(title: entry.title, action: #selector(menuAction), keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
        }

        @objc func menuAction(_ sender: NSMenuItem) {
            guard let parent, let row = menuRow, sender.tag < parent.contextMenu.count else { return }
            parent.contextMenu[sender.tag].action(row)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table, let parent else { return }
            let r = table.selectedRow
            let id = r >= 0 && r < items.count ? items[r].id : nil
            if id != parent.selection { parent.selection = id }
            if r >= 0 { table.scrollRowToVisible(r) }
            dwell?.cancel()
            if r >= 0 && r < items.count, let onDwell = parent.onDwell {
                let item = items[r]
                dwell = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    if !Task.isCancelled { onDwell(item) }
                }
            }
        }


        /// Mirrors the binding into the table without echoing it back.
        func applySelection() {
            guard let table, let parent else { return }
            let want = parent.selection.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
            guard want != table.selectedRow else { return }
            applying = true
            if want >= 0 {
                table.selectRowIndexes([want], byExtendingSelection: false)
                table.scrollRowToVisible(want)
            } else {
                table.deselectAll(nil)
            }
            applying = false
        }
    }

    final class HostCell: NSTableCellView {
        static var id: NSUserInterfaceItemIdentifier { .init("HostCell") }
        private let host = NSHostingView(rootView: AnyView(EmptyView()))

        init() {
            super.init(frame: .zero)
            identifier = Self.id
            host.translatesAutoresizingMaskIntoConstraints = false
            host.sizingOptions = []
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func show(_ view: AnyView) { host.rootView = view }
    }

    /// ↑/↓ and j/k (no modifiers) move the selection, Home/End select the first/last row, Return/Enter activates.
    final class KeyTable: NSTableView {
        var activate: (() -> Void)?
        var onKey: ((Character) -> Bool)?
        var onDownAtEnd: (() -> Void)?
        var isSelectable: ((Int) -> Bool)?

        override func keyDown(with event: NSEvent) {
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
                if event.isARepeat { return }
                return activate?() ?? super.keyDown(with: event)
            }
            let move: ListMotion.Move? = switch (event.keyCode, event.charactersIgnoringModifiers) {
            case (126, _), (_, "k"): .up
            case (125, _), (_, "j"): .down
            case (115, _): .home
            case (119, _): .end
            default: nil
            }
            let firstVisible = max(rows(in: visibleRect).location, 0)
            if mods.isEmpty, move == .down, numberOfRows > 0, selectedRow == numberOfRows - 1 { onDownAtEnd?() }
            guard mods.isEmpty, let move, let next = ListMotion.target(move, selected: selectedRow, firstVisible: firstVisible, count: numberOfRows,
                                                  isSelectable: isSelectable ?? { _ in true }) else {
                if mods.isEmpty, !event.isARepeat, let ch = event.charactersIgnoringModifiers?.first,
                   event.charactersIgnoringModifiers?.count == 1, onKey?(ch) == true { return }
                return super.keyDown(with: event)
            }
            selectRowIndexes([next], byExtendingSelection: false)
            scrollRowToVisible(next)
        }
    }
}
