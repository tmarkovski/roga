/// Lays out the lines of the history graph: the column of each commit's dot,
/// and the lines that join each commit to its parents.
///
/// Each column holds a lane, which waits for one commit: the next one down
/// the line it draws. A commit takes the leftmost lane that waits for it, or
/// the leftmost free column when none does. Any other lanes that wait for it
/// end at its dot, coming in from the right, the way Fork draws them. Its
/// lane then waits for its first parent, and each other parent gets a new
/// lane. So a line runs down to its parent's own row before it meets another,
/// rather than joining one above it, and ends at the parent's dot. A lane
/// steps left when the column next to it frees up, so lanes only move left,
/// a column at a time.
///
/// Lines longer than `longestLine` rows are cut, the way gitk cuts them.
/// Most of the width of a large history comes from them: Linux has about a
/// hundred at a typical row, and with them cut, 99% of its rows need seven
/// columns or fewer.
/// A cut line leaves the child and ends in an arrow pointing down a couple of
/// rows below, and starts again with an arrow pointing up a couple of rows
/// above the parent. Knowing whether a line is long takes the rows below it,
/// so a row is laid out once the `longestLine` rows after it are known.
///
/// It works from the top row down, a batch of rows at a time, so the first
/// screen only needs the first rows. Storing every line of every row would
/// take too much memory for Linux. So it stores each row's column and the
/// lines that change column, and every 64 rows, which columns have a line
/// crossing into the row from above. `row(_:)` works out the straight lines
/// from the nearest of those.
public struct LaneLayout: Sendable {
    public typealias Position = CommitGraph.Position

    /// A line in one row. It runs from the row's top edge, the commit's dot or
    /// a cut, down to the row's bottom edge, the dot or a cut.
    public struct Line: Hashable, Sendable {
        public enum End: Hashable, Sendable {
            /// A column at the row's top or bottom edge.
            case column(Int)
            /// The commit's dot, in the middle of the row.
            case commit
            /// The middle of the row in a column, where a line too long to
            /// draw is cut. It's drawn as an arrow pointing the way the line
            /// goes on: down at the bottom of a line, toward a parent far
            /// below, and up at the top of one, toward a child far above.
            case cut(Int)
        }

        public var top: End
        public var bottom: End
        /// The color of the lane the line belongs to, one of `colors`. A lane
        /// keeps its color when it moves over, and a lane that ends at a dot
        /// keeps it right up to the dot.
        public var color: Int

        public init(top: End, bottom: End, color: Int = 0) {
            self.top = top
            self.bottom = bottom
            self.color = color
        }
    }

    /// What to draw in one row.
    public struct Row: Hashable, Sendable {
        /// The column of the commit's dot.
        public var column: Int
        /// The color of the dot, which is its lane's.
        public var color: Int = 0
        /// The lines that pass through the row or touch the dot, with the
        /// straight ones first, from left to right.
        public var lines: [Line]

        /// The number of columns up to the rightmost line or dot.
        public var width: Int {
            var rightmost = column
            for line in lines {
                for end in [line.top, line.bottom] {
                    if case .column(let column) = end { rightmost = max(rightmost, column) }
                    if case .cut(let column) = end { rightmost = max(rightmost, column) }
                }
            }
            return rightmost + 1
        }
    }

    /// How many colors the lanes take turns with. `GitColors.lanes` in
    /// HistoryUI has one for each.
    public static let colors = 8
    /// The most rows a line runs before it's cut.
    public static let longestLine = 100
    /// How many rows the ends of a cut line run: down from the child to the
    /// arrow, and from the arrow down to the parent.
    static let cutLength = 2

    public let graph: CommitGraph
    /// The commits laid out so far, from top to bottom.
    public private(set) var rows: [Position] = []
    /// The number of columns the graph uses, which is the widest any row is.
    public var width: Int { waiting.count }
    /// The number of rows laid out so far.
    public var count: Int { rows.count }

    private var stored: [StoredRow] = []
    /// The color of each row's dot, which its lines above and below it share.
    private var rowColors: [UInt8] = []
    /// The lines that change column or end at a cut, row after row. Each
    /// row's lines end at its `bendEnd`.
    private var bends: [StoredBend] = []
    /// The color of each of `bends`.
    private var bendColors: [UInt8] = []
    /// Every `checkpointInterval` rows, the columns that have a line crossing
    /// the row's top edge, as bits. Each of those rows' words end at its
    /// entry in `checkpointEnds`.
    private var checkpointWords: [UInt64] = []
    private var checkpointEnds: [UInt32] = []
    /// The colors of the lines in those columns, from left to right, ending at
    /// each row's entry in `checkpointColorEnds`.
    private var checkpointColors: [UInt8] = []
    private var checkpointColorEnds: [UInt32] = []
    static let checkpointInterval = 64

    /// The rows that are known but not laid out yet, from `firstPending` on.
    private var pending: [Position] = []
    private var firstPending = 0
    private var isComplete = false
    /// The row of each known commit, or -1.
    private var rowOf: [Int32]
    /// The commit each column's lane waits for, or `free`. A column can be
    /// in use without waiting, while a cut line runs down to its arrow.
    private var waiting: [Position] = []
    private static let free = Position.max
    /// The color of the line in each column that's in use.
    private var laneColor: [UInt8] = []
    /// For each commit, the column of a lane that waits for it, or `none`.
    /// When more than one does, `shared` is among its `marks`, and the others
    /// are found by looking through `waiting`.
    private var waitingColumn: [Int32]
    private static let none: Int32 = -1
    /// For each commit, `farChild` when a child far above has a line to it
    /// that was cut, and `shared` when more than one lane waits for it. The
    /// bits from `farColorShift` up hold the color of the first such line, so
    /// that it starts again above the commit in the color it was cut in.
    private var marks: [UInt8]
    private static let farChild: UInt8 = 1
    private static let shared: UInt8 = 2
    private static let farColorShift: UInt8 = 2
    /// The columns no lane uses.
    private var freeColumns = ColumnSet()
    /// The columns with a line crossing the bottom edge of the last row.
    private var crossing = ColumnSet()
    /// The arrows that end cut lines below their children, in the order of
    /// their rows, from `firstCutEnd` on.
    private var cutEnds: [(row: Int, column: Int)] = []
    private var firstCutEnd = 0

    /// Prepares to lay out rows of commits from `graph`.
    public init(graph: CommitGraph) {
        self.graph = graph
        rowOf = Array(repeating: -1, count: graph.count)
        waitingColumn = Array(repeating: Self.none, count: graph.count)
        marks = Array(repeating: 0, count: graph.count)
    }

    /// Adds commits below the ones added so far, each after all of its
    /// children, as `HistoryOrder` hands them out. It lays out every row
    /// whose next `longestLine` rows are known, or every row once
    /// `isComplete` says no more will come, and returns the rows it laid out.
    @discardableResult
    public mutating func append(
        _ commits: some Sequence<Position>,
        isComplete: Bool
    ) throws(CommitGraphError) -> Range<Int> {
        precondition(!self.isComplete, "Rows were added after the last ones")
        for commit in commits {
            rowOf[Int(commit)] = Int32(rows.count + pending.count - firstPending)
            pending.append(commit)
        }
        self.isComplete = isComplete
        let start = rows.count
        while firstPending < pending.count && (isComplete || pending.count - firstPending > Self.longestLine) {
            try layOut(pending[firstPending])
            firstPending += 1
        }
        if firstPending > 65_536 {
            pending.removeFirst(firstPending)
            firstPending = 0
        }
        return start..<rows.count
    }

    private mutating func layOut(_ commit: Position) throws(CommitGraphError) {
        let row = rows.count
        if row % Self.checkpointInterval == 0 {
            checkpointWords += crossing.words
            checkpointEnds.append(UInt32(checkpointWords.count))
            for column in crossing.columns {
                checkpointColors.append(laneColor[column])
            }
            checkpointColorEnds.append(UInt32(checkpointColors.count))
        }
        let firstBend = bends.count

        // The commit takes the leftmost lane that waits for it, and the
        // others end at its dot, coming in from the right.
        var column = Int(waitingColumn[Int(commit)])
        let lineAbove = column >= 0
        if marks[Int(commit)] & Self.shared != 0 {
            column = waiting.firstIndex(of: commit)!
            for other in column + 1..<waiting.count where waiting[other] == commit {
                addBend(top: Int32(other), bottom: StoredBend.commit, color: laneColor[other])
                release(other)
            }
            marks[Int(commit)] &= ~Self.shared
        }
        if !lineAbove {
            column = takeFreeColumn()
        }
        let color = laneColor[column]
        waitingColumn[Int(commit)] = Self.none
        waiting[column] = Self.free
        crossing.remove(column)

        var lineBelow = false
        var index = 0
        while let parent = try graph.parent(of: commit, at: index) {
            index += 1
            if index > 1, try isRepeated(parent, before: index - 1, of: commit) { continue }
            let parentRow = rowOf[Int(parent)]
            if parentRow < 0 || Int(parentRow) > row + Self.longestLine {
                // The line is too long to draw, so it ends in an arrow below.
                var cutColumn = column
                if index == 1 {
                    lineBelow = true
                } else {
                    cutColumn = takeFreeColumn()
                    addBend(top: StoredBend.commit, bottom: Int32(cutColumn), color: laneColor[cutColumn])
                }
                if marks[Int(parent)] & Self.farChild == 0 {
                    marks[Int(parent)] |= Self.farChild | laneColor[cutColumn] << Self.farColorShift
                }
                crossing.insert(cutColumn)
                cutEnds.append((row: row + Self.cutLength, column: cutColumn))
                continue
            }
            // The line runs down to the parent's row, even when another lane
            // already waits for it.
            if index == 1 {
                wait(in: column, for: parent)
                lineBelow = true
            } else {
                let new = takeFreeColumn()
                wait(in: new, for: parent)
                addBend(top: StoredBend.commit, bottom: Int32(new), color: laneColor[new])
            }
        }
        if index == 0 {
            release(column)
        }

        // Cut lines that reach their arrows in this row end here.
        while firstCutEnd < cutEnds.count && cutEnds[firstCutEnd].row == row {
            let ended = cutEnds[firstCutEnd].column
            addBend(top: Int32(ended), bottom: StoredBend.cut(ended), color: laneColor[ended])
            release(ended)
            firstCutEnd += 1
        }
        // A commit a couple of rows below with a child far above gets the
        // start of the line from it. Its arrow goes in a column with nothing
        // else in this row: not the dot's, and not one that a line ends in or
        // leaves.
        let below = firstPending + Self.cutLength
        if below < pending.count, marks[Int(pending[below])] & Self.farChild != 0 {
            let mark = marks[Int(pending[below])]
            marks[Int(pending[below])] = mark & Self.shared
            var avoided = bends[firstBend...].compactMap { $0.top >= 0 ? Int($0.top) : nil }
            avoided.append(column)
            let new = takeFreeColumn(avoiding: avoided)
            laneColor[new] = mark >> Self.farColorShift
            wait(in: new, for: pending[below])
            addBend(top: StoredBend.cut(new), bottom: Int32(new), color: laneColor[new])
        }
        if firstCutEnd > 4096 {
            cutEnds.removeFirst(firstCutEnd)
            firstCutEnd = 0
        }

        // A lane moves left into the column next to it when that column is
        // free and nothing else touches it in this row, so the gap left by a
        // line that ended closes up, one column a row.
        if let lowestFree = freeColumns.first, let rightmost = crossing.last, lowestFree < rightmost {
            var touched = [column]
            for bend in bends[firstBend...] {
                for end in [bend.top, bend.bottom] where end != StoredBend.commit {
                    touched.append(end >= 0 ? Int(end) : Int(-2 - end))
                }
            }
            for lane in lowestFree + 1...rightmost where crossing.contains(lane) && waiting[lane] != Self.free {
                let left = lane - 1
                guard freeColumns.contains(left), !touched.contains(left) else { continue }
                if lane == column {
                    // The line from the dot moves, unless another line
                    // reaches the bottom edge where it does.
                    guard lineBelow, !touched.dropFirst().contains(lane) else { continue }
                    lineBelow = false
                    addBend(top: StoredBend.commit, bottom: Int32(left), color: laneColor[lane])
                } else {
                    guard !touched.contains(lane) else { continue }
                    addBend(top: Int32(lane), bottom: Int32(left), color: laneColor[lane])
                }
                move(lane, to: left)
                touched += [lane, left]
            }
        }

        rows.append(commit)
        stored.append(StoredRow(column: column, lineAbove: lineAbove, lineBelow: lineBelow, bendEnd: bends.count))
        rowColors.append(color)
    }

    private mutating func addBend(top: Int32, bottom: Int32, color: UInt8) {
        bends.append(StoredBend(top: top, bottom: bottom))
        bendColors.append(color)
    }

    /// Whether a parent is also listed before `index`, so it already has its
    /// line.
    private func isRepeated(_ parent: Position, before index: Int, of commit: Position) throws(CommitGraphError) -> Bool {
        for earlier in 0..<index where try graph.parent(of: commit, at: earlier) == parent {
            return true
        }
        return false
    }

    private mutating func takeFreeColumn() -> Int {
        takeFreeColumn(avoiding: [])
    }

    /// Takes the leftmost free column that isn't one of `avoided`, for a new
    /// lane, and gives the lane its color.
    private mutating func takeFreeColumn(avoiding avoided: [Int]) -> Int {
        let column: Int
        if let free = avoided.isEmpty ? freeColumns.first : freeColumns.columns.first(where: { !avoided.contains($0) }) {
            freeColumns.remove(free)
            column = free
        } else {
            waiting.append(Self.free)
            laneColor.append(0)
            column = waiting.count - 1
        }
        laneColor[column] = newColor(in: column)
        return column
    }

    /// The color for a new lane in `column`: the column's own, in turn,
    /// unless a lane beside it already has that color, and then the next one
    /// that neither lane beside it has.
    private func newColor(in column: Int) -> UInt8 {
        func color(beside other: Int) -> UInt8? {
            other >= 0 && other < waiting.count && !freeColumns.contains(other) ? laneColor[other] : nil
        }
        let left = color(beside: column - 1)
        let right = color(beside: column + 1)
        var color = UInt8(column % Self.colors)
        while color == left || color == right {
            color = (color + 1) % UInt8(Self.colors)
        }
        return color
    }

    private mutating func wait(in column: Int, for commit: Position) {
        waiting[column] = commit
        if waitingColumn[Int(commit)] == Self.none {
            waitingColumn[Int(commit)] = Int32(column)
        } else {
            marks[Int(commit)] |= Self.shared
        }
        crossing.insert(column)
    }

    /// Frees a column: one whose cut line reached its arrow, or whose lane
    /// ends at the dot in this row.
    private mutating func release(_ column: Int) {
        waiting[column] = Self.free
        crossing.remove(column)
        freeColumns.insert(column)
    }

    /// Moves the lane in one column to a free one.
    private mutating func move(_ lane: Int, to column: Int) {
        let commit = waiting[lane]
        waiting[lane] = Self.free
        crossing.remove(lane)
        freeColumns.insert(lane)
        freeColumns.remove(column)
        waiting[column] = commit
        laneColor[column] = laneColor[lane]
        crossing.insert(column)
        if waitingColumn[Int(commit)] == Int32(lane) {
            waitingColumn[Int(commit)] = Int32(column)
        }
    }

    /// The lines of a row that has been laid out.
    public func row(_ index: Int) -> Row {
        precondition(index < stored.count, "Row \(index) hasn't been laid out")
        let checkpoint = index / Self.checkpointInterval
        let start = checkpoint == 0 ? 0 : Int(checkpointEnds[checkpoint - 1])
        var crossing = ColumnSet(words: Array(checkpointWords[start..<Int(checkpointEnds[checkpoint])]))
        var colors = [UInt8](repeating: 0, count: waiting.count)
        let firstColor = checkpoint == 0 ? 0 : Int(checkpointColorEnds[checkpoint - 1])
        for (offset, column) in crossing.columns.enumerated() {
            colors[column] = checkpointColors[firstColor + offset]
        }
        for earlier in checkpoint * Self.checkpointInterval..<index {
            apply(earlier, to: &crossing, colors: &colors)
        }

        let row = stored[index]
        let column = row.column
        let color = Int(rowColors[index])
        let bends = bends(in: index)
        crossing.remove(column)
        for bend in bends where self.bends[bend].top >= 0 {
            crossing.remove(Int(self.bends[bend].top))
        }
        var lines: [Line] = []
        for straight in crossing.columns {
            lines.append(Line(top: .column(straight), bottom: .column(straight), color: Int(colors[straight])))
        }
        if row.lineAbove { lines.append(Line(top: .column(column), bottom: .commit, color: color)) }
        if row.lineBelow { lines.append(Line(top: .commit, bottom: .column(column), color: color)) }
        for bend in bends {
            lines.append(Line(top: self.bends[bend].topEnd, bottom: self.bends[bend].bottomEnd, color: Int(bendColors[bend])))
        }
        return Row(column: column, color: color, lines: lines)
    }

    /// Changes the columns crossing a row's top edge, and their colors, into
    /// the ones crossing its bottom edge.
    private func apply(_ index: Int, to crossing: inout ColumnSet, colors: inout [UInt8]) {
        let row = stored[index]
        let bends = bends(in: index)
        crossing.remove(row.column)
        for bend in bends where self.bends[bend].top >= 0 {
            crossing.remove(Int(self.bends[bend].top))
        }
        for bend in bends where self.bends[bend].bottom >= 0 {
            let column = Int(self.bends[bend].bottom)
            crossing.insert(column)
            colors[column] = bendColors[bend]
        }
        if row.lineBelow {
            crossing.insert(row.column)
            colors[row.column] = rowColors[index]
        }
    }

    /// Where a row's bends are in `bends` and `bendColors`.
    private func bends(in index: Int) -> Range<Int> {
        let start = index == 0 ? 0 : stored[index - 1].bendEnd
        return start..<stored[index].bendEnd
    }
}

extension LaneLayout {
    /// A row as it's stored: the column and whether lines join the dot in it
    /// from above and below, packed into one word, and where the row's bends
    /// end.
    private struct StoredRow: Sendable {
        private var bits: UInt32
        private var end: UInt32

        init(column: Int, lineAbove: Bool, lineBelow: Bool, bendEnd: Int) {
            precondition(column < 1 << 30, "The graph is too wide")
            bits = UInt32(column) | (lineAbove ? 1 << 30 : 0) | (lineBelow ? 1 << 31 : 0)
            end = UInt32(bendEnd)
        }

        var column: Int { Int(bits & (1 << 30 - 1)) }
        var lineAbove: Bool { bits & 1 << 30 != 0 }
        var lineBelow: Bool { bits & 1 << 31 != 0 }
        var bendEnd: Int { Int(end) }
    }

    /// A line that changes column or ends at a cut. Each end is a column on
    /// the row's edge when it's 0 or more, the dot when it's `commit`, and a
    /// cut in a column when it's `cut(column)`.
    private struct StoredBend: Sendable {
        var top: Int32
        var bottom: Int32

        static let commit: Int32 = -1

        static func cut(_ column: Int) -> Int32 {
            -2 - Int32(column)
        }

        var topEnd: Line.End { Self.end(top) }
        var bottomEnd: Line.End { Self.end(bottom) }

        private static func end(_ value: Int32) -> Line.End {
            switch value {
            case 0...: .column(Int(value))
            case commit: .commit
            default: .cut(Int(-2 - value))
            }
        }
    }
}

/// A set of columns, as bits.
struct ColumnSet: Sendable {
    var words: [UInt64] = []

    mutating func insert(_ column: Int) {
        let word = column >> 6
        if word >= words.count {
            words += repeatElement(0, count: word + 1 - words.count)
        }
        words[word] |= 1 << UInt64(column & 63)
    }

    mutating func remove(_ column: Int) {
        let word = column >> 6
        guard word < words.count else { return }
        words[word] &= ~(1 << UInt64(column & 63))
    }

    func contains(_ column: Int) -> Bool {
        let word = column >> 6
        return word < words.count && words[word] & 1 << UInt64(column & 63) != 0
    }

    /// The leftmost column in the set.
    var first: Int? {
        for (index, word) in words.enumerated() where word != 0 {
            return index << 6 + word.trailingZeroBitCount
        }
        return nil
    }

    /// The rightmost column in the set.
    var last: Int? {
        for (index, word) in words.enumerated().reversed() where word != 0 {
            return index << 6 + 63 - word.leadingZeroBitCount
        }
        return nil
    }

    /// The columns in the set, from left to right.
    var columns: [Int] {
        var columns: [Int] = []
        for (index, word) in words.enumerated() {
            var bits = word
            while bits != 0 {
                columns.append(index << 6 + bits.trailingZeroBitCount)
                bits &= bits - 1
            }
        }
        return columns
    }
}
