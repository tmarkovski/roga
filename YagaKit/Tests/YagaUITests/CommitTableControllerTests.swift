import AppKit
import Foundation
import Testing
@testable import HistoryUI

/// How the commit list reports its selection. Only what the user does is
/// reported, so that history loading again can't change what's selected.
@Suite(.timeLimit(.minutes(1)))
struct CommitTableControllerTests {
    /// A list with rows, which records the selections it reports.
    final class List {
        var count: Int
        var reported: [Int?] = []
        private(set) lazy var controller = CommitTableController(source: CommitTableController.Source(
            count: { [unowned self] in count },
            content: { _ in CommitRowContent(shortID: "") },
            loadText: { _ in [] },
            selectRow: { [unowned self] in reported.append($0) }
        ))

        init(count: Int) {
            self.count = count
            controller.reloadData()
        }

        var table: NSTableView { controller.scrollView.documentView as! NSTableView }
    }

    @Test func reportsWhatTheUserSelects() {
        let list = List(count: 10)
        // What a click or an arrow key ends up doing.
        list.table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        list.table.deselectAll(nil)
        #expect(list.reported == [3, nil])
    }

    @Test func doesntReportASelectionFromOutside() {
        let list = List(count: 10)
        list.controller.select(row: 4)
        #expect(list.controller.selectedRow == 4)
        list.controller.select(row: nil)
        #expect(list.controller.selectedRow == nil)
        #expect(list.reported.isEmpty)
    }

    @Test func doesntReportALostSelectionWhenRowsGoAway() {
        // The first rows of a new history replace all of an old one.
        let list = List(count: 10)
        list.controller.select(row: 8)
        list.count = 5
        list.controller.reloadData()
        #expect(list.reported.isEmpty)
        list.controller.select(row: 2)
        #expect(list.controller.selectedRow == 2)
        #expect(list.reported.isEmpty)
    }

    @Test func reportsAgainAfterChangingTheSelection() {
        let list = List(count: 10)
        list.controller.select(row: 1)
        list.controller.reloadData()
        list.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(list.reported == [2])
    }
}

/// Which badges the pointer and double-clicks find.
@Suite(.timeLimit(.minutes(1)))
struct CommitTableBadgeTests {
    typealias Badge = CommitRowContent.Badge

    static let badges = [
        Badge(title: "main", kind: .currentBranch, refName: "refs/heads/main"),
        Badge(title: "feature", kind: .branch, refName: "refs/heads/feature"),
        Badge(title: "origin/feature", kind: .remoteBranch, refName: "refs/remotes/origin/feature"),
        Badge(title: "v1.0", kind: .tag, refName: "refs/tags/v1.0"),
        Badge(title: "HEAD", kind: .detachedHead),
    ]

    /// A list whose row 1 has all the kinds of badge, and whose others have none.
    final class List {
        var checkedOut: [Badge] = []
        private(set) lazy var controller = CommitTableController(source: CommitTableController.Source(
            count: { 3 },
            content: { CommitTableBadgeTests.content(ofRow: $0) },
            loadText: { _ in [] },
            selectRow: { _ in },
            checkOut: { [unowned self] in checkedOut.append($0) }
        ))

        init() {
            table.frame.size.width = 1200
            table.tableColumns[0].width = 1200
            controller.reloadData()
        }

        var table: NSTableView { controller.scrollView.documentView as! NSTableView }

        /// The middle of a badge of row 1, in the table.
        func middle(ofBadge index: Int) -> NSPoint {
            let frame = table.frameOfCell(atColumn: 0, row: 1)
            let layout = CommitRowLayout(content: CommitTableBadgeTests.content(ofRow: 1), graphColumns: 0, size: frame.size)
            return NSPoint(x: frame.minX + layout.badges[index].midX, y: frame.minY + layout.badges[index].midY)
        }
    }

    static func content(ofRow row: Int) -> CommitRowContent {
        CommitRowContent(shortID: "abcd1234", badges: row == 1 ? badges : [], subject: "A subject")
    }

    @Test func checksOutTheBranchesOfTheBadgesThatHaveThem() {
        let list = List()
        for index in Self.badges.indices { list.controller.doubleClick(at: list.middle(ofBadge: index)) }
        #expect(list.checkedOut.map(\.title) == ["feature", "origin/feature"])
        #expect(list.checkedOut.map(\.refName) == ["refs/heads/feature", "refs/remotes/origin/feature"])
    }

    @Test func findsOnlyBadgesThatCanBeCheckedOut() {
        let list = List()
        #expect(list.controller.badge(at: list.middle(ofBadge: 0)) == nil)
        #expect(list.controller.badge(at: list.middle(ofBadge: 1)) == CommitTableController.BadgePlace(row: 1, index: 1))
        #expect(list.controller.badge(at: list.middle(ofBadge: 2)) == CommitTableController.BadgePlace(row: 1, index: 2))
        #expect(list.controller.badge(at: list.middle(ofBadge: 3)) == nil)
        #expect(list.controller.badge(at: list.middle(ofBadge: 4)) == nil)
    }

    @Test func doesNothingAwayFromABadge() {
        let list = List()
        let frame = list.table.frameOfCell(atColumn: 0, row: 1)
        // Past the badges, and the row above, which has none.
        list.controller.doubleClick(at: NSPoint(x: frame.maxX - 20, y: frame.midY))
        list.controller.doubleClick(at: NSPoint(x: list.middle(ofBadge: 1).x, y: frame.minY - 5))
        // Below the last row.
        list.controller.doubleClick(at: NSPoint(x: list.middle(ofBadge: 1).x, y: 10_000))
        #expect(list.checkedOut.isEmpty)
    }

    @Test func missesTheGapsBetweenBadges() {
        let list = List()
        let frame = list.table.frameOfCell(atColumn: 0, row: 1)
        let layout = CommitRowLayout(content: Self.content(ofRow: 1), graphColumns: 0, size: frame.size)
        let gap = (layout.badges[1].maxX + layout.badges[2].minX) / 2
        #expect(list.controller.badge(at: NSPoint(x: frame.minX + gap, y: frame.midY)) == nil)
    }

    @Test func keepsTheSubjectAfterTheBadges() throws {
        let layout = CommitRowLayout(content: Self.content(ofRow: 1), graphColumns: 3, size: NSSize(width: 1200, height: 28))
        #expect(layout.badges.count == Self.badges.count)
        let last = try #require(layout.badges.last)
        #expect(layout.subjectX > last.maxX)
        #expect(layout.subjectMaxX > layout.subjectX)
        // The badges go after the graph, in order, without touching.
        #expect(layout.badges[0].minX > LaneRenderer.width(columns: 3))
        for (first, second) in zip(layout.badges, layout.badges.dropFirst()) {
            #expect(first.maxX < second.minX)
        }
    }

    @Test func leavesOutBadgesThatDontFit() {
        let layout = CommitRowLayout(content: Self.content(ofRow: 1), graphColumns: 0, size: NSSize(width: 160, height: 28))
        #expect(layout.badges.count < Self.badges.count)
        #expect(layout.badges.allSatisfy { $0.maxX <= layout.subjectMaxX })
    }
}
