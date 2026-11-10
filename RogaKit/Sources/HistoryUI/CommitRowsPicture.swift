import AppKit

/// A few rows of the commit list as a picture, for showing what the list looks
/// like somewhere else, such as the colors' preview in Settings. The list's own
/// cell draws each row, so the picture can't drift from the list. It takes no
/// clicks, shows no tooltips, and VoiceOver passes it by: whatever shows it says
/// what it's a picture of.
public final class CommitRowsPicture: NSView {
    private let cells: [CommitCellView]
    private let selectedRow: Int?

    /// - Parameter selectedRow: The row that has the list's gray fill behind
    ///   it, which lines and badges also have to read on.
    public init(rows: [CommitRowContent], selectedRow: Int? = nil) {
        cells = rows.map { content in
            let cell = CommitCellView()
            cell.content = content
            return cell
        }
        self.selectedRow = selectedRow
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Pictures are made in code.")
    }

    /// How tall a picture of some rows is.
    public static func height(rows: Int) -> CGFloat {
        CGFloat(rows) * CommitCellView.height
    }

    override public var isFlipped: Bool { true }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height(rows: cells.count))
    }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        for (index, cell) in cells.enumerated() {
            let row = NSRect(x: 0, y: CGFloat(index) * CommitCellView.height, width: bounds.width, height: CommitCellView.height)
            guard row.intersects(dirtyRect) else { continue }
            if index == selectedRow {
                CommitRowView.selectionColor.setFill()
                let radius = CommitRowView.selectionRadius
                NSBezierPath(roundedRect: CommitRowView.selectionFrame(inRow: row), xRadius: radius, yRadius: radius).fill()
            }
            // The cells aren't in the window. Each draws as it does in the list,
            // at the place its row has here.
            cell.setFrameSize(row.size)
            context.saveGraphicsState()
            let move = NSAffineTransform()
            move.translateX(by: row.minX, yBy: row.minY)
            move.concat()
            cell.draw(cell.bounds)
            context.restoreGraphicsState()
        }
    }
}
