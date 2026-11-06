import Foundation
import GitCore
import Testing
@testable import CommitGraph

struct WorkingTreeLineTests {
    typealias Line = LaneLayout.Line

    /// A commit's ID from a number.
    func id(_ number: Int) -> ObjectID {
        ObjectID(hex: String(format: "%040x", number + 1))!
    }

    /// A graph from each commit's parents, and a layout of it with the tips in
    /// the order given, which puts the newest first because of the dates.
    func layout(_ parents: [Int: [Int]], tips: [Int], rowsLaidOut: Int? = nil) throws -> (LaneLayout, CommitGraph) {
        let newer = parents.keys.sorted().map { number in
            CommitGraph.NewerCommit(id: id(number), parents: parents[number]!.map(id), commitTime: Int64(number))
        }
        let graph = try CommitGraph(format: .sha1).adding(newer)
        var order = try HistoryOrder(graph: graph, tips: tips.map { graph.position(of: id($0))! }, sort: .date)
        var layout = LaneLayout(graph: graph)
        if let rowsLaidOut {
            try layout.append(try order.next(rowsLaidOut + LaneLayout.longestLine), isComplete: false)
        } else {
            try layout.append(try order.next(Int.max), isComplete: true)
        }
        return (layout, graph)
    }

    /// A line of commits from `count - 1`, the newest, down to 0.
    func chain(_ count: Int) -> [Int: [Int]] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, $0 == 0 ? [] : [$0 - 1]) })
    }

    /// Which columns a row's lines use at its top edge.
    func columnsAtTop(_ row: LaneLayout.Row) -> [Int] {
        row.lines.compactMap { if case .column(let column) = $0.top { column } else { nil } }
    }

    @Test func hasNoLineWithoutAHead() throws {
        let line = WorkingTreeLine(layout: try layout([0: []], tips: [0]).0, head: nil)
        #expect(line.row == LaneLayout.Row(column: 0, lines: []))
    }

    @Test func goesStraightIntoHeadInTheFirstRow() throws {
        let (layout, graph) = try layout(chain(3), tips: [2])
        let line = WorkingTreeLine(layout: layout, head: graph.position(of: id(2)))
        let column = layout.row(0).column
        let color = column % LaneLayout.colors
        #expect(line.row == LaneLayout.Row(column: column, color: color, lines: [Line(top: .commit, bottom: .column(column), color: color)]))
        #expect(line.adding(to: layout.row(0), at: 0).lines.last == Line(top: .column(column), bottom: .commit, color: color))
        #expect(line.adding(to: layout.row(1), at: 1) == layout.row(1))
    }

    @Test func runsPastCommitsAboveHeadInAFreeColumn() throws {
        // A branch with three newer commits, and HEAD where it left the line.
        let parents: [Int: [Int]] = [0: [], 1: [0], 2: [1], 3: [1], 4: [3], 5: [4]]
        let (layout, graph) = try layout(parents, tips: [2, 5])
        let head = try #require(graph.position(of: id(2)))
        let headRow = try #require(layout.rows.firstIndex(of: head))
        #expect(headRow > 0)
        let line = WorkingTreeLine(layout: layout, head: head)

        let column = (0..<headRow).map { layout.row($0).width }.max()!
        let color = column % LaneLayout.colors
        #expect(line.row.column == column)
        #expect(line.row.color == color)
        #expect(line.row.lines == [Line(top: .commit, bottom: .column(column), color: color)])
        for row in 0..<headRow {
            #expect(!columnsAtTop(layout.row(row)).contains(column))
            #expect(line.adding(to: layout.row(row), at: row).lines.last == Line(top: .column(column), bottom: .column(column), color: color))
        }
        let drawn = line.adding(to: layout.row(headRow), at: headRow)
        #expect(!columnsAtTop(layout.row(headRow)).contains(column))
        #expect(drawn.lines.last == Line(top: .column(column), bottom: .commit, color: color))
        #expect(line.adding(to: layout.row(headRow + 1), at: headRow + 1) == layout.row(headRow + 1))
    }

    @Test func widensTheRowsItCrosses() throws {
        let parents: [Int: [Int]] = [0: [], 1: [0], 2: [0]]
        let (layout, graph) = try layout(parents, tips: [1, 2])
        let line = WorkingTreeLine(layout: layout, head: graph.position(of: id(1)))
        #expect(line.adding(to: layout.row(0), at: 0).width == line.row.column + 1)
    }

    @Test func cutsALineThatsTooLong() throws {
        let length = LaneLayout.longestLine + 20
        let (layout, graph) = try layout(chain(length + 5), tips: [length + 4])
        let head = try #require(graph.position(of: id(4)))
        let headRow = try #require(layout.rows.firstIndex(of: head))
        #expect(headRow > LaneLayout.longestLine)
        let line = WorkingTreeLine(layout: layout, head: head)

        let column = line.row.column
        let color = column % LaneLayout.colors
        #expect(line.row.lines == [Line(top: .commit, bottom: .column(column), color: color)])
        #expect(line.adding(to: layout.row(0), at: 0).lines.last == Line(top: .column(column), bottom: .column(column), color: color))
        #expect(line.adding(to: layout.row(1), at: 1).lines.last == Line(top: .column(column), bottom: .cut(column), color: color))
        #expect(line.adding(to: layout.row(2), at: 2) == layout.row(2))
        #expect(line.adding(to: layout.row(headRow - 3), at: headRow - 3) == layout.row(headRow - 3))
        // The end of the line keeps the color it started with.
        let end = layout.row(headRow - 1).width
        #expect(line.adding(to: layout.row(headRow - 2), at: headRow - 2).lines.last == Line(top: .cut(end), bottom: .column(end), color: color))
        #expect(line.adding(to: layout.row(headRow - 1), at: headRow - 1).lines.last == Line(top: .column(end), bottom: .column(end), color: color))
        #expect(line.adding(to: layout.row(headRow), at: headRow).lines.last == Line(top: .column(end), bottom: .commit, color: color))
    }

    @Test func pointsDownWhenHeadIsntLaidOutYet() throws {
        let (layout, graph) = try layout(chain(400), tips: [399], rowsLaidOut: 10)
        let head = try #require(graph.position(of: id(0)))
        #expect(!layout.rows.contains(head))
        let line = WorkingTreeLine(layout: layout, head: head)
        let column = line.row.column
        #expect(line.adding(to: layout.row(1), at: 1).lines.last == Line(top: .column(column), bottom: .cut(column), color: column % LaneLayout.colors))
    }
}
