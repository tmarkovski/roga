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

    /// The rows in view, once the list has a height.
    func giveHeight(to list: List) -> Range<Int> {
        list.controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        list.controller.scrollView.layoutSubtreeIfNeeded()
        let rows = list.table.rows(in: list.table.visibleRect)
        return rows.location..<rows.location + rows.length
    }

    @Test func leavesARowInViewWhereItIsWhenItSelectsItBeforeHavingAHeight() {
        // The window shows a worktree again, which makes a new list with its
        // selection before the list has been laid out.
        let list = List(count: 100)
        list.controller.select(row: 2)
        let rows = giveHeight(to: list)
        #expect(rows.lowerBound == 0)
        #expect(rows.contains(2))
    }

    @Test func scrollsARowOutOfViewIntoViewOnceItHasAHeight() {
        let list = List(count: 100)
        list.controller.select(row: 50)
        let rows = giveHeight(to: list)
        #expect(rows.contains(50))
        #expect(rows.lowerBound < 50)
    }

    @Test func revealsTheLatestSelectionOnceItHasAHeight() {
        let list = List(count: 100)
        list.controller.select(row: 50)
        list.controller.select(row: 80)
        #expect(giveHeight(to: list).contains(80))
    }

    @Test func revealsNothingAfterTheSelectionGoesAway() {
        let list = List(count: 100)
        list.controller.select(row: 50)
        list.controller.select(row: nil)
        #expect(giveHeight(to: list).lowerBound == 0)
    }

    @Test func scrollsStraightAwayOnceItHasAHeight() {
        let list = List(count: 100)
        _ = giveHeight(to: list)
        list.controller.select(row: 50)
        let rows = list.table.rows(in: list.table.visibleRect)
        #expect(rows.location <= 50 && 50 < rows.location + rows.length)
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

    /// A list whose row 1 has all the kinds of badge, whose row 2 has the ones
    /// that aren't branches, and whose row 0 has none.
    final class List {
        var checkedOut: [Badge] = []
        var deleted: [Badge] = []
        var isBusy = false
        private(set) lazy var controller = CommitTableController(source: CommitTableController.Source(
            count: { 3 },
            content: { CommitTableBadgeTests.content(ofRow: $0) },
            loadText: { _ in [] },
            selectRow: { _ in },
            checkOut: { [unowned self] in checkedOut.append($0) },
            deleteBranch: { [unowned self] in deleted.append($0) },
            isBusy: { [unowned self] in isBusy }
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
        let badges = switch row {
        case 1: badges
        case 2: badges.filter { !$0.isBranch }
        default: [Badge]()
        }
        return CommitRowContent(shortID: "abcd1234", badges: badges, subject: "A subject")
    }

    @Test func aRowsMenuNamesEachBranchAboveItsItem() throws {
        let list = List()
        let menu = try #require(list.controller.menu(forRow: 1))
        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["main", "Delete Branch", "feature", "Delete Branch", "origin/feature", "Delete from Remote…"])
        #expect(items.map(\.isSectionHeader) == [true, false, true, false, true, false])
    }

    @Test func aRowsMenuListsUpstreamsThatShareABadge() {
        let content = CommitRowContent(shortID: "abcd1234", badges: [
            Badge(title: "main", kind: .currentBranch, refName: "refs/heads/main", upstream: "refs/remotes/origin/main"),
            Badge(title: "feature", kind: .branch, refName: "refs/heads/feature", upstream: "refs/remotes/origin/feature"),
            Badge(title: "upstream/main", kind: .remoteBranch, refName: "refs/remotes/upstream/main"),
        ])
        #expect(content.branches.map(\.title) == ["main", "feature", "origin/feature", "origin/main", "upstream/main"])
        #expect(content.branches.map(\.kind) == [.currentBranch, .branch, .remoteBranch, .remoteBranch, .remoteBranch])
        // Deleting from the remote acts on the upstream, not on the local branch.
        #expect(content.branches[2].refName == "refs/remotes/origin/feature")
        #expect(content.branches[2].upstream == nil)
    }

    @Test func saysWhatABadgeStandsFor() {
        #expect(Badge(title: "main", kind: .currentBranch, upstream: "refs/remotes/origin/main").spokenTitle == "main, current branch, in sync with origin/main")
        #expect(Badge(title: "main", kind: .currentBranch).spokenTitle == "main, current branch")
        #expect(Badge(title: "fix", kind: .branch, upstream: "refs/remotes/origin/fix").spokenTitle == "fix, in sync with origin/fix")
        #expect(Badge(title: "HEAD", kind: .detachedHead).spokenTitle == "HEAD, on no branch")
        #expect(Badge(title: "v1.0", kind: .tag).spokenTitle == "v1.0")
    }

    @Test func readsTheBodyLastWithVoiceOver() {
        let content = CommitRowContent(shortID: "abcd1234", badges: [Badge(title: "fix", kind: .branch, upstream: "refs/remotes/origin/fix")], subject: "A subject", body: "Why it changed.", author: "Ana", date: "Today")
        #expect(content.spokenText == "A subject, fix, in sync with origin/fix, Ana, Today, abcd1234, Why it changed.")
    }

    @Test func aRemotesBranchShowsItsNameBeforeItsRemote() {
        let remote = Badge(title: "origin/tm/fix", kind: .remoteBranch, refName: "refs/remotes/origin/tm/fix")
        #expect(remote.nameAndRemote.name == "tm/fix")
        #expect(remote.nameAndRemote.remote == "origin")
        // Everywhere that names it in words still has the whole name.
        #expect(remote.spokenTitle == "origin/tm/fix")
        #expect(Badge(title: "tm/fix", kind: .branch).nameAndRemote.remote == nil)
        #expect(Badge(title: "release/1.0", kind: .tag).nameAndRemote.name == "release/1.0")
    }

    @Test func aRemotesBranchIsWiderThanItsNameForItsRemote() throws {
        let size = NSSize(width: 1200, height: 28)
        let local = CommitRowContent(shortID: "a", badges: [Badge(title: "tm/fix", kind: .branch)])
        let remote = CommitRowContent(shortID: "a", badges: [Badge(title: "origin/tm/fix", kind: .remoteBranch)])
        let localWidth = try #require(CommitRowLayout(content: local, graphColumns: 0, size: size).badges.first).width
        let remoteWidth = try #require(CommitRowLayout(content: remote, graphColumns: 0, size: size).badges.first).width
        let style = CommitCellView.BadgeLook.of(.remoteBranch).remoteStyle
        #expect(remoteWidth >= localWidth + CommitRowLayout.width(of: "origin", in: style))
    }

    @Test func aBadgeThatStandsForItsUpstreamIsWiderForItsCloud() throws {
        let plain = CommitRowContent(shortID: "abcd1234", badges: [Badge(title: "feature", kind: .branch)], subject: "A subject")
        let merged = CommitRowContent(shortID: "abcd1234", badges: [Badge(title: "feature", kind: .branch, upstream: "refs/remotes/origin/feature")], subject: "A subject")
        let size = NSSize(width: 1200, height: 28)
        let plainWidth = try #require(CommitRowLayout(content: plain, graphColumns: 0, size: size).badges.first).width
        let mergedWidth = try #require(CommitRowLayout(content: merged, graphColumns: 0, size: size).badges.first).width
        #expect(mergedWidth > plainWidth)
    }

    @Test func aBadgesTooltipSaysWhatItStandsFor() throws {
        let cell = CommitCellView()
        cell.frame = NSRect(x: 0, y: 0, width: 1200, height: 28)
        cell.content = Self.content(ofRow: 1)
        let layout = CommitRowLayout(content: Self.content(ofRow: 1), graphColumns: 0, size: cell.bounds.size)
        let second = NSPoint(x: layout.badges[1].midX, y: layout.badges[1].midY)
        #expect(cell.view(cell, stringForToolTip: 0, point: second, userData: nil) == "feature")
        #expect(cell.view(cell, stringForToolTip: 0, point: NSPoint(x: layout.badges[0].midX, y: 14), userData: nil) == "main, current branch")
    }

    @Test func aRowsMenuActsOnTheBranchOfTheChosenItem() throws {
        let list = List()
        let menu = try #require(list.controller.menu(forRow: 1))
        let items = menu.items.filter { !$0.isSeparatorItem }
        for index in [3, 5] {
            let item = items[index]
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
        }
        #expect(list.deleted.map(\.refName) == ["refs/heads/feature", "refs/remotes/origin/feature"])
    }

    @Test func aRowsMenuDisablesTheCurrentBranch() throws {
        let list = List()
        let menu = try #require(list.controller.menu(forRow: 1))
        #expect(!menu.autoenablesItems)
        #expect(menu.items.filter { !$0.isSectionHeader && !$0.isSeparatorItem }.map(\.isEnabled) == [false, true, true])
    }

    @Test func aRowsMenuDisablesEverythingWhileSomethingRuns() throws {
        let list = List()
        list.isBusy = true
        let menu = try #require(list.controller.menu(forRow: 1))
        #expect(menu.items.filter { !$0.isSectionHeader && !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
    }

    @Test func aRowWithoutBranchesHasNoMenu() {
        let list = List()
        #expect(list.controller.menu(forRow: 0) == nil)
        #expect(list.controller.menu(forRow: 2) == nil)
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
