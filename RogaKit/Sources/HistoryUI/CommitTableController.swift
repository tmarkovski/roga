import AppKit
import MenuUI

/// The commit list: a view-based `NSTableView` whose rows have a fixed
/// height and draw themselves (decision 7).
///
/// It doesn't know about repositories. It asks `Source` how many rows there
/// are and what each one shows, and as rows scroll into view it asks for the
/// text of those rows and the ones around them, then redraws the rows that
/// got their text.
///
/// Each row's text starts after that row's own graph (`CommitRowLayout`), so a
/// row looks the same whichever rows are in view, and nothing moves sideways
/// while scrolling.
public final class CommitTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public struct Source {
        /// The number of rows.
        public var count: () -> Int
        /// What a row shows. It's called while drawing, so it has to answer
        /// at once, with whatever text has loaded.
        public var content: (Int) -> CommitRowContent
        /// Loads the text for rows that are about to be drawn, and returns the
        /// rows that have new text. It's cancelled when other rows come into
        /// view before it finishes.
        public var loadText: (Range<Int>) async -> IndexSet
        /// Says that the user selected a row, or no row. A selection made with
        /// `select(row:)` isn't reported.
        public var selectRow: (Int?) -> Void
        /// Says that the user double-clicked the badge of a branch.
        public var checkOut: (CommitRowContent.Badge) -> Void
        /// Says that the user double-clicked a row anywhere else.
        public var goToRow: (Int) -> Void
        /// Says that the user chose to delete some of the branches on a commit, by
        /// the full names of all of them.
        public var deleteBranches: ([String]) -> Void
        /// Whether something's running that deleting a branch has to wait for.
        public var isBusy: () -> Bool

        public init(
            count: @escaping () -> Int,
            content: @escaping (Int) -> CommitRowContent,
            loadText: @escaping (Range<Int>) async -> IndexSet,
            selectRow: @escaping (Int?) -> Void,
            checkOut: @escaping (CommitRowContent.Badge) -> Void = { _ in },
            goToRow: @escaping (Int) -> Void = { _ in },
            deleteBranches: @escaping ([String]) -> Void = { _ in },
            isBusy: @escaping () -> Bool = { false }
        ) {
            self.count = count
            self.content = content
            self.loadText = loadText
            self.selectRow = selectRow
            self.checkOut = checkOut
            self.goToRow = goToRow
            self.deleteBranches = deleteBranches
            self.isBusy = isBusy
        }
    }

    /// A badge of a row.
    struct BadgePlace: Equatable {
        var row: Int
        var index: Int
    }

    public let scrollView = NSScrollView()
    public var source: Source

    private let tableView = CommitTableView()
    private var textTask: Task<Void, Never>?
    private var requestedRows: Range<Int>?
    /// Whether the code here is changing the selection, rather than the user.
    private var isSettingSelection = false
    /// The badge the pointer is over, if double-clicking it would do something.
    private var hoveredBadge: BadgePlace?
    /// Whether the selected row is waiting for the list to have a height before
    /// it's scrolled into view.
    private var needsToRevealSelection = false

    public init(source: Source) {
        self.source = source
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = CommitCellView.height
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.allowsMultipleSelection = false
        tableView.setAccessibilityLabel("History")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.pointerMoved = { [unowned self] in updateHoveredBadge(atWindowLocation: $0) }
        tableView.menuForRow = { [unowned self] in menu(forRow: $0) }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(visibleRowsMayHaveChanged), name: NSView.boundsDidChangeNotification, object: clipView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(visibleRowsMayHaveChanged), name: NSView.frameDidChangeNotification, object: clipView
        )
    }

    isolated deinit {
        textTask?.cancel()
    }

    /// Shows new rows, such as when history is loaded again. The selected row
    /// number and scroll position stay where they are, unless the row is gone.
    public func reloadData() {
        isSettingSelection = true
        tableView.reloadData()
        isSettingSelection = false
        requestedRows = nil
        loadVisibleText()
        updateHoveredBadge()
    }

    /// The selected row, or nil when there's none.
    public var selectedRow: Int? {
        tableView.selectedRow >= 0 ? tableView.selectedRow : nil
    }

    /// Selects a row or none, for a selection that didn't start in the list.
    /// A newly selected row is scrolled into view.
    public func select(row: Int?) {
        guard row != selectedRow else { return }
        isSettingSelection = true
        defer { isSettingSelection = false }
        if let row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            revealSelectedRow()
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// Scrolls the selected row into view, as little as that takes. A new list
    /// has no height until it's laid out, and scrolling then would put the row at
    /// the top of the list however near the top it is, so that waits.
    private func revealSelectedRow() {
        needsToRevealSelection = scrollView.contentView.bounds.height < tableView.rowHeight
        guard !needsToRevealSelection, let selectedRow else { return }
        tableView.scrollRowToVisible(selectedRow)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSettingSelection else { return }
        source.selectRow(selectedRow)
    }

    /// Finds the badge at a point in the table, if double-clicking it would do
    /// something. It works from what the row shows, because the row may not have
    /// a view yet while rows are being reloaded.
    func badge(at point: NSPoint) -> BadgePlace? {
        let row = tableView.row(at: point)
        guard row >= 0 else { return nil }
        let content = source.content(row)
        guard !content.badges.isEmpty else { return nil }
        let frame = tableView.frameOfCell(atColumn: 0, row: row)
        let layout = CommitRowLayout(content: content, size: frame.size)
        let inRow = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard let index = layout.badges.firstIndex(where: { $0.contains(inRow) }), content.badges[index].canCheckOut else { return nil }
        return BadgePlace(row: row, index: index)
    }

    /// Moves the border to the badge under the pointer, for when rows move under
    /// the pointer rather than the other way around.
    private func updateHoveredBadge() {
        updateHoveredBadge(atWindowLocation: tableView.window?.mouseLocationOutsideOfEventStream)
    }

    /// Moves the border to the badge at a point in the window, or to none when
    /// the pointer has left the table.
    private func updateHoveredBadge(atWindowLocation location: NSPoint?) {
        var hovered: BadgePlace?
        if let location {
            let point = tableView.convert(location, from: nil)
            if tableView.visibleRect.contains(point) { hovered = badge(at: point) }
        }
        guard hovered != hoveredBadge else { return }
        if let old = hoveredBadge { cell(atRow: old.row)?.hoveredBadge = nil }
        hoveredBadge = hovered
        if let hovered { cell(atRow: hovered.row)?.hoveredBadge = hovered.index }
    }

    private func cell(atRow row: Int) -> CommitCellView? {
        guard row < tableView.numberOfRows else { return nil }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CommitCellView
    }

    @objc private func doubleClicked() {
        guard let event = NSApp.currentEvent else { return }
        doubleClick(at: tableView.convert(event.locationInWindow, from: nil))
    }

    /// Checks out the branch of the badge at a point in the table, if there is
    /// one, and otherwise goes to the row there. Below the last row, this does
    /// nothing.
    func doubleClick(at point: NSPoint) {
        if let place = badge(at: point) {
            source.checkOut(source.content(place.row).badges[place.index])
        } else {
            let row = tableView.row(at: point)
            if row >= 0 { source.goToRow(row) }
        }
    }

    /// What right-clicking a row offers, which is one item for deleting, whatever
    /// points to its commit (decision 38). Its dialog lists the branches and holds the
    /// choice, including those whose badges don't fit in the row. A row with no branch
    /// that could go has no menu.
    func menu(forRow row: Int) -> NSMenu? {
        let content = source.content(row)
        guard content.hasBranchThatCanGo else { return nil }
        let branches = content.branches
        return RefMenu.make([
            .command("Delete…", isDestructive: true, isEnabled: !source.isBusy()) { [weak self] in
                self?.source.deleteBranches(branches)
            },
        ])
    }

    @objc private func visibleRowsMayHaveChanged(_ notification: Notification) {
        if needsToRevealSelection { revealSelectedRow() }
        loadVisibleText()
        updateHoveredBadge()
    }

    /// Asks for the text of the visible rows, and a screen's worth above and
    /// below them so that scrolling a little finds it ready.
    private func loadVisibleText() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        let margin = max(visible.length, 20)
        let rows = max(0, visible.location - margin)..<min(source.count(), visible.location + visible.length + margin)
        guard !rows.isEmpty, rows != requestedRows else { return }
        requestedRows = rows

        textTask?.cancel()
        let loadText = source.loadText
        textTask = Task { [weak self] in
            let loaded = await loadText(rows)
            // Rows that got their text before a cancellation are redrawn too.
            guard let self, !loaded.isEmpty else { return }
            tableView.reloadData(forRowIndexes: loaded, columnIndexes: IndexSet(integer: 0))
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        source.count()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: CommitCellView.identifier, owner: nil) as? CommitCellView
            ?? CommitCellView()
        view.content = source.content(row)
        view.hoveredBadge = hoveredBadge?.row == row ? hoveredBadge?.index : nil
        return view
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: CommitRowView.identifier, owner: nil) as? CommitRowView ?? CommitRowView()
    }
}

/// Takes keyboard focus when it appears in a window where nothing else has
/// it, so that the arrow keys move through history straight away. It also says
/// when the pointer moves over it, for the border on the badge under it.
final class CommitTableView: NSTableView {
    /// Says where in the window the pointer is, or nil once it has left.
    var pointerMoved: (NSPoint?) -> Void = { _ in }
    /// Makes the menu for right-clicking a row, if it has one.
    var menuForRow: (Int) -> NSMenu? = { _ in nil }
    /// The row that last asked for a menu, which is the one to outline if it opens.
    private var rowOfMenu = -1
    /// The line around the row whose menu is open.
    private var rowOutline: CommitRowOutlineView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("The table is made in code.")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI may still be choosing a first responder, so wait a turn.
        Task { [weak self] in
            guard let self, let window, window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
    }

    /// The table only draws its own outline, which has square corners, when it's
    /// the one that returns the menu. So this returns it without asking the table,
    /// and the row gets a line of ours while the menu is open.
    override func menu(for event: NSEvent) -> NSMenu? {
        rowOfMenu = row(at: convert(event.locationInWindow, from: nil))
        return rowOfMenu >= 0 ? menuForRow(rowOfMenu) : nil
    }

    /// This doesn't look for the row under the event it's given, because that
    /// isn't always the event that asked for the menu. The line goes in the clip
    /// view, which scrolls it along with the table, because loading history again
    /// behind the menu would put the table's rows on top of a line in the table.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        rowOutline?.removeFromSuperview()
        guard let clipView = enclosingScrollView?.contentView else { return }
        let outline = CommitRowOutlineView(aroundRow: convert(rect(ofRow: rowOfMenu), to: clipView))
        clipView.addSubview(outline)
        rowOutline = outline
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        rowOutline?.removeFromSuperview()
        rowOutline = nil
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pointerMoved(event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerMoved(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointerMoved(nil)
    }
}
