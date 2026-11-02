import Foundation
import GitCore
import TestSupport
import Testing
@testable import CommitGraph

@Suite(.timeLimit(.minutes(1)))
struct LaneLayoutTests {
    typealias Line = LaneLayout.Line

    @Test(arguments: Fixture.History.allCases, [HistoryOrder.Sort.date, .topological])
    func joinsEveryCommitToItsParents(_ history: Fixture.History, _ sort: HistoryOrder.Sort) async throws {
        let repository = try await history.repository()
        let graph = try await history.graph()
        var cuts = 0
        for names in HistoryOrderTests.tipSets {
            let tips = try await resolve(names, in: repository).map { try #require(graph.position(of: $0)) }
            var order = try HistoryOrder(graph: graph, tips: tips, sort: sort)
            let rows = try order.next(Int.max)
            var layout = LaneLayout(graph: graph)
            try layout.append(rows, isComplete: true)
            #expect(layout.rows == rows)
            cuts += try checkLines(layout, names: names)
        }
        // The fixture has lines long enough to be cut.
        #expect(cuts > 0)
    }

    /// Lanes only move left, so a first parent is never to the right of its
    /// child unless the line between them was cut.
    @Test(arguments: [HistoryOrder.Sort.date, .topological])
    func keepsFirstParentsInTheirColumnOrToTheLeft(_ sort: HistoryOrder.Sort) async throws {
        let repository = try await Fixture.History.single.repository()
        let graph = try await Fixture.History.single.graph()
        let names = HistoryOrderTests.tipSets[4]
        let tips = try await resolve(names, in: repository).map { try #require(graph.position(of: $0)) }
        var order = try HistoryOrder(graph: graph, tips: tips, sort: sort)
        let rows = try order.next(Int.max)
        var layout = LaneLayout(graph: graph)
        try layout.append(rows, isComplete: true)

        var rowOf: [CommitGraph.Position: Int] = [:]
        for (row, commit) in rows.enumerated() {
            rowOf[commit] = row
        }
        var checked = 0
        for (row, commit) in rows.enumerated() {
            guard let parent = try graph.parent(of: commit, at: 0), let parentRow = rowOf[parent],
                  parentRow - row <= LaneLayout.longestLine
            else { continue }
            #expect(layout.row(parentRow).column <= layout.row(row).column)
            checked += 1
        }
        #expect(checked > rows.count / 2)
    }

    @Test func laysOutInBatches() async throws {
        let repository = try await Fixture.History.chain.repository()
        let graph = try await Fixture.History.chain.graph()
        let tips = try await resolve(HistoryOrderTests.tipSets[4], in: repository).map { try #require(graph.position(of: $0)) }
        var order = try HistoryOrder(graph: graph, tips: tips, sort: .date)
        let rows = try order.next(Int.max)
        var all = LaneLayout(graph: graph)
        try all.append(rows, isComplete: true)
        var batched = LaneLayout(graph: graph)
        var laidOut = 0
        for start in stride(from: 0, to: rows.count, by: 7) {
            let end = min(start + 7, rows.count)
            let range = try batched.append(rows[start..<end], isComplete: end == rows.count)
            #expect(range == laidOut..<batched.count)
            laidOut = batched.count
        }
        #expect(batched.rows == rows)
        #expect(batched.width == all.width)
        #expect(rows.indices.map(batched.row) == rows.indices.map(all.row))
    }

    /// A row waits for the rows below it that could hold the other ends of
    /// its lines.
    @Test func laysOutRowsOnceTheRowsBelowAreKnown() throws {
        let graph = try CommitGraph(format: .sha1).adding(chain(1...300))
        let positions = try (1...300).reversed().map { try #require(graph.position(of: id($0))) }
        var layout = LaneLayout(graph: graph)
        #expect(try layout.append(positions[0..<50], isComplete: false) == 0..<0)
        #expect(try layout.append(positions[50..<150], isComplete: false) == 0..<50)
        #expect(layout.rows == Array(positions[0..<50]))
        #expect(try layout.append(positions[150...], isComplete: true) == 50..<300)
    }

    /// A branch that leaves the main line and merges back draws in the second
    /// column, and moves left into the first when the main line reaches the
    /// commit they share.
    @Test func movesALaneLeftWhereItMeetsTheMainLine() throws {
        // merge has parents a and b, which both have the parent base.
        let (graph, merge, a, b, base) = try branchAndMerge()
        var layout = LaneLayout(graph: graph)
        try layout.append([merge, b, a, base], isComplete: true)

        #expect(layout.width == 2)
        #expect(layout.row(0) == LaneLayout.Row(column: 0, lines: [
            Line(top: .commit, bottom: .column(0)),
            Line(top: .commit, bottom: .column(1)),
        ]))
        #expect(layout.row(1) == LaneLayout.Row(column: 1, lines: [
            Line(top: .column(0), bottom: .column(0)),
            Line(top: .column(1), bottom: .commit),
            Line(top: .commit, bottom: .column(1)),
        ]))
        #expect(layout.row(2) == LaneLayout.Row(column: 0, lines: [
            Line(top: .column(0), bottom: .commit),
            Line(top: .commit, bottom: .column(0)),
            Line(top: .column(1), bottom: .column(0)),
        ]))
        #expect(layout.row(3) == LaneLayout.Row(column: 0, lines: [
            Line(top: .column(0), bottom: .commit),
        ]))
    }

    /// When the branch comes after the main line, its last commit joins the
    /// main line's lane.
    @Test func joinsTheLaneOnTheLeft() throws {
        let (graph, merge, a, b, base) = try branchAndMerge()
        var layout = LaneLayout(graph: graph)
        try layout.append([merge, a, b, base], isComplete: true)

        #expect(layout.row(1) == LaneLayout.Row(column: 0, lines: [
            Line(top: .column(1), bottom: .column(1)),
            Line(top: .column(0), bottom: .commit),
            Line(top: .commit, bottom: .column(0)),
        ]))
        #expect(layout.row(2) == LaneLayout.Row(column: 1, lines: [
            Line(top: .column(0), bottom: .column(0)),
            Line(top: .column(1), bottom: .commit),
            Line(top: .commit, bottom: .column(0)),
        ]))
        #expect(layout.row(3) == LaneLayout.Row(column: 0, lines: [
            Line(top: .column(0), bottom: .commit),
        ]))
    }

    /// A line longer than the longest one drawn ends in an arrow two rows
    /// below the child, and starts again two rows above the parent. The main
    /// line steps left once the arrow's column is free.
    @Test func cutsLongLines() throws {
        // A main line of 150 commits, and a branch from its first commit.
        let graph = try CommitGraph(format: .sha1).adding(chain(1...150) + [commit(1000, parents: [1])])
        let positions = try ([1000] + (1...150).reversed()).map { try #require(graph.position(of: id($0))) }
        var layout = LaneLayout(graph: graph)
        try layout.append(positions, isComplete: true)

        #expect(layout.row(0) == LaneLayout.Row(column: 0, lines: [
            Line(top: .commit, bottom: .column(0)),
        ]))
        #expect(layout.row(1) == LaneLayout.Row(column: 1, lines: [
            Line(top: .column(0), bottom: .column(0)),
            Line(top: .commit, bottom: .column(1)),
        ]))
        #expect(layout.row(2) == LaneLayout.Row(column: 1, lines: [
            Line(top: .column(1), bottom: .commit),
            Line(top: .commit, bottom: .column(1)),
            Line(top: .column(0), bottom: .cut(0)),
        ]))
        #expect(layout.row(3) == LaneLayout.Row(column: 1, lines: [
            Line(top: .column(1), bottom: .commit),
            Line(top: .commit, bottom: .column(0)),
        ]))
        #expect(layout.row(4) == LaneLayout.Row(column: 0, lines: [
            Line(top: .column(0), bottom: .commit),
            Line(top: .commit, bottom: .column(0)),
        ]))
        #expect(layout.row(148) == LaneLayout.Row(column: 0, lines: [
            Line(top: .column(0), bottom: .commit),
            Line(top: .commit, bottom: .column(0)),
            Line(top: .cut(1), bottom: .column(1)),
        ]))
        #expect(layout.row(149) == LaneLayout.Row(column: 0, lines: [
            Line(top: .column(0), bottom: .commit),
            Line(top: .commit, bottom: .column(0)),
            Line(top: .column(1), bottom: .column(0)),
        ]))
        #expect(layout.row(150) == LaneLayout.Row(column: 0, lines: [
            Line(top: .column(0), bottom: .commit),
        ]))
        #expect(layout.width == 2)
    }

    /// A lane steps left, one column a row, into a column that frees up.
    @Test func closesGapsLeftByLinesThatEnd() throws {
        // Three lines side by side. The left one ends first, and the other
        // two step left in turn.
        let graph = try CommitGraph(format: .sha1).adding(chain(1...3) + chain(11...15) + chain(21...25))
        let numbers = [3, 15, 25, 2, 14, 24, 1, 13, 23, 12, 22, 11, 21]
        let positions = try numbers.map { try #require(graph.position(of: id($0))) }
        var layout = LaneLayout(graph: graph)
        try layout.append(positions, isComplete: true)
        try checkLines(layout, names: ["gaps"])
        #expect(positions.indices.map { layout.row($0).column } == [0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 0, 1])
        #expect(layout.row(7) == LaneLayout.Row(column: 1, lines: [
            Line(top: .column(2), bottom: .column(2)),
            Line(top: .column(1), bottom: .commit),
            Line(top: .commit, bottom: .column(0)),
        ]))
        #expect(layout.row(8) == LaneLayout.Row(column: 2, lines: [
            Line(top: .column(0), bottom: .column(0)),
            Line(top: .column(2), bottom: .commit),
            Line(top: .commit, bottom: .column(1)),
        ]))
        #expect(layout.width == 3)
    }

    /// A lane doesn't step left in a row where another line reaches the
    /// bottom edge in its column, and the end of a cut line never steps.
    @Test func stepsLeftOnlyWhereNothingElseEnds() throws {
        // The main line ends, leaving the first column free. Then a commit
        // takes over the lane of a line further right that waits for its
        // parent.
        var graph = try CommitGraph(format: .sha1).adding([
            commit(1), commit(2, parents: [1]), commit(3), commit(4, parents: [3]),
            commit(5, parents: [3]), commit(6, parents: [5]),
        ])
        var layout = try laidOut([2, 6, 4, 1, 5, 3], in: graph)
        try checkLines(layout, names: ["a line moves into the dot's column"])
        #expect(layout.row(4) == LaneLayout.Row(column: 1, lines: [
            Line(top: .column(1), bottom: .commit),
            Line(top: .commit, bottom: .column(1)),
            Line(top: .column(2), bottom: .column(1)),
        ]))

        // The same, but the commit joins the line on its left.
        graph = try CommitGraph(format: .sha1).adding([
            commit(1), commit(2, parents: [1]), commit(3), commit(4, parents: [3]),
            commit(5, parents: [3]), commit(6, parents: [5]),
        ])
        layout = try laidOut([2, 4, 6, 1, 5, 3], in: graph)
        try checkLines(layout, names: ["a line joins on the left"])
        #expect(layout.row(4) == LaneLayout.Row(column: 2, lines: [
            Line(top: .column(1), bottom: .column(1)),
            Line(top: .column(2), bottom: .commit),
            Line(top: .commit, bottom: .column(1)),
        ]))

        // A line is cut where the column on its left is free.
        graph = try CommitGraph(format: .sha1).adding(
            [commit(1), commit(2, parents: [1]), commit(3), commit(4, parents: [3]), commit(5, parents: [4])]
                + chain(101...210)
        )
        layout = try laidOut([2, 5, 1, 4] + Array((101...210).reversed()) + [3], in: graph)
        try checkLines(layout, names: ["a cut line next to a free column"])
        #expect(layout.row(3) == LaneLayout.Row(column: 1, lines: [
            Line(top: .column(1), bottom: .commit),
            Line(top: .commit, bottom: .column(1)),
        ]))
    }

    /// The arrow that starts a cut line never sits on the dot of its row,
    /// even when the dot's column is the leftmost one free.
    @Test func keepsArrowsOffDots() throws {
        // A main line of 150 commits, a branch whose parent is far below,
        // and an unrelated commit.
        let graph = try CommitGraph(format: .sha1).adding(
            chain(1...150) + [commit(2000), commit(1000, parents: [2000]), commit(3000)]
        )
        let numbers = [150, 1000] + Array((1...149).reversed()) + [3000, 2000]
        var layout = LaneLayout(graph: graph)
        try layout.append(try numbers.map { try #require(graph.position(of: id($0))) }, isComplete: true)
        #expect(try checkLines(layout, names: ["arrows and dots"]) == 1)
        #expect(layout.row(150).column == 0)
        #expect(layout.row(150).lines.contains(Line(top: .cut(1), bottom: .column(1))))
    }

    /// An arrow that starts a cut line never meets one that ends another.
    @Test func keepsArrowsApart() throws {
        // A main line of 200 commits, with two branches whose parents are far
        // below. The first branch's parent comes two rows after the second
        // branch's line is cut.
        let graph = try CommitGraph(format: .sha1).adding(chain(1...200) + [
            commit(2001), commit(2002), commit(1000, parents: [2001]), commit(1001, parents: [2002]),
        ])
        let numbers = [200, 1001] + Array((101...199).reversed()) + [1000, 100, 99, 98, 2002]
            + Array((1...97).reversed()) + [2001]
        var layout = LaneLayout(graph: graph)
        try layout.append(try numbers.map { try #require(graph.position(of: id($0))) }, isComplete: true)
        #expect(try checkLines(layout, names: ["two arrows"]) == 2)
        #expect(layout.row(103).lines.contains(Line(top: .column(1), bottom: .cut(1))))
        #expect(layout.row(103).lines.contains(Line(top: .cut(2), bottom: .column(2))))
    }

    /// Columns that free up are used again, from the left.
    @Test func usesFreeColumnsAgain() throws {
        // Two unrelated roots, then a commit with no relation to either.
        let graph = try CommitGraph(format: .sha1).adding([
            commit(1), commit(2), commit(3, parents: [1]), commit(4, parents: [2]), commit(5),
        ])
        let positions = try [3, 4, 1, 2, 5].map { try #require(graph.position(of: id($0))) }
        var layout = LaneLayout(graph: graph)
        try layout.append(positions, isComplete: true)
        #expect(positions.indices.map { layout.row($0).column } == [0, 1, 0, 1, 0])
        #expect(layout.width == 2)
    }

    @Test func listsAParentOnce() throws {
        let graph = try CommitGraph(format: .sha1).adding([
            commit(1), commit(2), commit(3, parents: [1, 2, 1, 2]),
        ])
        let positions = try [3, 2, 1].map { try #require(graph.position(of: id($0))) }
        var layout = LaneLayout(graph: graph)
        try layout.append(positions, isComplete: true)
        #expect(layout.row(0).lines == [
            Line(top: .commit, bottom: .column(0)),
            Line(top: .commit, bottom: .column(1)),
        ])
    }

    // MARK: - Helpers

    /// Checks that the lines of every row continue in the next one, and that
    /// following the lines down from each commit's dot reaches its parents:
    /// directly when they're close, and through an arrow when they're far
    /// enough below for the line to be cut. A commit with a child that far
    /// above gets a line that starts at an arrow. Returns how many lines were
    /// cut.
    @discardableResult
    private func checkLines(_ layout: LaneLayout, names: [String]) throws -> Int {
        let graph = layout.graph
        let rows = layout.rows
        let drawn = rows.indices.map(layout.row)
        var rowOf: [CommitGraph.Position: Int] = [:]
        for (row, commit) in rows.enumerated() {
            rowOf[commit] = row
        }

        var widest = 0
        for (index, row) in drawn.enumerated() {
            let tops = row.lines.compactMap(\.top.column)
            let bottomsAbove = index == 0 ? [] : drawn[index - 1].lines.compactMap(\.bottom.column)
            #expect(tops.sorted() == Set(bottomsAbove).sorted(), "row \(index) from \(names)")
            #expect(!row.lines.contains(Line(top: .column(row.column), bottom: .column(row.column))))
            #expect(!row.lines.contains { $0.bottom == .commit && $0.top != .column(row.column) })
            #expect(!row.lines.contains { $0.top == .cut(row.column) || $0.bottom == .cut(row.column) })
            let cutColumns = row.lines.flatMap { line in
                [line.top, line.bottom].compactMap { end in
                    if case .cut(let column) = end { column } else { nil }
                }
            }
            #expect(cutColumns.count == Set(cutColumns).count, "row \(index) from \(names)")
            let columns = [row.column] + row.lines.flatMap { [$0.top.anyColumn, $0.bottom.anyColumn].compactMap(\.self) }
            #expect(row.width == columns.max()! + 1)
            widest = max(widest, row.width)
        }
        #expect(drawn.last?.lines.allSatisfy { $0.bottom == .commit } ?? true)
        #expect(layout.width == widest)

        // Follows a line down from a column at a row's bottom edge, and
        // returns where it ends: the row of a dot, or of a cut.
        func follow(_ column: Int, below row: Int) throws -> (row: Int, isCut: Bool) {
            var column = column
            var next = row + 1
            while true {
                let continuing = try #require(drawn[next].lines.first { $0.top == .column(column) })
                switch continuing.bottom {
                case .column(let below): column = below
                case .commit: return (next, false)
                case .cut: return (next, true)
                }
                next += 1
            }
        }

        var cuts = 0
        var cutTo: Set<CommitGraph.Position> = []
        for (index, row) in drawn.enumerated() {
            var reached: [CommitGraph.Position] = []
            var cutRows: [Int] = []
            for line in row.lines where line.top == .commit {
                let end = try follow(try #require(line.bottom.column), below: index)
                if end.isCut { cutRows.append(end.row) } else { reached.append(rows[end.row]) }
            }
            let parents = try graph.parents(of: rows[index]).reduce(into: [CommitGraph.Position]()) { list, parent in
                if !list.contains(parent) { list.append(parent) }
            }
            let near = parents.filter { rowOf[$0]! - index <= LaneLayout.longestLine }
            let far = parents.filter { rowOf[$0]! - index > LaneLayout.longestLine }
            #expect(reached.count == Set(reached).count)
            #expect(Set(reached) == Set(near), "row \(index) from \(names)")
            #expect(cutRows == Array(repeating: index + LaneLayout.cutLength, count: far.count))
            cuts += far.count
            cutTo.formUnion(far)
        }

        // Every line that starts at an arrow reaches a commit two rows below,
        // which has a child far above.
        var startsFrom: Set<CommitGraph.Position> = []
        for (index, row) in drawn.enumerated() {
            for line in row.lines {
                guard case .cut(let column) = line.top else { continue }
                let end = try follow(column, below: index)
                #expect(!end.isCut)
                #expect(end.row == index + LaneLayout.cutLength)
                startsFrom.insert(rows[end.row])
            }
        }
        #expect(startsFrom.isSubset(of: cutTo))
        for parent in cutTo {
            #expect(drawn[rowOf[parent]!].lines.contains { $0.bottom == .commit }, "a line reaches \(parent)")
        }
        return cuts
    }

    private func laidOut(_ numbers: [Int], in graph: CommitGraph) throws -> LaneLayout {
        var layout = LaneLayout(graph: graph)
        try layout.append(try numbers.map { try #require(graph.position(of: id($0))) }, isComplete: true)
        return layout
    }

    private func branchAndMerge() throws -> (CommitGraph, CommitGraph.Position, CommitGraph.Position, CommitGraph.Position, CommitGraph.Position) {
        let graph = try CommitGraph(format: .sha1).adding([
            commit(1), commit(2, parents: [1]), commit(3, parents: [1]), commit(4, parents: [2, 3]),
        ])
        let positions = try [4, 2, 3, 1].map { try #require(graph.position(of: id($0))) }
        return (graph, positions[0], positions[1], positions[2], positions[3])
    }

    /// Commits in a line, each the parent of the next.
    private func chain(_ numbers: ClosedRange<Int>) -> [CommitGraph.NewerCommit] {
        numbers.map { commit($0, parents: $0 == numbers.lowerBound ? [] : [$0 - 1]) }
    }

    private func id(_ number: Int) -> ObjectID {
        ObjectID(hex: String(repeating: "0", count: 32) + String(format: "%08x", number))!
    }

    private func commit(_ number: Int, parents: [Int] = []) -> CommitGraph.NewerCommit {
        CommitGraph.NewerCommit(id: id(number), parents: parents.map(id), commitTime: Int64(number))
    }
}

extension LaneLayout.Line.End {
    /// The column at the row's edge, if the line ends there.
    var column: Int? {
        if case .column(let column) = self { column } else { nil }
    }

    /// The column, unless the line ends at the dot.
    var anyColumn: Int? {
        switch self {
        case .column(let column), .cut(let column): column
        case .commit: nil
        }
    }
}
