import AppKit
import GitCore
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
        /// Says that the user selected rows, or none. A selection made with
        /// `select(rows:)` isn't reported. It's said once the frame that shows
        /// the new selection has been drawn, and changes made before then, such
        /// as with an arrow key held down, are said once, as where they ended.
        public var selectRows: (IndexSet) -> Void
        /// Says that the user double-clicked the badge of a branch.
        public var checkOut: (CommitRowContent.Badge) -> Void
        /// Says that the user double-clicked a row anywhere else.
        public var goToRow: (Int) -> Void
        /// What right-clicking a row offers, given the badge under the pointer if
        /// there's one that names a ref (decision 65).
        public var menuEntries: (_ row: Int, _ badge: CommitRowContent.Badge?) -> [RefMenu.Entry] = { _, _ in [] }

        public init(
            count: @escaping () -> Int,
            content: @escaping (Int) -> CommitRowContent,
            loadText: @escaping (Range<Int>) async -> IndexSet,
            selectRows: @escaping (IndexSet) -> Void,
            checkOut: @escaping (CommitRowContent.Badge) -> Void = { _ in },
            goToRow: @escaping (Int) -> Void = { _ in },
            menuEntries: @escaping (_ row: Int, _ badge: CommitRowContent.Badge?) -> [RefMenu.Entry] = { _, _ in [] }
        ) {
            self.count = count
            self.content = content
            self.loadText = loadText
            self.selectRows = selectRows
            self.checkOut = checkOut
            self.goToRow = goToRow
            self.menuEntries = menuEntries
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
    /// The report of what the user selected, while it waits for the frame that
    /// shows it to be drawn.
    private var waitingReport: Timer?
    /// The row that the last press in the window selected, so that the click
    /// doesn't report it again when the button comes up.
    private var rowSelectedByPress: Int?

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
        tableView.allowsMultipleSelection = true
        tableView.setAccessibilityLabel("History")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clicked)
        tableView.doubleAction = #selector(doubleClicked)
        tableView.pointerMoved = { [unowned self] in updateHoveredBadge(atWindowLocation: $0) }
        tableView.pressed = { [unowned self] in press($0) }
        tableView.menuForRow = { [unowned self] in menu(forRow: $0, at: $1) }

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
    /// A report that's waiting is dropped, because its row numbers are the old
    /// rows', and the selection the model has comes next.
    public func reloadData() {
        waitingReport?.invalidate()
        waitingReport = nil
        isSettingSelection = true
        tableView.reloadData()
        isSettingSelection = false
        requestedRows = nil
        loadVisibleText()
        updateHoveredBadge()
    }

    /// The selected row, or nil when there's none or more than one.
    public var selectedRow: Int? {
        selectedRows.count == 1 ? selectedRows.first : nil
    }

    /// The selected rows.
    public var selectedRows: IndexSet {
        tableView.selectedRowIndexes
    }

    /// Selects a row or none, for a selection that didn't start in the list.
    public func select(row: Int?) {
        select(rows: row.map { IndexSet(integer: $0) } ?? [])
    }

    /// Selects rows or none, for a selection that didn't start in the list, such
    /// as a branch's commits. The first of them is scrolled into view, if none of
    /// them was selected before. While the user's own selection is waiting to be
    /// reported, the model's is older than the list's, so it's left alone.
    public func select(rows: IndexSet) {
        guard rows != selectedRows, waitingReport == nil else { return }
        isSettingSelection = true
        defer { isSettingSelection = false }
        let isNew = rows.intersection(selectedRows).isEmpty
        if rows.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            if isNew { revealSelectedRow() }
        }
    }

    /// Scrolls the first selected row into view, as little as that takes. A new
    /// list has no height until it's laid out, and scrolling then would put the row
    /// at the top of the list however near the top it is, so that waits.
    private func revealSelectedRow() {
        needsToRevealSelection = scrollView.contentView.bounds.height < tableView.rowHeight
        guard !needsToRevealSelection, let first = selectedRows.first else { return }
        tableView.scrollRowToVisible(first)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSettingSelection else { return }
        reportSelection()
    }

    /// Tells the model what's selected once the frame that shows it has been
    /// drawn. What the panels do about a new selection takes several frames'
    /// time, and the highlight would otherwise wait for it in the same frame. A
    /// timer that's already due fires after the run loop has committed the frame,
    /// where a main-queue block or a task can run before it. A report that's
    /// already waiting is replaced, so that holding down an arrow key doesn't
    /// send one for every row it passes.
    private func reportSelection() {
        waitingReport?.invalidate()
        let timer = Timer(timeInterval: 0, target: self, selector: #selector(sendReport), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        waitingReport = timer
    }

    @objc private func sendReport() {
        waitingReport = nil
        source.selectRows(selectedRows)
    }

    /// The row for uncommitted changes can't be one of several selected rows
    /// (decision 56). Command-clicking it selects it alone, and otherwise it's left
    /// out of what's selected with it.
    public func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard proposed.count > 1, source.count() > 0, source.content(0).isWorkingTree, proposed.contains(0) else { return proposed }
        return selectedRows.contains(0) ? proposed.subtracting(IndexSet(integer: 0)) : IndexSet(integer: 0)
    }

    /// Selects the row a click is on as soon as the button goes down, rather
    /// than when it comes up as AppKit does, which is about a tenth of a second
    /// sooner for a click (the table says which clicks).
    func press(_ event: NSEvent) {
        rowSelectedByPress = nil
        guard let row = tableView.rowToSelect(onPress: event) else { return }
        rowSelectedByPress = row
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func clicked() {
        reportClick(onRow: tableView.clickedRow, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
    }

    /// A click on the row that's already the only one selected reports it again,
    /// because the panels may be showing something else for it, such as a branch
    /// with only that commit. The row that the click's press selected has been
    /// reported already.
    func reportClick(onRow row: Int, modifiers: NSEvent.ModifierFlags) {
        let wasSelectedByPress = row == rowSelectedByPress
        rowSelectedByPress = nil
        guard row >= 0, !wasSelectedByPress, selectedRows == IndexSet(integer: row),
              modifiers.intersection([.command, .shift]).isEmpty
        else { return }
        reportSelection()
    }

    /// Finds the badge at a point in the table, if double-clicking it would do
    /// something. It works from what the row shows, because the row may not have
    /// a view yet while rows are being reloaded.
    func badge(at point: NSPoint) -> BadgePlace? {
        guard let place = anyBadge(at: point), source.content(place.row).badges[place.index].canCheckOut else { return nil }
        return place
    }

    /// Finds the badge at a point in the table, whatever it can do.
    private func anyBadge(at point: NSPoint) -> BadgePlace? {
        let row = tableView.row(at: point)
        guard row >= 0 else { return nil }
        let content = source.content(row)
        guard !content.badges.isEmpty else { return nil }
        let frame = tableView.frameOfCell(atColumn: 0, row: row)
        let layout = CommitRowLayout(content: content, size: frame.size)
        let inRow = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard let index = layout.badges.firstIndex(where: { $0.contains(inRow) }) else { return nil }
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

    /// What right-clicking a row offers, which acts on the ref under the pointer
    /// when it's over a badge.
    func menu(forRow row: Int, at point: NSPoint? = nil) -> NSMenu? {
        let place = point.flatMap(anyBadge)
        let badge = place.map { source.content($0.row).badges[$0.index] }.flatMap { $0.refName == nil ? nil : $0 }
        let entries = source.menuEntries(row, badge)
        return entries.isEmpty ? nil : RefMenu.make(entries)
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
/// when the pointer moves over it, for the border on the badge under it, and
/// when the button goes down in its window, before AppKit handles the press.
final class CommitTableView: NSTableView {
    /// Says where in the window the pointer is, or nil once it has left.
    var pointerMoved: (NSPoint?) -> Void = { _ in }
    /// Says that the left button went down in the table's window.
    var pressed: (NSEvent) -> Void = { _ in }
    /// What watches for presses while the table is in a window.
    private var pressMonitor: Any?
    /// Makes the menu for right-clicking a row, if it has one.
    var menuForRow: (Int, NSPoint) -> NSMenu? = { _, _ in nil }
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

    isolated deinit {
        if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchPresses()
        // SwiftUI may still be choosing a first responder, so wait a turn.
        Task { [weak self] in
            guard let self, let window, window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
    }

    /// A gesture recognizer decides what a click on the table does, and it selects
    /// the row only once the button comes up. A local monitor sees the press before
    /// the recognizers do, and passes it on as it is. Overriding `mouseDown(with:)`
    /// wouldn't do, because AppKit then handles clicks on the table without its
    /// recognizers, in another way.
    private func watchPresses() {
        if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
        pressMonitor = nil
        guard window != nil else { return }
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, let window, event.windowNumber == window.windowNumber { pressed(event) }
            return event
        }
    }

    /// The row that a press selects as the button goes down: that of a plain
    /// single click on one of the table's rows, in its window while that window
    /// is key, when the row isn't already the only one selected. Clicks with
    /// Command, Shift, Control or Option, double-clicks, clicks below the last
    /// row and clicks on anything over the table are left to AppKit.
    func rowToSelect(onPress event: NSEvent) -> Int? {
        guard event.type == .leftMouseDown, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
              let window, window.isKeyWindow, event.windowNumber == window.windowNumber,
              let frameView = window.contentView?.superview ?? window.contentView,
              let hit = frameView.hitTest(event.locationInWindow), hit.isDescendant(of: self)
        else { return nil }
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, selectedRowIndexes != IndexSet(integer: row) else { return nil }
        return row
    }

    /// The table only draws its own outline, which has square corners, when it's
    /// the one that returns the menu. So this returns it without asking the table,
    /// and the row gets a line of ours while the menu is open.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        rowOfMenu = row(at: point)
        return rowOfMenu >= 0 ? menuForRow(rowOfMenu, point) : nil
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
