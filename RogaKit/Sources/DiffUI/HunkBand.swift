import AppKit

/// The band that starts a hunk: a little space that sets it apart from the hunk
/// above, then the hunk's header over a thin line, with room for buttons of the
/// usual small size on the right.
///
/// It takes two rows, because every row of a diff is the same height, which is how
/// a position in the view becomes a row. Its rows are empty in the text, as a
/// conflict's band's are, and the layout manager draws the header in them, so
/// copying lines across hunks doesn't pick up git's `@@` lines.
nonisolated struct HunkBand: Sendable, Hashable {
    static let rowCount = 2

    /// The band's first row.
    var row: Int
    /// The index of the hunk's header among the patch's lines, which is how the
    /// commands for a hunk name it.
    var line: Int
    /// What the band says: the header as git prints it.
    var label: String

    /// The space above the band's line, about a quarter of its two rows: 8 points
    /// in the usual code font. It gives way in the smallest fonts, so that what's
    /// left still fits a button.
    static func gap(lineHeight: CGFloat) -> CGFloat {
        let height = lineHeight * CGFloat(rowCount)
        return max(0, min((height * 0.24).rounded(), height - 24))
    }

    /// Where the header and the buttons go, from the top of the band's first row:
    /// below the gap, down to the line at the bottom.
    static func content(lineHeight: CGFloat) -> (top: CGFloat, height: CGFloat) {
        let gap = gap(lineHeight: lineHeight)
        return (gap, lineHeight * CGFloat(rowCount) - gap)
    }

    /// How tall a button on the band is: as tall as a small button elsewhere,
    /// unless the band is too thin for that.
    static func buttonHeight(lineHeight: CGFloat) -> CGFloat {
        min(22, content(lineHeight: lineHeight).height - 2)
    }

    /// Where the band's words go, from the top of its first row: a box one row
    /// tall, so that they sit on a baseline as a row's text does, centered under
    /// the gap and rounded up the view rather than down, which lines them up with
    /// the words on the band's buttons.
    static func headingTop(lineHeight: CGFloat) -> CGFloat {
        let content = content(lineHeight: lineHeight)
        return (content.top + (content.height - lineHeight) / 2).rounded(.down)
    }
}

/// The hunks' headers, in bold, over the gutter and the text from the view's left
/// edge, so that each reads as the heading of its hunk and stays put as the text
/// scrolls sideways. It lets every click through to the text under it, where a
/// right-click on a band has its menu.
final class HunkHeaders: NSView {
    struct Header: Equatable {
        var label: String
        /// Where it's drawn, which ends before the band's buttons while they show.
        var box: NSRect
    }

    var headers: [Header] = [] {
        didSet {
            if headers != oldValue { needsDisplay = true }
        }
    }

    /// The metrics of the document showing, which the headers are drawn in.
    var metrics: DiffMetrics = .current {
        didSet {
            if metrics !== oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = metrics.paragraph.mutableCopy() as! NSMutableParagraphStyle
        paragraph.lineBreakMode = .byTruncatingTail
        for header in headers where header.box.intersects(dirtyRect) && header.box.width > 0 {
            NSAttributedString(string: header.label, attributes: [
                .font: metrics.boldFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]).draw(with: header.box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
