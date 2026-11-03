import AppKit
import CommitGraph

/// The commit list: a view-based `NSTableView` whose rows have a fixed
/// height and draw themselves (decision 7).
///
/// It doesn't know about repositories. It asks `Source` how many rows there
/// are and what each one shows, and as rows scroll into view it asks for the
/// text of those rows and the ones around them, then redraws the rows that
/// got their text.
///
/// The graph is as wide as the rows in view need, up to
/// `LaneRenderer.maxColumns`. While scrolling it only widens, as wider rows
/// come into view, so the text doesn't move back and forth. Once scrolling
/// stops, it fits the rows in view again. When the rows are reloaded with
/// the same ones in view, such as when the rest of history arrives, it stays
/// as it was.
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

        public init(
            count: @escaping () -> Int,
            content: @escaping (Int) -> CommitRowContent,
            loadText: @escaping (Range<Int>) async -> IndexSet,
            selectRow: @escaping (Int?) -> Void,
            checkOut: @escaping (CommitRowContent.Badge) -> Void = { _ in }
        ) {
            self.count = count
            self.content = content
            self.loadText = loadText
            self.selectRow = selectRow
            self.checkOut = checkOut
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
    private var graphColumns = 0
    private var fitGraphTask: Task<Void, Never>?
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
        fitGraphTask?.cancel()
    }

    /// Shows new rows, such as when history is loaded again. The selected row
    /// number and scroll position stay where they are, unless the row is gone.
    public func reloadData() {
        isSettingSelection = true
        tableView.reloadData()
        isSettingSelection = false
        requestedRows = nil
        sizeGraph(canNarrow: true)
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
        let layout = CommitRowLayout(content: content, graphColumns: graphColumns, size: frame.size)
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
    /// one. Double-clicking anywhere else in a row does nothing.
    func doubleClick(at point: NSPoint) {
        guard let place = badge(at: point) else { return }
        source.checkOut(source.content(place.row).badges[place.index])
    }

    @objc private func visibleRowsMayHaveChanged(_ notification: Notification) {
        if needsToRevealSelection { revealSelectedRow() }
        sizeGraph(canNarrow: false)
        loadVisibleText()
        updateHoveredBadge()

        fitGraphTask?.cancel()
        fitGraphTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.sizeGraph(canNarrow: true)
        }
    }

    /// Makes the graph as wide as the rows in view need. Unless it can
    /// narrow, it only gets wider.
    private func sizeGraph(canNarrow: Bool) {
        let visible = tableView.rows(in: tableView.visibleRect)
        var needed = canNarrow ? 0 : graphColumns
        for row in visible.location..<visible.location + visible.length {
            needed = max(needed, source.content(row).lanes?.width ?? 0)
        }
        needed = min(needed, LaneRenderer.maxColumns)
        guard needed != graphColumns else { return }
        graphColumns = needed
        for row in visible.location..<visible.location + visible.length {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CommitCellView)?.graphColumns = needed
        }
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
        view.graphColumns = graphColumns
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
