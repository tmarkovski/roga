import AppKit
import Foundation
import Testing
@testable import CommitGraph
import GitCore
@testable import HistoryUI
import MenuUI

/// Lets the run loop turn, which sends the report the list is holding until the
/// frame that shows the selection has been drawn.
@MainActor func waitForReport() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

/// How the commit list reports its selection. Only what the user does is
/// reported, so that history loading again can't change what's selected.
@Suite(.timeLimit(.minutes(1)))
struct CommitTableControllerTests {
    /// A list with rows, which records the selections it reports.
    final class List {
        var count: Int
        var reported: [IndexSet] = []
        private(set) lazy var controller = CommitTableController(source: CommitTableController.Source(
            count: { [unowned self] in count },
            content: { _ in CommitRowContent(shortID: "") },
            loadText: { _ in [] },
            selectRows: { [weak self] in self?.reported.append($0) }
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
        waitForReport()
        list.table.deselectAll(nil)
        waitForReport()
        #expect(list.reported == [IndexSet(integer: 3), IndexSet()])
    }

    @Test func reportsOnceTheRunLoopHasTurned() {
        let list = List(count: 10)
        list.table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        #expect(list.reported.isEmpty)
        waitForReport()
        #expect(list.reported == [IndexSet(integer: 3)])
    }

    @Test func reportsOnlyWhereSeveralChangesInARowEnd() {
        // An arrow key held down.
        let list = List(count: 10)
        for row in 3...6 {
            list.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        waitForReport()
        #expect(list.reported == [IndexSet(integer: 6)])
    }

    @Test func keepsWhatTheUserSelectedUntilTheModelHasHeard() {
        // The window updates the list with the model's selection, which is
        // older than the one waiting to be reported.
        let list = List(count: 10)
        list.table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        list.controller.select(row: 1)
        #expect(list.controller.selectedRow == 3)
        waitForReport()
        #expect(list.reported == [IndexSet(integer: 3)])
        list.controller.select(row: 1)
        #expect(list.controller.selectedRow == 1)
    }

    @Test func dropsAReportWhenTheRowsChangeBeforeItsSent() {
        // Its row numbers are the old history's.
        let list = List(count: 10)
        list.table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        list.controller.reloadData()
        waitForReport()
        #expect(list.reported.isEmpty)
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
        waitForReport()
        #expect(list.reported == [IndexSet(integer: 2)])
    }

    @Test func reportsSeveralRowsTheUserSelects() {
        // What Shift-clicking a run of rows and Command-clicking another does.
        let list = List(count: 10)
        list.table.selectRowIndexes(IndexSet(2...4), byExtendingSelection: false)
        waitForReport()
        list.table.selectRowIndexes(IndexSet(integer: 7), byExtendingSelection: true)
        waitForReport()
        #expect(list.reported == [IndexSet(2...4), IndexSet([2, 3, 4, 7])])
        #expect(list.controller.selectedRows == IndexSet([2, 3, 4, 7]))
        #expect(list.controller.selectedRow == nil)
    }

    @Test func selectsSeveralRowsFromOutsideWithoutReportingThem() {
        // A branch's commits, which a review selects.
        let list = List(count: 10)
        list.controller.select(rows: IndexSet([1, 2, 5]))
        #expect(list.controller.selectedRows == IndexSet([1, 2, 5]))
        list.controller.select(rows: [])
        #expect(list.controller.selectedRows.isEmpty)
        #expect(list.reported.isEmpty)
    }
}

/// Selecting a clicked row as the button goes down, and reporting it once.
@Suite(.timeLimit(.minutes(1)))
struct CommitTablePressTests {
    /// A window that says it's key, which the list's own window has to be. It's
    /// never shown.
    final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// A list of ten rows, in a window tall enough for all of them.
    final class List {
        var reported: [IndexSet] = []
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        private(set) lazy var controller = CommitTableController(source: CommitTableController.Source(
            count: { 10 },
            content: { _ in CommitRowContent(shortID: "") },
            loadText: { _ in [] },
            selectRows: { [weak self] in self?.reported.append($0) }
        ))

        init() {
            window.isReleasedWhenClosed = false
            window.contentView = controller.scrollView
            controller.reloadData()
            controller.scrollView.layoutSubtreeIfNeeded()
        }

        var table: NSTableView { controller.scrollView.documentView as! NSTableView }

        /// A press on a row, or below the last one.
        func press(row: Int, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1, in window: NSWindow? = nil) -> NSEvent {
            let rect = table.rect(ofRow: min(row, 9))
            let y = row > 9 ? rect.maxY + 40 : rect.midY
            let location = table.convert(NSPoint(x: rect.midX, y: y), to: nil)
            return NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: modifiers, timestamp: 0,
                windowNumber: (window ?? self.window).windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
            )!
        }
    }

    @Test func aPlainPressSelectsItsRow() {
        let list = List()
        list.controller.press(list.press(row: 3))
        #expect(list.controller.selectedRow == 3)
        waitForReport()
        #expect(list.reported == [IndexSet(integer: 3)])
    }

    @Test func theClickDoesntReportARowItsPressSelected() {
        let list = List()
        list.controller.press(list.press(row: 3))
        waitForReport()
        list.controller.reportClick(onRow: 3, modifiers: [])
        waitForReport()
        #expect(list.reported == [IndexSet(integer: 3)])
    }

    @Test func aClickOnTheOnlySelectedRowReportsItAgain() {
        let list = List()
        list.controller.press(list.press(row: 3))
        waitForReport()
        list.controller.reportClick(onRow: 3, modifiers: [])
        // The second click's press leaves the row alone, so its release reports it.
        list.controller.press(list.press(row: 3))
        list.controller.reportClick(onRow: 3, modifiers: [])
        waitForReport()
        #expect(list.reported == [IndexSet(integer: 3), IndexSet(integer: 3)])
    }

    @Test func aPressSelectsOneOfSeveralSelectedRowsAlone() {
        let list = List()
        list.controller.select(rows: IndexSet(2...5))
        list.controller.press(list.press(row: 4))
        #expect(list.controller.selectedRows == IndexSet(integer: 4))
        waitForReport()
        #expect(list.reported == [IndexSet(integer: 4)])
    }

    @Test func leavesOtherPressesToAppKit() {
        let list = List()
        list.controller.select(row: 1)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let presses = [
            list.press(row: 3, modifiers: .command),
            list.press(row: 3, modifiers: .shift),
            list.press(row: 3, modifiers: .control),
            list.press(row: 3, modifiers: .option),
            list.press(row: 3, clickCount: 2),
            list.press(row: 12),
            list.press(row: 3, in: other),
        ]
        for press in presses {
            list.controller.press(press)
            #expect(list.controller.selectedRow == 1)
        }
        waitForReport()
        #expect(list.reported.isEmpty)
    }

    @Test func leavesPressesToAppKitWhileTheWindowIsntKey() {
        let list = List()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.controller.scrollView
        list.controller.scrollView.layoutSubtreeIfNeeded()
        list.controller.press(list.press(row: 3, in: window))
        #expect(list.controller.selectedRow == nil)
    }
}

/// The row for uncommitted changes, which can't be one of several selected rows.
@Suite(.timeLimit(.minutes(1)))
struct CommitTableWorkingTreeSelectionTests {
    func makeController() -> CommitTableController {
        let controller = CommitTableController(source: CommitTableController.Source(
            count: { 10 },
            content: { $0 == 0 ? CommitRowContent(shortID: "", isWorkingTree: true) : CommitRowContent(shortID: "") },
            loadText: { _ in [] },
            selectRows: { _ in }
        ))
        controller.reloadData()
        return controller
    }

    func propose(_ rows: IndexSet, to controller: CommitTableController) -> IndexSet {
        let table = controller.scrollView.documentView as! NSTableView
        return controller.tableView(table, selectionIndexesForProposedSelection: rows)
    }

    @Test func itsLeftOutOfARunOfCommits() {
        let controller = makeController()
        controller.select(row: 0)
        #expect(propose(IndexSet(0...3), to: controller) == IndexSet(1...3))
    }

    @Test func commandClickingItSelectsItAlone() {
        let controller = makeController()
        controller.select(rows: IndexSet([2, 3]))
        #expect(propose(IndexSet([0, 2, 3]), to: controller) == IndexSet(integer: 0))
    }

    @Test func itsSelectedAloneAsUsual() {
        let controller = makeController()
        controller.select(row: 4)
        #expect(propose(IndexSet(integer: 0), to: controller) == IndexSet(integer: 0))
        #expect(propose(IndexSet([4, 5]), to: controller) == IndexSet([4, 5]))
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
        var wentTo: [Int] = []
        /// What the menus were asked for, by row and badge.
        var menusAskedFor: [(row: Int, badge: Badge?)] = []
        /// Whether a row has anything to offer.
        var offersAMenu = true
        private(set) lazy var controller = CommitTableController(source: CommitTableController.Source(
            count: { 3 },
            content: { CommitTableBadgeTests.content(ofRow: $0) },
            loadText: { _ in [] },
            selectRows: { _ in },
            checkOut: { [unowned self] in checkedOut.append($0) },
            goToRow: { [unowned self] in wentTo.append($0) },
            menuEntries: { [unowned self] row, badge in
                menusAskedFor.append((row, badge))
                return offersAMenu ? [.command("Revert…") {}] : []
            }
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
            let layout = CommitRowLayout(content: CommitTableBadgeTests.content(ofRow: 1), size: frame.size)
            return NSPoint(x: frame.minX + layout.badges[index].midX, y: frame.minY + layout.badges[index].midY)
        }
    }

    static func commit(_ number: Int) -> ObjectID {
        ObjectID(hex: String(repeating: String(number), count: 40))!
    }

    static func content(ofRow row: Int) -> CommitRowContent {
        let badges = switch row {
        case 1: badges
        case 2: badges.filter { !$0.isBranch }
        default: [Badge]()
        }
        return CommitRowContent(shortID: "abcd1234", badges: badges, subject: "A subject")
    }

    @Test func aRowsMenuIsWhatItsSourceOffers() throws {
        let list = List()
        let menu = try #require(list.controller.menu(forRow: 1))
        #expect(menu.items.map(\.title) == ["Revert…"])
        #expect(list.menusAskedFor.count == 1)
        #expect(list.menusAskedFor[0].row == 1)
        #expect(list.menusAskedFor[0].badge == nil)
    }

    @Test func aMenuOpenedOnABadgeActsOnThatBadge() throws {
        let list = List()
        // The current branch can't be double-clicked, but its menu still goes by it.
        _ = list.controller.menu(forRow: 1, at: list.middle(ofBadge: 0))
        _ = list.controller.menu(forRow: 1, at: list.middle(ofBadge: 1))
        #expect(list.menusAskedFor.map(\.badge?.title) == ["main", "feature"])
    }

    @Test func listsEveryBranchWithLocalOnesFirstAndRemoteOnesFromAToZ() {
        let content = CommitRowContent(shortID: "abcd1234", badges: [
            Badge(title: "main", kind: .currentBranch, refName: "refs/heads/main", upstream: "refs/remotes/origin/main"),
            Badge(title: "feature", kind: .branch, refName: "refs/heads/feature", upstream: "refs/remotes/origin/feature"),
            Badge(title: "upstream/main", kind: .remoteBranch, refName: "refs/remotes/upstream/main"),
            Badge(title: "v1.0", kind: .tag, refName: "refs/tags/v1.0"),
            Badge(title: "HEAD", kind: .detachedHead),
        ])
        #expect(content.branches == [
            "refs/heads/main", "refs/heads/feature",
            "refs/remotes/origin/feature", "refs/remotes/origin/main", "refs/remotes/upstream/main",
        ])
    }

    @Test func listsOtherRemotesBranchesThatShareABadge() {
        let content = CommitRowContent(shortID: "abcd1234", badges: [
            Badge(title: "main", kind: .currentBranch, refName: "refs/heads/main", upstream: "refs/remotes/origin/main", otherRemoteBranches: ["refs/remotes/upstream/main"]),
            Badge(title: "feature", kind: .branch, refName: "refs/heads/feature", upstream: "refs/remotes/origin/feature", otherRemoteBranches: ["refs/remotes/fork/feature"]),
        ])
        #expect(content.branches == [
            "refs/heads/main", "refs/heads/feature",
            "refs/remotes/fork/feature", "refs/remotes/origin/feature", "refs/remotes/origin/main", "refs/remotes/upstream/main",
        ])
    }

    @Test func aRowHasABranchThatCanGoUnlessItsOnlyTheCurrentOne() {
        func canGo(_ badge: Badge) -> Bool {
            CommitRowContent(shortID: "abcd1234", badges: [badge]).hasBranchThatCanGo
        }
        #expect(!canGo(Badge(title: "main", kind: .currentBranch, refName: "refs/heads/main")))
        #expect(!canGo(Badge(title: "v1.0", kind: .tag, refName: "refs/tags/v1.0")))
        #expect(!canGo(Badge(title: "HEAD", kind: .detachedHead)))
        #expect(canGo(Badge(title: "main", kind: .currentBranch, refName: "refs/heads/main", upstream: "refs/remotes/origin/main")))
        #expect(canGo(Badge(title: "feature", kind: .branch, refName: "refs/heads/feature")))
        #expect(canGo(Badge(title: "origin/feature", kind: .remoteBranch, refName: "refs/remotes/origin/feature")))
    }

    @Test func saysWhatABadgeStandsFor() {
        #expect(Badge(title: "main", kind: .currentBranch, upstream: "refs/remotes/origin/main").spokenTitle == "main, current branch, in sync with origin/main")
        #expect(Badge(title: "main", kind: .currentBranch).spokenTitle == "main, current branch")
        #expect(Badge(title: "fix", kind: .branch, upstream: "refs/remotes/origin/fix").spokenTitle == "fix, in sync with origin/fix")
        #expect(Badge(title: "main", kind: .currentBranch, upstream: "refs/remotes/origin/main", otherRemoteBranches: ["refs/remotes/upstream/main"]).spokenTitle == "main, current branch, in sync with origin/main and upstream/main")
        #expect(Badge(title: "fix", kind: .branch, upstream: "refs/remotes/origin/fix", otherRemoteBranches: ["refs/remotes/backup/fix", "refs/remotes/upstream/fix"]).spokenTitle == "fix, in sync with origin/fix, backup/fix and upstream/fix")
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
        let localWidth = try #require(CommitRowLayout(content: local, size: size).badges.first).width
        let remoteWidth = try #require(CommitRowLayout(content: remote, size: size).badges.first).width
        let style = CommitCellView.BadgeLook.of(.remoteBranch).remoteStyle
        #expect(remoteWidth >= localWidth + CommitRowLayout.width(of: "origin", in: style))
    }

    @Test func aBadgeThatStandsForItsUpstreamIsWiderForItsCloud() throws {
        let plain = CommitRowContent(shortID: "abcd1234", badges: [Badge(title: "feature", kind: .branch)], subject: "A subject")
        let merged = CommitRowContent(shortID: "abcd1234", badges: [Badge(title: "feature", kind: .branch, upstream: "refs/remotes/origin/feature")], subject: "A subject")
        let size = NSSize(width: 1200, height: 28)
        let plainWidth = try #require(CommitRowLayout(content: plain, size: size).badges.first).width
        let mergedWidth = try #require(CommitRowLayout(content: merged, size: size).badges.first).width
        #expect(mergedWidth > plainWidth)
    }

    @Test func aBadgeIsWiderForEachRemoteItStandsFor() throws {
        func width(others: [String]) throws -> CGFloat {
            let badge = Badge(title: "feature", kind: .branch, upstream: "refs/remotes/origin/feature", otherRemoteBranches: others)
            let content = CommitRowContent(shortID: "abcd1234", badges: [badge], subject: "A subject")
            return try #require(CommitRowLayout(content: content, size: NSSize(width: 1200, height: 28)).badges.first).width
        }
        #expect(Badge(title: "feature", kind: .branch).cloudCount == 0)
        #expect(Badge(title: "feature", kind: .branch, upstream: "refs/remotes/origin/feature", otherRemoteBranches: ["refs/remotes/upstream/feature"]).cloudCount == 2)
        let one = try width(others: [])
        let two = try width(others: ["refs/remotes/upstream/feature"])
        let three = try width(others: ["refs/remotes/backup/feature", "refs/remotes/upstream/feature"])
        #expect(two > one)
        #expect(three - two == two - one)
    }

    @Test func aBadgesTooltipSaysWhatItStandsFor() throws {
        let cell = CommitCellView()
        cell.frame = NSRect(x: 0, y: 0, width: 1200, height: 28)
        cell.content = Self.content(ofRow: 1)
        let layout = CommitRowLayout(content: Self.content(ofRow: 1), size: cell.bounds.size)
        let second = NSPoint(x: layout.badges[1].midX, y: layout.badges[1].midY)
        #expect(cell.view(cell, stringForToolTip: 0, point: second, userData: nil) == "feature")
        #expect(cell.view(cell, stringForToolTip: 0, point: NSPoint(x: layout.badges[0].midX, y: 14), userData: nil) == "main, current branch")
    }

    /// A right-click in the middle of a row, as the table gets it.
    static func rightClick(onRow row: Int, in table: NSTableView) throws -> NSEvent {
        let frame = table.rect(ofRow: row)
        return try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: table.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    static func outlines(in table: NSTableView) -> [CommitRowOutlineView] {
        (table.superview?.subviews ?? []).compactMap { $0 as? CommitRowOutlineView }
    }

    @Test func aRowHasAnOutlineJustOutsideItsFillWhileItsMenuIsOpen() throws {
        let list = List()
        let event = try Self.rightClick(onRow: 1, in: list.table)
        let menu = try #require(list.table.menu(for: event))
        #expect(Self.outlines(in: list.table).isEmpty)

        // The event that comes with opening the menu needn't be over the row.
        let elsewhere = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: -100, y: -100), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        list.table.willOpenMenu(menu, with: elsewhere)
        let outline = try #require(Self.outlines(in: list.table).first)
        let width = CommitRowOutlineView.lineWidth
        let fill = CommitRowView.selectionFrame(inRow: list.table.rect(ofRow: 1))
        #expect(outline.frame == fill.insetBy(dx: -width, dy: -width))
        // The table draws its square outline around the row it says was clicked.
        #expect(list.table.clickedRow == -1)

        // The table puts its rows above its other views when it loads them again.
        list.table.reloadData()
        #expect(list.table.superview?.subviews.last === outline)

        list.table.didCloseMenu(menu, with: event)
        #expect(Self.outlines(in: list.table).isEmpty)
    }

    @Test func aRowWithoutAMenuHasNoOutlineToOpen() throws {
        let list = List()
        list.offersAMenu = false
        #expect(list.table.menu(for: try Self.rightClick(onRow: 0, in: list.table)) == nil)
    }

    @Test func anOutlineFollowsTheFillsCornersAndLeavesItsMiddleEmpty() throws {
        let row = NSRect(x: 0, y: 0, width: 400, height: CommitCellView.height)
        let outline = CommitRowOutlineView(aroundRow: row)
        let image = try #require(outline.bitmapImageRepForCachingDisplay(in: outline.bounds))
        outline.cacheDisplay(in: outline.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / outline.bounds.width
        func isDrawn(x: CGFloat, y: CGFloat) -> Bool {
            (image.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0) > 0.5
        }
        // Along the straight part of an edge, where the line is, then where the fill goes.
        let width = CommitRowOutlineView.lineWidth
        #expect(isDrawn(x: outline.bounds.midX, y: width / 2))
        #expect(!isDrawn(x: outline.bounds.midX, y: width + 1))
        // Across a corner: a square line would be at the first point, and the curve is at the second.
        #expect(!isDrawn(x: 1, y: 1))
        #expect(isDrawn(x: 3, y: 3))
        #expect(!isDrawn(x: 6, y: 6))
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

    @Test func goesToTheRowAwayFromABadge() {
        let list = List()
        let frame = list.table.frameOfCell(atColumn: 0, row: 1)
        // Past the badges, and the row above, which has none.
        list.controller.doubleClick(at: NSPoint(x: frame.maxX - 20, y: frame.midY))
        list.controller.doubleClick(at: NSPoint(x: list.middle(ofBadge: 1).x, y: frame.minY - 5))
        #expect(list.wentTo == [1, 0])
        #expect(list.checkedOut.isEmpty)
    }

    @Test func goesToTheRowOnABadgeThatCantBeCheckedOut() {
        let list = List()
        // The current branch, a tag and a detached `HEAD`.
        for index in [0, 3, 4] { list.controller.doubleClick(at: list.middle(ofBadge: index)) }
        #expect(list.wentTo == [1, 1, 1])
        #expect(list.checkedOut.isEmpty)
    }

    @Test func aBadgeThatCanBeCheckedOutDoesntGoToItsRow() {
        let list = List()
        list.controller.doubleClick(at: list.middle(ofBadge: 1))
        #expect(list.wentTo.isEmpty)
    }

    @Test func doesNothingBelowTheLastRow() {
        let list = List()
        list.controller.doubleClick(at: NSPoint(x: list.middle(ofBadge: 1).x, y: 10_000))
        #expect(list.wentTo.isEmpty)
        #expect(list.checkedOut.isEmpty)
    }

    @Test func missesTheGapsBetweenBadges() {
        let list = List()
        let frame = list.table.frameOfCell(atColumn: 0, row: 1)
        let layout = CommitRowLayout(content: Self.content(ofRow: 1), size: frame.size)
        let gap = (layout.badges[1].maxX + layout.badges[2].minX) / 2
        #expect(list.controller.badge(at: NSPoint(x: frame.minX + gap, y: frame.midY)) == nil)
    }

    @Test func keepsTheSubjectAfterTheBadges() throws {
        var content = Self.content(ofRow: 1)
        content.lanes = CommitRowIndentTests.lanes(columns: 3)
        let layout = CommitRowLayout(content: content, size: NSSize(width: 1200, height: 28))
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
        let layout = CommitRowLayout(content: Self.content(ofRow: 1), size: NSSize(width: 160, height: 28))
        #expect(layout.badges.count < Self.badges.count)
        #expect(layout.badges.allSatisfy { $0.maxX <= layout.subjectMaxX })
    }
}

/// Where a row's text starts, which depends on nothing but the row, so that it
/// stays in place while other rows scroll past.
@Suite(.timeLimit(.minutes(1)))
struct CommitRowIndentTests {
    typealias Badge = CommitRowContent.Badge

    static let size = NSSize(width: 1200, height: 28)
    static let badge = Badge(title: "feature", kind: .branch, refName: "refs/heads/feature")

    /// A row with its dot in the first column and a line in each of `columns` columns.
    static func lanes(columns: Int) -> LaneLayout.Row {
        LaneLayout.Row(column: 0, lines: (0..<columns).map { LaneLayout.Line(top: .column($0), bottom: .column($0)) })
    }

    static func layout(columns: Int?, width: CGFloat = size.width) -> CommitRowLayout {
        let content = CommitRowContent(
            shortID: "abcd1234",
            subject: "A subject",
            author: "An author",
            date: "A date",
            lanes: columns.map { lanes(columns: $0) }
        )
        return CommitRowLayout(content: content, size: NSSize(width: width, height: size.height))
    }

    @Test func theTextMovesRightAColumnAtATime() {
        let widths = (1...LaneRenderer.maxColumns).map { Self.layout(columns: $0).subjectX }
        for (narrower, wider) in zip(widths, widths.dropFirst()) {
            #expect(wider - narrower == LaneRenderer.spacing)
        }
    }

    @Test func theTextClearsTheRightmostLine() {
        for columns in 1...LaneRenderer.maxColumns {
            let rightmost = CommitRowLayout.graphX + LaneRenderer.spacing * (CGFloat(columns) - 0.5)
            #expect(Self.layout(columns: columns).subjectX > rightmost + LaneRenderer.ringRadius)
        }
    }

    @Test func theTextFollowsTheLinesRatherThanTheDot() {
        let dotOnTheLeft = LaneLayout.Row(column: 0, lines: [LaneLayout.Line(top: .column(4), bottom: .column(4))])
        let dotOnTheRight = LaneLayout.Row(column: 4, lines: [])
        let left = CommitRowLayout(content: CommitRowContent(shortID: "a", lanes: dotOnTheLeft), size: Self.size)
        let right = CommitRowLayout(content: CommitRowContent(shortID: "a", lanes: dotOnTheRight), size: Self.size)
        #expect(left.subjectX == right.subjectX)
        #expect(left.subjectX == Self.layout(columns: 5).subjectX)
    }

    @Test func aRowWiderThanTheGraphShowsDoesntPushTheTextFurther() {
        let widest = Self.layout(columns: LaneRenderer.maxColumns).subjectX
        #expect(Self.layout(columns: LaneRenderer.maxColumns + 20).subjectX == widest)
    }

    @Test func aRowWithoutAGraphStartsAtTheInset() {
        // The first column's dot is centered on the inset that text starts at.
        #expect(Self.layout(columns: nil).subjectX == CommitRowLayout.graphX + LaneRenderer.spacing / 2)
    }

    @Test func badgesStartWhereTheTextWould() throws {
        let content = CommitRowContent(shortID: "a", badges: [Self.badge], lanes: Self.lanes(columns: 4))
        let badge = try #require(CommitRowLayout(content: content, size: Self.size).badges.first)
        #expect(badge.minX == Self.layout(columns: 4).subjectX)
    }

    /// The row's columns on the right, as what each says and where it goes.
    static func rightColumns(_ layout: CommitRowLayout) -> [String] {
        layout.columns.map { "\($0.text ?? "") at \($0.x) width \($0.width)" }
    }

    @Test func everyRowShowsTheSameColumnsOnTheRight() {
        for width in stride(from: CGFloat(200), through: 900, by: 20) {
            let expected = Self.rightColumns(Self.layout(columns: 1, width: width))
            for columns in [nil, 3, LaneRenderer.maxColumns, LaneRenderer.maxColumns + 20] {
                #expect(Self.rightColumns(Self.layout(columns: columns, width: width)) == expected, "at width \(width)")
            }
        }
    }

    @Test func theColumnsOnTheRightLeaveEvenTheWidestRowSomeOfItsSubject() {
        for width in stride(from: CGFloat(200), through: 900, by: 10) {
            let layout = Self.layout(columns: LaneRenderer.maxColumns, width: width)
            guard !layout.columns.isEmpty else { continue }
            #expect(layout.subjectMaxX - layout.subjectX >= 120, "at width \(width)")
        }
    }

    @Test func aRowsBadgeStaysPutWhenAWiderRowComesIntoView() throws {
        // Row 1 needs one column, and row 40 needs the most a graph shows.
        let content: (Int) -> CommitRowContent = { row in
            CommitRowContent(
                shortID: "a",
                badges: row == 1 ? [Self.badge] : [],
                lanes: Self.lanes(columns: row == 40 ? LaneRenderer.maxColumns : 1)
            )
        }
        let controller = CommitTableController(source: CommitTableController.Source(
            count: { 100 },
            content: content,
            loadText: { _ in [] },
            selectRows: { _ in }
        ))
        let table = try #require(controller.scrollView.documentView as? NSTableView)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        table.tableColumns[0].width = 800
        controller.reloadData()
        controller.scrollView.layoutSubtreeIfNeeded()

        let frame = table.frameOfCell(atColumn: 0, row: 1)
        let badge = try #require(CommitRowLayout(content: content(1), size: frame.size).badges.first)
        let middle = NSPoint(x: frame.minX + badge.midX, y: frame.minY + badge.midY)
        let place = CommitTableController.BadgePlace(row: 1, index: 0)
        #expect(controller.badge(at: middle) == place)

        // Scrolling past the wide row leaves the same point on the same badge.
        table.scrollRowToVisible(40)
        #expect(table.rows(in: table.visibleRect).contains(40))
        table.scrollRowToVisible(1)
        #expect(controller.badge(at: middle) == place)
    }
}
