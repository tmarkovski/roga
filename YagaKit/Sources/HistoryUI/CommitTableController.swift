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

        public init(
            count: @escaping () -> Int,
            content: @escaping (Int) -> CommitRowContent,
            loadText: @escaping (Range<Int>) async -> IndexSet
        ) {
            self.count = count
            self.content = content
            self.loadText = loadText
        }
    }

    public let scrollView = NSScrollView()
    public var source: Source

    private let tableView = CommitTableView()
    private var textTask: Task<Void, Never>?
    private var requestedRows: Range<Int>?
    private var graphColumns = 0
    private var fitGraphTask: Task<Void, Never>?

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

    /// Shows new rows, such as when history is loaded again. The selection
    /// and scroll position stay where they are.
    public func reloadData() {
        tableView.reloadData()
        requestedRows = nil
        sizeGraph(canNarrow: true)
        loadVisibleText()
    }

    @objc private func visibleRowsMayHaveChanged(_ notification: Notification) {
        sizeGraph(canNarrow: false)
        loadVisibleText()

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
        return view
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: CommitRowView.identifier, owner: nil) as? CommitRowView ?? CommitRowView()
    }
}

/// Takes keyboard focus when it appears in a window where nothing else has
/// it, so that the arrow keys move through history straight away.
final class CommitTableView: NSTableView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI may still be choosing a first responder, so wait a turn.
        Task { [weak self] in
            guard let self, let window, window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
    }
}
