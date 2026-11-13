/// Which of the graph's lines are drawn faded, along with some commits' dots:
/// the commits that the checked-out branch is missing, which a pull would
/// bring in.
///
/// A line belongs to the commit it leads down from, so it's faded when that
/// commit is. A line from a commit that isn't faded stays as it is, even into
/// a faded commit's dot, and so does a faded commit's line into a commit that
/// isn't. That keeps every line one strength from end to end, however many
/// faded rows it passes.
///
/// The layout doesn't say which commit a line comes from, so this follows each
/// line down from its commit, row by row, by the column it crosses each row's
/// edges in. The start of a cut line is the exception, since the commit it
/// comes from is far above and may be one of several: it's faded when the
/// commit it leads to is.
public struct FadedLines: Sendable {
    public typealias Position = LaneLayout.Position
    public typealias Row = LaneLayout.Row

    /// The faded lines in each row that has any, as indices into the row's
    /// `lines`.
    private var faded: [Int: [Int]] = [:]

    /// No faded lines.
    public init() {}

    /// The lines of `commits` in the rows laid out so far.
    public init(layout: LaneLayout, commits: Set<Position>) {
        guard !commits.isEmpty else { return }
        // The commits a branch is missing are usually the newest, so this
        // stops early.
        var first: Int?
        var last = 0
        var found = 0
        for (index, commit) in layout.rows.enumerated() where commits.contains(commit) {
            if first == nil { first = index }
            last = index
            found += 1
            if found == commits.count { break }
        }
        guard let first else { return }

        func isFaded(_ index: Int) -> Bool {
            index < layout.count && commits.contains(layout.rows[index])
        }
        // The columns of the faded lines crossing the top edge of the row.
        var columns = Set<Int>()
        // The start of a cut line goes a couple of rows above its commit.
        var index = max(0, first - LaneLayout.cutLength)
        while index < layout.count, index <= last || !columns.isEmpty {
            let row = layout.row(index)
            var lines: [Int] = []
            var below = Set<Int>()
            for (number, line) in row.lines.enumerated() {
                let lineIsFaded = switch line.top {
                case .column(let column): columns.contains(column)
                case .commit: isFaded(index)
                case .cut: isFaded(index + LaneLayout.cutLength)
                }
                guard lineIsFaded else { continue }
                lines.append(number)
                if case .column(let column) = line.bottom { below.insert(column) }
            }
            if !lines.isEmpty { faded[index] = lines }
            columns = below
            index += 1
        }
    }

    /// Whether no line is faded.
    public var isEmpty: Bool { faded.isEmpty }

    /// The layout's row `index`, with its faded lines marked. It has to come
    /// straight from the layout, before anything else adds lines to it.
    public func marking(_ row: Row, at index: Int) -> Row {
        guard let lines = faded[index] else { return row }
        var row = row
        for line in lines where line < row.lines.count {
            row.lines[line].isFaded = true
        }
        return row
    }
}
