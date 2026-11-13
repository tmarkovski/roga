import Foundation
import GitCore
import Testing
@testable import CommitGraph

struct FadedLinesTests {
    typealias Line = LaneLayout.Line

    /// A commit's ID from a number.
    func id(_ number: Int) -> ObjectID {
        ObjectID(hex: String(format: "%040x", number + 1))!
    }

    /// A graph from each commit's parents, laid out in date order, which puts
    /// the highest number first.
    func layout(_ parents: [Int: [Int]], tips: [Int]) throws -> (LaneLayout, CommitGraph) {
        let newer = parents.keys.sorted().map { number in
            CommitGraph.NewerCommit(id: id(number), parents: parents[number]!.map(id), commitTime: Int64(number))
        }
        let graph = try CommitGraph(format: .sha1).adding(newer)
        var order = try HistoryOrder(graph: graph, tips: tips.map { graph.position(of: id($0))! }, sort: .date)
        var layout = LaneLayout(graph: graph)
        try layout.append(try order.next(Int.max), isComplete: true)
        return (layout, graph)
    }

    func faded(_ numbers: [Int], in layout: LaneLayout, _ graph: CommitGraph) -> FadedLines {
        FadedLines(layout: layout, commits: Set(numbers.map { graph.position(of: id($0))! }))
    }

    /// The row of a commit.
    func row(of number: Int, in layout: LaneLayout, _ graph: CommitGraph) -> Int {
        layout.rows.firstIndex(of: graph.position(of: id(number))!)!
    }

    /// Each row's lines, marked, as which of them are faded.
    func fadedLines(_ lines: FadedLines, in layout: LaneLayout) -> [[Line]] {
        (0..<layout.count).map { index in lines.marking(layout.row(index), at: index).lines.filter(\.isFaded) }
    }

    @Test func fadesNothingWithoutCommits() throws {
        let (layout, _) = try layout([0: [], 1: [0], 2: [1]], tips: [2])
        let lines = FadedLines(layout: layout, commits: [])
        #expect(lines.isEmpty)
        #expect(fadedLines(lines, in: layout).allSatisfy { $0.isEmpty })
    }

    /// The branch is on 1, and its upstream on 3.
    @Test func fadesTheLinesDownFromTheMissingCommits() throws {
        let (layout, graph) = try layout([0: [], 1: [0], 2: [1], 3: [2]], tips: [3, 1])
        let lines = faded([3, 2], in: layout, graph)
        #expect(fadedLines(lines, in: layout) == [
            [Line(top: .commit, bottom: .column(0))],
            [Line(top: .column(0), bottom: .commit), Line(top: .commit, bottom: .column(0))],
            // The line into the branch's own commit comes from a missing one.
            [Line(top: .column(0), bottom: .commit)],
            [],
        ].map { $0.map { Line(top: $0.top, bottom: $0.bottom, color: 0, isFaded: true) } })
    }

    /// The branch has 1 and its upstream has 2 and 3, all on 0, so the
    /// branch's line passes the missing commits.
    @Test func leavesALinePastAMissingCommitAsItIs() throws {
        let (layout, graph) = try layout([0: [], 1: [0], 2: [0], 3: [2]], tips: [3, 1])
        let lines = faded([3, 2], in: layout, graph)
        let one = row(of: 1, in: layout, graph)
        let zero = row(of: 0, in: layout, graph)
        let marked = fadedLines(lines, in: layout)
        // The upstream's line runs past 1 to 0, faded, and 1's own line doesn't.
        let oneRow = lines.marking(layout.row(one), at: one)
        #expect(oneRow.lines.contains { $0.isFaded && $0.top == .column(layout.row(row(of: 2, in: layout, graph)).column) })
        #expect(oneRow.lines.contains { !$0.isFaded && $0.top == .commit })
        // In 0's row, one line comes in from each, and only the upstream's is faded.
        let zeroRow = lines.marking(layout.row(zero), at: zero)
        #expect(zeroRow.lines.filter { $0.bottom == .commit }.count == 2)
        #expect(marked[zero].count == 1)
        #expect(zeroRow.lines.filter { $0.bottom == .commit && !$0.isFaded }.count == 1)
    }

    /// Someone's branch 4 is on the upstream's 2, which the branch is missing,
    /// but 4 isn't missing: a pull wouldn't bring it in.
    @Test func leavesALineIntoAMissingCommitAsItIs() throws {
        let (layout, graph) = try layout([0: [], 1: [0], 2: [0], 3: [2], 4: [2]], tips: [4, 3, 1])
        let lines = faded([3, 2], in: layout, graph)
        let two = row(of: 2, in: layout, graph)
        let twoRow = lines.marking(layout.row(two), at: two)
        // 3's line and 4's line both end at 2's dot.
        let intoTwo = twoRow.lines.filter { $0.bottom == .commit }
        #expect(intoTwo.count == 2)
        #expect(intoTwo.filter(\.isFaded).count == 1)
        let four = row(of: 4, in: layout, graph)
        #expect(lines.marking(layout.row(four), at: four).lines.allSatisfy { !$0.isFaded })
    }

    /// A missing commit far above its parent has its line cut. The arrow below
    /// it is faded, and the start again above the parent, which isn't missing,
    /// isn't.
    @Test func fadesACutLineBelowAMissingCommit() throws {
        let rungs = LaneLayout.longestLine + 20
        var parents: [Int: [Int]] = [0: []]
        for number in 1...rungs { parents[number] = [number - 1] }
        parents[rungs + 1] = [0]
        let (layout, graph) = try layout(parents, tips: [rungs + 1, rungs])
        let lines = faded([rungs + 1], in: layout, graph)
        let marked = fadedLines(lines, in: layout)
        let rows = marked.indices.filter { !marked[$0].isEmpty }
        #expect(rows == Array(0...LaneLayout.cutLength))
        if case .cut = marked[LaneLayout.cutLength].first?.bottom {} else {
            Issue.record("The faded line doesn't end in an arrow: \(marked[LaneLayout.cutLength])")
        }
        // The line starts again a couple of rows above 0, at full strength.
        let restart = row(of: 0, in: layout, graph) - LaneLayout.cutLength
        #expect(layout.row(restart).lines.contains { if case .cut = $0.top { true } else { false } })
    }

    /// The upstream's 2 is a merge of the branch's 1 and someone's 3, which
    /// the branch is missing too.
    @Test func fadesBothLinesFromAMissingMerge() throws {
        let (layout, graph) = try layout([0: [], 1: [0], 3: [0], 4: [1, 3]], tips: [4, 1])
        let lines = faded([4, 3], in: layout, graph)
        let four = row(of: 4, in: layout, graph)
        let fourRow = lines.marking(layout.row(four), at: four)
        #expect(fourRow.lines.filter { $0.top == .commit }.count == 2)
        #expect(fourRow.lines.allSatisfy { $0.isFaded })
        // 1's own line into 0 stays as it is.
        let one = row(of: 1, in: layout, graph)
        #expect(lines.marking(layout.row(one), at: one).lines.contains { $0.top == .commit && !$0.isFaded })
    }
}
