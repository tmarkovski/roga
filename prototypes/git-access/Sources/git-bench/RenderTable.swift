import AppKit

@MainActor
enum AppKitStyle {
    static let palette: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPink,
        .systemPurple, .systemTeal, .systemYellow, .systemRed,
    ]
    static let subject: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.labelColor,
    ]
    static let detail: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
}

/// Shows the history in a view-based `NSTableView` whose rows draw themselves.
@MainActor
final class TableEngine: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let model: HistoryModel
    private let tableView = NSTableView()

    init(model: HistoryModel) { self.model = model }

    func makeView() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = RowMetrics.height
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        return scrollView
    }

    func prependCommits(_ count: Int) {
        model.prependCommits(count)
        tableView.insertRows(at: IndexSet(integersIn: 0..<count), withAnimation: [])
    }

    func select(row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: CommitRowView.identifier, owner: nil) as? CommitRowView
            ?? CommitRowView(model: model)
        view.row = row
        view.needsDisplay = true
        return view
    }
}

/// One commit row, drawn directly instead of being built from text fields.
@MainActor
final class CommitRowView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("CommitRowView")

    private let model: HistoryModel
    var row = 0

    init(model: HistoryModel) {
        self.model = model
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        firstRowDrawn = true
        rowsDrawn += 1
        let (column, width) = model.lanes(row)
        for lane in 0..<width {
            AppKitStyle.palette[lane % AppKitStyle.palette.count].setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: RowMetrics.laneX(lane), y: 0))
            path.line(to: NSPoint(x: RowMetrics.laneX(lane), y: bounds.height))
            path.lineWidth = 2
            path.stroke()
        }
        AppKitStyle.palette[column % AppKitStyle.palette.count].setFill()
        NSBezierPath(ovalIn: NSRect(x: RowMetrics.laneX(column) - 4, y: bounds.midY - 4, width: 8, height: 8)).fill()

        let textY: CGFloat = 3
        let authorX = bounds.width - 310
        let subjectRect = NSRect(x: RowMetrics.graphWidth + 8, y: textY,
                                 width: max(0, authorX - RowMetrics.graphWidth - 16), height: 17)
        (model.subject(row) as NSString).draw(with: subjectRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                              attributes: AppKitStyle.subject)
        (model.author(row) as NSString).draw(at: NSPoint(x: authorX, y: textY), withAttributes: AppKitStyle.detail)
        (model.date(row) as NSString).draw(at: NSPoint(x: bounds.width - 140, y: textY), withAttributes: AppKitStyle.detail)
    }
}
