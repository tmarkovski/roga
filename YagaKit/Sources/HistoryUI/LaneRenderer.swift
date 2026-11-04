import AppKit
import CommitGraph

/// Draws the graph in one row of the commit list: the lines that pass
/// through it and the commit's dot.
///
/// A row's graph is as wide as its own lines, up to `maxColumns`. Lines further
/// right are clipped, and a dot further right is drawn at the edge.
enum LaneRenderer {
    static let spacing: CGFloat = 12
    /// The most columns a row's graph shows.
    static let maxColumns = 10
    private static let dotRadius: CGFloat = 4
    /// Small enough to stay clear of the edge of a selected row's fill.
    static let ringRadius: CGFloat = 6
    private static let lineWidth: CGFloat = 1.5
    private static let arrowSize: CGFloat = 3
    /// How far an arrow's tip stops short of the middle of the row, so that it
    /// doesn't touch a line running along the middle and seem to join it.
    private static let arrowClearance: CGFloat = 3
    /// How far across a line between the dot and another column the curve's
    /// control point sits. This keeps the line nearly flat at first, so that it
    /// crosses the columns between at a right angle and turns late, however far
    /// it goes. It's the value that fits how Fork draws these lines.
    private static let flatRun: CGFloat = 0.6

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

    /// Draws `row` in a graph that starts at `x`, in a flipped view of the row's
    /// height.
    ///
    /// - Parameters:
    ///   - isHollow: Whether the dot is a ring, for a row that isn't a commit.
    ///     Lines start at its edge, so that it stays empty.
    ///   - isCurrent: Whether a larger ring goes around the dot, for the commit
    ///     `HEAD` is on. Lines stop at the ring, which leaves a gap around the dot.
    static func draw(_ row: LaneLayout.Row, at x: CGFloat, height: CGFloat, isHollow: Bool = false, isCurrent: Bool = false) {
        guard let context = NSGraphicsContext.current else { return }
        let columns = min(row.width, maxColumns)

        func center(_ column: Int) -> CGFloat {
            x + (CGFloat(column) + 0.5) * spacing
        }
        let middle = height / 2
        let dot = NSPoint(x: center(min(row.column, columns - 1)), y: middle)
        let ring = NSRect(x: dot.x - ringRadius, y: dot.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)

        // Only the lines are clipped to the graph, because a ring in the first
        // or last column reaches a little past it.
        context.saveGraphicsState()
        let graph = NSRect(x: x, y: 0, width: width(columns: columns), height: height)
        graph.clip()
        if isCurrent {
            let outsideRing = NSBezierPath(rect: graph)
            outsideRing.appendOval(in: ring)
            outsideRing.windingRule = .evenOdd
            outsideRing.addClip()
        }
        for line in row.lines {
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let start: NSPoint = switch line.top {
            case .column(let column): NSPoint(x: center(column), y: 0)
            case .commit: isHollow ? NSPoint(x: dot.x, y: dot.y + dotRadius) : dot
            case .cut(let column): NSPoint(x: center(column), y: middle + arrowClearance)
            }
            let end: NSPoint = switch line.bottom {
            case .column(let column): NSPoint(x: center(column), y: height)
            case .commit: dot
            case .cut(let column): NSPoint(x: center(column), y: middle - arrowClearance)
            }
            path.move(to: start)
            if start.x == end.x {
                path.line(to: end)
            } else if case .commit = line.top {
                // Leave the dot sideways, and turn down into the column by the
                // row's bottom edge.
                let flat = start.x + (end.x - start.x) * flatRun
                path.curve(to: end, controlPoint1: NSPoint(x: flat, y: start.y), controlPoint2: NSPoint(x: end.x, y: start.y))
            } else if case .commit = line.bottom {
                // The same curve the other way, arriving at the dot sideways.
                let flat = end.x + (start.x - end.x) * flatRun
                path.curve(to: end, controlPoint1: NSPoint(x: start.x, y: end.y), controlPoint2: NSPoint(x: flat, y: end.y))
            } else {
                // A lane moving over, away from any dot, leaves and arrives
                // straight up and down, curving between.
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
        context.restoreGraphicsState()

        let circle = NSRect(x: dot.x - dotRadius, y: dot.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
        if isHollow {
            stroke(circle.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), column: row.column)
        } else {
            color(row.column).setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        if isCurrent {
            stroke(ring, column: row.column)
        }
    }

    private static func stroke(_ oval: NSRect, column: Int) {
        let path = NSBezierPath(ovalIn: oval)
        path.lineWidth = lineWidth
        color(column).setStroke()
        path.stroke()
    }

    private static func color(_ column: Int) -> NSColor {
        palette[column % palette.count]
    }
}
