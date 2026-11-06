/// The line from the row of a worktree's uncommitted changes, above the first
/// commit, down to the commit `HEAD` points to.
///
/// It's drawn over a `LaneLayout` rather than laid out with it, because the
/// worktree can go from clean to changed at any moment, and laying out all of
/// Linux again takes seconds. It runs straight down in the first column free of
/// every row it crosses, and curves into `HEAD`'s dot, in the color of the
/// column it starts in. A commit above `HEAD`
/// is usually on another branch, so `HEAD` is often not the first row.
///
/// Like the layout's own lines, it's cut when it's longer than
/// `LaneLayout.longestLine`, into an arrow pointing down a couple of rows below
/// the worktree's row, and an arrow pointing up a couple of rows above `HEAD`.
public struct WorkingTreeLine: Sendable {
    public typealias Row = LaneLayout.Row
    public typealias Line = LaneLayout.Line

    /// What to draw in the worktree's own row.
    public let row: Row
    /// The part of the line in each row that it crosses.
    private var lines: [Int: Line] = [:]

    /// - Parameter head: The commit `HEAD` points to, or nil when there's none
    ///   yet. It can be below the rows laid out so far, and then only the
    ///   line's start is known.
    public init(layout: LaneLayout, head: LaneLayout.Position?) {
        guard let head else {
            row = Row(column: 0, lines: [])
            return
        }
        func column(clearOf rows: Range<Int>) -> Int {
            rows.reduce(0) { max($0, layout.row($1).width) }
        }
        func straight(_ column: Int, color: Int) -> Line {
            Line(top: .column(column), bottom: .column(column), color: color)
        }

        let headRow = layout.rows.firstIndex(of: head)
        if let headRow, headRow <= LaneLayout.longestLine {
            let column = headRow == 0 ? layout.row(0).column : column(clearOf: 0..<headRow)
            let color = column % LaneLayout.colors
            row = Row(column: column, color: color, lines: [Line(top: .commit, bottom: .column(column), color: color)])
            for index in 0..<headRow {
                lines[index] = straight(column, color: color)
            }
            lines[headRow] = Line(top: .column(column), bottom: .commit, color: color)
            return
        }

        let start = 0..<min(LaneLayout.cutLength, layout.count)
        let startColumn = column(clearOf: start)
        // Both ends of a cut line are one line, so they share a color.
        let color = startColumn % LaneLayout.colors
        if let last = start.last {
            row = Row(column: startColumn, color: color, lines: [Line(top: .commit, bottom: .column(startColumn), color: color)])
            for index in start.dropLast() {
                lines[index] = straight(startColumn, color: color)
            }
            lines[last] = Line(top: .column(startColumn), bottom: .cut(startColumn), color: color)
        } else {
            row = Row(column: startColumn, color: color, lines: [Line(top: .commit, bottom: .cut(startColumn), color: color)])
        }

        if let headRow {
            let end = headRow - LaneLayout.cutLength..<headRow
            let endColumn = column(clearOf: end)
            for index in end {
                lines[index] = straight(endColumn, color: color)
            }
            lines[end.lowerBound] = Line(top: .cut(endColumn), bottom: .column(endColumn), color: color)
            lines[headRow] = Line(top: .column(endColumn), bottom: .commit, color: color)
        }
    }

    /// A row of the layout, with the part of this line that crosses it.
    public func adding(to row: Row, at index: Int) -> Row {
        guard let line = lines[index] else { return row }
        var row = row
        row.lines.append(line)
        return row
    }
}
