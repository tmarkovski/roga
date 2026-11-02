import AppKit
import CommitGraph

/// Draws the graph in one row of the commit list: the lines that pass
/// through it and the commit's dot.
///
/// The commit list decides how many columns to show. Lines further right
/// are clipped, and a dot further right is drawn at the edge.
enum LaneRenderer {
    static let spacing: CGFloat = 12
    /// The most columns the graph shows.
    static let maxColumns = 10
    private static let dotRadius: CGFloat = 4
    private static let lineWidth: CGFloat = 1.5
    private static let arrowSize: CGFloat = 3

    /// Each column's color, in turn. The first column, where the main line
    /// usually runs, gets the accent color.
    private static let palette: [NSColor] = [
        .controlAccentColor, .systemPurple, .systemTeal, .systemOrange,
        .systemPink, .systemGreen, .systemIndigo, .systemBrown,
    ]

    /// The width of a graph that shows `columns` columns.
    static func width(columns: Int) -> CGFloat {
        CGFloat(min(columns, maxColumns)) * spacing
    }

    /// Draws `row` in a graph that shows `columns` columns and starts at
    /// `x`, in a flipped view of the row's height.
    static func draw(_ row: LaneLayout.Row, columns: Int, at x: CGFloat, height: CGFloat) {
        let width = width(columns: columns)
        guard width > 0, let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        NSRect(x: x, y: 0, width: width, height: height).clip()

        func center(_ column: Int) -> CGFloat {
            x + (CGFloat(column) + 0.5) * spacing
        }
        let middle = height / 2
        let dot = NSPoint(x: center(min(row.column, min(columns, maxColumns) - 1)), y: middle)

        for line in row.lines {
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let start: NSPoint = switch line.top {
            case .column(let column): NSPoint(x: center(column), y: 0)
            case .commit: dot
            case .cut(let column): NSPoint(x: center(column), y: middle)
            }
            let end: NSPoint = switch line.bottom {
            case .column(let column): NSPoint(x: center(column), y: height)
            case .commit: dot
            case .cut(let column): NSPoint(x: center(column), y: middle)
            }
            path.move(to: start)
            if start.x == end.x {
                path.line(to: end)
            } else {
                // Leave and arrive straight up and down, curving between.
                let turn = (start.y + end.y) / 2
                path.curve(to: end, controlPoint1: NSPoint(x: start.x, y: turn), controlPoint2: NSPoint(x: end.x, y: turn))
            }
            // A cut line ends in an arrow pointing the way it goes on.
            if case .cut = line.bottom {
                path.move(to: NSPoint(x: end.x - arrowSize, y: end.y - arrowSize))
                path.line(to: end)
                path.line(to: NSPoint(x: end.x + arrowSize, y: end.y - arrowSize))
            }
            if case .cut = line.top {
                path.move(to: NSPoint(x: start.x - arrowSize, y: start.y + arrowSize))
                path.line(to: start)
                path.line(to: NSPoint(x: start.x + arrowSize, y: start.y + arrowSize))
            }
            color(line.lane(commitColumn: row.column)).setStroke()
            path.stroke()
        }

        color(row.column).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: dot.x - dotRadius, y: dot.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2
        )).fill()
    }

    private static func color(_ column: Int) -> NSColor {
        palette[column % palette.count]
    }
}
